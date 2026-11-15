#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Settings are fixed at import. Tests set XAGENT_SANDBOX_ROOT and XAGENT_CURSOR_ROOT first.
$script:Root = if ($env:XAGENT_SANDBOX_ROOT) { $env:XAGENT_SANDBOX_ROOT } else { Join-Path $env:LOCALAPPDATA 'xagent' }
$script:CursorRoot = if ($env:XAGENT_CURSOR_ROOT) { $env:XAGENT_CURSOR_ROOT } else { Join-Path $env:LOCALAPPDATA 'cursor-agent' }
$script:ConfigPath = Join-Path $script:Root 'sandbox.json'
$script:SandboxDir = Join-Path $script:Root 'sandbox'
$script:CacheRoot = Join-Path $script:SandboxDir 'cursor'
$script:IdleDir = Join-Path $script:SandboxDir 'idle'
# Tests point these at a fake profile through InModuleScope. Never copy the real login in a test.
$script:LoginProfile = $env:USERPROFILE
$script:LoginAppData = $env:APPDATA
$script:MinimumBuild = 26300
$script:VersionPattern = '^\d{4}\.\d{1,2}\.\d{1,2}(-\d{2}-\d{2}-\d{2})?-[a-f0-9]+$'
# \\?\pipe\uv\%llu-%lu  and  \\?\pipe\LOCAL\%llu plus a null. The original terminator after these 20 bytes stays.
$script:PipePattern = [byte[]](0x5C, 0x5C, 0x3F, 0x5C, 0x70, 0x69, 0x70, 0x65, 0x5C, 0x75, 0x76, 0x5C, 0x25, 0x6C, 0x6C, 0x75, 0x2D, 0x25, 0x6C, 0x75)
$script:PipeReplacement = [byte[]](0x5C, 0x5C, 0x3F, 0x5C, 0x70, 0x69, 0x70, 0x65, 0x5C, 0x4C, 0x4F, 0x43, 0x41, 0x4C, 0x5C, 0x25, 0x6C, 0x6C, 0x75, 0x00)

if (-not ('XagentSandbox' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'SandboxNative.cs')
}

function Parse-VersionString {
    param(
        [string]$versionString
    )

    # Split on '-' to remove the commit hash part
    $datePart = $versionString.Split('-')[0]

    # Split on '.' to get year, month, day
    $parts = $datePart.Split('.')

    # Ensure we have exactly 3 parts (year, month, day)
    if ($parts.Length -ne 3) {
        throw "Invalid version format. Expected format: YYYY.MM.DD-commit"
    }

    # Pad month and day to 2 digits if needed, then concatenate
    $year = $parts[0]
    $month = $parts[1].PadLeft(2, '0')
    $day = $parts[2].PadLeft(2, '0')

    # Return as integer for proper numeric comparison
    return [int]($year + $month + $day)
}

function Get-ObjectProperty($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Resolve-SandboxPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-SamePath([string]$Left, [string]$Right) {
    return [string]::Equals((Resolve-SandboxPath $Left), (Resolve-SandboxPath $Right), [StringComparison]::OrdinalIgnoreCase)
}

function Test-SameHash([string]$Left, [string]$Right) {
    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
    return [string]::Equals($Left.Trim(), $Right.Trim(), [StringComparison]::OrdinalIgnoreCase)
}

function Get-SandboxFileHash([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $hash = $sha.ComputeHash($stream)
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
    return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
}

function Get-CursorVersionName([string]$CursorRoot) {
    $versionsDir = Join-Path $CursorRoot 'versions'
    if (-not (Test-Path -LiteralPath $versionsDir)) { return $null }
    $dirs = @(Get-ChildItem -LiteralPath $versionsDir -Directory | Where-Object { $_.Name -match $script:VersionPattern })
    if ($dirs.Count -eq 0) { return $null }
    $picked = $dirs | Sort-Object { Parse-VersionString $_.Name } -Descending | Select-Object -First 1
    return $picked.Name
}

function Get-VersionMissingMessage([string]$CursorRoot) {
    $versionsDir = Join-Path $CursorRoot 'versions'
    return "Cursor CLI not found at $versionsDir (no version folder matches)"
}

function ConvertTo-UvVersion([string]$Raw) {
    $text = $Raw.Trim()
    if (($text.StartsWith("'") -and $text.EndsWith("'")) -or ($text.StartsWith('"') -and $text.EndsWith('"'))) {
        if ($text.Length -ge 2) { $text = $text.Substring(1, $text.Length - 2).Trim() }
    }
    $base = ($text -split '-', 2)[0].Trim()
    if (-not $base) { throw 'no output' }
    return [version]$base
}

function Test-UvAtLeast153([version]$Version) {
    if ($Version.Major -gt 1) { return $true }
    if ($Version.Major -lt 1) { return $false }
    return ($Version.Minor -ge 53)
}

function Read-NodeUv([string]$NodeExe, [scriptblock]$UvProbe) {
    $rawResult = $null
    try {
        $rawResult = & $UvProbe $NodeExe
    } catch {
        $reason = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'no output' }
        return @{ ok = $false; reason = $reason.Trim() }
    }
    if ($null -eq $rawResult) { return @{ ok = $false; reason = 'no output' } }
    if ($rawResult -is [version]) {
        return @{ ok = $true; raw = $rawResult.ToString(); version = [version]$rawResult }
    }
    $text = ((@($rawResult) | ForEach-Object { "$_" }) -join "`n").Trim()
    if (-not $text) { return @{ ok = $false; reason = 'no output' } }
    try {
        $version = ConvertTo-UvVersion $text
    } catch {
        $reason = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'no output' }
        return @{ ok = $false; reason = $reason.Trim() }
    }
    return @{ ok = $true; raw = $text; version = $version }
}

function Invoke-DefaultUvProbe {
    param([Parameter(Mandatory)][string]$NodeExe)
    $id = [guid]::NewGuid().ToString('N')
    $stdout = Join-Path ([IO.Path]::GetTempPath()) "xagent-uv-$id.out"
    $stderr = Join-Path ([IO.Path]::GetTempPath()) "xagent-uv-$id.err"
    $proc = $null
    try {
        $work = [IO.Path]::GetDirectoryName($NodeExe)
        $proc = Start-Process -FilePath $NodeExe -ArgumentList @('-p', 'process.versions.uv') -WorkingDirectory $work -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ErrorAction Stop
        if (-not $proc.WaitForExit(5000)) {
            try { $proc.Kill($true) } catch {}
            try { $null = $proc.WaitForExit(2000) } catch {}
            throw 'timed out after 5 s'
        }
        $text = ''
        if (Test-Path -LiteralPath $stdout) { $text = [IO.File]::ReadAllText($stdout).Trim() }
        if ($proc.ExitCode -ne 0) { throw "exit code $($proc.ExitCode)" }
        if (-not $text) { throw 'no output' }
        return $text
    } finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

function Get-PatternProblem([string]$Version, [int]$Count) {
    return "Cursor ${Version}: node.exe pipe-name pattern found $Count times; Sandbox.psm1 needs an update (use -NoSandbox to run unsandboxed)"
}

function Get-PipePatternOffsets([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return ,@() }
    $found = [XagentSandbox]::FindFilePattern($Path, $script:PipePattern)
    return ,$found
}

function Set-PipePattern([string]$Path, [int]$Offset) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    for ($i = 0; $i -lt $script:PipeReplacement.Length; $i++) {
        $bytes[$Offset + $i] = $script:PipeReplacement[$i]
    }
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Write-PatchJson([string]$Directory, $Body) {
    $json = ($Body | ConvertTo-Json -Depth 6) + "`n"
    [IO.File]::WriteAllText((Join-Path $Directory 'patch.json'), $json, [Text.UTF8Encoding]::new($false))
}

function Remove-SandboxTree([string]$Path, [string]$Version) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch {
        throw "sandbox: Cursor ${Version}: cannot replace cache folder ${Path} (in use?): $($_.Exception.Message)"
    }
}

function Test-CachedRuntime([string]$Dest, [string]$SourceNode) {
    $patchPath = Join-Path $Dest 'patch.json'
    $cachedNode = Join-Path $Dest 'node.exe'
    if (-not (Test-Path -LiteralPath $patchPath) -or -not (Test-Path -LiteralPath $cachedNode)) { return $null }
    try {
        $patch = [IO.File]::ReadAllText($patchPath) | ConvertFrom-Json
    } catch {
        return $null
    }
    $cachedHash = Get-SandboxFileHash $cachedNode
    $patchedFlag = [bool](Get-ObjectProperty $patch 'patched')
    $uvText = [string](Get-ObjectProperty $patch 'uv')
    if (-not $patchedFlag) {
        try { $version = ConvertTo-UvVersion $uvText } catch { return $null }
        if (-not (Test-UvAtLeast153 $version)) { return $null }
        if (-not (Test-Path -LiteralPath $SourceNode)) { return $null }
        $sourceHash = Get-SandboxFileHash $SourceNode
        if (-not (Test-SameHash $cachedHash $sourceHash)) { return $null }
        return @{ uv = $uvText; patched = $false }
    }
    $recorded = [string](Get-ObjectProperty $patch 'patchedSha256')
    if (-not (Test-SameHash $cachedHash $recorded)) { return $null }
    $sourceRecorded = Get-ObjectProperty $patch 'sourceSha256'
    if ($sourceRecorded -is [string] -and -not [string]::IsNullOrWhiteSpace($sourceRecorded)) {
        if (-not (Test-Path -LiteralPath $SourceNode)) { return $null }
        $sourceHash = Get-SandboxFileHash $SourceNode
        if (-not (Test-SameHash $sourceHash $sourceRecorded)) { return $null }
    }
    return @{ uv = $uvText; patched = $true }
}

function Test-SandboxLedgerField($Ledger, [string]$Name) {
    if ($null -eq $Ledger) { return $false }
    if ($Ledger -is [System.Collections.IDictionary]) {
        if (-not $Ledger.Contains($Name)) { return $false }
        return $null -ne $Ledger[$Name]
    }
    $prop = $Ledger.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $false }
    return $null -ne $prop.Value
}

function Copy-SandboxLedgerTable($Ledger) {
    $table = [ordered]@{}
    if ($Ledger -is [System.Collections.IDictionary]) {
        foreach ($key in @($Ledger.Keys)) {
            $table[[string]$key] = $Ledger[$key]
        }
    } else {
        foreach ($prop in @($Ledger.PSObject.Properties)) {
            $table[$prop.Name] = $prop.Value
        }
    }
    return $table
}

function Read-SandboxLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $obj = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    } catch {
        return $null
    }
    if ($obj -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $grants = Get-ObjectProperty $obj 'grants'
    if ($null -eq $grants) {
        $items = @()
    } else {
        $items = @($grants)
    }
    $arr = New-Object object[] $items.Count
    for ($i = 0; $i -lt $items.Count; $i++) { $arr[$i] = $items[$i] }
    if ($null -eq $obj.PSObject.Properties['grants']) {
        $obj | Add-Member -NotePropertyName 'grants' -NotePropertyValue $arr
    } else {
        $obj.PSObject.Properties['grants'].Value = $arr
    }
    return $obj
}

function Write-SandboxLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Ledger
    )
    foreach ($name in @('slot', 'sid', 'pid', 'startTime', 'runtimeVersion', 'worktree', 'grants')) {
        if (-not (Test-SandboxLedgerField $Ledger $name)) {
            throw "sandbox: ledger is missing field '$name'"
        }
    }
    $table = Copy-SandboxLedgerTable $Ledger
    $start = $table['startTime']
    if ($start -is [datetime]) {
        $table['startTime'] = $start.ToUniversalTime().ToString('o')
    }
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrEmpty($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $json = ($table | ConvertTo-Json -Depth 6) + "`n"
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Get-LedgerRuntimeVersions([string]$SandboxDir) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $SandboxDir)) { return $set }
    foreach ($file in @(Get-ChildItem -LiteralPath $SandboxDir -Filter 'slot-?.json' -File -ErrorAction SilentlyContinue)) {
        $obj = Read-SandboxLedger -Path $file.FullName
        if ($null -eq $obj) { continue }
        $value = Get-ObjectProperty $obj 'runtimeVersion'
        if ($value -is [string] -and -not [string]::IsNullOrWhiteSpace($value)) {
            [void]$set.Add($value)
        }
    }
    Write-Output -NoEnumerate $set
}

function Invoke-SandboxCachePrune([string]$CacheRoot, [string]$KeepVersion) {
    $sandboxDir = Split-Path -Parent $CacheRoot
    $partials = @(Get-ChildItem -LiteralPath $CacheRoot -Force -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.Name.EndsWith('.partial') -and $_.Name -ne ($KeepVersion + '.partial')
    })
    foreach ($dir in $partials) {
        try {
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop
        } catch {
            throw "sandbox: Cursor ${KeepVersion}: cannot prune runtime cache folder $($dir.FullName): $($_.Exception.Message)"
        }
    }

    $ledger = Get-LedgerRuntimeVersions -SandboxDir $sandboxDir
    $versions = @(Get-ChildItem -LiteralPath $CacheRoot -Force -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match $script:VersionPattern
    })
    $sorted = @($versions | Sort-Object { Parse-VersionString $_.Name } -Descending)
    $keep = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [void]$keep.Add($KeepVersion)
    $take = [Math]::Min(2, $sorted.Count)
    for ($i = 0; $i -lt $take; $i++) { [void]$keep.Add($sorted[$i].Name) }
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        if ([string]::Equals($sorted[$i].Name, $KeepVersion, [StringComparison]::OrdinalIgnoreCase)) {
            if (($i + 1) -lt $sorted.Count) { [void]$keep.Add($sorted[$i + 1].Name) }
            break
        }
    }
    foreach ($name in $ledger) { [void]$keep.Add($name) }
    foreach ($dir in $versions) {
        if ($keep.Contains($dir.Name)) { continue }
        try {
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop
        } catch {
            throw "sandbox: Cursor ${KeepVersion}: cannot prune runtime cache folder $($dir.FullName): $($_.Exception.Message)"
        }
    }
}

function Get-SubstMap {
    $map = @{}
    $lines = @(& subst.exe 2>&1)
    foreach ($line in $lines) {
        $text = [string]$line
        if ($text -match '^([A-Za-z]):\\: => (.*)$') {
            $map[$Matches[1].ToUpperInvariant()] = $Matches[2].Trim()
        }
    }
    return $map
}

function Get-DriveLetters {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        if ($drive.Name) { [void]$set.Add($drive.Name.Substring(0, 1).ToUpperInvariant()) }
    }
    Write-Output -NoEnumerate $set
}

function Test-LetterFreeWithMap {
    param([string]$Letter, $Map, $Drives)
    $Letter = $Letter.Trim().ToUpperInvariant()
    if ($Letter -notmatch '^[A-Z]$') { return 'used' }
    if ($Map.ContainsKey($Letter)) {
        return ('ours:' + (Resolve-SandboxPath $Map[$Letter]))
    }
    if ($Drives.Contains($Letter)) { return 'used' }
    return 'free'
}

function Test-LetterFree {
    param(
        [Parameter(Mandatory)][string]$Letter
    )
    return Test-LetterFreeWithMap -Letter $Letter -Map (Get-SubstMap) -Drives (Get-DriveLetters)
}

function Test-OursTarget([string]$Status, [string]$Expected) {
    if (-not $Status.StartsWith('ours:')) { return $false }
    return (Test-SamePath $Status.Substring(5) $Expected)
}

function ConvertTo-LetterList($Raw) {
    $list = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Raw) { return ,$list.ToArray() }
    $items = if ($Raw -is [string]) { ,$Raw } else { @($Raw) }
    foreach ($slot in $items) {
        if ($null -eq $slot) { continue }
        $text = ([string]$slot).Trim().ToUpperInvariant()
        if ($text) { $list.Add($text) }
    }
    return ,$list.ToArray()
}

function Get-LettersShape($Letters) {
    $runtime = $null
    $slots = [string[]]::new(0)
    $reserved = $false
    if ($null -ne $Letters) {
        $runtimeText = Get-ObjectProperty $Letters 'runtime'
        if (-not [string]::IsNullOrWhiteSpace([string]$runtimeText)) {
            $runtime = ([string]$runtimeText).Trim().ToUpperInvariant()
            $reserved = $true
        }
        $slots = ConvertTo-LetterList (Get-ObjectProperty $Letters 'slots')
        if ($slots.Count -gt 0) { $reserved = $true }
    }
    return @{ reserved = $reserved; runtime = $runtime; slots = $slots }
}

function Get-FreeLetterSuggestions {
    $map = Get-SubstMap
    $drives = Get-DriveLetters
    $found = New-Object System.Collections.Generic.List[string]
    for ($code = 90; $code -ge 68; $code--) {
        $letter = [string][char]$code
        if ((Test-LetterFreeWithMap -Letter $letter -Map $map -Drives $drives) -eq 'free') {
            $found.Add($letter)
            if ($found.Count -eq 3) { break }
        }
    }
    Write-Output -NoEnumerate $found.ToArray()
}

function Invoke-SubstMap([string]$Letter, [string]$Target) {
    $output = @(& subst.exe "${Letter}:" $Target 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $text = (@($output) | ForEach-Object { "$_" }) -join ' '
        throw "sandbox: subst ${Letter}: failed ($text)"
    }
}

function Test-LedgerProcessLive([string]$LedgerPath) {
    $obj = Read-SandboxLedger -Path $LedgerPath
    if ($null -eq $obj) { return $false }
    $processIdText = Get-ObjectProperty $obj 'pid'
    $start = Get-ObjectProperty $obj 'startTime'
    if ($null -eq $processIdText -or $null -eq $start) { return $false }
    $processId = 0
    if (-not [int]::TryParse([string]$processIdText, [ref]$processId) -or $processId -le 0) { return $false }
    try {
        $proc = Get-Process -Id $processId -ErrorAction Stop
    } catch {
        return $false
    }
    try {
        $expected = if ($start -is [datetime]) { $start.ToUniversalTime() } else { ([datetime][string]$start).ToUniversalTime() }
    } catch {
        return $false
    }
    $delta = [Math]::Abs(($proc.StartTime.ToUniversalTime() - $expected).TotalSeconds)
    return ($delta -lt 2)
}

function Get-ReservedLetterState {
    param(
        [string]$Letter,
        [string]$Expected,
        [string]$LedgerPath,
        [bool]$Slot,
        $Map,
        $Drives
    )
    $status = Test-LetterFreeWithMap -Letter $Letter -Map $Map -Drives $Drives
    if ($status -eq 'free') { return 'free' }
    if ($status -eq 'used') { return 'used' }
    $target = $status.Substring(5)
    if (Test-SamePath $target $Expected) { return 'ours' }
    if ($Slot -and (Test-LedgerProcessLive $LedgerPath)) { return 'busy' }
    return 'used'
}

function Save-SandboxConfig($Config) {
    $dir = Split-Path -Parent $script:ConfigPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $json = ($Config | ConvertTo-Json -Depth 30) + "`n"
    [IO.File]::WriteAllText($script:ConfigPath, $json, [Text.UTF8Encoding]::new($false))
}

function Resolve-SandboxCall {
    param($Bound, [string]$CursorRoot, [string]$CacheRoot, [scriptblock]$UvProbe)
    $cursor = $CursorRoot
    if (-not $Bound.ContainsKey('CursorRoot') -or [string]::IsNullOrWhiteSpace($CursorRoot)) { $cursor = $script:CursorRoot }
    $cache = $CacheRoot
    if (-not $Bound.ContainsKey('CacheRoot') -or [string]::IsNullOrWhiteSpace($CacheRoot)) { $cache = $script:CacheRoot }
    $probe = $UvProbe
    if (-not $Bound.ContainsKey('UvProbe') -or $null -eq $UvProbe) { $probe = $script:DefaultUvProbe }
    return @{
        CursorRoot = $cursor
        CacheRoot = [IO.Path]::GetFullPath($cache)
        UvProbe = $probe
    }
}

function New-EmptyLetters {
    return @{
        reserved = $false
        runtime = $null
        slots = [string[]]::new(0)
        states = @{}
    }
}

function New-SupportResult {
    param(
        [bool]$Ok,
        [int]$Build,
        $CursorVersion,
        $Uv,
        $PatternCount,
        $Letters,
        [AllowEmptyCollection()][string[]]$Problems
    )
    # An empty array assigned from if/pipeline output collapses to $null. Build it directly.
    $storedProblems = New-Object string[] 0
    if ($null -ne $Problems -and $Problems.Length -gt 0) {
        $storedProblems = [string[]]$Problems
    }
    return @{
        ok = $Ok
        build = $Build
        cursorVersion = $CursorVersion
        uv = $Uv
        patternCount = $PatternCount
        letters = $Letters
        problems = $storedProblems
    }
}

function Get-SupportConfigLayout([string]$CacheRoot) {
    $cacheFull = [IO.Path]::GetFullPath($CacheRoot)
    $sandboxDir = Split-Path -Parent $cacheFull
    $root = Split-Path -Parent $sandboxDir
    return @{
        Cache = $cacheFull
        SandboxDir = $sandboxDir
        Root = $root
        ConfigPath = (Join-Path $root 'sandbox.json')
    }
}

function Read-SupportConfig([string]$CacheRoot) {
    $layout = Get-SupportConfigLayout $CacheRoot
    if (-not (Test-Path -LiteralPath $layout.ConfigPath)) {
        return @{ Ok = $true; Config = $null; Error = $null }
    }
    try {
        $parsed = [IO.File]::ReadAllText($layout.ConfigPath) | ConvertFrom-Json
        return @{ Ok = $true; Config = $parsed; Error = $null }
    } catch {
        return @{ Ok = $false; Config = $null; Error = $_.Exception.Message }
    }
}

function Get-SupportLetters([string]$CacheRoot, $Config, $Problems) {
    $layout = Get-SupportConfigLayout $CacheRoot
    $lettersObj = $null
    if ($null -ne $Config) {
        $lettersObj = Get-ObjectProperty $Config 'letters'
    }
    $shape = Get-LettersShape $lettersObj
    if (-not $shape.reserved) { return New-EmptyLetters }

    $cursor = Join-Path $layout.SandboxDir 'cursor'
    $idle = Join-Path $layout.SandboxDir 'idle'
    $map = Get-SubstMap
    $drives = Get-DriveLetters
    $states = @{}
    $entries = New-Object System.Collections.Generic.List[object]
    if ($shape.runtime) {
        $entries.Add([pscustomobject]@{ Letter = $shape.runtime; Expected = $cursor; Slot = $false })
    }
    foreach ($slot in @($shape.slots)) {
        $entries.Add([pscustomobject]@{ Letter = $slot; Expected = $idle; Slot = $true })
    }
    foreach ($entry in $entries) {
        $ledger = Join-Path $layout.SandboxDir ("slot-$($entry.Letter).json")
        $state = Get-ReservedLetterState -Letter $entry.Letter -Expected $entry.Expected -LedgerPath $ledger -Slot:([bool]$entry.Slot) -Map $map -Drives $drives
        $states[$entry.Letter] = $state
        if ($state -eq 'used') {
            $Problems.Add("reserved letter $($entry.Letter): is used by another drive; choose new letters")
        }
    }
    return @{
        reserved = $true
        runtime = $shape.runtime
        slots = [string[]]$shape.slots
        states = $states
    }
}

# Separator-bounded: C:\Users\me2 is not under C:\Users\me. Both arguments are already normalized.
function Test-SandboxPathUnder([string]$Candidate, [string]$Folder) {
    if ([string]::IsNullOrEmpty($Candidate) -or [string]::IsNullOrEmpty($Folder)) { return $false }
    if ([string]::Equals($Candidate, $Folder, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $Folder.TrimEnd('\', '/') + '\'
    return $Candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Test-SandboxReadObject($Entry) {
    if ($null -eq $Entry) { return $false }
    if ($Entry -is [string] -or $Entry -is [System.ValueType]) { return $false }
    if ($Entry -is [System.Collections.IDictionary]) { return $true }
    if ($Entry -is [System.Management.Automation.PSCustomObject]) { return $true }
    if ($Entry -is [System.Collections.IEnumerable]) { return $false }
    return $true
}

function Format-ReadListProblem([string]$Path, [string]$Reason) {
    return "read-list entry '$Path' $Reason; edit sandbox.json"
}

function Get-SandboxProfileRoot {
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { return $null }
    return [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\', '/')
}

function Add-SandboxProtectedFolders($Folders) {
    $profile = Get-SandboxProfileRoot
    if ($profile) {
        foreach ($leaf in @('.ssh', '.aws', '.gnupg', '.cursor', 'AppData\Roaming')) {
            $Folders.Add([IO.Path]::GetFullPath((Join-Path $profile $leaf)).TrimEnd('\', '/'))
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $Folders.Add([IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'cursor-agent')).TrimEnd('\', '/'))
    }
}

# reason is $null when the entry is allowed. path is the message text when refused, and the normalized full path when allowed.
function Resolve-SandboxReadEntry($Entry) {
    $raw = $null
    $hasRaw = $false
    if (Test-SandboxReadObject $Entry) {
        $raw = Get-ObjectProperty $Entry 'path'
        $hasRaw = $true
    }
    if (-not $hasRaw -or $raw -isnot [string] -or $raw.Length -eq 0) {
        $shown = ''
        if ($null -ne $raw -and $raw -isnot [string]) { $shown = [string]$raw }
        return @{ path = $shown; addToPath = $false; reason = 'is not a valid path' }
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($raw)
    if ($expanded.Length -gt 0 -and $expanded[0] -eq [char]'~') {
        $profileRoot = Get-SandboxProfileRoot
        if ($null -eq $profileRoot) { $profileRoot = '' }
        $expanded = $profileRoot + $expanded.Substring(1)
    }

    # GetFullPath turns a relative path into an absolute one, so the absolute check uses the expanded text.
    try {
        $full = [IO.Path]::GetFullPath($expanded)
    } catch {
        return @{ path = $raw; addToPath = $false; reason = 'is not a valid path' }
    }
    if (-not [IO.Path]::IsPathFullyQualified($expanded)) {
        return @{ path = $expanded.TrimEnd('\', '/'); addToPath = $false; reason = 'is not an absolute path' }
    }
    # GetFullPath keeps the path the user wrote when it only changes case or a trailing separator.
    $normalized = $full.TrimEnd('\', '/')
    $authored = $expanded.Replace('/', '\').TrimEnd('\')
    if ([string]::Equals($normalized, $authored, [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $authored
    }

    $profile = Get-SandboxProfileRoot
    if ($profile -and [string]::Equals($normalized, $profile, [StringComparison]::OrdinalIgnoreCase)) {
        return @{ path = $normalized; addToPath = $false; reason = 'is the profile root' }
    }

    $protected = New-Object System.Collections.Generic.List[string]
    Add-SandboxProtectedFolders $protected
    foreach ($folder in $protected) {
        if (Test-SandboxPathUnder $normalized $folder) {
            return @{ path = $normalized; addToPath = $false; reason = "is under a protected folder ($folder)" }
        }
    }

    $sandboxRoot = $null
    if (-not [string]::IsNullOrWhiteSpace($script:Root)) {
        $sandboxRoot = [IO.Path]::GetFullPath($script:Root).TrimEnd('\', '/')
    }
    if ($sandboxRoot -and (Test-SandboxPathUnder $normalized $sandboxRoot)) {
        return @{ path = $normalized; addToPath = $false; reason = "is under the sandbox's own folder" }
    }

    if (-not (Test-Path -LiteralPath $normalized)) {
        return @{ path = $normalized; addToPath = $false; reason = 'does not exist' }
    }

    $addToPath = $false
    $flag = Get-ObjectProperty $Entry 'addToPath'
    if ($null -ne $flag) { $addToPath = [bool]$flag }
    return @{ path = $normalized; addToPath = $addToPath; reason = $null }
}

function Add-SandboxReadListProblems($Config, $Problems) {
    if ($null -eq $Config) { return }
    $read = Get-ObjectProperty $Config 'read'
    if ($null -eq $read) { return }
    foreach ($entry in @($read)) {
        $resolved = Resolve-SandboxReadEntry $entry
        if ($null -ne $resolved.reason) {
            $Problems.Add((Format-ReadListProblem $resolved.path $resolved.reason))
        }
    }
}

function Test-SandboxReadList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Entries
    )
    $result = New-Object System.Collections.Generic.List[pscustomobject]
    if ($null -ne $Entries) {
        foreach ($entry in @($Entries)) {
            $resolved = Resolve-SandboxReadEntry $entry
            if ($null -ne $resolved.reason) {
                throw ("sandbox: " + (Format-ReadListProblem $resolved.path $resolved.reason))
            }
            $result.Add([pscustomobject]@{ path = [string]$resolved.path; addToPath = [bool]$resolved.addToPath })
        }
    }
    Write-Output -NoEnumerate $result.ToArray()
}

function Assert-SandboxOutsideProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    $profile = Get-SandboxProfileRoot
    if (-not $profile) { return }
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if (Test-SandboxPathUnder $full $profile) {
        throw 'sandbox: repos under the user profile are not supported'
    }
}

function Get-SandboxEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Slot,
        [AllowNull()][AllowEmptyCollection()][object[]]$ReadList
    )
    # SandboxNative.cs sorts the block. The names are the whole environment the child receives.
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('SystemRoot', 'windir', 'ComSpec', 'PATHEXT', 'NUMBER_OF_PROCESSORS', 'PROCESSOR_ARCHITECTURE', 'OS')) {
        $value = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if ($null -eq $value) { $value = '' }
        $list.Add("${name}=${value}")
    }

    $pathValue = 'C:\Windows\System32;C:\Windows;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Program Files\PowerShell\7;C:\Program Files\Git\cmd'
    if ($null -ne $ReadList) {
        foreach ($entry in @($ReadList)) {
            if ($null -eq $entry) { continue }
            $add = Get-ObjectProperty $entry 'addToPath'
            if (-not $add) { continue }
            $entryPath = Get-ObjectProperty $entry 'path'
            if ($null -eq $entryPath) { $entryPath = '' }
            $pathValue = $pathValue + ';' + [string]$entryPath
        }
    }
    $list.Add("PATH=$pathValue")
    $list.Add('PSModulePath=C:\Program Files\PowerShell\Modules;C:\Program Files\PowerShell\7\Modules')

    $homeDir = $Slot + ':\.xagent\sandbox\home'
    $tmp = $Slot + ':\.xagent\sandbox\tmp'
    $list.Add("USERPROFILE=$homeDir")
    $list.Add("HOME=$homeDir")
    $list.Add("APPDATA=$homeDir\AppData\Roaming")
    $list.Add("LOCALAPPDATA=$homeDir\AppData\Local")
    $list.Add("TEMP=$tmp")
    $list.Add("TMP=$tmp")
    $list.Add('CURSOR_INVOKED_AS=agent.cmd')
    $list.Add("NODE_COMPILE_CACHE=$tmp\node-compile-cache")
    Write-Output -NoEnumerate $list.ToArray()
}

function Get-WindowsBuild {
    return [int][Environment]::OSVersion.Version.Build
}

$script:DefaultUvProbe = ${function:Invoke-DefaultUvProbe}

function Test-SandboxSupport {
    [CmdletBinding()]
    param(
        [string]$CursorRoot,
        [string]$CacheRoot,
        [scriptblock]$UvProbe
    )
    if ($env:XAGENT_SANDBOX_FORCE_FAIL) {
        return (New-SupportResult -Ok $false -Build (Get-WindowsBuild) -CursorVersion $null -Uv $null -PatternCount $null -Letters (New-EmptyLetters) -Problems @('forced failure (XAGENT_SANDBOX_FORCE_FAIL)'))
    }

    $call = Resolve-SandboxCall -Bound $PSBoundParameters -CursorRoot $CursorRoot -CacheRoot $CacheRoot -UvProbe $UvProbe
    $CursorRoot = $call.CursorRoot
    $CacheRoot = $call.CacheRoot
    $UvProbe = $call.UvProbe

    $problems = New-Object System.Collections.Generic.List[string]
    $build = Get-WindowsBuild
    if ($build -lt $script:MinimumBuild) {
        $problems.Add("Windows build $build is older than $($script:MinimumBuild); the sandbox needs Windows 11 build $($script:MinimumBuild) or later")
    }

    $cursorVersion = $null
    $uvRaw = $null
    $patternCount = $null
    $version = Get-CursorVersionName -CursorRoot $CursorRoot
    if (-not $version) {
        $problems.Add((Get-VersionMissingMessage $CursorRoot))
    } else {
        $cursorVersion = $version
        $sourceNode = Join-Path (Join-Path (Join-Path $CursorRoot 'versions') $version) 'node.exe'
        $uv = Read-NodeUv -NodeExe $sourceNode -UvProbe $UvProbe
        if (-not $uv.ok) {
            $problems.Add("Cursor ${version}: cannot read libuv version from node.exe ($($uv.reason))")
        } else {
            $uvRaw = [string]$uv.raw
            if (Test-UvAtLeast153 $uv.version) {
                $patternCount = $null
            } else {
                try {
                    $offsets = Get-PipePatternOffsets -Path $sourceNode
                    $patternCount = @($offsets).Count
                } catch {
                    $problems.Add("Cursor ${version}: cannot read node.exe ($($_.Exception.Message))")
                    $patternCount = $null
                }
                if ($null -ne $patternCount -and $patternCount -ne 1) {
                    $problems.Add((Get-PatternProblem -Version $version -Count $patternCount))
                }
            }
        }
    }

    $loaded = Read-SupportConfig -CacheRoot $CacheRoot
    if (-not $loaded.Ok) {
        $problems.Add("cannot read sandbox.json ($($loaded.Error))")
        $letters = New-EmptyLetters
    } else {
        $letters = Get-SupportLetters -CacheRoot $CacheRoot -Config $loaded.Config -Problems $problems
        Add-SandboxReadListProblems -Config $loaded.Config -Problems $problems
    }
    return (New-SupportResult -Ok ($problems.Count -eq 0) -Build $build -CursorVersion $cursorVersion -Uv $uvRaw -PatternCount $patternCount -Letters $letters -Problems $problems.ToArray())
}

function Get-SandboxRuntime {
    [CmdletBinding()]
    param(
        [string]$CursorRoot,
        [string]$CacheRoot,
        [scriptblock]$UvProbe
    )
    $call = Resolve-SandboxCall -Bound $PSBoundParameters -CursorRoot $CursorRoot -CacheRoot $CacheRoot -UvProbe $UvProbe
    $CursorRoot = $call.CursorRoot
    $CacheRoot = $call.CacheRoot
    $UvProbe = $call.UvProbe

    $version = Get-CursorVersionName -CursorRoot $CursorRoot
    if (-not $version) { throw "sandbox: $(Get-VersionMissingMessage $CursorRoot)" }

    $sourceDir = Join-Path (Join-Path $CursorRoot 'versions') $version
    $sourceNode = Join-Path $sourceDir 'node.exe'
    $dest = Join-Path $CacheRoot $version
    $reuse = Test-CachedRuntime -Dest $dest -SourceNode $sourceNode
    if ($null -ne $reuse) {
        return @{
            root = $CacheRoot
            version = $version
            uv = [string]$reuse.uv
            patched = [bool]$reuse.patched
        }
    }

    # Probe the source before any cache folder is deleted. A failure leaves the cache as it was.
    $uv = Read-NodeUv -NodeExe $sourceNode -UvProbe $UvProbe
    if (-not $uv.ok) {
        throw "sandbox: Cursor ${version}: cannot read libuv version from node.exe ($($uv.reason))"
    }
    $needPatch = -not (Test-UvAtLeast153 $uv.version)
    if ($needPatch) {
        $offsets = Get-PipePatternOffsets -Path $sourceNode
        if (@($offsets).Count -ne 1) {
            throw "sandbox: $(Get-PatternProblem -Version $version -Count $(@($offsets).Count))"
        }
    }

    if (-not (Test-Path -LiteralPath $CacheRoot)) {
        New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null
    }
    $partial = Join-Path $CacheRoot ($version + '.partial')
    Remove-SandboxTree -Path $dest -Version $version
    Remove-SandboxTree -Path $partial -Version $version
    try {
        Copy-Item -LiteralPath $sourceDir -Destination $partial -Recurse -Force -ErrorAction Stop
    } catch {
        throw "sandbox: Cursor ${version}: copying to the runtime cache failed: $($_.Exception.Message)"
    }

    $patched = $false
    if (-not $needPatch) {
        Write-PatchJson -Directory $partial -Body ([ordered]@{ patched = $false; uv = [string]$uv.raw })
    } else {
        $copyNode = Join-Path $partial 'node.exe'
        $copyOffsets = Get-PipePatternOffsets -Path $copyNode
        if (@($copyOffsets).Count -ne 1) {
            Remove-SandboxTree -Path $partial -Version $version
            throw "sandbox: $(Get-PatternProblem -Version $version -Count $(@($copyOffsets).Count))"
        }
        $offset = [int]$copyOffsets[0]
        $sourceHash = Get-SandboxFileHash $sourceNode
        Set-PipePattern -Path $copyNode -Offset $offset
        $patchedHash = Get-SandboxFileHash $copyNode
        Write-PatchJson -Directory $partial -Body ([ordered]@{
            patched = $true
            offset = $offset
            uv = [string]$uv.raw
            sourceSha256 = $sourceHash
            patchedSha256 = $patchedHash
        })
        $patched = $true
    }

    try {
        Rename-Item -LiteralPath $partial -NewName $version -ErrorAction Stop
    } catch {
        throw "sandbox: Cursor ${version}: cannot replace cache folder ${dest} (in use?): $($_.Exception.Message)"
    }
    Invoke-SandboxCachePrune -CacheRoot $CacheRoot -KeepVersion $version
    return @{
        root = $CacheRoot
        version = $version
        uv = [string]$uv.raw
        patched = $patched
    }
}

function Get-SandboxConfig {
    [CmdletBinding()]
    param()
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        return @{ letters = $null; read = @() }
    }
    try {
        $text = [IO.File]::ReadAllText($script:ConfigPath)
        $obj = $text | ConvertFrom-Json -AsHashtable
    } catch {
        throw "sandbox: cannot read sandbox.json ($($_.Exception.Message))"
    }
    if ($null -eq $obj) { return @{ letters = $null; read = @() } }
    if (-not $obj.Contains('letters')) { $obj['letters'] = $null }
    if (-not $obj.Contains('read') -or $null -eq $obj['read']) { $obj['read'] = @() }
    return $obj
}

function Set-SandboxLetters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Letters
    )
    $clean = @($Letters | ForEach-Object {
        if ($null -eq $_) { '' } else { $_.Trim().ToUpperInvariant() }
    })
    $valid = ($clean.Count -eq 3)
    if ($valid) {
        $seen = @{}
        foreach ($letter in $clean) {
            if ($letter -notmatch '^[D-Z]$' -or $seen.ContainsKey($letter)) { $valid = $false; break }
            $seen[$letter] = $true
        }
    }
    if (-not $valid) { throw 'sandbox: -Reserve needs three distinct letters D-Z' }

    $cfg = Get-SandboxConfig
    $current = Get-LettersShape (Get-ObjectProperty $cfg 'letters')
    if ($current.reserved -and $current.runtime -eq $clean[0] -and @($current.slots).Count -eq 2 -and $current.slots[0] -eq $clean[1] -and $current.slots[1] -eq $clean[2]) {
        $map = Get-SubstMap
        $drives = Get-DriveLetters
        $cursor = Join-Path $script:SandboxDir 'cursor'
        $idle = Join-Path $script:SandboxDir 'idle'
        $runtimeStatus = Test-LetterFreeWithMap -Letter $clean[0] -Map $map -Drives $drives
        $slot1 = Test-LetterFreeWithMap -Letter $clean[1] -Map $map -Drives $drives
        $slot2 = Test-LetterFreeWithMap -Letter $clean[2] -Map $map -Drives $drives
        if ((Test-OursTarget $runtimeStatus $cursor) -and (Test-OursTarget $slot1 $idle) -and (Test-OursTarget $slot2 $idle)) {
            return
        }
    }

    $map = Get-SubstMap
    $drives = Get-DriveLetters
    foreach ($letter in $clean) {
        $status = Test-LetterFreeWithMap -Letter $letter -Map $map -Drives $drives
        if ($status -ne 'free') { throw "sandbox: letter ${letter}: is in use" }
    }

    $cursorDir = Join-Path $script:SandboxDir 'cursor'
    $idleDir = Join-Path $script:SandboxDir 'idle'
    New-Item -ItemType Directory -Force -Path $cursorDir, $idleDir | Out-Null
    Invoke-SubstMap -Letter $clean[0] -Target $cursorDir
    Invoke-SubstMap -Letter $clean[1] -Target $idleDir
    Invoke-SubstMap -Letter $clean[2] -Target $idleDir
    try {
        [void][XagentSandbox]::EnsureProfile("xagent.slot-$($clean[1])")
        [void][XagentSandbox]::EnsureProfile("xagent.slot-$($clean[2])")
    } catch {
        throw "sandbox: EnsureProfile failed: $($_.Exception.Message)"
    }
    $cfg['letters'] = @{ runtime = $clean[0]; slots = @($clean[1], $clean[2]) }
    if ($null -eq (Get-ObjectProperty $cfg 'read')) { $cfg['read'] = @() }
    Save-SandboxConfig $cfg
}

function Get-NoLettersReservedMessage {
    $suggested = @(Get-FreeLetterSuggestions)
    if ($suggested.Count -eq 1 -and $suggested[0] -is [System.Array]) { $suggested = @($suggested[0]) }
    if ($suggested.Count -lt 3) { return 'sandbox: no drive letters reserved; not enough free letters D-Z' }
    $a = $suggested[0]; $b = $suggested[1]; $c = $suggested[2]
    return "sandbox: no drive letters reserved; suggested: $a, $b, $c; ask the user, then run delegate.ps1 -SandboxCheck -Reserve $a,$b,$c -Repo <repo>"
}

function Initialize-SandboxLetters {
    [CmdletBinding()]
    param()
    $cfg = Get-SandboxConfig
    $shape = Get-LettersShape (Get-ObjectProperty $cfg 'letters')
    if (-not $shape.reserved) {
        throw (Get-NoLettersReservedMessage)
    }
    if ([string]::IsNullOrWhiteSpace([string]$shape.runtime) -or @($shape.slots).Count -ne 2) {
        throw 'sandbox: sandbox.json letters must be a runtime letter and two slots'
    }

    $map = Get-SubstMap
    $drives = Get-DriveLetters
    $cursorDir = Join-Path $script:SandboxDir 'cursor'
    $idleDir = Join-Path $script:SandboxDir 'idle'
    $plan = @(
        [pscustomobject]@{ Letter = [string]$shape.runtime; Target = $cursorDir; Slot = $false }
        [pscustomobject]@{ Letter = [string]$shape.slots[0]; Target = $idleDir; Slot = $true }
        [pscustomobject]@{ Letter = [string]$shape.slots[1]; Target = $idleDir; Slot = $true }
    )
    foreach ($item in $plan) {
        $ledger = Join-Path $script:SandboxDir ("slot-$($item.Letter).json")
        $state = Get-ReservedLetterState -Letter $item.Letter -Expected $item.Target -LedgerPath $ledger -Slot:([bool]$item.Slot) -Map $map -Drives $drives
        if ($state -eq 'used') {
            throw "sandbox: reserved letter $($item.Letter): is used by another drive; choose new letters"
        }
    }
    if (-not (Test-Path -LiteralPath $cursorDir)) { New-Item -ItemType Directory -Force -Path $cursorDir | Out-Null }
    if (-not (Test-Path -LiteralPath $idleDir)) { New-Item -ItemType Directory -Force -Path $idleDir | Out-Null }
    foreach ($item in $plan) {
        $ledger = Join-Path $script:SandboxDir ("slot-$($item.Letter).json")
        $state = Get-ReservedLetterState -Letter $item.Letter -Expected $item.Target -LedgerPath $ledger -Slot:([bool]$item.Slot) -Map $map -Drives $drives
        if ($state -eq 'free') { Invoke-SubstMap -Letter $item.Letter -Target $item.Target }
    }
}

function Add-SandboxGrantRow($Rows, $Seen, [string]$Path, [string]$Spec) {
    $full = Resolve-SandboxPath $Path
    if ([string]::IsNullOrEmpty($full)) { return }
    if ($Seen.Add($full + '|' + $Spec)) {
        $Rows.Add([pscustomobject]@{ path = $full; spec = $Spec })
    }
}

# Nearest parent first, stopping before the drive root. The drive root never gets a row.
function Get-SandboxGrantAncestors([string]$Path) {
    $list = New-Object System.Collections.Generic.List[string]
    $full = Resolve-SandboxPath $Path
    if (-not [string]::IsNullOrEmpty($full)) {
        $current = [IO.Path]::GetDirectoryName($full)
        while (-not [string]::IsNullOrEmpty($current)) {
            $root = [IO.Path]::GetPathRoot($current)
            if ([string]::IsNullOrEmpty($root)) { break }
            if ([string]::Equals($current.TrimEnd('\', '/'), $root.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
                break
            }
            $list.Add((Resolve-SandboxPath $current))
            $next = [IO.Path]::GetDirectoryName($current)
            if ([string]::IsNullOrEmpty($next) -or [string]::Equals($next, $current, [StringComparison]::OrdinalIgnoreCase)) { break }
            $current = $next
        }
    }
    Write-Output -NoEnumerate $list.ToArray()
}

# Profile root first, then down to the entry's parent. Nothing above the profile root.
function Get-SandboxProfileGrantChain([string]$EntryPath, [string]$ProfileRoot) {
    $up = New-Object System.Collections.Generic.List[string]
    $current = [IO.Path]::GetDirectoryName($EntryPath)
    while (-not [string]::IsNullOrEmpty($current)) {
        $norm = Resolve-SandboxPath $current
        if (-not (Test-SandboxPathUnder $norm $ProfileRoot)) { break }
        $up.Add($norm)
        if ([string]::Equals($norm, $ProfileRoot, [StringComparison]::OrdinalIgnoreCase)) { break }
        $next = [IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrEmpty($next) -or [string]::Equals($next, $current, [StringComparison]::OrdinalIgnoreCase)) { break }
        $current = $next
    }
    $down = New-Object System.Collections.Generic.List[string]
    for ($i = $up.Count - 1; $i -ge 0; $i--) { $down.Add($up[$i]) }
    Write-Output -NoEnumerate $down.ToArray()
}

# One level, no -Recurse and no -FollowSymlink. worktrees is not a child grant.
function Get-SandboxGitChildren([string]$GitDir) {
    $sorted = New-Object System.Collections.Generic.List[System.IO.FileSystemInfo]
    if (Test-Path -LiteralPath $GitDir -PathType Container) {
        foreach ($child in @(Get-ChildItem -LiteralPath $GitDir -Force)) {
            $sorted.Add($child)
        }
        if ($sorted.Count -gt 1) {
            $sorted.Sort([System.Comparison[System.IO.FileSystemInfo]]{
                param($Left, $Right)
                [StringComparer]::OrdinalIgnoreCase.Compare($Left.Name, $Right.Name)
            })
        }
    }
    Write-Output -NoEnumerate $sorted.ToArray()
}

function Get-SandboxGrantList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$WtName,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$RuntimeVersion,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$ReadList,
        [switch]$ReadOnly
    )
    if ([string]::IsNullOrEmpty($WtName) -or $WtName -eq '.' -or $WtName -eq '..' -or $WtName.Contains('\') -or $WtName.Contains('/')) {
        throw "sandbox: invalid worktree name '$WtName'"
    }

    $rows = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $worktreeSpec = if ($ReadOnly) { '(OI)(CI)RX' } else { '(OI)(CI)M' }
    $worktreeFull = Resolve-SandboxPath $Worktree
    Add-SandboxGrantRow $rows $seen $worktreeFull $worktreeSpec
    Add-SandboxGrantRow $rows $seen (Join-Path $worktreeFull '.xagent\sandbox') '(OI)(CI)M'

    $gitDir = Resolve-SandboxPath (Join-Path (Resolve-SandboxPath $Repo) '.git')
    Add-SandboxGrantRow $rows $seen $gitDir 'RX'
    $children = Get-SandboxGitChildren $gitDir
    foreach ($child in $children) {
        if ([string]::Equals($child.Name, 'worktrees', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $childSpec = if ($child.PSIsContainer) { '(OI)(CI)RX' } else { 'RX' }
        Add-SandboxGrantRow $rows $seen $child.FullName $childSpec
    }
    Add-SandboxGrantRow $rows $seen (Join-Path $gitDir 'worktrees') 'RA'
    Add-SandboxGrantRow $rows $seen (Join-Path $gitDir "worktrees\$WtName") '(OI)(CI)M'

    $worktreeAncestors = Get-SandboxGrantAncestors $worktreeFull
    foreach ($ancestor in $worktreeAncestors) {
        Add-SandboxGrantRow $rows $seen $ancestor 'RA'
    }
    $gitAncestors = Get-SandboxGrantAncestors $gitDir
    foreach ($ancestor in $gitAncestors) {
        Add-SandboxGrantRow $rows $seen $ancestor 'RA'
    }

    $runtime = Resolve-SandboxPath $RuntimeRoot
    $versionDir = Join-Path $runtime $RuntimeVersion
    Add-SandboxGrantRow $rows $seen $runtime 'RA'
    Add-SandboxGrantRow $rows $seen $versionDir '(OI)(CI)RX'
    Add-SandboxGrantRow $rows $seen (Join-Path $versionDir '.running') '(OI)(CI)M'

    if ($null -ne $ReadList) {
        $profile = Get-SandboxProfileRoot
        foreach ($entry in @($ReadList)) {
            if ($null -eq $entry) { continue }
            $raw = Get-ObjectProperty $entry 'path'
            if ($null -eq $raw) { $raw = '' }
            $entryPath = Resolve-SandboxPath ([string]$raw)
            Add-SandboxGrantRow $rows $seen $entryPath '(OI)(CI)RX'
            if ($profile -and (Test-SandboxPathUnder $entryPath $profile)) {
                $chain = Get-SandboxProfileGrantChain $entryPath $profile
                foreach ($ancestor in $chain) {
                    Add-SandboxGrantRow $rows $seen $ancestor 'RA'
                }
            }
        }
    }
    Write-Output -NoEnumerate $rows.ToArray()
}

# RA is a specific right. icacls rejects "*<sid>:RA" (win32 87) and accepts "*<sid>:(RA)".
# The ledger keeps the design's spec string; only the grant command is parenthesized.
function ConvertTo-SandboxIcaclsSpec([string]$Spec) {
    if ($Spec -eq 'RA') { return '(RA)' }
    return $Spec
}

function Format-SandboxIcaclsError($Output) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Output)) {
        if ($null -eq $item) { continue }
        $text = ([string]$item).Trim()
        if ($text.Length -gt 0) { $lines.Add($text) }
    }
    if ($lines.Count -eq 0) { return '<no output>' }
    return ($lines.ToArray() -join '; ')
}

function Remove-SandboxGrants {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Ledger
    )
    $none = New-Object object[] 0
    if ($null -eq $Ledger) {
        Write-Output -NoEnumerate $none
        return
    }
    $grants = Get-ObjectProperty $Ledger 'grants'
    $grantList = @()
    if ($null -ne $grants) { $grantList = @($grants) }
    if ($grantList.Count -eq 0) {
        Write-Output -NoEnumerate $none
        return
    }
    $sid = [string](Get-ObjectProperty $Ledger 'sid')
    if ([string]::IsNullOrWhiteSpace($sid)) {
        throw 'sandbox: ledger has no sid'
    }
    # No /T. A missing path is already gone, so it counts as removed.
    $failed = New-Object System.Collections.Generic.List[object]
    foreach ($grant in $grantList) {
        $path = Get-ObjectProperty $grant 'path'
        if ($null -eq $path) { continue }
        $pathText = [string]$path
        if ([string]::IsNullOrWhiteSpace($pathText)) { continue }
        if (-not (Test-Path -LiteralPath $pathText)) { continue }
        $spec = Get-ObjectProperty $grant 'spec'
        $output = @(& icacls.exe $pathText /remove ('*' + $sid) 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $failed.Add([pscustomobject]@{
                path = $pathText
                spec = $spec
                error = (Format-SandboxIcaclsError $output)
            })
        }
    }
    Write-Output -NoEnumerate $failed.ToArray()
}

function Resolve-SandboxLetterPlan {
    $cfg = Get-SandboxConfig
    $shape = Get-LettersShape (Get-ObjectProperty $cfg 'letters')
    if ($shape.reserved) {
        if ([string]::IsNullOrWhiteSpace([string]$shape.runtime) -or @($shape.slots).Count -ne 2) {
            throw 'sandbox: sandbox.json letters must be a runtime letter and two slots'
        }
    }
    return @{
        Config = $cfg
        Reserved = [bool]$shape.reserved
        Shape = $shape
    }
}

function Test-SandboxAbandoned([Exception]$Exception) {
    $ex = $Exception
    while ($null -ne $ex) {
        if ($ex -is [Threading.AbandonedMutexException]) { return $true }
        $ex = $ex.InnerException
    }
    return $false
}

# WaitOne(0): true means taken. AbandonedMutexException also means taken (this caller owns it).
# false means another process holds it. A mutex this caller rejects is always released, if owned, and disposed.
function Open-SandboxSlotMutex([string]$Letter) {
    $mutex = [Threading.Mutex]::new($false, "Local\xagent-slot-$Letter")
    $owned = $false
    try {
        $owned = $mutex.WaitOne(0)
    } catch {
        if (-not (Test-SandboxAbandoned $_.Exception)) {
            $mutex.Dispose()
            throw
        }
        $owned = $true
    }
    return @{ Mutex = $mutex; Owned = $owned }
}

function Close-SandboxMutex($Mutex, [bool]$Owned) {
    if ($null -eq $Mutex) { return }
    if ($Owned) {
        try { $Mutex.ReleaseMutex() } catch { }
    }
    $Mutex.Dispose()
}

# Failed grants are written back as {path, spec} only. The ledger's other fields stay.
# Returns the Remove-SandboxGrants failures (empty when the ledger was deleted).
function Clear-DeadSandboxLedger([string]$Path) {
    $ledger = Read-SandboxLedger -Path $Path
    $failed = Remove-SandboxGrants -Ledger $ledger
    if ($null -eq $failed -or $failed.Count -eq 0) {
        Remove-Item -LiteralPath $Path -Force
        Write-Output -NoEnumerate (New-Object object[] 0)
        return
    }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($row in @($failed)) {
        $rows.Add([pscustomobject]@{
            path = (Get-ObjectProperty $row 'path')
            spec = (Get-ObjectProperty $row 'spec')
        })
    }
    $ledger.grants = $rows.ToArray()
    Write-SandboxLedger -Path $Path -Ledger $ledger
    Write-Output -NoEnumerate $failed
}

function Get-SandboxLoopbackExemptions {
    param(
        [AllowEmptyString()][AllowNull()][string]$Text,
        [AllowEmptyCollection()][AllowNull()][string[]]$Sids
    )
    $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($sid in @($Sids)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$sid)) {
            [void]$wanted.Add(([string]$sid).Trim())
        }
    }
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not [string]::IsNullOrEmpty($Text)) {
        foreach ($line in ($Text -split '\r?\n')) {
            if ($line -match '^\s*SID:\s*(\S+)\s*$') {
                $sid = $Matches[1]
                if ($wanted.Contains($sid)) {
                    $rows.Add([pscustomobject]@{
                        sid = $sid
                        command = "CheckNetIsolation LoopbackExempt -d -p=$sid"
                    })
                }
            }
        }
    }
    Write-Output -NoEnumerate $rows.ToArray()
}

function Read-SandboxLoopbackExemptText {
    $exe = Join-Path $env:SystemRoot 'System32\CheckNetIsolation.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return '' }
    try {
        $output = @(& $exe 'LoopbackExempt' '-s' 2>&1)
        if ($LASTEXITCODE -ne 0) { return '' }
        return ((@($output) | ForEach-Object { "$_" }) -join "`n")
    } catch {
        return ''
    }
}

function Invoke-SandboxSubstDelete([string]$Letter) {
    $output = @(& subst.exe "${Letter}:" '/D' 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $text = ((@($output) | ForEach-Object { "$_" }) -join ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { $text = "subst ${Letter}: /D exited $LASTEXITCODE" }
        throw "sandbox: release failed: $text"
    }
}

function Get-SandboxSlot {
    [CmdletBinding()]
    param(
        [int]$TimeoutSec = 60
    )
    $plan = Resolve-SandboxLetterPlan
    if (-not $plan.Reserved) {
        throw (Get-NoLettersReservedMessage)
    }
    $slots = @($plan.Shape.slots)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        foreach ($letter in $slots) {
            $opened = Open-SandboxSlotMutex -Letter ([string]$letter)
            if (-not $opened.Owned) {
                Close-SandboxMutex -Mutex $opened.Mutex -Owned $false
                continue
            }
            $busy = $false
            $result = $null
            try {
                $ledgerPath = Join-Path $script:SandboxDir ("slot-$letter.json")
                if (Test-LedgerProcessLive $ledgerPath) {
                    $busy = $true
                } else {
                    if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
                        $null = Clear-DeadSandboxLedger -Path $ledgerPath
                    }
                    $container = "xagent.slot-$letter"
                    $sid = [XagentSandbox]::EnsureProfile($container)
                    $result = [pscustomobject]@{
                        letter = [string]$letter
                        mutex = $opened.Mutex
                        container = $container
                        sid = [string]$sid
                    }
                }
            } catch {
                Close-SandboxMutex -Mutex $opened.Mutex -Owned $true
                throw
            }
            if ($busy) {
                Close-SandboxMutex -Mutex $opened.Mutex -Owned $true
                continue
            }
            return $result
        }
        if ($clock.Elapsed.TotalSeconds -ge $TimeoutSec) {
            throw 'sandbox: no free slot (both slots busy)'
        }
        $remain = $TimeoutSec - $clock.Elapsed.TotalSeconds
        if ($remain -gt 0) {
            Start-Sleep -Seconds ([Math]::Min(2.0, $remain))
        }
    }
}

function Remove-SandboxLetters {
    [CmdletBinding()]
    param()
    $plan = Resolve-SandboxLetterPlan
    if (-not $plan.Reserved) {
        return @{
            released = (New-Object object[] 0)
            exemptions = (New-Object object[] 0)
            leftoverGrants = (New-Object object[] 0)
        }
    }

    $cfg = $plan.Config
    $runtime = [string]$plan.Shape.runtime
    $slots = @($plan.Shape.slots)
    $held = New-Object 'System.Collections.Generic.List[Threading.Mutex]'
    try {
        foreach ($letter in $slots) {
            $opened = Open-SandboxSlotMutex -Letter ([string]$letter)
            if (-not $opened.Owned) {
                Close-SandboxMutex -Mutex $opened.Mutex -Owned $false
                throw 'sandbox: a slot is in use; release refused'
            }
            $held.Add($opened.Mutex)
            $ledgerPath = Join-Path $script:SandboxDir ("slot-$letter.json")
            if (Test-LedgerProcessLive $ledgerPath) {
                throw 'sandbox: a slot is in use; release refused'
            }
        }

        $names = @(
            ("xagent.slot-" + $slots[0])
            ("xagent.slot-" + $slots[1])
        )
        $sids = New-Object System.Collections.Generic.List[string]
        foreach ($name in $names) {
            try {
                $sids.Add([string][XagentSandbox]::EnsureProfile($name))
            } catch {
                throw "sandbox: release failed: $($_.Exception.Message)"
            }
        }

        $exemptText = Read-SandboxLoopbackExemptText
        $exemptions = Get-SandboxLoopbackExemptions -Text $exemptText -Sids $sids.ToArray()

        $leftover = New-Object System.Collections.Generic.List[object]
        if (Test-Path -LiteralPath $script:SandboxDir -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $script:SandboxDir -Filter 'slot-?.json' -File -ErrorAction SilentlyContinue)) {
                $ledger = Read-SandboxLedger -Path $file.FullName
                $failed = Remove-SandboxGrants -Ledger $ledger
                if ($null -eq $failed) { continue }
                foreach ($row in @($failed)) { $leftover.Add($row) }
            }
        }

        $map = Get-SubstMap
        $released = New-Object System.Collections.Generic.List[string]
        foreach ($letter in @($runtime, [string]$slots[0], [string]$slots[1])) {
            if (-not $map.ContainsKey($letter)) { continue }
            Invoke-SandboxSubstDelete -Letter $letter
            $released.Add($letter)
        }

        foreach ($name in $names) {
            try {
                [XagentSandbox]::DeleteProfile($name)
            } catch {
                throw "sandbox: release failed: $($_.Exception.Message)"
            }
        }

        if (Test-Path -LiteralPath $script:SandboxDir) {
            try {
                Remove-Item -LiteralPath $script:SandboxDir -Recurse -Force -ErrorAction Stop
            } catch {
                throw "sandbox: release failed: $($_.Exception.Message)"
            }
        }

        if ($cfg -is [System.Collections.IDictionary]) {
            [void]$cfg.Remove('letters')
        }
        Save-SandboxConfig $cfg

        return @{
            released = $released.ToArray()
            exemptions = $exemptions
            leftoverGrants = $leftover.ToArray()
        }
    } finally {
        foreach ($mutex in $held) {
            Close-SandboxMutex -Mutex $mutex -Owned $true
        }
    }
}

# Same rules as delegate.ps1's Quote. Named so it cannot clash with that function.
function ConvertTo-SandboxArgument([string]$s) {
    # MSVCRT/Go command-line escaping: backslashes are literal unless they precede a quote
    if ($s -and $s -notmatch '[\s"]') { return $s }
    $s = [regex]::Replace($s, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
    $s = [regex]::Replace($s, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
    '"' + $s + '"'
}

function Get-SandboxCommandLine {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments
    )
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add((ConvertTo-SandboxArgument $Exe))
    foreach ($arg in @($Arguments)) {
        $parts.Add((ConvertTo-SandboxArgument ([string]$arg)))
    }
    return ($parts.ToArray() -join ' ')
}

function Copy-SandboxLoginFile([string]$Source, [string]$Destination, [bool]$ReadOnly) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return }
    try {
        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            $existing = Get-Item -LiteralPath $Destination -Force
            $existing.IsReadOnly = $false
        }
        [IO.File]::Copy($Source, $Destination, $true)
        $copied = Get-Item -LiteralPath $Destination -Force
        $copied.IsReadOnly = $ReadOnly
    } catch {
        throw "sandbox: cannot copy ${Source}: $($_.Exception.Message)"
    }
}

function New-SandboxRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Slot,
        [Parameter(Mandatory)]$Runtime,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$WtName,
        [switch]$ReadOnly
    )

    # On a throw, leave the ledger and any grants. The caller's finally calls Stop-SandboxRun.
    Assert-SandboxOutsideProfile -Path $Worktree
    Assert-SandboxOutsideProfile -Path (Join-Path $Repo '.git')

    $cfg = Get-SandboxConfig
    $readValue = Get-ObjectProperty $cfg 'read'
    $readItems = $null
    if ($null -ne $readValue) {
        if ($readValue -is [System.Array]) {
            $readItems = $readValue
        } else {
            $readItems = [object[]]::new(1)
            $readItems[0] = $readValue
        }
    }
    $read = Test-SandboxReadList -Entries $readItems
    $shape = Get-LettersShape (Get-ObjectProperty $cfg 'letters')
    if (-not $shape.reserved) {
        throw (Get-NoLettersReservedMessage)
    }
    $runtimeLetter = [string]$shape.runtime

    $runtimeRoot = [string](Get-ObjectProperty $Runtime 'root')
    $runtimeVersion = [string](Get-ObjectProperty $Runtime 'version')
    $grantArgs = @{
        Repo = $Repo
        Worktree = $Worktree
        WtName = $WtName
        RuntimeRoot = $runtimeRoot
        RuntimeVersion = $runtimeVersion
        ReadList = $read
    }
    if ($ReadOnly) { $grantArgs['ReadOnly'] = $true }
    $fresh = Get-SandboxGrantList @grantArgs

    $rows = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($row in @($fresh)) {
        if ($null -eq $row) { continue }
        Add-SandboxGrantRow $rows $seen ([string](Get-ObjectProperty $row 'path')) ([string](Get-ObjectProperty $row 'spec'))
    }

    $letter = [string]$Slot.letter
    $ledgerPath = Join-Path $script:SandboxDir "slot-$letter.json"
    if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
        $old = Read-SandboxLedger -Path $ledgerPath
        if ($null -ne $old) {
            foreach ($row in @(Get-ObjectProperty $old 'grants')) {
                if ($null -eq $row) { continue }
                $oldPath = Get-ObjectProperty $row 'path'
                $oldSpec = Get-ObjectProperty $row 'spec'
                if ($null -eq $oldPath -or $null -eq $oldSpec) { continue }
                Add-SandboxGrantRow $rows $seen ([string]$oldPath) ([string]$oldSpec)
            }
        }
    }

    $worktreeFull = Resolve-SandboxPath $Worktree
    Write-SandboxLedger -Path $ledgerPath -Ledger ([ordered]@{
        slot = $letter
        sid = [string]$Slot.sid
        pid = $PID
        startTime = (Get-Process -Id $PID).StartTime
        runtimeVersion = $runtimeVersion
        worktree = $worktreeFull
        grants = $rows.ToArray()
    })

    $runHome = Join-Path $worktreeFull '.xagent\sandbox\home'
    $versionDir = Join-Path (Resolve-SandboxPath $runtimeRoot) $runtimeVersion
    foreach ($dir in @(
        (Join-Path $runHome '.cursor'),
        (Join-Path $runHome 'AppData\Roaming\Cursor'),
        (Join-Path $runHome 'AppData\Local'),
        (Join-Path $worktreeFull '.xagent\sandbox\tmp'),
        (Join-Path $versionDir '.running')
    )) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    # No /T. A missing path stays in the ledger; removal skips it too.
    $sid = [string]$Slot.sid
    foreach ($row in $rows) {
        $pathText = [string]$row.path
        if ([string]::IsNullOrWhiteSpace($pathText)) { continue }
        if (-not (Test-Path -LiteralPath $pathText)) { continue }
        $spec = ConvertTo-SandboxIcaclsSpec ([string]$row.spec)
        $output = @(& icacls.exe $pathText /grant ("*${sid}:${spec}") 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "sandbox: grant failed on ${pathText}: $(Format-SandboxIcaclsError $output)"
        }
    }

    Copy-SandboxLoginFile (Join-Path $script:LoginProfile '.cursor\cli-config.json') (Join-Path $runHome '.cursor\cli-config.json') $false
    Copy-SandboxLoginFile (Join-Path $script:LoginAppData 'Cursor\auth.json') (Join-Path $runHome 'AppData\Roaming\Cursor\auth.json') $false
    Copy-SandboxLoginFile (Join-Path $script:LoginProfile '.gitconfig') (Join-Path $runHome '.gitconfig') $true

    $letterKey = $letter.Trim().ToUpperInvariant()
    $map = Get-SubstMap
    if ($map.ContainsKey($letterKey)) {
        Invoke-SandboxSubstDelete -Letter $letterKey
    }
    Invoke-SubstMap -Letter $letterKey -Target $worktreeFull

    $envVars = Get-SandboxEnvironment -Slot $letter -ReadList $read
    return [pscustomobject]@{
        slot = $letter
        container = $Slot.container
        sid = $Slot.sid
        runtimeLetter = $runtimeLetter
        runtimeVersion = $runtimeVersion
        patched = [bool](Get-ObjectProperty $Runtime 'patched')
        cwd = ($letter + ':\')
        env = $envVars
        worktree = $worktreeFull
    }
}

function Start-SandboxProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory)][string]$StdoutPath,
        [Parameter(Mandatory)][string]$StderrPath
    )
    $commandLine = Get-SandboxCommandLine -Exe $Exe -Arguments $Arguments
    $sid = [string](Get-ObjectProperty $Run 'sid')
    $cwd = [string](Get-ObjectProperty $Run 'cwd')
    $envList = Get-ObjectProperty $Run 'env'
    if ($null -eq $envList) {
        $envList = [string[]]::new(0)
    } else {
        $envList = [string[]]@($envList)
    }
    try {
        return [XagentSandbox]::Start($sid, $Exe, $commandLine, $cwd, $envList, $StdoutPath, $StderrPath)
    } catch {
        throw "sandbox: cannot start ${Exe}: $($_.Exception.GetBaseException().Message)"
    }
}

function Stop-SandboxRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Run,
        [Parameter(Mandatory)]$Slot,
        [AllowNull()][RunHandle]$Handle
    )
    $notes = New-Object System.Collections.Generic.List[string]
    $letter = [string]$Slot.letter
    $ledgerWorktree = $null

    try {
        if ($null -ne $Handle -and -not $Handle.Closed) {
            $null = [XagentSandbox]::Finish($Handle)
        }
    } catch {
        $notes.Add("close handles: $($_.Exception.Message)")
    }

    try {
        $ledgerPath = Join-Path $script:SandboxDir "slot-$letter.json"
        if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
            $parsed = Read-SandboxLedger -Path $ledgerPath
            if ($null -eq $parsed) {
                $notes.Add("remove grants: ledger unreadable $ledgerPath")
            } else {
                $remembered = Get-ObjectProperty $parsed 'worktree'
                if ($null -ne $remembered) { $ledgerWorktree = [string]$remembered }
                $failed = Clear-DeadSandboxLedger -Path $ledgerPath
                foreach ($row in @($failed)) {
                    if ($null -eq $row) { continue }
                    $grantPath = Get-ObjectProperty $row 'path'
                    $grantError = Get-ObjectProperty $row 'error'
                    $notes.Add("grant not removed: $grantPath ($grantError)")
                }
            }
        }
    } catch {
        $notes.Add("remove grants: $($_.Exception.Message)")
    }

    try {
        $worktree = $null
        if ($null -ne $Run) {
            $worktree = Get-ObjectProperty $Run 'worktree'
        } else {
            $worktree = $ledgerWorktree
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$worktree)) {
            $authPath = Join-Path ([string]$worktree) '.xagent\sandbox\home\AppData\Roaming\Cursor\auth.json'
            if (Test-Path -LiteralPath $authPath) {
                Remove-Item -LiteralPath $authPath -Force
            }
        }
    } catch {
        $notes.Add("delete auth.json: $($_.Exception.Message)")
    }

    try {
        $cfg = Get-SandboxConfig
        $shape = Get-LettersShape (Get-ObjectProperty $cfg 'letters')
        $letterKey = $letter.Trim().ToUpperInvariant()
        $isSlot = $false
        foreach ($candidate in @($shape.slots)) {
            if ([string]$candidate -eq $letterKey) { $isSlot = $true; break }
        }
        if ($isSlot) {
            New-Item -ItemType Directory -Force -Path $script:IdleDir | Out-Null
            $map = Get-SubstMap
            if ($map.ContainsKey($letterKey)) {
                Invoke-SandboxSubstDelete -Letter $letterKey
            }
            Invoke-SubstMap -Letter $letterKey -Target $script:IdleDir
        }
    } catch {
        $notes.Add("remap slot: $($_.Exception.Message)")
    }

    try {
        Close-SandboxMutex -Mutex $Slot.mutex -Owned $true
    } catch {
        $notes.Add("release slot: $($_.Exception.Message)")
    }

    Write-Output -NoEnumerate $notes.ToArray()
}

Export-ModuleMember -Function Test-SandboxSupport, Get-SandboxRuntime, Get-SandboxConfig, Set-SandboxLetters, Initialize-SandboxLetters, Remove-SandboxGrants, Get-SandboxSlot, Remove-SandboxLetters, New-SandboxRun, Start-SandboxProcess, Stop-SandboxRun
