<#
.SYNOPSIS
  Delegate one subtask to a Cursor (agent) or Antigravity (agy) CLI worker, run
  headlessly in an isolated git worktree. Prints one compact JSON summary.

.DESCRIPTION
  Guardrails (why this script is allow-listed instead of the raw CLIs):
    - The worker ALWAYS runs in a dedicated git worktree on branch xagent/<TaskId>,
      never in the main checkout.
    - Hard timeout; the whole process tree is killed when it expires.
    - Every prompt, stdout and stderr is logged to <repo>\.xagent\runs\<TaskId>\.
    - The worker is told not to commit or push; the lead reviews and merges.

  Layout:
    <repo>\.xagent\runs\<TaskId>\<stamp>-<agent>.{prompt.txt,stdout.json,stderr.txt}
    <repoParent>\<repoName>.xagent\<TaskId>\          (worktree)
    <worktree>\.xagent\task.md, result.json             (hand-off files)
  .xagent/ is added to the repo's .git/info/exclude (not to .gitignore).

.EXAMPLE
  pwsh -NoProfile -File delegate.ps1 -Agent agy -Repo D:\proj -TaskId add-mul -TaskFile D:\proj\.xagent\tasks\add-mul.md
  pwsh -NoProfile -File delegate.ps1 -Agent agy -Repo D:\proj -TaskId add-mul -TaskFile review1.md -Resume <conversation_id>
  pwsh -NoProfile -File delegate.ps1 -Cleanup -Repo D:\proj -TaskId add-mul
#>
[CmdletBinding()]
param(
    [ValidateSet('cursor', 'agy')] [string]$Agent,
    [Parameter(Mandatory)] [string]$Repo,
    [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9][a-z0-9-]{0,48}$')] [string]$TaskId,
    [string]$TaskFile,
    [string]$Base = 'HEAD',
    [string]$Resume,
    [string]$Model,
    [ValidateRange(30, 3600)] [int]$TimeoutSec = 900,
    [switch]$Cleanup
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Out-Summary([hashtable]$h) { $h | ConvertTo-Json -Depth 6 -Compress; exit 0 }
function Fail([string]$msg) { @{ ok = $false; error = $msg } | ConvertTo-Json -Compress; exit 1 }
function Invoke-Git { param([Parameter(ValueFromRemainingArguments)] $a) $out = & git.exe @a 2>&1; if ($LASTEXITCODE -ne 0) { throw "git $($a -join ' '): $out" }; $out }
function Quote([string]$s) { if ($s -match '[\s"]') { '"' + ($s -replace '"', '\"') + '"' } else { $s } }

# ---------- resolve repo & worktree paths ----------
$Repo = (Resolve-Path -LiteralPath $Repo).Path.TrimEnd('\')
$top = (Invoke-Git -C $Repo rev-parse --show-toplevel | Select-Object -First 1) -replace '/', '\'
if ($top.TrimEnd('\') -ne $Repo) { Fail "Repo must be the top level of a git repo (got $top)" }

$repoName = Split-Path $Repo -Leaf
$wtRoot = Join-Path (Split-Path $Repo -Parent) "$repoName.xagent"
$wt = Join-Path $wtRoot $TaskId
$branch = "xagent/$TaskId"
$runDir = Join-Path $Repo ".xagent\runs\$TaskId"

# keep .xagent/ out of git status in every worktree (info/exclude is shared)
$commonDir = (Invoke-Git -C $Repo rev-parse --git-common-dir | Select-Object -First 1)
if (-not [IO.Path]::IsPathRooted($commonDir)) { $commonDir = Join-Path $Repo $commonDir }
$exclude = Join-Path $commonDir 'info\exclude'
New-Item -ItemType Directory -Force (Split-Path $exclude) | Out-Null
if (-not (Test-Path $exclude) -or -not (Select-String -LiteralPath $exclude -SimpleMatch '.xagent/' -Quiet)) {
    Add-Content -LiteralPath $exclude -Value '.xagent/'
}

# ---------- cleanup mode ----------
if ($Cleanup) {
    $notes = @()
    if (Test-Path $wt) {
        $dirtyTracked = @(& git -C $wt status --porcelain --untracked-files=no 2>$null)
        & git -C $Repo merge-base --is-ancestor $branch HEAD 2>$null
        $merged = ($LASTEXITCODE -eq 0)
        if ($dirtyTracked.Count -gt 0) { Fail "Worktree $wt has uncommitted changes to tracked files; not removing" }
        if (-not $merged) { Fail "Branch $branch is not merged into $Repo HEAD; not removing worktree" }
        # merged + no tracked changes: only untracked leftovers (__pycache__, .xagent logs) remain
        Invoke-Git -C $Repo worktree remove --force $wt | Out-Null; $notes += "removed worktree $wt"
    }
    & git -C $Repo branch -d $branch 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $notes += "deleted merged branch $branch" }
    else { $notes += "branch $branch kept (not merged, or missing); delete manually with git branch -D if intended" }
    Out-Summary @{ ok = $true; cleanup = $notes }
}

if (-not $Agent) { Fail '-Agent is required (cursor|agy)' }
if (-not $TaskFile) { Fail '-TaskFile is required' }
$TaskFile = (Resolve-Path -LiteralPath $TaskFile).Path

# ---------- create or reuse worktree ----------
if (-not (Test-Path $wt)) {
    New-Item -ItemType Directory -Force $wtRoot | Out-Null
    & git -C $Repo rev-parse --verify --quiet "refs/heads/$branch" | Out-Null
    if ($LASTEXITCODE -eq 0) { Invoke-Git -C $Repo worktree add $wt $branch | Out-Null }
    else { Invoke-Git -C $Repo worktree add -b $branch $wt $Base | Out-Null }
}
$wtTop = (Invoke-Git -C $wt rev-parse --show-toplevel | Select-Object -First 1) -replace '/', '\'
if ($wtTop.TrimEnd('\') -ne $wt -or $wt -eq $Repo) { Fail "Safety check failed: worktree toplevel is $wtTop, expected $wt" }

# ---------- hand-off files ----------
$xDir = Join-Path $wt '.xagent'
New-Item -ItemType Directory -Force $xDir, $runDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
# Unique file name per run: a resumed worker must not assume it already read it.
$taskName = "task-$stamp.md"
Copy-Item -LiteralPath $TaskFile -Destination (Join-Path $xDir $taskName) -Force
$resultFile = Join-Path $xDir 'result.json'
Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue

$contract = 'Work only inside this directory. Do NOT git commit or git push. ' +
            'When finished, write a JSON object to .xagent/result.json with keys: status (done|blocked|partial), summary (describe what you did in THIS run), files_changed (array), tests_run (command and pass/fail), open_questions (array). ' +
            'Also reply with that same JSON object as your final message.'
$prompt = if ($Resume) {
    "FOLLOW-UP from the lead reviewer: there are NEW instructions you have not seen yet in .xagent/$taskName. " +
    'Read that file now and apply the requested changes to the current files. ' + $contract
} else {
    "You are a sub-agent working in this git worktree. Your task is in .xagent/$taskName - read it and complete it. " + $contract
}

$logBase = Join-Path $runDir "$stamp-$Agent"
$stdoutF = "$logBase.stdout.json"; $stderrF = "$logBase.stderr.txt"
Set-Content -LiteralPath "$logBase.prompt.txt" -Value ($prompt + "`n`n--- $taskName ---`n" + (Get-Content -Raw -LiteralPath $TaskFile))

# ---------- build command ----------
$skillDir = Split-Path $PSScriptRoot -Parent
switch ($Agent) {
    'cursor' {
        $launcher = Join-Path $env:LOCALAPPDATA 'cursor-agent\cursor-agent.ps1'
        if (-not (Test-Path $launcher)) { Fail "Cursor CLI not found at $launcher" }
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $cliArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher,
                     '-p', '--force', '--trust', '--output-format', 'json', '--workspace', $wt)
        if ($Resume) { $cliArgs += @('--resume', $Resume) }
        if ($Model) { $cliArgs += @('--model', $Model) }
        $cliArgs += $prompt
        $env:CURSOR_INVOKED_AS = 'agent.cmd'
    }
    'agy' {
        $exe = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'
        if (-not (Test-Path $exe)) { Fail "Antigravity CLI not found at $exe" }
        $schema = Join-Path $skillDir 'result.schema.json'
        $cliArgs = @('-p', $prompt, '--output-format', 'json', '--json-schema', $schema, '--dangerously-skip-permissions')
        if ($Resume) { $cliArgs += @('--conversation', $Resume) }
        if ($Model) { $cliArgs += @('--model', $Model) }
    }
}

# ---------- run with timeout ----------
$sw = [Diagnostics.Stopwatch]::StartNew()
$proc = Start-Process -FilePath $exe -ArgumentList (($cliArgs | ForEach-Object { Quote $_ }) -join ' ') `
    -WorkingDirectory $wt -RedirectStandardOutput $stdoutF -RedirectStandardError $stderrF -NoNewWindow -PassThru
$timedOut = -not $proc.WaitForExit($TimeoutSec * 1000)
if ($timedOut) { & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null; $proc.WaitForExit(10000) | Out-Null }
$sw.Stop()
$exitCode = if ($timedOut) { -1 } else { $proc.ExitCode }

# ---------- parse output ----------
$raw = if (Test-Path $stdoutF) { Get-Content -Raw -LiteralPath $stdoutF } else { '' }
$j = $null; $sessionId = $null; $finalText = $null; $cliStatus = $null
if ($raw) {
    $line = ($raw -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    try {
        $j = $line | ConvertFrom-Json
        if ($Agent -eq 'cursor') { $sessionId = $j.session_id; $finalText = $j.result; $cliStatus = $j.subtype }
        else { $sessionId = $j.conversation_id; $finalText = $j.response; $cliStatus = $j.status }
    } catch { $finalText = $raw }
}

$result = $null
if ($Agent -eq 'agy' -and $j -and $j.PSObject.Properties['structured_output'] -and $j.structured_output) { $result = $j.structured_output }
if (-not $result -and (Test-Path $resultFile)) { try { $result = Get-Content -Raw -LiteralPath $resultFile | ConvertFrom-Json } catch { } }
if (-not $result -and $finalText) {
    $t = ($finalText -replace '(?s)^\s*```(json)?\s*', '' -replace '(?s)\s*```\s*$', '')
    try { $result = $t | ConvertFrom-Json } catch { }
}

$changes = @(& git -C $wt status --porcelain --untracked-files=all 2>$null | Where-Object { $_ -notmatch '\.xagent/' })
$diffStat = (& git -C $wt diff --shortstat 2>$null) -join ' '
$stderrTail = if (Test-Path $stderrF) {
    ((Get-Content -LiteralPath $stderrF | Where-Object { $_ -notmatch 'logging before google.Init' }) | Select-Object -Last 5) -join "`n"
} else { '' }

Out-Summary @{
    ok          = (-not $timedOut -and $exitCode -eq 0)
    agent       = $Agent
    taskId      = $TaskId
    worktree    = $wt
    branch      = $branch
    exitCode    = $exitCode
    timedOut    = $timedOut
    seconds     = [int]$sw.Elapsed.TotalSeconds
    cliStatus   = $cliStatus
    sessionId   = $sessionId
    result      = $(if ($result) { $result } elseif ($finalText) { $finalText.Substring(0, [Math]::Min(1500, $finalText.Length)) } else { $null })
    changes     = $changes
    diffStat    = $diffStat
    stderrTail  = $stderrTail
    logs        = $logBase
}
