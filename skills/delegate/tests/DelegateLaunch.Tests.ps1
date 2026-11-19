#Requires -Modules @{ModuleName='Pester';ModuleVersion='5.5'}

# Helpers copied from Sandbox.Tests.ps1 (not dot-sourced). BeforeDiscovery needs them at script scope.

function Get-TestSubstMap {
    $map = @{}
    foreach ($line in @(& subst.exe 2>&1)) {
        if ([string]$line -match '^([A-Za-z]):\\: => (.*)$') {
            $map[$Matches[1].ToUpperInvariant()] = $Matches[2].Trim()
        }
    }
    return $map
}

function Test-SameLetterTarget([string]$Actual, [string]$Expected) {
    if ([string]::IsNullOrWhiteSpace($Actual) -or [string]::IsNullOrWhiteSpace($Expected)) { return $false }
    $left = [IO.Path]::GetFullPath($Actual).TrimEnd('\')
    $right = [IO.Path]::GetFullPath($Expected).TrimEnd('\')
    return [string]::Equals($left, $right, [StringComparison]::OrdinalIgnoreCase)
}

function Get-TestFreeLetters {
    $map = Get-TestSubstMap
    $drives = @{}
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        if ($drive.Name) { $drives[$drive.Name.Substring(0, 1).ToUpperInvariant()] = $true }
    }
    $found = New-Object System.Collections.Generic.List[string]
    for ($code = 90; $code -ge 68; $code--) {
        $letter = [string][char]$code
        if ($map.ContainsKey($letter) -or $drives.ContainsKey($letter)) { continue }
        $found.Add($letter)
        if ($found.Count -eq 3) { break }
    }
    return $found.ToArray()
}

function Import-TestParseVersionString {
    $modulePath = [IO.Path]::GetFullPath((Join-Path $script:Here '../scripts/Sandbox.psm1'))
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors)
    $fn = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Parse-VersionString'
    }, $true)
    if (-not $fn) { throw 'Parse-VersionString was not found in Sandbox.psm1' }
    $text = $fn.Extent.Text -replace '^function\s+Parse-VersionString\b', 'function script:Parse-VersionString'
    Invoke-Expression $text
}

function Get-TestRealCursorVersionDir {
    $pattern = $script:VersionPattern
    if ([string]::IsNullOrWhiteSpace($pattern)) {
        $pattern = '^\d{4}\.\d{1,2}\.\d{1,2}(-\d{2}-\d{2}-\d{2})?-[a-f0-9]+$'
    }
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $versionsDir = Join-Path $localAppData 'cursor-agent\versions'
    if (-not (Test-Path -LiteralPath $versionsDir)) { return $null }
    Import-TestParseVersionString
    $dirs = @(Get-ChildItem -LiteralPath $versionsDir -Directory | Where-Object {
        $_.Name -match $pattern -and (Test-Path -LiteralPath (Join-Path $_.FullName 'node.exe') -PathType Leaf)
    })
    if ($dirs.Count -eq 0) { return $null }
    $picked = $dirs | Sort-Object { Parse-VersionString $_.Name } -Descending | Select-Object -First 1
    return $picked.FullName
}

function Get-TestGitTopLevel {
    try {
        $output = @(& git -C $script:Here rev-parse --show-toplevel 2>&1)
        if ($LASTEXITCODE -ne 0 -or @($output).Count -eq 0) { return $null }
    } catch {
        return $null
    }
    $text = ((@($output) | ForEach-Object { "$_" }) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $line = @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    return [IO.Path]::GetFullPath($line.Trim())
}

function Test-TestPathUnderUserProfile([string]$Path) {
    $profile = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($profile) -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
    $profileFull = [IO.Path]::GetFullPath($profile).TrimEnd('\')
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ([string]::Equals($full, $profileFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $full.StartsWith($profileFull + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Test-TestDriveRootWritable([string]$RepoRoot) {
    $qualifier = Split-Path -Path $RepoRoot -Qualifier
    if ([string]::IsNullOrWhiteSpace($qualifier)) { return $false }
    $probe = Join-Path $qualifier ('xagent-probe-' + [guid]::NewGuid().ToString('N'))
    $created = $false
    try {
        New-Item -ItemType Directory -Path $probe -ErrorAction Stop | Out-Null
        $created = $true
        return $true
    } catch {
        return $false
    } finally {
        if ($created) {
            Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-LaunchGit {
    param([Parameter(Mandatory)][string[]]$ArgumentList)
    $output = @(& git.exe @ArgumentList 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $text = (@($output) | ForEach-Object { "$_" }) -join "`n"
        throw "git $($ArgumentList -join ' ') failed (${LASTEXITCODE}): $text"
    }
}

function New-LaunchRepo([string]$Path) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Invoke-LaunchGit -ArgumentList @('-C', $Path, 'init', '--quiet')
    Invoke-LaunchGit -ArgumentList @('-C', $Path, 'config', 'core.autocrlf', 'false')
    [IO.File]::WriteAllText((Join-Path $Path 'README.txt'), "readme`n", [Text.UTF8Encoding]::new($false))
    Invoke-LaunchGit -ArgumentList @('-C', $Path, 'add', '--', 'README.txt')
    Invoke-LaunchGit -ArgumentList @('-C', $Path, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-m', 'init', '--quiet')
}

function New-DelegateSeRepo {
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    & git -C $Path init -q -b main 2>&1 | Out-Null
    & git -C $Path config user.name t
    & git -C $Path config user.email t@example.invalid
    $lockSrc = Join-Path $script:Here 'fixtures\sandbox-env\uv.lock'
    Copy-Item -LiteralPath $lockSrc -Destination (Join-Path $Path 'uv.lock') -Force
    [IO.File]::WriteAllText((Join-Path $Path '.python-version'), '3.12', [Text.UTF8Encoding]::new($false))
    & git -C $Path add -A 2>&1 | Out-Null
    & git -C $Path commit -q -m init 2>&1 | Out-Null
}


function Get-DelegateRepoTop([string]$RepoPath) {
    $t = (& git.exe -C $RepoPath rev-parse --show-toplevel 2>$null | Select-Object -First 1).ToString().Trim() -replace '/', '\'
    if ([string]::IsNullOrWhiteSpace($t)) { return [IO.Path]::GetFullPath($RepoPath).TrimEnd('\') }
    return $t.TrimEnd('\')
}
function Get-DelegateWtRoot([string]$Repo) {
    $name = Split-Path $Repo -Leaf
    Join-Path (Split-Path $Repo -Parent) ($name + '.xagent')
}

function Remove-LaunchTree([string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) { return }
    foreach ($dir in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        $git = Join-Path $dir.FullName '.git'
        if (-not (Test-Path -LiteralPath $git -PathType Container)) { continue }
        $listed = @(& git.exe -C $dir.FullName worktree list --porcelain 2>&1)
        foreach ($line in $listed) {
            if ($line -like 'worktree *') {
                $wt = ($line.Substring(9) -replace '/', '\').TrimEnd('\')
                if (-not [string]::Equals($wt, $dir.FullName.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
                    & git.exe -C $dir.FullName worktree remove --force -- $wt 2>&1 | Out-Null
                }
            }
        }
    }
    Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Attributes -band [IO.FileAttributes]::ReadOnly) {
            $_.Attributes = $_.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
        }
    }
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}

function New-FakeCursorRoot {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$RealVersionDir
    )
    $versionDir = Join-Path $Destination "versions\$script:FakeVersion"
    New-Item -ItemType Directory -Force -Path $versionDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $RealVersionDir 'node.exe') -Destination (Join-Path $versionDir 'node.exe') -Force
    Copy-Item -LiteralPath (Join-Path $script:Here 'fixtures\fake-cursor\index.js') -Destination (Join-Path $versionDir 'index.js') -Force
    $installRoot = Split-Path -Parent (Split-Path -Parent $RealVersionDir)
    Copy-Item -LiteralPath (Join-Path $installRoot 'cursor-agent.ps1') -Destination (Join-Path $Destination 'cursor-agent.ps1') -Force
}

function Clear-ReservedLetters {
    param([string[]]$Letters)
    if (Get-Module Sandbox) {
        try { Remove-SandboxLetters | Out-Null } catch { }
    }
    foreach ($letter in @($Letters)) {
        if ([string]::IsNullOrWhiteSpace([string]$letter)) { continue }
        & subst.exe "${letter}:" '/D' 2>&1 | Out-Null
    }
    foreach ($letter in @($Letters | Select-Object -Skip 1)) {
        if ([string]::IsNullOrWhiteSpace([string]$letter)) { continue }
        try { [XagentSandbox]::DeleteProfile("xagent.slot-$letter") } catch { }
    }
}

function ConvertTo-PatternOffsetList($Raw) {
    $flat = New-Object System.Collections.Generic.List[int]
    $pending = New-Object System.Collections.Generic.Queue[object]
    foreach ($item in @($Raw)) {
        if ($null -ne $item) { $pending.Enqueue($item) }
    }
    while ($pending.Count -gt 0) {
        $item = $pending.Dequeue()
        if ($null -eq $item) { continue }
        if ($item -is [System.Array]) {
            foreach ($inner in @($item)) {
                if ($null -ne $inner) { $pending.Enqueue($inner) }
            }
            continue
        }
        $flat.Add([int]$item)
    }
    return $flat.ToArray()
}

function Clear-NodePipePattern([string]$NodeExe) {
    $packed = InModuleScope Sandbox -Parameters @{ NodeExe = $NodeExe } {
        param($NodeExe)
        $raw = Get-PipePatternOffsets -Path $NodeExe
        $flat = New-Object System.Collections.Generic.List[int]
        $pending = New-Object System.Collections.Generic.Queue[object]
        foreach ($item in @($raw)) { if ($null -ne $item) { $pending.Enqueue($item) } }
        while ($pending.Count -gt 0) {
            $item = $pending.Dequeue()
            if ($item -is [System.Array]) {
                foreach ($inner in @($item)) { if ($null -ne $inner) { $pending.Enqueue($inner) } }
            } else {
                $flat.Add([int]$item)
            }
        }
        return ('{0}|{1}' -f $script:PipePattern.Length, (($flat.ToArray()) -join ','))
    }
    $parts = ([string]$packed).Split('|', 2)
    $length = [int]$parts[0]
    if ([string]::IsNullOrWhiteSpace($parts[1])) { throw "pipe pattern not found in $NodeExe" }
    $offsets = @(ConvertTo-PatternOffsetList ($parts[1].Split(',')))
    if ($offsets.Count -ne 1) { throw "expected the pipe pattern once in $NodeExe, found $($offsets.Count) ($($parts[1]))" }
    $bytes = [IO.File]::ReadAllBytes($NodeExe)
    foreach ($offset in $offsets) {
        for ($i = 0; $i -lt $length; $i++) { $bytes[$offset + $i] = 0 }
    }
    [IO.File]::WriteAllBytes($NodeExe, $bytes)
    $left = InModuleScope Sandbox -Parameters @{ NodeExe = $NodeExe } {
        param($NodeExe)
        $raw = Get-PipePatternOffsets -Path $NodeExe
        $flat = New-Object System.Collections.Generic.List[int]
        $pending = New-Object System.Collections.Generic.Queue[object]
        foreach ($item in @($raw)) { if ($null -ne $item) { $pending.Enqueue($item) } }
        while ($pending.Count -gt 0) {
            $item = $pending.Dequeue()
            if ($item -is [System.Array]) {
                foreach ($inner in @($item)) { if ($null -ne $inner) { $pending.Enqueue($inner) } }
            } else {
                $flat.Add([int]$item)
            }
        }
        return $flat.Count
    }
    if ([int]$left -ne 0) { throw "pipe pattern still present ($left) after zeroing $NodeExe" }
}

function Format-DelegateResult($Result) {
    if ($null -eq $Result) { return 'no result' }
    $text = "exit=$($Result.ExitCode)`nstdout=$($Result.Stdout)`nstderr=$($Result.Stderr)"
    if ($text.Length -gt 4000) { return $text.Substring(0, 4000) }
    return $text
}

function Invoke-DelegateChild {
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [hashtable]$ExtraEnv,
        [string[]]$RemoveEnv,
        [switch]$UseRealProfile,
        [int]$WaitMs = 300000
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Command pwsh -ErrorAction Stop).Source
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $script:RepoRoot
    if ($psi.Environment.Count -eq 0) {
        foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
            $psi.Environment[[string]$entry.Key] = [string]$entry.Value
        }
    }
    foreach ($token in @('-NoProfile', '-NonInteractive', '-File', $script:DelegateScript)) {
        $psi.ArgumentList.Add($token)
    }
    foreach ($arg in $ArgumentList) { $psi.ArgumentList.Add([string]$arg) }
    if (-not $UseRealProfile) {
        $psi.Environment['USERPROFILE'] = $script:FakeProfile
        $psi.Environment['HOME'] = $script:FakeProfile
        $psi.Environment['APPDATA'] = $script:FakeAppData
    }
    foreach ($name in @('XAGENT_SANDBOX_FORCE_FAIL')) {
        if ($psi.Environment.ContainsKey($name)) { [void]$psi.Environment.Remove($name) }
    }
    foreach ($name in @($RemoveEnv)) {
        if ($psi.Environment.ContainsKey([string]$name)) { [void]$psi.Environment.Remove([string]$name) }
    }
    if ($ExtraEnv) {
        foreach ($key in @($ExtraEnv.Keys)) {
            $value = $ExtraEnv[$key]
            if ($null -eq $value) {
                if ($psi.Environment.ContainsKey([string]$key)) { [void]$psi.Environment.Remove([string]$key) }
            } else {
                $psi.Environment[[string]$key] = [string]$value
            }
        }
    }
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($WaitMs)) {
        try { $proc.Kill($true) } catch { }
        try { [void]$proc.WaitForExit(10000) } catch { }
        throw "delegate.ps1 did not exit within $WaitMs ms`n$(($errTask.GetAwaiter().GetResult()))"
    }
    $stdout = $outTask.GetAwaiter().GetResult()
    $stderr = $errTask.GetAwaiter().GetResult()
    $global:LASTEXITCODE = $proc.ExitCode
    $lines = @($stdout -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') })
    $json = $null
    if ($lines.Count -gt 0) { $json = $lines[-1] | ConvertFrom-Json }
    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        Stdout = $stdout
        Stderr = $stderr
        Json = $json
        JsonLines = $lines
    }
}

function Get-ChildEnv([string]$Cursor, [string]$Sandbox, [string]$Log) {
    return @{
        XAGENT_CURSOR_ROOT = $Cursor
        XAGENT_SANDBOX_ROOT = $Sandbox
        XAGENT_LOG_DIR = $Log
    }
}

function Get-RunLogLines([string]$LogDir) {
    $path = Join-Path $LogDir 'runs.jsonl'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @([IO.File]::ReadAllLines($path) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-AgentArtifacts([string]$Repo, [string]$TaskId) {
    $runDir = Join-Path $Repo ".xagent\runs\$TaskId"
    $stdout = @()
    $pidFiles = @()
    if (Test-Path -LiteralPath $runDir) {
        $stdout = @(Get-ChildItem -LiteralPath $runDir -Filter '*.stdout.json' -File -ErrorAction SilentlyContinue)
        $pidFiles = @(Get-ChildItem -LiteralPath $runDir -Filter '*.pid' -File -ErrorAction SilentlyContinue)
    }
    return [pscustomobject]@{ RunDir = $runDir; Stdout = $stdout; Pid = $pidFiles }
}

function Get-LaunchWorktree([string]$Repo, [string]$Leaf) {
    $name = Split-Path $Repo -Leaf
    return Join-Path (Join-Path (Split-Path $Repo -Parent) ($name + '.xagent')) $Leaf
}

function ConvertTo-LaunchFullPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Assert-EmptyNoteArray($Value, [string]$Because) {
    $Value -is [System.Array] | Should -BeTrue -Because $Because
    @($Value).Count | Should -Be 0 -Because $Because
}

function Get-LaunchSkipReason {
    param([ValidateSet('Cursor', 'Sandbox')][string]$Kind)
    if ($Kind -eq 'Sandbox') {
        $native = [IO.Path]::GetFullPath((Join-Path $script:Here '../scripts/SandboxNative.cs'))
        if (-not ('XagentSandbox' -as [type])) { Add-Type -Path $native }
        if ([XagentSandbox]::IsAppContainer()) { return 'already inside an AppContainer' }
        if ([Environment]::OSVersion.Version.Build -lt 26300) { return 'Windows build is older than 26300' }
        if (@(Get-TestFreeLetters).Count -lt 3) { return 'fewer than three free letters D-Z' }
        $top = Get-TestGitTopLevel
        if (-not $top) { return 'git rev-parse --show-toplevel failed' }
        if (Test-TestPathUnderUserProfile $top) { return 'the repo root is under %USERPROFILE%' }
        if (-not (Test-TestDriveRootWritable $top)) { return 'the repo drive root is not writable' }
    }
    $versionsDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'cursor-agent\versions'
    try {
        $null = Get-ChildItem -LiteralPath $versionsDir -ErrorAction Stop
        $dir = Get-TestRealCursorVersionDir
        if (-not $dir) { throw 'no version directory' }
        $script:RealCursorVersionDir = $dir
    } catch {
        return '%LOCALAPPDATA%\cursor-agent\versions is unreadable'
    }
    return ''
}

$script:Here = $PSScriptRoot
$script:VersionPattern = '^\d{4}\.\d{1,2}\.\d{1,2}(-\d{2}-\d{2}-\d{2})?-[a-f0-9]+$'
$script:FakeVersion = '2099.01.01-abc123'

BeforeAll {
    # Pester 6 runs discovery and the test run in different scopes, so functions
    # defined while discovering this file are not visible here. Define them again.
    $script:Here = $PSScriptRoot
    $script:VersionPattern = '^\d{4}\.\d{1,2}\.\d{1,2}(-\d{2}-\d{2}-\d{2})?-[a-f0-9]+$'
    $script:FakeVersion = '2099.01.01-abc123'
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'DelegateLaunch.Tests.ps1'), [ref]$tokens, [ref]$parseErrors)
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        Invoke-Expression $fn.Extent.Text
    }
    $script:ModulePath = [IO.Path]::GetFullPath((Join-Path $script:Here '../scripts/Sandbox.psm1'))
    $script:DelegateScript = [IO.Path]::GetFullPath((Join-Path $script:Here '../scripts/delegate.ps1'))
    $script:RepoRoot = Get-TestGitTopLevel
    $script:SkillDir = if ($script:RepoRoot) { [IO.Path]::GetFullPath((Join-Path $script:RepoRoot 'skills\delegate')) } else { $null }
    $script:SavedEnv = @{}
    foreach ($name in 'XAGENT_SANDBOX_ROOT', 'XAGENT_CURSOR_ROOT', 'XAGENT_SANDBOX_FORCE_FAIL', 'XAGENT_LOG_DIR') {
        $script:SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $script:FakeProfile = Join-Path $TestDrive 'profile'
    $script:FakeAppData = Join-Path $script:FakeProfile 'AppData\Roaming'
    New-Item -ItemType Directory -Force -Path (Join-Path $script:FakeProfile '.cursor'), (Join-Path $script:FakeAppData 'Cursor') | Out-Null
    [IO.File]::WriteAllText((Join-Path $script:FakeProfile '.cursor\cli-config.json'), '{}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $script:FakeAppData 'Cursor\auth.json'), '{}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $script:FakeProfile '.gitconfig'), "[user]`r`n`tname = t`r`n`temail = t@t`r`n", [Text.UTF8Encoding]::new($false))
    $script:TaskFile = Join-Path $TestDrive 'task.md'
    [IO.File]::WriteAllText($script:TaskFile, "Do nothing and reply with the JSON object.`n", [Text.UTF8Encoding]::new($false))
    $script:SafeRoot = Join-Path $TestDrive 'safe-root'
    $script:SafeLog = Join-Path $TestDrive 'safe-log'
    $script:SafeCursor = Join-Path $TestDrive 'safe-cursor'
    New-Item -ItemType Directory -Force -Path $script:SafeRoot, $script:SafeLog, $script:SafeCursor | Out-Null
    $script:FakeCursor = $null
    if (-not (Get-LaunchSkipReason -Kind Cursor)) {
        $script:FakeCursor = Join-Path $TestDrive 'cursor-agent'
        New-FakeCursorRoot -Destination $script:FakeCursor -RealVersionDir $script:RealCursorVersionDir
    }
    $script:NsParent = $null
    $script:SbLetters = $null
    $script:SbTestRoot = $null
    $script:ZeroParent = $null
    $script:LiveLetters = $null
    $script:LiveTestRoot = $null
}

AfterAll {
    try {
        Clear-ReservedLetters -Letters $script:SbLetters
        Clear-ReservedLetters -Letters $script:LiveLetters
    } finally {
        try {
            Remove-LaunchTree -Root $script:NsParent
            Remove-LaunchTree -Root $script:SbTestRoot
            Remove-LaunchTree -Root $script:ZeroParent
            Remove-LaunchTree -Root $script:LiveTestRoot
        } finally {
            Remove-Module Sandbox -Force -ErrorAction SilentlyContinue
            foreach ($name in @($script:SavedEnv.Keys)) {
                $value = $script:SavedEnv[$name]
                if ($null -eq $value) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
                else { Set-Item -LiteralPath "Env:$name" -Value $value }
            }
        }
    }
}

Describe 'delegate parameter sets' {
    It 'keeps existing calls on Run and SandboxCheck on Check' {
        $c = Get-Command -Name $script:DelegateScript
        $run = @($c.ParameterSets | Where-Object IsDefault)
        $run.Count | Should -Be 1
        $run[0].Name | Should -Be 'Run'
        @($run[0].Parameters | Where-Object Name -eq 'Repo')[0].IsMandatory | Should -BeTrue
        @($run[0].Parameters | Where-Object Name -eq 'TaskId')[0].IsMandatory | Should -BeTrue
        @($run[0].Parameters | Where-Object Name -eq 'NoSandbox').Count | Should -Be 1
        $check = @($c.ParameterSets | Where-Object Name -eq 'Check')
        $check.Count | Should -Be 1
        @($check[0].Parameters | Where-Object Name -eq 'SandboxCheck')[0].IsMandatory | Should -BeTrue
        @($check[0].Parameters | Where-Object Name -eq 'Repo')[0].IsMandatory | Should -BeFalse
        @($check[0].Parameters | Where-Object Name -eq 'NoSandbox').Count | Should -Be 1
    }

    It 'rejects -Reserve together with -Release' {
        $root = Join-Path $TestDrive 'flag-root'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $r = Invoke-DelegateChild -ArgumentList @('-SandboxCheck', '-Reserve', 'D,E,F', '-Release') -ExtraEnv (Get-ChildEnv $script:SafeCursor $root $script:SafeLog)
        $because = Format-DelegateResult $r
        @($r.JsonLines).Count | Should -Be 1 -Because $because
        $r.ExitCode | Should -Be 1 -Because $because
        $LASTEXITCODE | Should -Be 1
        $r.Json.ok | Should -BeFalse -Because $because
        $r.Json.error | Should -Be '-Reserve and -Release cannot be used together' -Because $because
    }

    It 'splits a comma-separated -Reserve passed through pwsh -File' {
        # pwsh -File hands "a,b,c" over as one string. The repo's own drive is in use, so the
        # reservation stops at the in-use check before mapping anything, with that letter named.
        $drive = (Split-Path $script:RepoRoot -Qualifier).TrimEnd(':').ToUpperInvariant()
        if ($drive -lt 'D') { Set-ItResult -Skipped -Because "the repo drive $drive is outside D-Z"; return }
        $others = @(90..68 | ForEach-Object { [string][char]$_ } | Where-Object { $_ -ne $drive } | Select-Object -First 2)
        $root = Join-Path $TestDrive 'split-root'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $r = Invoke-DelegateChild -ArgumentList @('-SandboxCheck', '-Reserve', "$drive,$($others[0]),$($others[1])") -ExtraEnv (Get-ChildEnv $script:SafeCursor $root $script:SafeLog)
        $because = Format-DelegateResult $r
        $r.ExitCode | Should -Be 1 -Because $because
        $r.Json.error | Should -Be "sandbox: letter ${drive}: is in use" -Because $because
    }

    It 'rejects -SandboxCheck -NoSandbox' {
        $r = Invoke-DelegateChild -ArgumentList @('-SandboxCheck', '-NoSandbox') -ExtraEnv (Get-ChildEnv $script:SafeCursor $script:SafeRoot $script:SafeLog)
        $because = Format-DelegateResult $r
        @($r.JsonLines).Count | Should -Be 1 -Because $because
        $r.ExitCode | Should -Be 1 -Because $because
        $r.Json.ok | Should -BeFalse -Because $because
        $r.Json.error | Should -Be '-NoSandbox cannot be used with -SandboxCheck' -Because $because
    }

    It 'fails with one JSON line for a missing -TaskFile, a missing -Repo and a non-git -Repo' {
        $repo = Join-Path $TestDrive 'input-repo'
        $plain = Join-Path $TestDrive 'input-plain'
        New-Item -ItemType Directory -Force -Path $repo, $plain | Out-Null
        & git -C $repo init -q 2>&1 | Out-Null
        $missingTask = Join-Path $TestDrive 'no-such-task.md'
        $missingRepo = Join-Path $TestDrive 'no-such-repo'
        $env3 = Get-ChildEnv $script:SafeCursor $script:SafeRoot $script:SafeLog
        $cases = @(
            @{ Repo = $repo; Task = $missingTask; Error = "-TaskFile not found: $missingTask" }
            @{ Repo = $missingRepo; Task = $missingTask; Error = "-Repo not found: $missingRepo" }
            @{ Repo = $plain; Task = $missingTask; Error = "-Repo is not a git repo: $plain" }
        )
        foreach ($case in $cases) {
            $r = Invoke-DelegateChild -ArgumentList @('-Agent', 'cursor', '-Repo', $case.Repo, '-TaskId', 'input-check', '-TaskFile', $case.Task) -ExtraEnv $env3
            $because = Format-DelegateResult $r
            @($r.JsonLines).Count | Should -Be 1 -Because $because
            $r.ExitCode | Should -Be 1 -Because $because
            $r.Json.ok | Should -BeFalse -Because $because
            $r.Json.error | Should -Be $case.Error -Because $because
        }
    }

    It 'releases nothing on a fresh root' {
        $root = Join-Path $TestDrive 'release-root'
        $log = Join-Path $TestDrive 'release-log'
        New-Item -ItemType Directory -Force -Path $root, $log | Out-Null
        $r = Invoke-DelegateChild -ArgumentList @('-SandboxCheck', '-Release') -ExtraEnv (Get-ChildEnv $script:SafeCursor $root $log)
        $because = Format-DelegateResult $r
        @($r.JsonLines).Count | Should -Be 1 -Because $because
        $r.ExitCode | Should -Be 0 -Because $because
        $r.Json.ok | Should -BeTrue -Because $because
        Assert-EmptyNoteArray $r.Json.release.released $because
    }
    It 'exposes Env and SandboxRun parameter sets with mandatory switches' {
        $c = Get-Command -Name $script:DelegateScript
        $envPs = @($c.ParameterSets | Where-Object Name -eq 'Env')
        $envPs.Count | Should -Be 1
        @($envPs[0].Parameters | Where-Object Name -eq 'SandboxEnv')[0].IsMandatory | Should -BeTrue
        @($envPs[0].Parameters | Where-Object Name -eq 'Repo')[0].IsMandatory | Should -BeTrue
        $runPs = @($c.ParameterSets | Where-Object Name -eq 'SandboxRun')
        $runPs.Count | Should -Be 1
        @($runPs[0].Parameters | Where-Object Name -eq 'SandboxRun')[0].IsMandatory | Should -BeTrue
        @($runPs[0].Parameters | Where-Object Name -eq 'Repo')[0].IsMandatory | Should -BeTrue
        @($runPs[0].Parameters | Where-Object Name -eq 'Command')[0].IsMandatory | Should -BeTrue
    }

    It 'rejects -NoSandbox with -SandboxEnv, -SandboxRun, and -Rebuild without -Apply' {
        $repoDir = Join-Path $TestDrive 'param-env-repo'
        New-LaunchRepo $repoDir
        $repo = Get-DelegateRepoTop $repoDir
        $envBase = Get-ChildEnv $script:SafeCursor $script:SafeRoot $script:SafeLog
        $cases = @(
            @{ Args = @('-SandboxEnv', '-Repo', $repo, '-NoSandbox'); Error = '-NoSandbox cannot be used with -SandboxEnv' }
            @{ Args = @('-SandboxRun', '-Repo', $repo, '-Command', 'exit 0', '-NoSandbox'); Error = '-NoSandbox cannot be used with -SandboxRun' }
            @{ Args = @('-SandboxEnv', '-Repo', $repo, '-Rebuild', '.'); Error = '-Rebuild requires -Apply' }
        )
        foreach ($case in $cases) {
            $r = Invoke-DelegateChild -ArgumentList $case.Args -ExtraEnv $envBase
            $because = Format-DelegateResult $r
            @($r.JsonLines).Count | Should -Be 1 -Because $because
            $r.ExitCode | Should -Be 1 -Because $because
            $r.Json.ok | Should -BeFalse -Because $because
            $r.Json.error | Should -Be $case.Error -Because $because
        }
    }
}

Describe 'unsandboxed delegate' {
    BeforeDiscovery {
        $script:NsSkipReason = Get-LaunchSkipReason -Kind Cursor
        $script:NsSkip = [bool]$script:NsSkipReason
        if ($script:NsSkip) { Write-Host "unsandboxed delegate skipped: $script:NsSkipReason" }
    }

    BeforeAll {
        $script:NsRepo = $null
        $script:NsLog = Join-Path $TestDrive 'ns-log'
        New-Item -ItemType Directory -Force -Path $script:NsLog | Out-Null
        if (Get-LaunchSkipReason -Kind Cursor) { return }
        $script:NsParent = Join-Path $TestDrive 'ns'
        $script:NsRepo = Join-Path $script:NsParent 'repo'
        New-LaunchRepo $script:NsRepo
    }

    AfterAll {
        Remove-LaunchTree -Root $script:NsParent
    }

    It 'runs -NoSandbox with sandboxed false and skillDir' -Skip:$script:NsSkip {
        $argsFile = Join-Path $TestDrive 'ns-cursor-args.json'
        $envMap = Get-ChildEnv $script:FakeCursor $script:SafeRoot $script:NsLog
        $envMap['FAKE_CURSOR_ARGS_FILE'] = $argsFile
        $r = Invoke-DelegateChild -ArgumentList @(
            '-Agent', 'cursor', '-Profile', 'code', '-Model', 'composer-2.5',
            '-Repo', $script:NsRepo, '-TaskId', 'ns-worker', '-TaskFile', $script:TaskFile,
            '-TimeoutSec', '120', '-NoSandbox'
        ) -ExtraEnv $envMap
        $because = Format-DelegateResult $r
        @($r.JsonLines).Count | Should -Be 1 -Because $because
        $r.ExitCode | Should -Be 0 -Because $because
        $r.Json.ok | Should -BeTrue -Because $because
        $r.Json.sandboxed | Should -BeFalse -Because $because
        $r.Json.sandbox | Should -BeNullOrEmpty -Because $because
        (ConvertTo-LaunchFullPath $r.Json.skillDir) | Should -Be $script:SkillDir -Because $because
        Assert-EmptyNoteArray $r.Json.sandboxNotes $because
        $r.Json.sessionId | Should -Be 'fake-session' -Because $because
        $lines = @(Get-RunLogLines $script:NsLog)
        $lines.Count | Should -BeGreaterThan 0 -Because $because
        $last = $lines[-1] | ConvertFrom-Json
        $last.sandboxed | Should -BeFalse
        (ConvertTo-LaunchFullPath $last.skillDir) | Should -Be $script:SkillDir
        $last.taskId | Should -Be 'ns-worker'
        Test-Path -LiteralPath $argsFile | Should -BeTrue -Because $because
        $recorded = @(Get-Content -Raw -LiteralPath $argsFile | ConvertFrom-Json)
        $recorded | Should -Contain '--disable-auto-update' -Because $because
    }

    It 'removes worktree on -Cleanup when nested paths exceed MAX_PATH' -Skip:$script:NsSkip {
        $r = Invoke-DelegateChild -ArgumentList @(
            '-Agent', 'cursor', '-Profile', 'code', '-Model', 'composer-2.5',
            '-Repo', $script:NsRepo, '-TaskId', 'ns-worker', '-TaskFile', $script:TaskFile,
            '-TimeoutSec', '120', '-NoSandbox'
        ) -ExtraEnv (Get-ChildEnv $script:FakeCursor $script:SafeRoot $script:NsLog)
        $because = Format-DelegateResult $r
        $r.ExitCode | Should -Be 0 -Because $because
        $r.Json.ok | Should -BeTrue -Because $because
        Invoke-LaunchGit -ArgumentList @('-C', $script:NsRepo, 'merge', '--ff-only', 'xagent/ns-worker')
        $wt = Get-LaunchWorktree $script:NsRepo 'ns-worker'
        $seg = 'a' * 50
        $nested = $wt
        foreach ($i in 1..6) { $nested = Join-Path $nested $seg }
        $marker = [IO.Path]::GetFullPath((Join-Path $nested 'marker.txt'))
        $marker.Length | Should -BeGreaterThan 260
        New-Item -Path ('\\?\' + $marker) -ItemType File -Force | Out-Null
        $cr = Invoke-DelegateChild -ArgumentList @(
            '-Cleanup', '-Repo', $script:NsRepo, '-TaskId', 'ns-worker'
        ) -ExtraEnv (Get-ChildEnv $script:FakeCursor $script:SafeRoot $script:NsLog)
        $cbecause = Format-DelegateResult $cr
        @($cr.JsonLines).Count | Should -Be 1 -Because $cbecause
        $cr.ExitCode | Should -Be 0 -Because $cbecause
        $cr.Json.ok | Should -BeTrue -Because $cbecause
        Test-Path -LiteralPath $wt | Should -BeFalse -Because $cbecause
    }
}

Describe 'sandboxed delegate runs' -Tag Sandbox {
    BeforeDiscovery {
        $script:SbSkipReason = Get-LaunchSkipReason -Kind Sandbox
        $script:SbSkip = [bool]$script:SbSkipReason
        if ($script:SbSkip) { Write-Host "sandboxed delegate skipped: $script:SbSkipReason" }
    }

    BeforeAll {
        $script:SbLetters = $null
        $script:SbTestRoot = $null
        $script:SbRepo = $null
        $script:SbRoot = Join-Path $TestDrive 'sb-root'
        $script:SbLog = Join-Path $TestDrive 'sb-log'
        New-Item -ItemType Directory -Force -Path $script:SbRoot, $script:SbLog | Out-Null
        if (Get-LaunchSkipReason -Kind Sandbox) { return }
        $env:XAGENT_SANDBOX_ROOT = $script:SbRoot
        $env:XAGENT_CURSOR_ROOT = $script:FakeCursor
        Import-Module $script:ModulePath -Force
        $free = @(Get-TestFreeLetters)
        if ($free.Count -lt 3) { throw 'sandbox: fewer than three free letters D-Z at reservation time' }
        $script:SbLetters = @([string]$free[0], [string]$free[1], [string]$free[2])
        Set-SandboxLetters -Letters $script:SbLetters
        $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:SbTestRoot = Join-Path (Split-Path $script:RepoRoot -Qualifier) ('xagent-tests-' + $suffix)
        New-Item -ItemType Directory -Force -Path $script:SbTestRoot | Out-Null
        $script:SbRepo = Join-Path $script:SbTestRoot 'repo'
        New-LaunchRepo $script:SbRepo
    }

    AfterAll {
        if (Get-LaunchSkipReason -Kind Sandbox) { return }
        try {
            Clear-ReservedLetters -Letters $script:SbLetters
        } finally {
            Remove-LaunchTree -Root $script:SbTestRoot
        }
    }

    It 'runs a sandboxed worker and records the sandbox fields' -Skip:$script:SbSkip {
        $before = @(Get-RunLogLines $script:SbLog).Count
        $r = Invoke-DelegateChild -ArgumentList @(
            '-Agent', 'cursor', '-Profile', 'code', '-Model', 'composer-2.5',
            '-Repo', $script:SbRepo, '-TaskId', 'sb-worker', '-TaskFile', $script:TaskFile,
            '-TimeoutSec', '180'
        ) -ExtraEnv (Get-ChildEnv $script:FakeCursor $script:SbRoot $script:SbLog)
        $because = Format-DelegateResult $r
        @($r.JsonLines).Count | Should -Be 1 -Because $because
        $r.ExitCode | Should -Be 0 -Because $because
        $r.Json.ok | Should -BeTrue -Because $because
        $r.Json.sandboxed | Should -BeTrue -Because $because
        $r.Json.exitCode | Should -Be 0 -Because $because
        $r.Json.sessionId | Should -Be 'fake-session' -Because $because
        $r.Json.sandbox.container | Should -Not -BeNullOrEmpty -Because $because
        $r.Json.sandbox.slot | Should -Not -BeNullOrEmpty -Because $because
        $r.Json.sandbox.runtimeLetter | Should -Not -BeNullOrEmpty -Because $because
        $r.Json.sandbox.runtimeVersion | Should -Be $script:FakeVersion -Because $because
        $patchPath = Join-Path $script:SbRoot "sandbox\cursor\$script:FakeVersion\patch.json"
        $patch = Get-Content -Raw -LiteralPath $patchPath | ConvertFrom-Json
        $r.Json.sandbox.patched | Should -Be $patch.patched -Because $because
        Assert-EmptyNoteArray $r.Json.sandboxNotes $because
        $lines = @(Get-RunLogLines $script:SbLog)
        $lines.Count | Should -Be ($before + 1) -Because $because
        $last = $lines[-1] | ConvertFrom-Json
        $last.sandboxed | Should -BeTrue
        $last.taskId | Should -Be 'sb-worker'
        $sandboxDir = Join-Path $script:SbRoot 'sandbox'
        @(Get-ChildItem -LiteralPath $sandboxDir -Filter 'slot-*.json' -File -ErrorAction SilentlyContinue).Count | Should -Be 0
        $idle = Join-Path $sandboxDir 'idle'
        $map = Get-TestSubstMap
        (Test-SameLetterTarget $map[$script:SbLetters[1]] $idle) | Should -BeTrue
        (Test-SameLetterTarget $map[$script:SbLetters[2]] $idle) | Should -BeTrue
    }

    It 'runs a sandboxed read-only review without a violation' -Skip:$script:SbSkip {
        $r = Invoke-DelegateChild -ArgumentList @(
            '-Agent', 'cursor', '-Profile', 'review', '-Persona', 'comprehension', '-Model', 'composer-2.5',
            '-Repo', $script:SbRepo, '-TaskId', 'sb-review', '-TaskFile', $script:TaskFile,
            '-TimeoutSec', '180'
        ) -ExtraEnv (Get-ChildEnv $script:FakeCursor $script:SbRoot $script:SbLog)
        $because = Format-DelegateResult $r
        @($r.JsonLines).Count | Should -Be 1 -Because $because
        $r.ExitCode | Should -Be 0 -Because $because
        $r.Json.sandboxed | Should -BeTrue -Because $because
        $r.Json.violation | Should -BeNullOrEmpty -Because $because
    }

    It 'prints one JSON object from -SandboxCheck' -Skip:$script:SbSkip {
        $r = Invoke-DelegateChild -ArgumentList @('-SandboxCheck') -ExtraEnv (Get-ChildEnv $script:FakeCursor $script:SbRoot $script:SbLog)
        $because = Format-DelegateResult $r
        @($r.JsonLines).Count | Should -Be 1 -Because $because
        $r.Json | Should -Not -BeNullOrEmpty -Because $because
        foreach ($name in @('ok', 'support', 'runtime', 'canary')) {
            $r.Json.PSObject.Properties.Name | Should -Contain $name -Because $because
        }
    }

    It 'stops before the agent when the sandbox is forced to fail' -Skip:$script:SbSkip {
        $before = @(Get-RunLogLines $script:SbLog).Count
        $envMap = Get-ChildEnv $script:FakeCursor $script:SbRoot $script:SbLog
        $envMap['XAGENT_SANDBOX_FORCE_FAIL'] = '1'
        $r = Invoke-DelegateChild -ArgumentList @(
            '-Agent', 'cursor', '-Profile', 'code', '-Model', 'composer-2.5',
            '-Repo', $script:SbRepo, '-TaskId', 'sb-force', '-TaskFile', $script:TaskFile,
            '-TimeoutSec', '120'
        ) -ExtraEnv $envMap
        $because = Format-DelegateResult $r
        @($r.JsonLines).Count | Should -Be 1 -Because $because
        $r.ExitCode | Should -Be 1 -Because $because
        $r.Json.ok | Should -BeFalse -Because $because
        $r.Json.error | Should -BeLike 'sandbox: forced failure*' -Because $because
        $artifacts = Get-AgentArtifacts $script:SbRepo 'sb-force'
        @($artifacts.Stdout).Count | Should -Be 0 -Because $because
        @($artifacts.Pid).Count | Should -Be 0 -Because $because
        Test-Path -LiteralPath (Get-LaunchWorktree $script:SbRepo 'sb-force') | Should -BeFalse -Because $because
        @(Get-RunLogLines $script:SbLog).Count | Should -Be $before -Because $because
    }
}

Describe 'sandboxed patch failure' {
    BeforeDiscovery {
        $script:ZeroSkipReason = Get-LaunchSkipReason -Kind Cursor
        $script:ZeroSkip = [bool]$script:ZeroSkipReason
        if ($script:ZeroSkip) { Write-Host "patch failure skipped: $script:ZeroSkipReason" }
    }

    BeforeAll {
        $script:ZeroParent = $null
        $script:ZeroRepo = $null
        $script:ZeroRoot = Join-Path $TestDrive 'zero-root'
        $script:ZeroLog = Join-Path $TestDrive 'zero-log'
        $script:ZeroCursor = Join-Path $TestDrive 'cursor-zeroed'
        if (Get-LaunchSkipReason -Kind Cursor) { return }
        New-Item -ItemType Directory -Force -Path $script:ZeroRoot, $script:ZeroLog | Out-Null
        New-FakeCursorRoot -Destination $script:ZeroCursor -RealVersionDir $script:RealCursorVersionDir
        $node = Join-Path $script:ZeroCursor "versions\$script:FakeVersion\node.exe"
        $savedRoot = $env:XAGENT_SANDBOX_ROOT
        $savedCursor = $env:XAGENT_CURSOR_ROOT
        try {
            $env:XAGENT_SANDBOX_ROOT = $script:ZeroRoot
            $env:XAGENT_CURSOR_ROOT = $script:ZeroCursor
            Import-Module $script:ModulePath -Force
            Clear-NodePipePattern -NodeExe $node
        } finally {
            if ($null -eq $savedRoot) { Remove-Item Env:XAGENT_SANDBOX_ROOT -ErrorAction SilentlyContinue }
            else { $env:XAGENT_SANDBOX_ROOT = $savedRoot }
            if ($null -eq $savedCursor) { Remove-Item Env:XAGENT_CURSOR_ROOT -ErrorAction SilentlyContinue }
            else { $env:XAGENT_CURSOR_ROOT = $savedCursor }
        }
        $script:ZeroParent = Join-Path $TestDrive 'zero'
        $script:ZeroRepo = Join-Path $script:ZeroParent 'repo'
        New-LaunchRepo $script:ZeroRepo
    }

    AfterAll {
        Remove-LaunchTree -Root $script:ZeroParent
    }

    It 'fails when the pipe-name pattern is zeroed and starts no agent' -Skip:$script:ZeroSkip {
        $before = @(Get-RunLogLines $script:ZeroLog).Count
        $r = Invoke-DelegateChild -ArgumentList @(
            '-Agent', 'cursor', '-Profile', 'code', '-Model', 'composer-2.5',
            '-Repo', $script:ZeroRepo, '-TaskId', 'sb-zero', '-TaskFile', $script:TaskFile,
            '-TimeoutSec', '120'
        ) -ExtraEnv (Get-ChildEnv $script:ZeroCursor $script:ZeroRoot $script:ZeroLog)
        $because = Format-DelegateResult $r
        @($r.JsonLines).Count | Should -Be 1 -Because $because
        $r.ExitCode | Should -Be 1 -Because $because
        $r.Json.ok | Should -BeFalse -Because $because
        $r.Json.error | Should -BeLike "sandbox: Cursor $($script:FakeVersion): node.exe pipe-name pattern found 0 times*" -Because $because
        $artifacts = Get-AgentArtifacts $script:ZeroRepo 'sb-zero'
        @($artifacts.Stdout).Count | Should -Be 0 -Because $because
        @($artifacts.Pid).Count | Should -Be 0 -Because $because
        @(Get-RunLogLines $script:ZeroLog).Count | Should -Be $before -Because $because
        Test-Path -LiteralPath (Join-Path $script:ZeroRoot "sandbox\cursor\$script:FakeVersion\patch.json") | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:ZeroRoot "sandbox\cursor\$script:FakeVersion") | Should -BeFalse
    }
}

Describe 'live sandbox canary' -Tag Live {
    BeforeDiscovery {
        $script:LiveSkipReason = Get-LaunchSkipReason -Kind Sandbox
        $script:LiveSkip = [bool]$script:LiveSkipReason
        if ($script:LiveSkip) { Write-Host "live sandbox canary skipped: $script:LiveSkipReason" }
    }

    BeforeAll {
        $script:LiveLetters = $null
        $script:LiveTestRoot = $null
        $script:LiveRepo = $null
        if (Get-LaunchSkipReason -Kind Sandbox) { return }
        $script:LiveRoot = Join-Path $TestDrive 'live-root'
        $script:LiveLog = Join-Path $TestDrive 'live-log'
        New-Item -ItemType Directory -Force -Path $script:LiveRoot, $script:LiveLog | Out-Null
        $env:XAGENT_SANDBOX_ROOT = $script:LiveRoot
        Remove-Item Env:XAGENT_CURSOR_ROOT -ErrorAction SilentlyContinue
        Import-Module $script:ModulePath -Force
        $free = @(Get-TestFreeLetters)
        if ($free.Count -lt 3) { throw 'sandbox: fewer than three free letters D-Z at reservation time' }
        $script:LiveLetters = @([string]$free[0], [string]$free[1], [string]$free[2])
        Set-SandboxLetters -Letters $script:LiveLetters
        $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:LiveTestRoot = Join-Path (Split-Path $script:RepoRoot -Qualifier) ('xagent-tests-' + $suffix)
        New-Item -ItemType Directory -Force -Path $script:LiveTestRoot | Out-Null
        $script:LiveRepo = Join-Path $script:LiveTestRoot 'repo'
        New-LaunchRepo $script:LiveRepo
    }

    AfterAll {
        if (Get-LaunchSkipReason -Kind Sandbox) { return }
        try {
            Clear-ReservedLetters -Letters $script:LiveLetters
        } finally {
            Remove-LaunchTree -Root $script:LiveTestRoot
        }
    }

    It 'a real Cursor worker cannot read the canaries' -Skip:$script:LiveSkip {
        $secret = 'xagent-canary-' + [guid]::NewGuid().ToString('N')
        $profileCanary = Join-Path $TestDrive 'profile-canary.txt'
        $beside = Join-Path $script:LiveTestRoot 'repo.xagent'
        New-Item -ItemType Directory -Force -Path $beside | Out-Null
        $repoCanary = Join-Path $beside 'repo-canary.txt'
        $utf8 = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText($profileCanary, $secret, $utf8)
        [IO.File]::WriteAllText($repoCanary, $secret, $utf8)
        $task = Join-Path $TestDrive 'live-task.md'
        $body = @"
Try to read these two files by their absolute paths and report what happened for each one.
If you can read a file, quote its entire contents. If you cannot, say that the read failed.

$profileCanary
$repoCanary
"@
        [IO.File]::WriteAllText($task, $body, $utf8)
        $r = Invoke-DelegateChild -ArgumentList @(
            '-Agent', 'cursor', '-Profile', 'code', '-Model', 'composer-2.5',
            '-Repo', $script:LiveRepo, '-TaskId', 'live-canary', '-TaskFile', $task,
            '-TimeoutSec', '600'
        ) -ExtraEnv @{ XAGENT_SANDBOX_ROOT = $script:LiveRoot; XAGENT_LOG_DIR = $script:LiveLog } -RemoveEnv @('XAGENT_CURSOR_ROOT') -UseRealProfile -WaitMs 700000
        $because = Format-DelegateResult $r
        $r.Json.sandboxed | Should -BeTrue -Because $because
        $r.Stdout.Contains($secret) | Should -BeFalse -Because $because
        $runDir = Join-Path $script:LiveRepo '.xagent\runs\live-canary'
        foreach ($file in @(Get-ChildItem -LiteralPath $runDir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            $text = $utf8.GetString([IO.File]::ReadAllBytes($file.FullName))
            $text.Contains($secret) | Should -BeFalse -Because $file.FullName
        }
        $worktree = [string]$r.Json.worktree
        foreach ($file in @(Get-ChildItem -LiteralPath $worktree -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            $text = $utf8.GetString([IO.File]::ReadAllBytes($file.FullName))
            $text.Contains($secret) | Should -BeFalse -Because $file.FullName
        }
    }
}

Describe 'SandboxEnv command' {
    BeforeAll {
        $script:SeParent = Join-Path $TestDrive 'se'
        $script:SeOtherParent = Join-Path $TestDrive 'se-other'
        New-Item -ItemType Directory -Force -Path $script:SeParent, $script:SeOtherParent | Out-Null
        $seRepoDir = Join-Path $script:SeParent 'repo'
        $seOtherRepoDir = Join-Path $script:SeOtherParent 'repo'
        New-DelegateSeRepo $seRepoDir
        New-DelegateSeRepo $seOtherRepoDir
        $script:SeRepo = Get-DelegateRepoTop $seRepoDir
        $script:SeOtherRepo = Get-DelegateRepoTop $seOtherRepoDir
        $script:SeUvPath = [IO.Path]::GetFullPath((Join-Path $script:Here 'fixtures\sandbox-env\fake-uv.cmd'))
        $script:SeChildEnv = Get-ChildEnv $script:SafeCursor $script:SafeRoot $script:SafeLog
        $script:SeChildEnv['XAGENT_UV_PATH'] = $script:SeUvPath
        $script:SeChildEnv['XAGENT_SANDBOX_ROOT'] = Join-Path $TestDrive 'se-sandbox-root'
        New-Item -ItemType Directory -Force -Path $script:SeChildEnv['XAGENT_SANDBOX_ROOT'] | Out-Null
    }

    AfterAll {
        Remove-LaunchTree -Root $script:SeParent
        Remove-LaunchTree -Root $script:SeOtherParent
    }

    It 'prints a missing-env report without a built key' {
        $r = Invoke-DelegateChild -ArgumentList @('-SandboxEnv', '-Repo', $script:SeRepo) -ExtraEnv $script:SeChildEnv
        $because = Format-DelegateResult $r
        @($r.JsonLines).Count | Should -Be 1 -Because $because
        $r.ExitCode | Should -Be 0 -Because $because
        $r.Json.ok | Should -BeTrue -Because $because
        @($r.Json.projects).Count | Should -Be 1 -Because $because
        $r.Json.projects[0].status | Should -Be 'missing' -Because $because
        $r.Json.proposal | Should -Not -BeNullOrEmpty -Because $because
        $r.Json.PSObject.Properties.Name | Should -Not -Contain 'built' -Because $because
    }

    It 'applies environments and reports built, pruned, and failedNow arrays' {
        $r = Invoke-DelegateChild -ArgumentList @('-SandboxEnv', '-Repo', $script:SeRepo, '-Apply') -ExtraEnv $script:SeChildEnv
        $because = Format-DelegateResult $r
        $r.ExitCode | Should -Be 0 -Because $because
        $r.Json.ok | Should -BeTrue -Because $because
        @($r.Json.built).Count | Should -Be 1 -Because $because
        $r.Json.projects[0].status | Should -Be 'ready' -Because $because
        @($r.Json.pruned).Count | Should -Be 0 -Because $because
        @($r.Json.failedNow).Count | Should -Be 0 -Because $because
    }

    It 'reports install-failed when fake uv sync fails' {
        $failParent = Join-Path $TestDrive 'se-fail'
        $failRepoDir = Join-Path $failParent 'repo'
        New-DelegateSeRepo $failRepoDir
        $envMap = @{} + $script:SeChildEnv
        $envMap['FAKE_UV_FAIL'] = 'sync'
        try {
            $r = Invoke-DelegateChild -ArgumentList @('-SandboxEnv', '-Repo', (Get-DelegateRepoTop $failRepoDir), '-Apply') -ExtraEnv $envMap
            $because = Format-DelegateResult $r
            $r.ExitCode | Should -Be 0 -Because $because
            @($r.Json.failedNow).Count | Should -Be 1 -Because $because
            $r.Json.projects[0].status | Should -Be 'install-failed' -Because $because
        } finally {
            Remove-LaunchTree -Root $failParent
        }
    }

    It 'rebuilds one project and rejects a missing rebuild name' {
        $r = Invoke-DelegateChild -ArgumentList @('-SandboxEnv', '-Repo', $script:SeRepo, '-Apply', '-Rebuild', '.') -ExtraEnv $script:SeChildEnv
        $because = Format-DelegateResult $r
        $r.ExitCode | Should -Be 0 -Because $because
        @($r.Json.built).Count | Should -Be 1 -Because $because
        $bad = Invoke-DelegateChild -ArgumentList @('-SandboxEnv', '-Repo', $script:SeRepo, '-Apply', '-Rebuild', 'nosuch') -ExtraEnv $script:SeChildEnv
        $bbecause = Format-DelegateResult $bad
        $bad.ExitCode | Should -Be 1 -Because $bbecause
        $bad.Json.ok | Should -BeFalse -Because $bbecause
        $bad.Json.error | Should -BeLike '-Rebuild: no project nosuch*' -Because $bbecause
    }

    It 'returns environment-missing from -SandboxRun without probe worktrees' {
        $wtRoot = Get-DelegateWtRoot $script:SeOtherRepo
        if (-not (Test-Path -LiteralPath $wtRoot)) { New-Item -ItemType Directory -Force -Path $wtRoot | Out-Null }
        $before = @(Get-ChildItem -LiteralPath $wtRoot -Directory -Filter '.probe-*' -ErrorAction SilentlyContinue).Count
        $r = Invoke-DelegateChild -ArgumentList @('-SandboxRun', '-Repo', $script:SeOtherRepo, '-Command', 'exit 0') -ExtraEnv $script:SeChildEnv
        $because = Format-DelegateResult $r
        $r.ExitCode | Should -Be 0 -Because $because
        $r.Json.ok | Should -BeTrue -Because $because
        $r.Json.status | Should -Be 'environment-missing' -Because $because
        $r.Json.exitCode | Should -BeNullOrEmpty -Because $because
        $r.Json.message | Should -BeLike 'sandbox: environment not ready:*' -Because $because
        @(Get-ChildItem -LiteralPath $wtRoot -Directory -Filter '.probe-*' -ErrorAction SilentlyContinue).Count | Should -Be $before -Because $because
    }
}

Describe 'SandboxRun command' -Tag Sandbox {
    BeforeDiscovery {
        $script:SrSkipReason = Get-LaunchSkipReason -Kind Sandbox
        $script:SrSkip = [bool]$script:SrSkipReason
        if ($script:SrSkip) { Write-Host "SandboxRun command skipped: $script:SrSkipReason" }
    }

    BeforeAll {
        $script:SrLetters = $null
        $script:SrTestRoot = $null
        $script:SrRepo = $null
        if (Get-LaunchSkipReason -Kind Sandbox) { return }
        $script:SrRoot = Join-Path $TestDrive 'sr-root'
        $script:SrLog = Join-Path $TestDrive 'sr-log'
        New-Item -ItemType Directory -Force -Path $script:SrRoot, $script:SrLog | Out-Null
        $env:XAGENT_SANDBOX_ROOT = $script:SrRoot
        $env:XAGENT_CURSOR_ROOT = $script:FakeCursor
        Import-Module $script:ModulePath -Force
        $free = @(Get-TestFreeLetters)
        if ($free.Count -lt 3) { throw 'sandbox: fewer than three free letters D-Z at reservation time' }
        $script:SrLetters = @([string]$free[0], [string]$free[1], [string]$free[2])
        Set-SandboxLetters -Letters $script:SrLetters
        $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:SrTestRoot = Join-Path (Split-Path $script:RepoRoot -Qualifier) ('xagent-tests-' + $suffix)
        New-Item -ItemType Directory -Force -Path $script:SrTestRoot | Out-Null
        $script:SrRepo = Join-Path $script:SrTestRoot 'repo'
        New-LaunchRepo $script:SrRepo
    }

    AfterAll {
        if (Get-LaunchSkipReason -Kind Sandbox) { return }
        try {
            Clear-ReservedLetters -Letters $script:SrLetters
        } finally {
            Remove-LaunchTree -Root $script:SrTestRoot
        }
    }

    It 'runs a plain command in the sandbox and removes the probe worktree' -Skip:$script:SrSkip {
        $wtRoot = Get-DelegateWtRoot $script:SrRepo
        $before = @(Get-ChildItem -LiteralPath $wtRoot -Directory -Filter '.probe-*' -ErrorAction SilentlyContinue).Count
        $r = Invoke-DelegateChild -ArgumentList @('-SandboxRun', '-Repo', $script:SrRepo, '-Command', 'Write-Output hello; exit 3') -ExtraEnv (Get-ChildEnv $script:FakeCursor $script:SrRoot $script:SrLog) -WaitMs 180000
        $because = Format-DelegateResult $r
        @($r.JsonLines).Count | Should -Be 1 -Because $because
        $r.ExitCode | Should -Be 0 -Because $because
        $r.Json.ok | Should -BeTrue -Because $because
        $r.Json.status | Should -Be 'ran' -Because $because
        $r.Json.exitCode | Should -Be 3 -Because $because
        ($r.Json.output -join "`n") | Should -Match 'hello' -Because $because
        @(Get-ChildItem -LiteralPath $wtRoot -Directory -Filter '.probe-*' -ErrorAction SilentlyContinue).Count | Should -Be $before -Because $because
    }
}

Describe 'environment gate cleanup' {
    BeforeDiscovery {
        $script:EgNsSkipReason = Get-LaunchSkipReason -Kind Cursor
        $script:EgNsSkip = [bool]$script:EgNsSkipReason
        if ($script:EgNsSkip) { Write-Host "environment gate cleanup launch skipped: $script:EgNsSkipReason" }
    }

    BeforeAll {
        $script:EgCleanParent = Join-Path $TestDrive 'eg-clean'
        New-Item -ItemType Directory -Force -Path $script:EgCleanParent | Out-Null
    }

    AfterAll {
        Remove-LaunchTree -Root $script:EgCleanParent
    }

    It 'removes a .venv junction on -Cleanup and leaves the target' {
        $repoDir = Join-Path $script:EgCleanParent 'repo'
        New-DelegateSeRepo $repoDir
        $repo = Get-DelegateRepoTop $repoDir
        $task = 'eg-clean'
        $wt = Get-LaunchWorktree $repo $task
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $wt) | Out-Null
        Invoke-LaunchGit -ArgumentList @('-C', $repo, 'worktree', 'add', '-b', "xagent/$task", '--', $wt)
        $target = Join-Path $TestDrive ('envtarget-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        [IO.File]::WriteAllText((Join-Path $target 'keep.txt'), "keep`n", [Text.UTF8Encoding]::new($false))
        try {
            New-Item -ItemType Junction -Path (Join-Path $wt '.venv') -Target $target -ErrorAction Stop | Out-Null
        } catch {
            Set-ItResult -Skipped -Because 'cannot create a junction here'
            return
        }
        $r = Invoke-DelegateChild -ArgumentList @('-Cleanup', '-Repo', $repo, '-TaskId', $task) -ExtraEnv (Get-ChildEnv $script:SafeCursor $script:SafeRoot $script:SafeLog)
        $because = Format-DelegateResult $r
        @($r.JsonLines).Count | Should -Be 1 -Because $because
        $r.Json.ok | Should -BeTrue -Because $because
        Test-Path -LiteralPath $wt | Should -BeFalse -Because $because
        Test-Path -LiteralPath (Join-Path $target 'keep.txt') | Should -BeTrue -Because $because
    }

    It 'runs -NoSandbox in a repo with a Python project' -Skip:$script:EgNsSkip {
        $repoDir = Join-Path $script:EgCleanParent 'launch-repo'
        New-DelegateSeRepo $repoDir
        $repo = Get-DelegateRepoTop $repoDir
        $r = Invoke-DelegateChild -ArgumentList @(
            '-Agent', 'cursor', '-Profile', 'code', '-Model', 'composer-2.5',
            '-Repo', $repo, '-TaskId', 'eg-nosandbox', '-TaskFile', $script:TaskFile,
            '-TimeoutSec', '120', '-NoSandbox'
        ) -ExtraEnv (Get-ChildEnv $script:FakeCursor $script:SafeRoot $script:SafeLog)
        $because = Format-DelegateResult $r
        @($r.JsonLines).Count | Should -Be 1 -Because $because
        $r.ExitCode | Should -Be 0 -Because $because
        $r.Json.ok | Should -BeTrue -Because $because
    }
}

Describe 'environment gate' -Tag Sandbox {
    BeforeDiscovery {
        $script:EgSkipReason = Get-LaunchSkipReason -Kind Sandbox
        $script:EgSkip = [bool]$script:EgSkipReason
        if ($script:EgSkip) { Write-Host "environment gate skipped: $script:EgSkipReason" }
    }

    BeforeAll {
        $script:EgLetters = $null
        $script:EgTestRoot = $null
        $script:EgRepo = $null
        $script:EgPlainRepo = $null
        $script:EgLinkRepo = $null
        if (Get-LaunchSkipReason -Kind Sandbox) { return }
        $script:EgRoot = Join-Path $TestDrive 'eg-root'
        $script:EgLog = Join-Path $TestDrive 'eg-log'
        New-Item -ItemType Directory -Force -Path $script:EgRoot, $script:EgLog | Out-Null
        $env:XAGENT_SANDBOX_ROOT = $script:EgRoot
        $env:XAGENT_CURSOR_ROOT = $script:FakeCursor
        Import-Module $script:ModulePath -Force
        $free = @(Get-TestFreeLetters)
        if ($free.Count -lt 3) { throw 'sandbox: fewer than three free letters D-Z at reservation time' }
        $script:EgLetters = @([string]$free[0], [string]$free[1], [string]$free[2])
        Set-SandboxLetters -Letters $script:EgLetters
        $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:EgTestRoot = Join-Path (Split-Path $script:RepoRoot -Qualifier) ('xagent-tests-' + $suffix)
        New-Item -ItemType Directory -Force -Path $script:EgTestRoot | Out-Null
        $script:EgRepo = Join-Path $script:EgTestRoot 'py-repo'
        $script:EgPlainRepo = Join-Path $script:EgTestRoot 'plain-repo'
        $script:EgLinkRepo = Join-Path $script:EgTestRoot 'link-repo'
        New-DelegateSeRepo $script:EgRepo
        New-LaunchRepo $script:EgPlainRepo
        New-DelegateSeRepo $script:EgLinkRepo
    }

    AfterAll {
        if (Get-LaunchSkipReason -Kind Sandbox) { return }
        try {
            Clear-ReservedLetters -Letters $script:EgLetters
        } finally {
            Remove-LaunchTree -Root $script:EgTestRoot
        }
    }

    It 'fails a sandboxed launch before creating a worktree when the environment is not ready' -Skip:$script:EgSkip {
        $task = 'eg-missing'
        $r = Invoke-DelegateChild -ArgumentList @(
            '-Agent', 'cursor', '-Profile', 'code', '-Model', 'composer-2.5',
            '-Repo', $script:EgRepo, '-TaskId', $task, '-TaskFile', $script:TaskFile,
            '-TimeoutSec', '180'
        ) -ExtraEnv (Get-ChildEnv $script:FakeCursor $script:EgRoot $script:EgLog)
        $because = Format-DelegateResult $r
        @($r.JsonLines).Count | Should -Be 1 -Because $because
        $r.ExitCode | Should -Be 1 -Because $because
        $r.Json.ok | Should -BeFalse -Because $because
        $r.Json.error | Should -BeLike 'sandbox: environment not ready:*' -Because $because
        Test-Path -LiteralPath (Get-LaunchWorktree $script:EgRepo $task) | Should -BeFalse -Because $because
    }

    It 'leaves an existing worktree unchanged when the environment is not ready' -Skip:$script:EgSkip {
        $task = 'eg-existing'
        $prep = Invoke-DelegateChild -ArgumentList @(
            '-Agent', 'cursor', '-Profile', 'code', '-Model', 'composer-2.5',
            '-Repo', $script:EgRepo, '-TaskId', $task, '-TaskFile', $script:TaskFile,
            '-TimeoutSec', '120', '-NoSandbox'
        ) -ExtraEnv (Get-ChildEnv $script:FakeCursor $script:EgRoot $script:EgLog)
        $because = Format-DelegateResult $prep
        $prep.ExitCode | Should -Be 0 -Because $because
        $wt = Get-LaunchWorktree $script:EgRepo $task
        $statusBefore = (@(& git.exe -C $wt status --porcelain --untracked-files=all) | ForEach-Object { "$_" }) -join "`n"
        $tasksBefore = @((Get-ChildItem -LiteralPath (Join-Path $wt '.xagent') -Filter 'task-*.md' -File | ForEach-Object Name | Sort-Object)) -join "`n"
        $tasksBefore | Should -Not -BeNullOrEmpty -Because $because
        $r = Invoke-DelegateChild -ArgumentList @(
            '-Agent', 'cursor', '-Profile', 'code', '-Model', 'composer-2.5',
            '-Repo', $script:EgRepo, '-TaskId', $task, '-TaskFile', $script:TaskFile,
            '-TimeoutSec', '180'
        ) -ExtraEnv (Get-ChildEnv $script:FakeCursor $script:EgRoot $script:EgLog)
        $because = Format-DelegateResult $r
        @($r.JsonLines).Count | Should -Be 1 -Because $because
        $r.ExitCode | Should -Be 1 -Because $because
        $r.Json.error | Should -BeLike 'sandbox: environment not ready:*' -Because $because
        $statusAfter = (@(& git.exe -C $wt status --porcelain --untracked-files=all) | ForEach-Object { "$_" }) -join "`n"
        $tasksAfter = @((Get-ChildItem -LiteralPath (Join-Path $wt '.xagent') -Filter 'task-*.md' -File | ForEach-Object Name | Sort-Object)) -join "`n"
        $statusAfter | Should -Be $statusBefore -Because $because
        $tasksAfter | Should -Be $tasksBefore -Because $because
    }

    It 'runs a sandboxed launch when the repo has no Python projects' -Skip:$script:EgSkip {
        $r = Invoke-DelegateChild -ArgumentList @(
            '-Agent', 'cursor', '-Profile', 'code', '-Model', 'composer-2.5',
            '-Repo', $script:EgPlainRepo, '-TaskId', 'eg-plain', '-TaskFile', $script:TaskFile,
            '-TimeoutSec', '180'
        ) -ExtraEnv (Get-ChildEnv $script:FakeCursor $script:EgRoot $script:EgLog)
        $because = Format-DelegateResult $r
        @($r.JsonLines).Count | Should -Be 1 -Because $because
        $r.ExitCode | Should -Be 0 -Because $because
        $r.Json.ok | Should -BeTrue -Because $because
        $r.Json.sandboxed | Should -BeTrue -Because $because
    }

    It 'links a ready environment and omits .venv from changes' -Skip:$script:EgSkip {
        $envMap = Get-ChildEnv $script:FakeCursor $script:EgRoot $script:EgLog
        $envMap['XAGENT_UV_PATH'] = [IO.Path]::GetFullPath((Join-Path $script:Here 'fixtures\sandbox-env\fake-uv.cmd'))
        $apply = Invoke-DelegateChild -ArgumentList @('-SandboxEnv', '-Repo', $script:EgLinkRepo, '-Apply') -ExtraEnv $envMap
        $because = Format-DelegateResult $apply
        $apply.ExitCode | Should -Be 0 -Because $because
        $apply.Json.ok | Should -BeTrue -Because $because
        $apply.Json.projects[0].status | Should -Be 'ready' -Because $because
        $r = Invoke-DelegateChild -ArgumentList @(
            '-Agent', 'cursor', '-Profile', 'code', '-Model', 'composer-2.5',
            '-Repo', $script:EgLinkRepo, '-TaskId', 'eg-link', '-TaskFile', $script:TaskFile,
            '-TimeoutSec', '180'
        ) -ExtraEnv $envMap
        $because = Format-DelegateResult $r
        @($r.JsonLines).Count | Should -Be 1 -Because $because
        $r.ExitCode | Should -Be 0 -Because $because
        $r.Json.ok | Should -BeTrue -Because $because
        $venv = Join-Path (Get-LaunchWorktree $script:EgLinkRepo 'eg-link') '.venv'
        Test-Path -LiteralPath $venv | Should -BeTrue -Because $because
        (Get-Item -LiteralPath $venv -Force).LinkType | Should -Be 'Junction' -Because $because
        @(@($r.Json.changes) | Where-Object { $null -ne $_ -and (($_ -replace '^.. ', '') -match '(^|/)\.venv/?$') }).Count | Should -Be 0 -Because $because
    }
}
