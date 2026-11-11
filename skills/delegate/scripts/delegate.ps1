<#
.SYNOPSIS
  Delegate one subtask to a Cursor CLI worker or read-only reviewer, run headlessly
  in an isolated git worktree. Prints one compact JSON summary.

.DESCRIPTION
  Guardrails (why this script is allow-listed instead of the raw CLI):
    - The worker ALWAYS runs in a dedicated git worktree on branch xagent/<TaskId>,
      never in the main checkout. Read-only runs (review, council) get a detached,
      throwaway worktree <TaskId>-<Seat|Agent>.
    - Hard timeout; the whole process tree is killed when it expires.
    - Known secret variables are removed from the worker's environment (best effort).
    - Read-only runs have project rule files (AGENTS.md, CLAUDE.md, .cursor/ ...) removed
      from their worktree, unless -KeepRuleFiles; they are restored before the read-only check.
    - Every prompt, stdout and stderr is logged to <repo>\.xagent\runs\<TaskId>\.
    - The worker is told not to commit or push; the lead reviews and merges.
    - Antigravity (agy) is disabled unless models.json sets agy.enabled (T0: its FAQ forbids
      wrapping agy in third-party agents on consumer plans).

  Layout:
    <repo>\.xagent\runs\<TaskId>\<stamp>-<Seat|Agent>.{prompt.txt,stdout.json,stderr.txt,pid}
    <repoParent>\<repoName>.xagent\<TaskId>[-<Seat|Agent>]\   (worktree)
    <worktree>\.xagent\task-<stamp>.md, result.json, base.sha  (hand-off files)
    $env:XAGENT_LOG_DIR (default %LOCALAPPDATA%\xagent)\runs.jsonl   (one line per run)
  .xagent/ is added to the repo's .git/info/exclude (not to .gitignore).

.EXAMPLE
  pwsh -NoProfile -File delegate.ps1 -Agent cursor -Repo D:\proj -TaskId add-mul -TaskFile D:\proj\.xagent\tasks\add-mul.md
  pwsh -NoProfile -File delegate.ps1 -Agent cursor -Repo D:\proj -TaskId add-mul -TaskFile review1.md -Resume <session_id>
  pwsh -NoProfile -File delegate.ps1 -Agent cursor -Profile review -Persona zoom_out -Model grok-4.7-medium -Repo D:\proj -TaskId r1-zo -TaskFile t.md
  pwsh -NoProfile -File delegate.ps1 -Agent cursor -Profile council -Seat glm -Repo D:\proj -TaskId c1 -TaskFile q.md
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
    [ValidateSet('code', 'code-hard', 'review', 'council')] [string]$Profile = 'code',
    [ValidatePattern('^[a-z_]+$')] [string]$Persona,   # review profile: personas/<name>.md (EGM goldfish)
    [ValidatePattern('^[A-Za-z0-9._-]+\.md$')] [string]$Standard,   # review: a file in personas/ (default: personas/standards.json)
    [string[]]$TargetFile,                             # extra files copied into the worktree's .xagent/
    [switch]$KeepRuleFiles,                            # read-only runs: keep AGENTS.md, .cursor/ etc. (they are the target)
    [ValidatePattern('^[a-z0-9]+$')] [string]$Seat,    # names the read-only worktree and logs (council: grok|glm)
    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')] [string]$Feature,   # written to runs.jsonl and the pid file
    [string]$Model,
    [ValidateRange(30, 3600)] [int]$TimeoutSec = 900,
    [switch]$Cleanup,
    [switch]$Discard   # with -Cleanup: remove an UNMERGED worker worktree+branch, saving its diff to the run logs
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Decode git's output as UTF-8, not the console code page (437 here), so non-ASCII file names survive (dogfood D14).
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

function Out-Summary([hashtable]$h) { $h | ConvertTo-Json -Depth 6 -Compress; exit 0 }
function Fail([string]$msg) { @{ ok = $false; error = $msg } | ConvertTo-Json -Compress; exit 1 }
function Invoke-Git { param([Parameter(ValueFromRemainingArguments)] $a) $out = & git.exe @a 2>&1; if ($LASTEXITCODE -ne 0) { throw "git $($a -join ' '): $out" }; $out }
function Quote([string]$s) {
    # MSVCRT/Go command-line escaping: backslashes are literal unless they precede a quote
    if ($s -and $s -notmatch '[\s"]') { return $s }
    $s = [regex]::Replace($s, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
    $s = [regex]::Replace($s, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
    '"' + $s + '"'
}

# Project rule files a reviewer must not load: AGENTS.md, CLAUDE.md, GEMINI.md, .cursorrules, and
# anything under .cursor/ or .agents/, at any depth. Only tracked files exist in a fresh worktree.
$ruleFilePattern = '(^|/)(AGENTS\.md|CLAUDE\.md|GEMINI\.md|\.cursorrules)$|(^|/)(\.cursor|\.agents)/'
function Get-RuleFiles([string]$dir) { @(& git -C $dir ls-files 2>$null | Where-Object { $_ -match $ruleFilePattern }) }
function Restore-RuleFiles([string]$dir) {
    # put back any tracked rule file that is missing from the worktree
    $missing = @(& git -C $dir ls-files --deleted 2>$null | Where-Object { $_ -match $ruleFilePattern })
    if ($missing.Count -gt 0) { & git -C $dir checkout HEAD -- @missing 2>&1 | Out-Null }
}

# ---------- resolve repo & worktree paths ----------
$Repo = (Resolve-Path -LiteralPath $Repo).Path.TrimEnd('\')
$top = (Invoke-Git -C $Repo rev-parse --show-toplevel | Select-Object -First 1) -replace '/', '\'
if ($top.TrimEnd('\') -ne $Repo) { Fail "Repo must be the top level of a git repo (got $top)" }

$repoName = Split-Path $Repo -Leaf
$wtRoot = Join-Path (Split-Path $Repo -Parent) "$repoName.xagent"
$wt = Join-Path $wtRoot $TaskId
$branch = "xagent/$TaskId"
$runDir = Join-Path $Repo ".xagent\runs\$TaskId"

# ---------- model profile ----------
$skillDir = Split-Path $PSScriptRoot -Parent
$cfg = Get-Content -Raw -LiteralPath (Join-Path $skillDir 'models.json') | ConvertFrom-Json
$prof = $cfg.profiles.$Profile
$readOnly = [bool]$prof.readOnly
$isReview = ($Profile -eq 'review')
$suffix = if ($Seat) { $Seat } elseif ($Agent) { $Agent } else { 'cursor' }
if ($readOnly) {
    # read-only runs (review, council seats) each get a detached, throwaway worktree
    $wt = Join-Path $wtRoot "$TaskId-$suffix"
    $branch = $null
}

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
    # read-only worktrees of this task: <TaskId>-<label>, detached. The label has no '-', so the
    # read-only worktrees of a longer task id (<TaskId>-pc-cursor) are never matched.
    $detached = @{}
    $cur = $null
    foreach ($l in @(& git -C $Repo worktree list --porcelain 2>$null)) {
        if ($l -like 'worktree *') { $cur = ($l.Substring(9) -replace '/', '\').TrimEnd('\') }
        elseif ($l -eq 'detached' -and $cur) { $detached[$cur.ToLowerInvariant()] = $true }
    }
    $prefix = [regex]::Escape($TaskId)
    foreach ($d in @(Get-ChildItem -LiteralPath $wtRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^$prefix-[a-z0-9]+$" })) {
        $cwt = $d.FullName.TrimEnd('\')
        if (-not $detached.ContainsKey($cwt.ToLowerInvariant())) { continue }   # a worker worktree of another task
        Restore-RuleFiles $cwt
        $dirty = @(& git -C $cwt status --porcelain --untracked-files=no 2>$null)
        if ($dirty.Count -gt 0) { Fail "Read-only worktree $cwt has tracked changes (read-only violation?); inspect before removing" }
        Invoke-Git -C $Repo worktree remove --force $cwt | Out-Null; $notes += "removed read-only worktree $cwt"
    }
    if ($readOnly) { Out-Summary @{ ok = $true; cleanup = $notes } }
    $wt = Join-Path $wtRoot $TaskId
    if ($Discard) {
        # explicit throw-away of an unmerged worker branch (e.g. a failed attempt); keep its diff in the logs
        if (Test-Path $wt) {
            New-Item -ItemType Directory -Force $runDir | Out-Null
            $patch = Join-Path $runDir ("discarded-{0}.patch" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            & git -C $wt add -A -- . ':!.xagent' 2>$null | Out-Null
            & git -C $wt diff --cached HEAD | Set-Content -LiteralPath $patch
            Invoke-Git -C $Repo worktree remove --force $wt | Out-Null; $notes += "discarded worktree $wt (diff saved to $patch)"
        }
        & git -C $Repo branch -D $branch 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $notes += "deleted branch $branch" }
        Out-Summary @{ ok = $true; cleanup = $notes }
    }
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

if (-not $Agent) { Fail '-Agent is required (cursor)' }
if ($Agent -eq 'agy' -and -not ($cfg.PSObject.Properties['agy'] -and $cfg.agy.enabled)) {
    Fail "-Agent agy is disabled: $($cfg.agy.reason). Use -Agent cursor."
}
if (-not $TaskFile) { Fail '-TaskFile is required' }
$TaskFile = (Resolve-Path -LiteralPath $TaskFile).Path

if (-not $Model) {
    if ($Profile -eq 'council') {
        if (-not $Seat) { Fail "-Profile council needs -Seat (one of: $(($prof.seats.PSObject.Properties.Name) -join ', ')) or -Model" }
        if (-not $prof.seats.PSObject.Properties[$Seat]) { Fail "No council seat '$Seat' in models.json (seats: $(($prof.seats.PSObject.Properties.Name) -join ', '))" }
        $Model = $prof.seats.$Seat
    } elseif ($prof.PSObject.Properties['model']) { $Model = $prof.model }
}
if (-not $Model) { Fail "No model configured for profile '$Profile' in models.json; pass -Model" }
foreach ($pat in $cfg.blockedModelPatterns) {
    if ($Model -match $pat) { Fail "Model '$Model' is blocked by models.json (pattern '$pat')" }
}
$targets = @()
foreach ($t in @($TargetFile | Where-Object { $_ } | ForEach-Object { $_ -split ',' } | Where-Object { $_.Trim() })) {
    if (-not (Test-Path -LiteralPath $t.Trim() -PathType Leaf)) { Fail "-TargetFile not found: $t" }
    $targets += (Resolve-Path -LiteralPath $t.Trim()).Path
}
$personaFile = $null; $stdFile = $null
if ($isReview) {
    if (-not $Persona) { Fail "-Profile review requires -Persona (one of: $((Get-ChildItem (Join-Path $skillDir 'personas') -Filter *.md | Where-Object { $_.Name -ne 'README.md' -and $_.Name -notlike '*-standard.md' } | ForEach-Object BaseName) -join ', '))" }
    $personaFile = Join-Path $skillDir "personas\$Persona.md"
    if (-not (Test-Path $personaFile)) { Fail "Persona not found: $personaFile" }
    # standard: -Standard, else the persona's default in personas/standards.json, else none
    $std = $Standard
    if (-not $std) {
        $stdMap = Get-Content -Raw -LiteralPath (Join-Path $skillDir 'personas\standards.json') | ConvertFrom-Json
        if ($stdMap.PSObject.Properties[$Persona]) { $std = $stdMap.$Persona }
    }
    if ($std) {
        $stdFile = Join-Path $skillDir "personas\$std"
        if (-not (Test-Path -LiteralPath $stdFile)) { Fail "Standard not found: $stdFile" }
    }
}

# ---------- create or reuse worktree ----------
$created = $false
if (-not (Test-Path $wt)) {
    New-Item -ItemType Directory -Force $wtRoot | Out-Null
    if ($readOnly) { Invoke-Git -C $Repo worktree add --detach $wt $Base | Out-Null }
    else {
        & git -C $Repo rev-parse --verify --quiet "refs/heads/$branch" | Out-Null
        if ($LASTEXITCODE -eq 0) { Invoke-Git -C $Repo worktree add $wt $branch | Out-Null }
        else { Invoke-Git -C $Repo worktree add -b $branch $wt $Base | Out-Null }
    }
    $created = $true
}
$wtTop = (Invoke-Git -C $wt rev-parse --show-toplevel | Select-Object -First 1) -replace '/', '\'
if ($wtTop.TrimEnd('\') -ne $wt -or $wt -eq $Repo) { Fail "Safety check failed: worktree toplevel is $wtTop, expected $wt" }

# ---------- hand-off files ----------
$xDir = Join-Path $wt '.xagent'
New-Item -ItemType Directory -Force $xDir, $runDir | Out-Null
# baseSha: the commit the worktree was created from (kept across resumed runs)
$baseFile = Join-Path $xDir 'base.sha'
if ($created -or -not (Test-Path $baseFile)) {
    $bs = if ($created) { Invoke-Git -C $wt rev-parse HEAD | Select-Object -First 1 }
          else { Invoke-Git -C $wt merge-base HEAD $Base | Select-Object -First 1 }
    Set-Content -LiteralPath $baseFile -Value $bs
}
$baseSha = (Get-Content -LiteralPath $baseFile | Select-Object -First 1).Trim()

$contract = 'Work only inside this directory. Do NOT git commit or git push. ' +
            'When finished, write a JSON object to .xagent/result.json with keys: status (done|blocked|partial), summary (describe what you did in THIS run), files_changed (array), tests_run (command and pass/fail), open_questions (array). ' +
            'Also reply with that same JSON object as your final message.'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
# Unique file name per run: a resumed worker must not assume it already read it.
$taskName = "task-$stamp.md"
if ($isReview) {
    $parts = @((Get-Content -Raw -LiteralPath $personaFile), "`n---`n# Caller parameters`n`nMode: REVIEW`n")
    if ($stdFile) {
        $parts += "Target Standard (follow it; this is the standard the persona refers to, including any resources/document_standards/ path):`n`n" + (Get-Content -Raw -LiteralPath $stdFile)
    }
    # Preflight reviewers see the task file but not what the harness adds when a worker runs it (dogfood D4).
    $parts += "Harness context: if the target is a worker task file, the worker that runs it also receives this fixed instruction from the harness, so do not report its contents as missing from the task: `"$contract`" The worker runs in an isolated git worktree of this repository, in PowerShell on Windows."
    $parts += "`n---`n# Target document (review this; the repository is available read-only for context)`n`n" + (Get-Content -Raw -LiteralPath $TaskFile)
    Set-Content -LiteralPath (Join-Path $xDir $taskName) -Value ($parts -join "`n")
} else {
    Copy-Item -LiteralPath $TaskFile -Destination (Join-Path $xDir $taskName) -Force
}
$targetNames = @()
foreach ($t in $targets) {
    $n = Split-Path $t -Leaf
    Copy-Item -LiteralPath $t -Destination (Join-Path $xDir $n) -Force
    $targetNames += ".xagent/$n"
}
$targetNote = if ($targetNames.Count -gt 0) { " The caller also copied these files for you to read: $($targetNames -join ', ')." } else { '' }
$resultFile = Join-Path $xDir 'result.json'
Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue

$councilContract = 'This is a READ-ONLY consultation: do NOT create, modify or delete any files, and do not run commands that change state. ' +
            'You may read any file in this repository for context. Think independently and be candid; disagreement is valuable, agreement for its own sake is not. ' +
            'Critique first: find the weakest points, edge cases and blind spots before affirming anything; earn your agreement. No flattery or validating adjectives. ' +
            'Reply ONLY with a JSON object with keys: position, reasoning, risks (array), objections (array), missed_considerations (array), confidence (low|medium|high), would_change_mind_if, changed_position (boolean).'
$prompt = if ($isReview) {
    "Read .xagent/$taskName. It starts with your reviewer persona and instructions, followed by the caller parameters and the target document.$targetNote " +
    'Follow the persona exactly. This is READ-ONLY: do not create, modify or delete files. Reply with your full review report as your final message.'
} elseif ($readOnly -and $Resume) {
    "NEW ROUND from the lead: read .xagent/$taskName, which contains the other council members' positions and/or follow-up questions you have not seen yet.$targetNote " +
    'Respond to their strongest arguments; concede where they are right, hold firm where they are not. ' + $councilContract
} elseif ($readOnly) {
    "You are one member of a design council of independent AI models from different vendors, advising a lead engineer. The question is in .xagent/$taskName - read it.$targetNote " + $councilContract
} elseif ($Resume) {
    "FOLLOW-UP from the lead reviewer: there are NEW instructions you have not seen yet in .xagent/$taskName.$targetNote " +
    'Read that file now and apply the requested changes to the current files. ' + $contract
} else {
    "You are a sub-agent working in this git worktree. Your task is in .xagent/$taskName - read it and complete it.$targetNote " + $contract
}

$logBase = Join-Path $runDir "$stamp-$suffix"
$stdoutF = "$logBase.stdout.json"; $stderrF = "$logBase.stderr.txt"; $pidF = "$logBase.pid"
Set-Content -LiteralPath "$logBase.prompt.txt" -Value ($prompt + "`n`n--- $taskName ---`n" + (Get-Content -Raw -LiteralPath $TaskFile))

# ---------- build command ----------
switch ($Agent) {
    'cursor' {
        $launcher = Join-Path $env:LOCALAPPDATA 'cursor-agent\cursor-agent.ps1'
        if (-not (Test-Path $launcher)) { Fail "Cursor CLI not found at $launcher" }
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $cliArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher,
                     '-p', '--trust', '--output-format', 'json', '--workspace', $wt, '--model', $Model)
        # review: ask mode (read-only Q&A; plan mode made composer narrate without reporting)
        # council: plan mode (read-only analysis). Neither gets --force.
        if ($isReview) { $cliArgs += @('--mode', 'ask') } elseif ($readOnly) { $cliArgs += @('--mode', 'plan') } else { $cliArgs += '--force' }
        if ($Resume) { $cliArgs += @('--resume', $Resume) }
        $cliArgs += $prompt
        $env:CURSOR_INVOKED_AS = 'agent.cmd'
    }
    'agy' {
        # Reachable only with agy.enabled in models.json (e.g. a future API-key setup).
        $exe = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'
        if (-not (Test-Path $exe)) { Fail "Antigravity CLI not found at $exe" }
        if ($readOnly) {
            # Headless plan mode auto-denies shell tools, and flash models like to `ls`/`cat` the hand-off file,
            # which aborts the run. So embed the file in the prompt itself. Not via stdin: with --mode plan agy
            # wraps the prompt as "/plan <prompt>" and takes "-" literally.
            $embedded = ($prompt +
                "`n`nIMPORTANT: shell/terminal commands are disabled in this session and any attempt aborts the run. Do NOT run commands. " +
                "You may use file viewing/search tools to read repository files if needed.`n`n" +
                "The full contents of .xagent/$taskName follow (already loaded for you; no need to open the file):`n`n" + (Get-Content -Raw -LiteralPath (Join-Path $xDir $taskName)))
            if ($embedded.Length -gt 28000) { Fail "Embedded review/council prompt too long for the Windows command line ($($embedded.Length) chars); shorten the target document" }
            $cliArgs = @('-p', $embedded, '--output-format', 'json', '--model', $Model)
        } else {
            $cliArgs = @('-p', $prompt, '--output-format', 'json', '--model', $Model)
        }
        # a schema is also what lets plan mode finish with a reply instead of attempting a plan write
        $schema = Join-Path $skillDir $(if ($isReview) { 'review.schema.json' } elseif ($readOnly) { 'council.schema.json' } else { 'result.schema.json' })
        $cliArgs += @('--json-schema', $schema)
        if ($readOnly) { $cliArgs += @('--mode', 'plan') } else { $cliArgs += '--dangerously-skip-permissions' }
        if ($Resume) { $cliArgs += @('--conversation', $Resume) }
    }
}

# ---------- worker environment: drop known secret variables (best effort; see design Risks) ----------
$secretPattern = '(_API_KEY|_TOKEN|_SECRET)$|^(AWS_|AZURE_|ANTHROPIC_|OPENAI_)|^(GH_TOKEN|GITHUB_TOKEN|SSH_AUTH_SOCK|GOOGLE_APPLICATION_CREDENTIALS|DATABASE_URL)$'
foreach ($name in @([Environment]::GetEnvironmentVariables().Keys)) {
    if ($name -match $secretPattern) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
}

# ---------- run with timeout ----------
$ruleFilesRemoved = @()
$sw = [Diagnostics.Stopwatch]::StartNew()
$timedOut = $false; $exitCode = -1
try {
    if ($readOnly -and -not $KeepRuleFiles) {
        $ruleFilesRemoved = @(Get-RuleFiles $wt)   # @(): a single file would otherwise come back as a string
        foreach ($rf in $ruleFilesRemoved) { Remove-Item -LiteralPath (Join-Path $wt $rf) -Force -ErrorAction SilentlyContinue }
    }
    $proc = Start-Process -FilePath $exe -ArgumentList (($cliArgs | ForEach-Object { Quote $_ }) -join ' ') `
        -WorkingDirectory $wt -RedirectStandardOutput $stdoutF -RedirectStandardError $stderrF -NoNewWindow -PassThru
    try {
        $me = Get-Process -Id $PID
        [ordered]@{
            pid = $PID; startTime = $me.StartTime.ToUniversalTime().ToString('o')
            childPid = $proc.Id; childStartTime = $proc.StartTime.ToUniversalTime().ToString('o')
            feature = $(if ($Feature) { $Feature } else { $null })
        } | ConvertTo-Json -Compress | Set-Content -LiteralPath $pidF
    } catch { }
    $timedOut = -not $proc.WaitForExit($TimeoutSec * 1000)
    if ($timedOut) { & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null; $proc.WaitForExit(10000) | Out-Null }
    $exitCode = if ($timedOut) { -1 } else { $proc.ExitCode }
} finally {
    $sw.Stop()
    Remove-Item -LiteralPath $pidF -Force -ErrorAction SilentlyContinue
    if (@($ruleFilesRemoved).Count -gt 0) { Restore-RuleFiles $wt }
}

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
    # models sometimes add a preamble or code fences; try the outermost {...} span
    $t = ($finalText -replace '(?s)^\s*```(json)?\s*', '' -replace '(?s)\s*```\s*$', '')
    try { $result = $t | ConvertFrom-Json } catch {
        $i = $finalText.IndexOf('{'); $k = $finalText.LastIndexOf('}')
        if ($i -ge 0 -and $k -gt $i) { try { $result = $finalText.Substring($i, $k - $i + 1) | ConvertFrom-Json } catch { } }
    }
}

$changes = @(& git -C $wt status --porcelain --untracked-files=all 2>$null | Where-Object { $_ -notmatch '\.xagent/' })
$diffStat = (& git -C $wt diff --shortstat 2>$null) -join ' '
$stderrTail = if (Test-Path $stderrF) {
    ((Get-Content -LiteralPath $stderrF | Where-Object { $_ -notmatch 'logging before google.Init' }) | Select-Object -Last 5) -join "`n"
} else { '' }

# ---------- normalized token usage + central run log (outside every repo) ----------
function N($o, [string[]]$names) { foreach ($n in $names) { if ($o -and $o.PSObject.Properties[$n]) { return [int64]$o.$n } }; return 0 }
$u = if ($j -and $j.PSObject.Properties['usage']) { $j.usage } else { $null }
$usage = [ordered]@{
    input      = N $u 'inputTokens', 'input_tokens'
    output     = N $u 'outputTokens', 'output_tokens'
    reasoning  = N $u 'reasoningTokens', 'thinking_tokens'
    cacheRead  = N $u 'cacheReadTokens', 'cache_read_tokens'
    cacheWrite = N $u 'cacheWriteTokens', 'cache_write_tokens'
}
$usage.total = $usage.input + $usage.output + $usage.reasoning   # Cursor's own figure also adds cacheRead
try {
    $logDir = if ($env:XAGENT_LOG_DIR) { $env:XAGENT_LOG_DIR } else { Join-Path $env:LOCALAPPDATA 'xagent' }
    New-Item -ItemType Directory -Force $logDir | Out-Null
    $rec = [ordered]@{ ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'); repo = $Repo; taskId = $TaskId; agent = $Agent; profile = $Profile; model = $Model }
    if ($Seat) { $rec.seat = $Seat }
    if ($Feature) { $rec.feature = $Feature }
    $rec.resumed = [bool]$Resume; $rec.seconds = [int]$sw.Elapsed.TotalSeconds; $rec.exitCode = $exitCode; $rec.timedOut = $timedOut; $rec.usage = $usage
    Add-Content -LiteralPath (Join-Path $logDir 'runs.jsonl') -Value ($rec | ConvertTo-Json -Compress -Depth 4)
} catch { }

$reviewFile = $null
if ($isReview -and ($finalText -or $result)) {
    # full report goes to a file: read it in sections (headroom compresses long tool output)
    $reviewFile = "$logBase.review.md"
    $body = $finalText
    if ($result -and $result.PSObject.Properties['findings']) {
        $md = @()
        if ($result.PSObject.Properties['paraphrase'] -and $result.paraphrase) { $md += "## Paraphrase`n`n$($result.paraphrase)`n" }
        $md += "## Verdict: $($result.verdict)`n"
        foreach ($f in $result.findings) {
            $md += "### [$($f.severity)] $($f.scope)`n`n$($f.description)"
            if ($f.PSObject.Properties['recommendation'] -and $f.recommendation) { $md += "`n**Recommendation:** $($f.recommendation)" }
            $md += ''
        }
        $body = $md -join "`n"
    }
    Set-Content -LiteralPath $reviewFile -Value "<!-- persona: $Persona | agent: $Agent | model: $Model -->`n$body"
}

$violation = $null
if ($readOnly) {
    $tracked = @(& git -C $wt status --porcelain --untracked-files=no 2>$null)
    if ($tracked.Count -gt 0) { $violation = "read-only run modified tracked files: $($tracked -join '; ')" }
}

Out-Summary @{
    ok          = (-not $timedOut -and $exitCode -eq 0 -and -not $violation)
    violation   = $violation
    profile     = $Profile
    model       = $Model
    usage       = $usage
    agent       = $Agent
    seat        = $(if ($Seat) { $Seat } else { $null })
    feature     = $(if ($Feature) { $Feature } else { $null })
    taskId      = $TaskId
    worktree    = $wt
    branch      = $branch
    baseSha     = $baseSha
    exitCode    = $exitCode
    timedOut    = $timedOut
    seconds     = [int]$sw.Elapsed.TotalSeconds
    cliStatus   = $cliStatus
    sessionId   = $sessionId
    result      = $(if ($isReview) { $null } elseif ($result) { $result } elseif ($finalText) { $finalText.Substring(0, [Math]::Min(1500, $finalText.Length)) } else { $null })
    reviewFile  = $reviewFile
    changes     = $changes
    diffStat    = $diffStat
    stderrTail  = $stderrTail
    logs        = $logBase
}
