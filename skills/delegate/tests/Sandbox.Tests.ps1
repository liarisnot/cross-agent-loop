#Requires -Modules @{ModuleName='Pester';ModuleVersion='5.5'}

BeforeAll {
function Get-TestSha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function New-SyntheticNode {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Copies = 1
    )
    $padding = New-Object byte[] 32
    for ($i = 0; $i -lt $padding.Length; $i++) { $padding[$i] = 0xA5 }
    $tail = New-Object byte[] 16
    for ($i = 0; $i -lt $tail.Length; $i++) { $tail[$i] = 0x5A }
    $bytes = New-Object System.Collections.Generic.List[byte]
    if ($Copies -le 0) { $bytes.AddRange($padding) }
    for ($n = 0; $n -lt $Copies; $n++) {
        $bytes.AddRange($padding)
        $bytes.AddRange([byte[]]$script:PipePattern)
        $bytes.Add(0x00)
    }
    $bytes.AddRange($tail)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllBytes($Path, $bytes.ToArray())
}

function New-CursorTree {
    param(
        [Parameter(Mandatory)][string]$CursorRoot,
        [Parameter(Mandatory)][string]$Version,
        [int]$PatternCount = 1
    )
    $dir = Join-Path $CursorRoot "versions\$Version"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    New-SyntheticNode -Path (Join-Path $dir 'node.exe') -Copies $PatternCount
    Set-Content -LiteralPath (Join-Path $dir 'index.js') -Value '// synthetic' -Encoding utf8
    return $dir
}

function Get-ThrownMessage([scriptblock]$Command) {
    try {
        & $Command | Out-Null
        return $null
    } catch {
        return $_.Exception.Message
    }
}

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

function Get-IcaclsText([string]$Path) {
    return ((@(& icacls.exe $Path 2>&1) | ForEach-Object { "$_" }) -join "`n")
}

function Import-TestParseVersionString {
    $modulePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../scripts/Sandbox.psm1'))
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
        $output = @(& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1)
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

    $script:ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '../scripts/Sandbox.psm1')).Path
    $script:PipePattern = [byte[]](0x5C, 0x5C, 0x3F, 0x5C, 0x70, 0x69, 0x70, 0x65, 0x5C, 0x75, 0x76, 0x5C, 0x25, 0x6C, 0x6C, 0x75, 0x2D, 0x25, 0x6C, 0x75)
    $script:PipeReplacement = [byte[]](0x5C, 0x5C, 0x3F, 0x5C, 0x70, 0x69, 0x70, 0x65, 0x5C, 0x4C, 0x4F, 0x43, 0x41, 0x4C, 0x5C, 0x25, 0x6C, 0x6C, 0x75, 0x00)
    $script:VersionPattern = '^\d{4}\.\d{1,2}\.\d{1,2}(-\d{2}-\d{2}-\d{2})?-[a-f0-9]+$'
    $script:PatternProblem = 'node.exe pipe-name pattern found {0} times; Sandbox.psm1 needs an update (use -NoSandbox to run unsandboxed)'
    $script:SavedEnv = @{}
    foreach ($name in 'XAGENT_SANDBOX_ROOT', 'XAGENT_CURSOR_ROOT', 'XAGENT_SANDBOX_FORCE_FAIL') {
        $script:SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $env:XAGENT_SANDBOX_ROOT = Join-Path $TestDrive 'root'
    $env:XAGENT_CURSOR_ROOT = Join-Path $TestDrive 'cursor'
    New-Item -ItemType Directory -Force -Path $env:XAGENT_SANDBOX_ROOT, $env:XAGENT_CURSOR_ROOT | Out-Null
    Remove-Item Env:XAGENT_SANDBOX_FORCE_FAIL -ErrorAction SilentlyContinue
    Import-Module $script:ModulePath -Force
}

AfterAll {
    # Later test files run in the same process; don't leave them TestDrive paths or this module.
    Remove-Module Sandbox -Force -ErrorAction SilentlyContinue
    foreach ($name in $script:SavedEnv.Keys) {
        [Environment]::SetEnvironmentVariable($name, $script:SavedEnv[$name])
    }
}

Describe 'XagentSandbox' -Tag Sandbox {
    It 'imports and the XagentSandbox type exists' {
        [XagentSandbox] | Should -Not -BeNullOrEmpty
        [XagentSandbox]::IsAppContainer() | Should -BeOfType [bool]
    }

    It 'imports a second time without throwing' {
        { Import-Module $script:ModulePath -Force } | Should -Not -Throw
        'XagentSandbox' -as [type] | Should -Not -BeNullOrEmpty
    }

    It 'round-trips an AppContainer profile' {
        if ([XagentSandbox]::IsAppContainer()) {
            Set-ItResult -Skipped -Because 'already inside an AppContainer'
        }
        if ([Environment]::OSVersion.Version.Build -lt 26300) {
            Set-ItResult -Skipped -Because 'Windows build is older than 26300'
        }
        $name = 'xagent.test-' + [guid]::NewGuid().ToString('N')
        $created = $false
        try {
            $sid = [XagentSandbox]::EnsureProfile($name)
            $created = $true
            $sid | Should -Match '^S-1-'
            [XagentSandbox]::EnsureProfile($name) | Should -Be $sid
        } finally {
            if ($created) { [XagentSandbox]::DeleteProfile($name) }
        }
    }

    It 'Test-LetterFree returns ours for a letter mapped to the idle folder' {
        if ([XagentSandbox]::IsAppContainer()) {
            Set-ItResult -Skipped -Because 'already inside an AppContainer'
        }
        $letter = InModuleScope Sandbox {
            $map = Get-SubstMap
            $drives = Get-DriveLetters
            foreach ($code in 90..68) {
                $candidate = [string][char]$code
                if ((Test-LetterFreeWithMap -Letter $candidate -Map $map -Drives $drives) -eq 'free') { return $candidate }
            }
            return $null
        }
        if (-not $letter) { Set-ItResult -Skipped -Because 'no free drive letter D-Z' }
        $idle = Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox\idle'
        New-Item -ItemType Directory -Force -Path $idle | Out-Null
        try {
            & subst.exe "${letter}:" $idle
            $LASTEXITCODE | Should -Be 0
            $status = InModuleScope Sandbox -Parameters @{ Letter = $letter } {
                param($Letter)
                Test-LetterFree -Letter $Letter
            }
            $status | Should -Match '^ours:'
            $target = $status.Substring(5).TrimEnd('\')
            [string]::Equals($target, $idle.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        } finally {
            & subst.exe "${letter}:" /D | Out-Null
        }
    }
}

Describe 'Test-SandboxSupport' {
    It 'returns the unreserved shape and stays ok when the other checks pass' -Tag Sandbox {
        $root = Join-Path $TestDrive 'shape-root'
        $cursor = Join-Path $TestDrive 'shape-cursor'
        $version = '2026.04.05-abc123'
        New-CursorTree -CursorRoot $cursor -Version $version -PatternCount 1
        $cache = Join-Path $root 'sandbox\cursor'
        $result = Test-SandboxSupport -CursorRoot $cursor -CacheRoot $cache -UvProbe { '1.52.1' }
        $result.ok | Should -BeTrue
        $result.build | Should -Be ([Environment]::OSVersion.Version.Build)
        $result.cursorVersion | Should -Be $version
        $result.uv | Should -Be '1.52.1'
        $result.patternCount | Should -Be 1
        $result.letters.reserved | Should -BeFalse
        $result.letters.runtime | Should -BeNullOrEmpty
        $result.letters.slots.Count | Should -Be 0
        $result.letters.states.Count | Should -Be 0
        $null -eq $result.problems | Should -BeFalse
        @($result.problems).Count | Should -Be 0
        $result.problems -is [System.Array] | Should -BeTrue
    }

    It 'reports pattern count <count> with the pinned problem text' -Tag Sandbox -ForEach @(
        @{ Count = 0 }
        @{ Count = 2 }
    ) {
        $root = Join-Path $TestDrive "pat-$Count"
        $cursor = Join-Path $root 'cursor'
        $version = '2026.04.05-abc123'
        New-CursorTree -CursorRoot $cursor -Version $version -PatternCount $Count
        $cache = Join-Path $root 'sandbox\cursor'
        $result = Test-SandboxSupport -CursorRoot $cursor -CacheRoot $cache -UvProbe { '1.52.1' }
        $expected = "Cursor ${version}: " + ($script:PatternProblem -f $Count)
        $result.ok | Should -BeFalse
        $result.cursorVersion | Should -Be $version
        $result.patternCount | Should -Be $Count
        $result.uv | Should -Be '1.52.1'
        @($result.problems) | Should -Be @($expected)
        $result.letters.reserved | Should -BeFalse
    }

    It 'leaves patternCount null when libuv is 1.53 or later' {
        $cursor = Join-Path $TestDrive 'uv153-cursor'
        $version = '2026.04.05-abc123'
        New-CursorTree -CursorRoot $cursor -Version $version -PatternCount 0
        $result = Test-SandboxSupport -CursorRoot $cursor -CacheRoot (Join-Path $TestDrive 'uv153-cache') -UvProbe { '1.53.0-pre' }
        $result.ok | Should -BeTrue
        $result.uv | Should -Be '1.53.0-pre'
        $result.patternCount | Should -BeNullOrEmpty
        @($result.problems).Count | Should -Be 0
    }

    It 'returns at once when XAGENT_SANDBOX_FORCE_FAIL is set' {
        $cursor = Join-Path $TestDrive 'force-cursor'
        New-CursorTree -CursorRoot $cursor -Version '2026.04.05-abc123' -PatternCount 1
        try {
            $env:XAGENT_SANDBOX_FORCE_FAIL = '1'
            $result = Test-SandboxSupport -CursorRoot $cursor -CacheRoot (Join-Path $TestDrive 'force-cache') -UvProbe { '1.52.1' }
        } finally {
            Remove-Item Env:XAGENT_SANDBOX_FORCE_FAIL -ErrorAction SilentlyContinue
        }
        $result.ok | Should -BeFalse
        $result.cursorVersion | Should -BeNullOrEmpty
        $result.uv | Should -BeNullOrEmpty
        $result.patternCount | Should -BeNullOrEmpty
        $result.letters.reserved | Should -BeFalse
        @($result.problems) | Should -Be @('forced failure (XAGENT_SANDBOX_FORCE_FAIL)')
    }

    It 'names a missing Cursor install' {
        $cursor = Join-Path $TestDrive 'missing-cursor'
        New-Item -ItemType Directory -Force -Path $cursor | Out-Null
        $result = Test-SandboxSupport -CursorRoot $cursor -CacheRoot (Join-Path $TestDrive 'missing-cache') -UvProbe { '1.52.1' }
        $result.ok | Should -BeFalse
        $result.cursorVersion | Should -BeNullOrEmpty
        @($result.problems) | Should -Contain "Cursor CLI not found at $(Join-Path $cursor 'versions') (no version folder matches)"
    }

    It 'reports a uv probe failure and does not count the pattern' {
        $cursor = Join-Path $TestDrive 'uvfail-cursor'
        New-CursorTree -CursorRoot $cursor -Version '2026.04.05-abc123' -PatternCount 1
        $result = Test-SandboxSupport -CursorRoot $cursor -CacheRoot (Join-Path $TestDrive 'uvfail-cache') -UvProbe { throw 'exit code 3' }
        $result.ok | Should -BeFalse
        $result.patternCount | Should -BeNullOrEmpty
        @($result.problems) | Should -Contain 'Cursor 2026.04.05-abc123: cannot read libuv version from node.exe (exit code 3)'
    }
}

Describe 'Get-SandboxRuntime' {
    BeforeAll {
        function Invoke-Runtime {
            param([string]$Name, [int]$PatternCount, [scriptblock]$Probe, [string]$Version = '2026.08.09-abc123')
            $root = Join-Path $TestDrive $Name
            $cursor = Join-Path $root 'cursor'
            $cache = Join-Path $root 'sandbox\cursor'
            New-CursorTree -CursorRoot $cursor -Version $Version -PatternCount $PatternCount
            return @{
                Root = $root
                Cursor = $cursor
                Cache = $cache
                Version = $Version
                Source = Join-Path $cursor "versions\$Version\node.exe"
            }
        }
    }

    It 'patches a single pipe-name pattern and records patch.json' {
        $case = Invoke-Runtime -Name 'patch-once' -PatternCount 1
        $sourceLength = (Get-Item -LiteralPath $case.Source).Length
        $sourceHash = Get-TestSha256 $case.Source
        $result = Get-SandboxRuntime -CursorRoot $case.Cursor -CacheRoot $case.Cache -UvProbe { '1.52.1' }
        $result.root | Should -Be ([IO.Path]::GetFullPath($case.Cache))
        $result.version | Should -Be $case.Version
        $result.uv | Should -Be '1.52.1'
        $result.patched | Should -BeTrue

        $cached = Join-Path $case.Cache "$($case.Version)\node.exe"
        (Get-Item -LiteralPath $cached).Length | Should -Be $sourceLength
        $patch = Get-Content -Raw -LiteralPath (Join-Path $case.Cache "$($case.Version)\patch.json") | ConvertFrom-Json
        $patch.patched | Should -BeTrue
        $patch.offset | Should -Be 32
        $patch.uv | Should -Be '1.52.1'
        $patch.sourceSha256 | Should -Be $sourceHash
        $patch.patchedSha256 | Should -Be (Get-TestSha256 $cached)
        $bytes = [IO.File]::ReadAllBytes($cached)
        $slice = [byte[]]$bytes[$patch.offset..($patch.offset + 19)]
        [Convert]::ToHexString($slice).ToLowerInvariant() | Should -Be ([Convert]::ToHexString($script:PipeReplacement).ToLowerInvariant())
        $bytes[$patch.offset + 20] | Should -Be 0
        (Get-Content -Raw -LiteralPath (Join-Path $case.Cache "$($case.Version)\index.js")) | Should -Match 'synthetic'
    }

    It 'throws the pinned error for <Count> patterns and leaves no cache folder' -ForEach @(
        @{ Count = 0 }
        @{ Count = 2 }
    ) {
        $case = Invoke-Runtime -Name "patch-$Count" -PatternCount $Count
        $markerDir = Join-Path $case.Cache $case.Version
        New-Item -ItemType Directory -Force -Path $markerDir | Out-Null
        Set-Content -LiteralPath (Join-Path $markerDir 'marker.txt') -Value 'keep' -Encoding utf8
        $message = Get-ThrownMessage { Get-SandboxRuntime -CursorRoot $case.Cursor -CacheRoot $case.Cache -UvProbe { '1.52.0' } }
        $expected = 'sandbox: Cursor {0}: {1}' -f $case.Version, ($script:PatternProblem -f $Count)
        $message | Should -Be $expected
        Test-Path -LiteralPath (Join-Path $case.Cache "$($case.Version).partial") | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $markerDir 'marker.txt') | Should -Be 'keep'
    }

    It 'reuses a patched cache without rewriting node.exe' {
        $case = Invoke-Runtime -Name 'reuse' -PatternCount 1
        $null = Get-SandboxRuntime -CursorRoot $case.Cursor -CacheRoot $case.Cache -UvProbe { '1.52.1' }
        $cached = Join-Path $case.Cache "$($case.Version)\node.exe"
        $stamp = [datetime]::SpecifyKind([datetime]'2020-01-02T03:04:05', 'Utc')
        (Get-Item -LiteralPath $cached).LastWriteTimeUtc = $stamp
        $again = Get-SandboxRuntime -CursorRoot $case.Cursor -CacheRoot $case.Cache -UvProbe { throw 'probe should not run' }
        $again.patched | Should -BeTrue
        $again.uv | Should -Be '1.52.1'
        (Get-Item -LiteralPath $cached).LastWriteTimeUtc | Should -Be $stamp
    }

    It 'copies again when the cached node.exe hash changes' {
        $case = Invoke-Runtime -Name 'rehash' -PatternCount 1
        $null = Get-SandboxRuntime -CursorRoot $case.Cursor -CacheRoot $case.Cache -UvProbe { '1.52.1' }
        $cached = Join-Path $case.Cache "$($case.Version)\node.exe"
        $dir = Split-Path -Parent $cached
        Set-Content -LiteralPath (Join-Path $dir 'marker.txt') -Value 'stale' -Encoding utf8
        $bytes = [IO.File]::ReadAllBytes($cached)
        $bytes[0] = $bytes[0] -bxor 0xFF
        [IO.File]::WriteAllBytes($cached, $bytes)
        $again = Get-SandboxRuntime -CursorRoot $case.Cursor -CacheRoot $case.Cache -UvProbe { '1.52.1' }
        $again.patched | Should -BeTrue
        $restored = [IO.File]::ReadAllBytes($cached)
        $restored[0] | Should -Be 0xA5
        Test-Path -LiteralPath (Join-Path $dir 'marker.txt') | Should -BeFalse
        $patch = Get-Content -Raw -LiteralPath (Join-Path $dir 'patch.json') | ConvertFrom-Json
        $patch.patchedSha256 | Should -Be (Get-TestSha256 $cached)
    }

    It 'skips the patch when the probe returns <Uv>' -ForEach @(
        @{ Uv = '1.53.0' }
        @{ Uv = '1.53.0-pre' }
    ) {
        $case = Invoke-Runtime -Name "skip-$($Uv.Replace('.', '-'))" -PatternCount 2
        $sourceHash = Get-TestSha256 $case.Source
        $probe = [scriptblock]::Create("'$($Uv.Replace("'", "''"))'")
        $result = Get-SandboxRuntime -CursorRoot $case.Cursor -CacheRoot $case.Cache -UvProbe $probe
        $result.patched | Should -BeFalse
        $result.uv | Should -Be $Uv
        $cached = Join-Path $case.Cache "$($case.Version)\node.exe"
        (Get-TestSha256 $cached) | Should -Be $sourceHash
        $patch = Get-Content -Raw -LiteralPath (Join-Path $case.Cache "$($case.Version)\patch.json") | ConvertFrom-Json
        $patch.patched | Should -BeFalse
        $patch.uv | Should -Be $Uv
        $stamp = [datetime]::SpecifyKind([datetime]'2020-01-02T03:04:05', 'Utc')
        (Get-Item -LiteralPath $cached).LastWriteTimeUtc = $stamp
        $again = Get-SandboxRuntime -CursorRoot $case.Cursor -CacheRoot $case.Cache -UvProbe { throw 'probe should not run' }
        $again.patched | Should -BeFalse
        (Get-Item -LiteralPath $cached).LastWriteTimeUtc | Should -Be $stamp
    }

    It 'deletes an existing version folder and a stale partial before copying' {
        $case = Invoke-Runtime -Name 'replace' -PatternCount 1
        $old = Join-Path $case.Cache $case.Version
        $partial = Join-Path $case.Cache "$($case.Version).partial"
        New-Item -ItemType Directory -Force -Path $old, $partial | Out-Null
        Set-Content -LiteralPath (Join-Path $old 'old.txt') -Value 'old' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $partial 'partial.txt') -Value 'partial' -Encoding utf8
        $null = Get-SandboxRuntime -CursorRoot $case.Cursor -CacheRoot $case.Cache -UvProbe { '1.52.1' }
        Test-Path -LiteralPath (Join-Path $old 'old.txt') | Should -BeFalse
        Test-Path -LiteralPath $partial | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $old 'node.exe') | Should -BeTrue
    }

    It 'prunes older cache versions, partials, and keeps a ledger version' {
        $case = Invoke-Runtime -Name 'prune' -PatternCount 1 -Version '2026.12.01-ccc333'
        foreach ($name in @('2026.12.01-ccc333', '2026.06.01-bbb222', '2026.01.01-aaa111', '2025.01.01-ddd444')) {
            $dir = Join-Path $case.Cache $name
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'marker.txt') -Value $name -Encoding utf8
        }
        $partial = Join-Path $case.Cache '2024.02.02-eeeeee.partial'
        New-Item -ItemType Directory -Force -Path $partial | Out-Null
        $sandbox = Split-Path -Parent $case.Cache
        @{ runtimeVersion = '2025.01.01-ddd444' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sandbox 'slot-S.json') -Encoding utf8
        Set-Content -LiteralPath (Join-Path $sandbox 'slot-T.json') -Value '{' -Encoding utf8
        $result = Get-SandboxRuntime -CursorRoot $case.Cursor -CacheRoot $case.Cache -UvProbe { '1.52.1' }
        $result.version | Should -Be '2026.12.01-ccc333'
        Test-Path -LiteralPath (Join-Path $case.Cache '2026.12.01-ccc333\node.exe') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $case.Cache '2026.12.01-ccc333\marker.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $case.Cache '2026.06.01-bbb222') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $case.Cache '2026.01.01-aaa111') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $case.Cache '2025.01.01-ddd444') | Should -BeTrue
        Test-Path -LiteralPath $partial | Should -BeFalse
    }

    It 'patches the realpath and tmp code in the runtime copy and records it' {
        $case = Invoke-Runtime -Name 'jspatch' -PatternCount 1
        $src = Join-Path $case.Cursor "versions\$($case.Version)"
        $realpath = 'try{e=(0,P.realpathSync)(t)}catch{throw new Xw(t,`Cannot verify canonical path before ${r}: ${t}`)}'
        $tmp = 'const p="--cursor-persist-restore",h="cursor-agent",g="/tmp";function k(){return d().join(g,`cursor-agent-persist-${t}`)}'
        $utf8 = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Join-Path $src 'index.js'), "/*! x */$realpath;$tmp", $utf8)
        [IO.File]::WriteAllText((Join-Path $src 'worker.js'), "a;$realpath", $utf8)
        [IO.File]::WriteAllText((Join-Path $src 'twice.js'), "$realpath;$realpath", $utf8)
        $null = Get-SandboxRuntime -CursorRoot $case.Cursor -CacheRoot $case.Cache -UvProbe { '1.52.1' }
        $dir = Join-Path $case.Cache $case.Version
        $index = [IO.File]::ReadAllText((Join-Path $dir 'index.js'))
        $index.Contains('e=(0,P.realpathSync.native)(t)}catch{throw new Xw(t,`Cannot verify canonical path') | Should -BeTrue
        $index | Should -BeLike '*h="cursor-agent",g=require("node:os").tmpdir();*'
        [IO.File]::ReadAllText((Join-Path $dir 'worker.js')) | Should -BeLike '*realpathSync.native*'
        [IO.File]::ReadAllText((Join-Path $dir 'twice.js')) | Should -Not -BeLike '*realpathSync.native*'
        [IO.File]::ReadAllText((Join-Path $src 'index.js')) | Should -Not -BeLike '*realpathSync.native*'
        $patch = Get-Content -Raw -LiteralPath (Join-Path $dir 'patch.json') | ConvertFrom-Json
        $patch.jsPatch | Should -Be 2
        @($patch.jsPatched | Sort-Object) | Should -Be @('index.js:realpath', 'index.js:tmp', 'worker.js:realpath')
    }

    It 'copies again when patch.json records no JavaScript patch version' {
        $case = Invoke-Runtime -Name 'jspatch-old' -PatternCount 1
        $null = Get-SandboxRuntime -CursorRoot $case.Cursor -CacheRoot $case.Cache -UvProbe { '1.52.1' }
        $dir = Join-Path $case.Cache $case.Version
        $patchPath = Join-Path $dir 'patch.json'
        $patch = Get-Content -Raw -LiteralPath $patchPath | ConvertFrom-Json
        $patch.PSObject.Properties.Remove('jsPatch')
        $patch | ConvertTo-Json | Set-Content -LiteralPath $patchPath -Encoding utf8
        Set-Content -LiteralPath (Join-Path $dir 'marker.txt') -Value 'stale' -Encoding utf8
        $again = Get-SandboxRuntime -CursorRoot $case.Cursor -CacheRoot $case.Cache -UvProbe { '1.52.1' }
        $again.patched | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dir 'marker.txt') | Should -BeFalse
        (Get-Content -Raw -LiteralPath $patchPath | ConvertFrom-Json).jsPatch | Should -Be 2
    }

    It 'throws when no version folder matches and builds no cache' {
        $cursor = Join-Path $TestDrive 'empty-cursor'
        $cache = Join-Path $TestDrive 'empty-cache'
        New-Item -ItemType Directory -Force -Path $cursor | Out-Null
        $message = Get-ThrownMessage { Get-SandboxRuntime -CursorRoot $cursor -CacheRoot $cache -UvProbe { '1.52.1' } }
        $message | Should -Be "sandbox: Cursor CLI not found at $(Join-Path $cursor 'versions') (no version folder matches)"
        Test-Path -LiteralPath $cache | Should -BeFalse
    }

    It 'aborts on uv probe <Reason> and leaves the cache untouched' -ForEach @(
        @{ Reason = 'exit code 7' }
        @{ Reason = 'no output' }
        @{ Reason = 'timed out after 5 s' }
    ) {
        $case = Invoke-Runtime -Name "uv-$($Reason.GetHashCode())" -PatternCount 1
        $marker = Join-Path $case.Cache "$($case.Version)\marker.txt"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $marker) | Out-Null
        Set-Content -LiteralPath $marker -Value 'keep' -Encoding utf8
        $reason = $Reason
        $probe = [scriptblock]::Create("throw '$($reason.Replace("'", "''"))'")
        $message = Get-ThrownMessage { Get-SandboxRuntime -CursorRoot $case.Cursor -CacheRoot $case.Cache -UvProbe $probe }
        $message | Should -Be "sandbox: Cursor $($case.Version): cannot read libuv version from node.exe ($reason)"
        Get-Content -LiteralPath $marker | Should -Be 'keep'
        Test-Path -LiteralPath (Join-Path $case.Cache "$($case.Version).partial") | Should -BeFalse
    }
}

Describe 'Move-SandboxChat' {
    BeforeAll {
        function Get-ChatHash([string]$Text) {
            $bytes = [Security.Cryptography.MD5]::HashData([Text.Encoding]::UTF8.GetBytes($Text))
            return -join ($bytes | ForEach-Object { $_.ToString('x2') })
        }
    }

    It 'moves a chat from another slot folder to the current slot folder' {
        $wt = Join-Path $TestDrive 'chat-move'
        $chats = Join-Path $wt '.xagent\sandbox\home\.cursor\chats'
        $old = Join-Path (Join-Path $chats (Get-ChatHash 'Y:\')) 'abc-123'
        New-Item -ItemType Directory -Force -Path $old | Out-Null
        Set-Content -LiteralPath (Join-Path $old 'store.db') -Value 'chat' -Encoding utf8
        $note = Move-SandboxChat -Worktree $wt -Slot 'x' -SessionId 'abc-123'
        $note | Should -Be 'moved chat abc-123 to slot X'
        $new = Join-Path (Join-Path $chats (Get-ChatHash 'X:\')) 'abc-123'
        Get-Content -LiteralPath (Join-Path $new 'store.db') | Should -Be 'chat'
        Test-Path -LiteralPath $old | Should -BeFalse
    }

    It 'leaves a chat already in the current slot folder' {
        $wt = Join-Path $TestDrive 'chat-same'
        $here = Join-Path (Join-Path $wt ('.xagent\sandbox\home\.cursor\chats\' + (Get-ChatHash 'X:\'))) 'abc-123'
        New-Item -ItemType Directory -Force -Path $here | Out-Null
        Move-SandboxChat -Worktree $wt -Slot 'X' -SessionId 'abc-123' | Should -BeNullOrEmpty
        Test-Path -LiteralPath $here | Should -BeTrue
    }

    It 'returns nothing when the chat or the chats folder is missing' {
        $wt = Join-Path $TestDrive 'chat-none'
        Move-SandboxChat -Worktree $wt -Slot 'X' -SessionId 'abc-123' | Should -BeNullOrEmpty
        New-Item -ItemType Directory -Force -Path (Join-Path $wt '.xagent\sandbox\home\.cursor\chats\deadbeef') | Out-Null
        Move-SandboxChat -Worktree $wt -Slot 'X' -SessionId 'abc-123' | Should -BeNullOrEmpty
    }
}

Describe 'version choice' {
    It 'picks the same folder as the launcher Parse-VersionString sort' {
        $launcher = Join-Path $env:LOCALAPPDATA 'cursor-agent\cursor-agent.ps1'
        if (-not (Test-Path -LiteralPath $launcher)) {
            Set-ItResult -Skipped -Because 'cursor-agent.ps1 is unreadable'
        }
        $tokens = $null
        $errors = $null
        try {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tokens, [ref]$errors)
        } catch {
            Set-ItResult -Skipped -Because 'cursor-agent.ps1 is unreadable'
        }
        $fn = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Parse-VersionString'
        }, $true)
        if (-not $fn) { Set-ItResult -Skipped -Because 'cursor-agent.ps1 is unreadable' }
        Invoke-Expression $fn.Extent.Text

        $cursor = Join-Path $TestDrive 'versions-cursor'
        $names = @(
            '2026.01.15-aaa111',
            '2026.11.02-bbb222',
            '2026.11.02-ccc333',
            '2026.11.02-01-02-03-ddd444',
            '2025.12.31-eee555',
            'notes',
            '2026.11.02-GGGGGG'
        )
        foreach ($name in $names) {
            $dir = Join-Path $cursor "versions\$name"
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            if ($name -match $script:VersionPattern) {
                New-SyntheticNode -Path (Join-Path $dir 'node.exe') -Copies 1
            }
        }
        $oracle = Get-ChildItem -LiteralPath (Join-Path $cursor 'versions') -Directory |
            Where-Object { $_.Name -match $script:VersionPattern } |
            Sort-Object { Parse-VersionString $_.Name } -Descending |
            Select-Object -First 1
        $result = Test-SandboxSupport -CursorRoot $cursor -CacheRoot (Join-Path $TestDrive 'versions-cache') -UvProbe { '1.52.1' }
        $result.cursorVersion | Should -Be $oracle.Name
        $result.ok | Should -BeTrue
    }
}

Describe 'letters' {
    It 'Test-LetterFree reports a real drive as used and a free letter as free' {
        $used = InModuleScope Sandbox { Test-LetterFree -Letter 'c' }
        $used | Should -Be 'used'
        $free = InModuleScope Sandbox {
            $map = Get-SubstMap
            $drives = Get-DriveLetters
            foreach ($code in 90..68) {
                $candidate = [string][char]$code
                $status = Test-LetterFreeWithMap -Letter $candidate -Map $map -Drives $drives
                if ($status -eq 'free') { return $candidate }
            }
            return $null
        }
        if (-not $free) { Set-ItResult -Skipped -Because 'no free drive letter D-Z' }
        InModuleScope Sandbox -Parameters @{ Letter = $free } {
            param($Letter)
            Test-LetterFree -Letter $Letter
        } | Should -Be 'free'
    }

    It 'rejects duplicate letters before the in-use check' {
        $message = Get-ThrownMessage { Set-SandboxLetters -Letters 'D', 'D', 'E' }
        $message | Should -Be 'sandbox: -Reserve needs three distinct letters D-Z'
        $trimmed = Get-ThrownMessage { Set-SandboxLetters -Letters ' y ', 'Y', 'Z' }
        $trimmed | Should -Be 'sandbox: -Reserve needs three distinct letters D-Z'
    }

    It 'rejects letters outside D-Z before the in-use check' {
        $message = Get-ThrownMessage { Set-SandboxLetters -Letters 'A', 'B', 'C' }
        $message | Should -Be 'sandbox: -Reserve needs three distinct letters D-Z'
        $message = Get-ThrownMessage { Set-SandboxLetters -Letters 'C', 'Y', 'Z' }
        $message | Should -Be 'sandbox: -Reserve needs three distinct letters D-Z'
    }

    It 'rejects a letter that is already in use' {
        $used = InModuleScope Sandbox {
            $map = Get-SubstMap
            $drives = Get-DriveLetters
            foreach ($code in 68..90) {
                $candidate = [string][char]$code
                if ((Test-LetterFreeWithMap -Letter $candidate -Map $map -Drives $drives) -eq 'used') { return $candidate }
            }
            return $null
        }
        $others = @(InModuleScope Sandbox -Parameters @{ Used = $used } {
            param($Used)
            $map = Get-SubstMap
            $drives = Get-DriveLetters
            $found = @()
            foreach ($code in 90..68) {
                $candidate = [string][char]$code
                if ($candidate -eq $Used) { continue }
                if ((Test-LetterFreeWithMap -Letter $candidate -Map $map -Drives $drives) -eq 'free') { $found += $candidate }
                if ($found.Count -eq 2) { break }
            }
            $found
        })
        if (-not $used -or $others.Count -lt 2) { Set-ItResult -Skipped -Because 'no used drive letter D-Z' }
        $message = Get-ThrownMessage { Set-SandboxLetters -Letters $used, $others[0], $others[1] }
        $message | Should -Be "sandbox: letter ${used}: is in use"
        $lower = $used.ToLowerInvariant()
        $message = Get-ThrownMessage { Set-SandboxLetters -Letters " $lower ", $others[0], $others[1] }
        $message | Should -Be "sandbox: letter ${used}: is in use"
    }

    It 'Initialize-SandboxLetters names three free letters and the literal repo token' {
        $env:XAGENT_SANDBOX_ROOT = Join-Path $TestDrive 'init-root'
        $env:XAGENT_CURSOR_ROOT = Join-Path $TestDrive 'init-cursor'
        New-Item -ItemType Directory -Force -Path $env:XAGENT_SANDBOX_ROOT, $env:XAGENT_CURSOR_ROOT | Out-Null
        Import-Module $script:ModulePath -Force
        $expected = InModuleScope Sandbox {
            $suggested = @(Get-FreeLetterSuggestions)
            if ($suggested.Count -eq 1 -and $suggested[0] -is [System.Array]) { $suggested = @($suggested[0]) }
            $a = $suggested[0]; $b = $suggested[1]; $c = $suggested[2]
            "sandbox: no drive letters reserved; suggested: $a, $b, $c; ask the user, then run delegate.ps1 -SandboxCheck -Reserve $a,$b,$c -Repo <repo>"
        }
        $message = Get-ThrownMessage { Initialize-SandboxLetters }
        $message | Should -Be $expected
        $message | Should -Match '^sandbox: no drive letters reserved; suggested: [D-Z], [D-Z], [D-Z]; ask the user, then run delegate.ps1 -SandboxCheck -Reserve [D-Z],[D-Z],[D-Z] -Repo <repo>$'
        Test-Path -LiteralPath (Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox') | Should -BeFalse
    }

    It 'Get-SandboxConfig defaults when sandbox.json is missing' {
        $cfg = Get-SandboxConfig
        $cfg.letters | Should -BeNullOrEmpty
        @($cfg.read).Count | Should -Be 0
    }

    It 'reports a reserved letter that another drive is using' {
        $cursor = Join-Path $TestDrive 'letters-cursor'
        $root = Join-Path $TestDrive 'letters-root'
        New-CursorTree -CursorRoot $cursor -Version '2026.04.05-abc123' -PatternCount 1
        $used = InModuleScope Sandbox {
            foreach ($code in 68..90) {
                $candidate = [string][char]$code
                if ((Test-LetterFree -Letter $candidate) -eq 'used') { return $candidate }
            }
            return $null
        }
        $free = @(InModuleScope Sandbox {
            $map = Get-SubstMap
            $drives = Get-DriveLetters
            $found = @()
            foreach ($code in 90..68) {
                $candidate = [string][char]$code
                if ((Test-LetterFreeWithMap -Letter $candidate -Map $map -Drives $drives) -eq 'free') { $found += $candidate }
                if ($found.Count -eq 2) { break }
            }
            $found
        })
        if (-not $used -or $free.Count -lt 2) { Set-ItResult -Skipped -Because 'need one used and two free letters D-Z' }
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        @{ letters = @{ runtime = $used; slots = @($free[0], $free[1]) }; read = @() } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'sandbox.json') -Encoding utf8
        $cache = Join-Path $root 'sandbox\cursor'
        $result = Test-SandboxSupport -CursorRoot $cursor -CacheRoot $cache -UvProbe { '1.52.1' }
        $result.ok | Should -BeFalse
        $result.letters.reserved | Should -BeTrue
        $result.letters.runtime | Should -Be $used
        @($result.letters.slots) | Should -Be @($free[0], $free[1])
        $result.letters.states[$used] | Should -Be 'used'
        $result.letters.states[$free[0]] | Should -Be 'free'
        $result.letters.states[$free[1]] | Should -Be 'free'
        @($result.problems) | Should -Contain "reserved letter ${used}: is used by another drive; choose new letters"
    }

    It 'treats a slot still mapped to a dead run''s worktree as stale, not used' {
        # 2026-11-16: a killed run left its slot mapped to its worktree, and the next run refused it.
        $dir = Join-Path $TestDrive 'stale-slot'
        $wt = Join-Path $dir 'wt'
        $other = Join-Path $dir 'other'
        New-Item -ItemType Directory -Force -Path $wt, $other | Out-Null
        $ledger = Join-Path $dir 'slot-Q.json'
        $deadPid = 999999
        @{ slot = 'Q'; sid = 'S-1-15-2-1'; pid = $deadPid; startTime = '2026-01-01T00:00:00Z'; worktree = $wt; grants = @() } |
            ConvertTo-Json | Set-Content -LiteralPath $ledger -Encoding utf8
        $states = InModuleScope Sandbox -Parameters @{ Wt = $wt; Other = $other; Ledger = $ledger; Idle = (Join-Path $dir 'idle') } {
            param($Wt, $Other, $Ledger, $Idle)
            $drives = [Collections.Generic.HashSet[string]]::new()
            @{
                stale = Get-ReservedLetterState -Letter 'Q' -Expected $Idle -LedgerPath $Ledger -Slot $true -Map @{ Q = $Wt } -Drives $drives
                elsewhere = Get-ReservedLetterState -Letter 'Q' -Expected $Idle -LedgerPath $Ledger -Slot $true -Map @{ Q = $Other } -Drives $drives
                runtime = Get-ReservedLetterState -Letter 'Q' -Expected $Idle -LedgerPath $Ledger -Slot $false -Map @{ Q = $Wt } -Drives $drives
                noLedger = Get-ReservedLetterState -Letter 'Q' -Expected $Idle -LedgerPath (Join-Path $Idle 'none.json') -Slot $true -Map @{ Q = $Wt } -Drives $drives
            }
        }
        $states.stale | Should -Be 'stale'
        $states.elsewhere | Should -Be 'used'
        $states.runtime | Should -Be 'used'
        $states.noLedger | Should -Be 'used'
    }
}

Describe 'read list and environment' {
    BeforeAll {
        $script:ReadRoot = Join-Path $TestDrive 'read-root'
        $script:ReadCursor = Join-Path $TestDrive 'read-cursor'
        $env:XAGENT_SANDBOX_ROOT = $script:ReadRoot
        $env:XAGENT_CURSOR_ROOT = $script:ReadCursor
        New-Item -ItemType Directory -Force -Path $script:ReadRoot, $script:ReadCursor | Out-Null
        $script:ReadVersion = '2026.04.05-abc123'
        New-CursorTree -CursorRoot $script:ReadCursor -Version $script:ReadVersion -PatternCount 1
        Import-Module $script:ModulePath -Force

        function Set-ReadConfig($Read) {
            $payload = @{ letters = $null; read = @($Read) }
            $json = $payload | ConvertTo-Json -Depth 6
            $path = Join-Path $script:ReadRoot 'sandbox.json'
            [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
        }

        function Get-ReadSupport {
            $cache = Join-Path $script:ReadRoot 'sandbox\cursor'
            return Test-SandboxSupport -CursorRoot $script:ReadCursor -CacheRoot $cache -UvProbe { '1.53.0' }
        }

        function Get-NormalizedEntryPath([string]$Path) {
            $expanded = [Environment]::ExpandEnvironmentVariables($Path)
            if ($expanded.Length -gt 0 -and $expanded[0] -eq [char]'~') {
                $profileRoot = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\', '/')
                $expanded = $profileRoot + $expanded.Substring(1)
            }
            $full = [IO.Path]::GetFullPath($expanded).TrimEnd('\', '/')
            $authored = $expanded.Replace('/', '\').TrimEnd('\')
            if ([string]::Equals($full, $authored, [StringComparison]::OrdinalIgnoreCase)) { return $authored }
            return $full
        }

        function Get-ReadProblemText([string]$Path, [string]$Reason) {
            return "read-list entry '$Path' $Reason; edit sandbox.json"
        }
    }

    AfterAll {
        $env:XAGENT_SANDBOX_ROOT = Join-Path $TestDrive 'root'
        $env:XAGENT_CURSOR_ROOT = Join-Path $TestDrive 'cursor'
        Import-Module $script:ModulePath -Force
    }

    It 'refuses each read-list case in the throw and in Test-SandboxSupport' {
        $profile = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\', '/')
        $ssh = [IO.Path]::GetFullPath((Join-Path $profile '.ssh')).TrimEnd('\', '/')
        $roaming = [IO.Path]::GetFullPath((Join-Path $profile 'AppData\Roaming')).TrimEnd('\', '/')
        $cursorAgent = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'cursor-agent')).TrimEnd('\', '/')
        $sandboxDir = [IO.Path]::GetFullPath((Join-Path $script:ReadRoot 'sandbox')).TrimEnd('\', '/')
        $missing = Join-Path $TestDrive ('missing-' + [guid]::NewGuid().ToString('N'))
        $cases = @(
            @{ Name = 'profile root'; Entry = $profile; Reason = 'is the profile root' }
            @{ Name = 'ssh'; Entry = '~\.ssh'; Reason = "is under a protected folder ($ssh)" }
            @{ Name = 'ssh mixed case'; Entry = '~\.SSH\id_ed25519'; Reason = "is under a protected folder ($ssh)" }
            @{ Name = 'roaming'; Entry = '~\AppData\Roaming\x'; Reason = "is under a protected folder ($roaming)" }
            @{ Name = 'cursor-agent'; Entry = '%LOCALAPPDATA%\cursor-agent\versions'; Reason = "is under a protected folder ($cursorAgent)" }
            @{ Name = 'sandbox folder'; Entry = $sandboxDir; Reason = "is under the sandbox's own folder" }
            @{ Name = 'missing'; Entry = $missing; Reason = 'does not exist' }
        )
        foreach ($case in $cases) {
            $display = Get-NormalizedEntryPath $case.Entry
            $expected = Get-ReadProblemText $display $case.Reason
            $thrown = InModuleScope Sandbox -Parameters @{ Entry = $case.Entry } {
                param($Entry)
                try {
                    Test-SandboxReadList -Entries @([pscustomobject]@{ path = $Entry }) | Out-Null
                    return $null
                } catch {
                    return $_.Exception.Message
                }
            }
            $thrown | Should -Be "sandbox: $expected" -Because $case.Name
            Set-ReadConfig @(@{ path = $case.Entry })
            $result = Get-ReadSupport
            @($result.problems) | Should -Be @($expected) -Because $case.Name
        }
        $mixed = Get-NormalizedEntryPath '~\.SSH\id_ed25519'
        $mixed | Should -Match '\.SSH\\id_ed25519$'
        $ssh | Should -Match '\.ssh$'
    }

    It 'refuses a malformed entry and a relative path in both message forms' {
        $malformed = "read-list entry '' is not a valid path; edit sandbox.json"
        $thrown = InModuleScope Sandbox {
            try {
                Test-SandboxReadList -Entries @([pscustomobject]@{ addToPath = $true }) | Out-Null
                return $null
            } catch {
                return $_.Exception.Message
            }
        }
        $thrown | Should -Be "sandbox: $malformed"
        Set-ReadConfig @(@{ addToPath = $true })
        @((Get-ReadSupport).problems) | Should -Be @($malformed)

        $relative = "read-list entry 'tools\python' is not an absolute path; edit sandbox.json"
        $thrown = InModuleScope Sandbox {
            try {
                Test-SandboxReadList -Entries @([pscustomobject]@{ path = 'tools\python' }) | Out-Null
                return $null
            } catch {
                return $_.Exception.Message
            }
        }
        $thrown | Should -Be "sandbox: $relative"
        Set-ReadConfig @(@{ path = 'tools\python' })
        @((Get-ReadSupport).problems) | Should -Be @($relative)
    }

    It 'lists the pattern problem and then each refused entry, in config order' {
        $cursor = Join-Path $TestDrive 'order-cursor'
        New-CursorTree -CursorRoot $cursor -Version $script:ReadVersion -PatternCount 0
        $profile = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\', '/')
        $ssh = [IO.Path]::GetFullPath((Join-Path $profile '.ssh')).TrimEnd('\', '/')
        $first = Get-NormalizedEntryPath $profile
        $second = Get-NormalizedEntryPath '~\.ssh'
        Set-ReadConfig @(
            @{ path = $profile }
            @{ path = '~\.ssh' }
        )
        $cache = Join-Path $script:ReadRoot 'sandbox\cursor'
        $result = Test-SandboxSupport -CursorRoot $cursor -CacheRoot $cache -UvProbe { '1.52.1' }
        $pattern = "Cursor $($script:ReadVersion): " + ($script:PatternProblem -f 0)
        $entry1 = Get-ReadProblemText $first 'is the profile root'
        $entry2 = Get-ReadProblemText $second "is under a protected folder ($ssh)"
        @($result.problems) | Should -Be @($pattern, $entry1, $entry2)
    }

    It 'returns a normalized entry and an empty result for null or empty input' {
        $tool = Join-Path $TestDrive 'allowed-tool'
        New-Item -ItemType Directory -Force -Path $tool | Out-Null
        $written = $tool.TrimEnd('\', '/') + '\'
        $expected = Get-NormalizedEntryPath $written
        $got = InModuleScope Sandbox -Parameters @{ Written = $written } {
            param($Written)
            $entries = Test-SandboxReadList -Entries @([pscustomobject]@{ path = $Written })
            $entries[0]
        }
        $got.path | Should -Be $expected
        $got.addToPath | Should -Be $false
        $counts = InModuleScope Sandbox {
            $fromNull = Test-SandboxReadList -Entries $null
            $fromEmpty = Test-SandboxReadList -Entries @()
            [pscustomobject]@{
                NullCount = $(if ($null -eq $fromNull) { -1 } else { @($fromNull).Count })
                EmptyCount = $(if ($null -eq $fromEmpty) { -1 } else { @($fromEmpty).Count })
            }
        }
        $counts.NullCount | Should -Be 0
        $counts.EmptyCount | Should -Be 0

        Set-ReadConfig @(@{ path = $written })
        $support = Get-ReadSupport
        $support.ok | Should -BeTrue
        @($support.problems).Count | Should -Be 0
    }

    It 'builds the environment from the listed names and addToPath entries' {
        $tool = Join-Path $TestDrive 'on-path-tool'
        New-Item -ItemType Directory -Force -Path $tool | Out-Null
        $tool = Get-NormalizedEntryPath $tool
        $oldGh = [Environment]::GetEnvironmentVariable('GH_TOKEN', 'Process')
        $oldAws = [Environment]::GetEnvironmentVariable('AWS_SECRET_ACCESS_KEY', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('GH_TOKEN', 'gh-secret-value', 'Process')
            [Environment]::SetEnvironmentVariable('AWS_SECRET_ACCESS_KEY', 'aws-secret-value', 'Process')
            $packed = InModuleScope Sandbox -Parameters @{ Tool = $tool } {
                param($Tool)
                $read = Test-SandboxReadList -Entries @([pscustomobject]@{ path = $Tool; addToPath = $true })
                [pscustomobject]@{
                    Block = Get-SandboxEnvironment -Slot 'S' -ReadList $read
                    Bare = Get-SandboxEnvironment -Slot 'S' -ReadList $null
                    Empty = Get-SandboxEnvironment -Slot 'S' -ReadList @()
                }
            }
        } finally {
            [Environment]::SetEnvironmentVariable('GH_TOKEN', $oldGh, 'Process')
            [Environment]::SetEnvironmentVariable('AWS_SECRET_ACCESS_KEY', $oldAws, 'Process')
        }

        $expectedNames = @(
            'SystemRoot', 'windir', 'SystemDrive', 'ProgramData', 'ComSpec', 'PATHEXT', 'NUMBER_OF_PROCESSORS',
            'PROCESSOR_ARCHITECTURE', 'OS', 'PATH', 'PSModulePath', 'USERPROFILE',
            'HOME', 'APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP', 'CURSOR_INVOKED_AS',
            'NODE_COMPILE_CACHE'
        ) | Sort-Object
        $base = 'C:\Windows\System32;C:\Windows;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Program Files\PowerShell\7;C:\Program Files\Git\cmd'
        foreach ($block in ($packed.Block, $packed.Bare, $packed.Empty)) {
            $names = @($block | ForEach-Object { ($_ -split '=', 2)[0] })
            @($names | Sort-Object) | Should -Be @($expectedNames)
            $names | Should -Not -Contain 'GH_TOKEN'
            $names | Should -Not -Contain 'AWS_SECRET_ACCESS_KEY'
        }
        $map = @{}
        foreach ($item in @($packed.Block)) {
            $pair = $item -split '=', 2
            $map[$pair[0]] = $pair[1]
        }
        $map['PATH'] | Should -Be ($base + ';' + $tool)
        $map['USERPROFILE'] | Should -Be 'S:\.xagent\sandbox\home'
        $map['HOME'] | Should -Be 'S:\.xagent\sandbox\home'
        $map['APPDATA'] | Should -Be 'S:\.xagent\sandbox\home\AppData\Roaming'
        $map['LOCALAPPDATA'] | Should -Be 'S:\.xagent\sandbox\home\AppData\Local'
        $map['TEMP'] | Should -Be 'S:\.xagent\sandbox\tmp'
        $map['TMP'] | Should -Be 'S:\.xagent\sandbox\tmp'
        $map['NODE_COMPILE_CACHE'] | Should -Be 'S:\.xagent\sandbox\tmp\node-compile-cache'
        $map['CURSOR_INVOKED_AS'] | Should -Be 'agent.cmd'
        $map['PSModulePath'] | Should -Be 'C:\Program Files\PowerShell\Modules;C:\Program Files\PowerShell\7\Modules'
        $map['SystemRoot'] | Should -Be ([Environment]::GetEnvironmentVariable('SystemRoot', 'Process'))
        $bareMap = @{}
        foreach ($item in @($packed.Bare)) {
            $pair = $item -split '=', 2
            $bareMap[$pair[0]] = $pair[1]
        }
        $bareMap['PATH'] | Should -Be $base
        $emptyMap = @{}
        foreach ($item in @($packed.Empty)) {
            $pair = $item -split '=', 2
            $emptyMap[$pair[0]] = $pair[1]
        }
        $emptyMap['PATH'] | Should -Be $base
    }

    It 'refuses a repo under the user profile and accepts a sibling' {
        $profile = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\', '/')
        $child = Join-Path $profile 'Documents'
        $refused = @($profile, ($profile + '\'), $child, $child.ToUpperInvariant())
        foreach ($target in $refused) {
            $message = InModuleScope Sandbox -Parameters @{ Target = $target } {
                param($Target)
                try {
                    Assert-SandboxOutsideProfile -Path $Target
                    return $null
                } catch {
                    return $_.Exception.Message
                }
            }
            $message | Should -Be 'sandbox: repos under the user profile are not supported'
        }
        foreach ($target in @(($profile + '2'), 'D:\xagent-outside-profile')) {
            InModuleScope Sandbox -Parameters @{ Target = $target } {
                param($Target)
                Assert-SandboxOutsideProfile -Path $Target
            }
        }
    }

    It 'reports one parse problem and no read-list problems when sandbox.json is invalid' {
        [IO.File]::WriteAllText((Join-Path $script:ReadRoot 'sandbox.json'), '{ not json', [Text.UTF8Encoding]::new($false))
        $result = Get-ReadSupport
        @($result.problems).Count | Should -Be 1
        $result.problems[0] | Should -Match '^cannot read sandbox.json \('
        $result.problems[0] | Should -Match '\)$'
        $result.problems[0] | Should -Not -Match 'read-list'
    }

    It 'treats a null or empty read list as no problem' {
        foreach ($readJson in @('null', '[]')) {
            $json = '{ "letters": null, "read": ' + $readJson + ' }'
            [IO.File]::WriteAllText((Join-Path $script:ReadRoot 'sandbox.json'), $json, [Text.UTF8Encoding]::new($false))
            $result = Get-ReadSupport
            $result.ok | Should -BeTrue
            @($result.problems).Count | Should -Be 0
        }
    }
}

Describe 'grant list and ledger' {
    BeforeAll {
        $script:GrantRoot = Join-Path $TestDrive 'grant-root'
        $script:GrantCursor = Join-Path $TestDrive 'grant-cursor'
        $env:XAGENT_SANDBOX_ROOT = $script:GrantRoot
        $env:XAGENT_CURSOR_ROOT = $script:GrantCursor
        New-Item -ItemType Directory -Force -Path $script:GrantRoot, $script:GrantCursor | Out-Null
        Import-Module $script:ModulePath -Force

        $script:GrantRepoParent = Join-Path $TestDrive 'grant-repos'
        $script:GrantRepoName = 'widget'
        $script:GrantRepo = Join-Path $script:GrantRepoParent $script:GrantRepoName
        $script:GrantWorktree = Join-Path $script:GrantRepoParent ($script:GrantRepoName + '.xagent\task-1')
        $script:GrantRuntime = Join-Path $TestDrive 'grant-runtime'
        $script:GrantVersion = '2026.04.05-abc123'
        $script:GrantWtName = 'wt-a'
        $script:GrantReadEntry = Join-Path $TestDrive 'grant-read-tool'
        $git = Join-Path $script:GrantRepo '.git'
        foreach ($dir in @('objects', 'refs', 'info', 'hooks', 'logs', 'worktrees\wt-a', 'worktrees\wt-b')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $git $dir) | Out-Null
        }
        foreach ($file in @('config', 'HEAD', 'packed-refs')) {
            Set-Content -LiteralPath (Join-Path $git $file) -Value 'x' -Encoding ascii
        }
        New-Item -ItemType Directory -Force -Path $script:GrantWorktree, (Join-Path $script:GrantRuntime $script:GrantVersion), $script:GrantReadEntry | Out-Null

        function Resolve-GrantPath([string]$Path) {
            if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
            return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
        }

        function Test-GrantUnder([string]$Candidate, [string]$Folder) {
            if ([string]::IsNullOrEmpty($Candidate) -or [string]::IsNullOrEmpty($Folder)) { return $false }
            if ([string]::Equals($Candidate, $Folder, [StringComparison]::OrdinalIgnoreCase)) { return $true }
            return $Candidate.StartsWith($Folder.TrimEnd('\', '/') + '\', [StringComparison]::OrdinalIgnoreCase)
        }

        function Get-GrantProfileRoot {
            if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { return $null }
            return [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\', '/')
        }

        function Get-GrantAncestors([string]$Path) {
            $list = New-Object System.Collections.Generic.List[string]
            $full = Resolve-GrantPath $Path
            if (-not [string]::IsNullOrEmpty($full)) {
                $current = [IO.Path]::GetDirectoryName($full)
                while (-not [string]::IsNullOrEmpty($current)) {
                    $root = [IO.Path]::GetPathRoot($current)
                    if ([string]::IsNullOrEmpty($root)) { break }
                    if ([string]::Equals($current.TrimEnd('\', '/'), $root.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) { break }
                    $list.Add((Resolve-GrantPath $current))
                    $next = [IO.Path]::GetDirectoryName($current)
                    if ([string]::IsNullOrEmpty($next) -or [string]::Equals($next, $current, [StringComparison]::OrdinalIgnoreCase)) { break }
                    $current = $next
                }
            }
            foreach ($item in $list) { $item }
        }

        function Get-ProfileGrantChain([string]$EntryPath, [string]$ProfileRoot) {
            $up = New-Object System.Collections.Generic.List[string]
            $current = [IO.Path]::GetDirectoryName($EntryPath)
            while (-not [string]::IsNullOrEmpty($current)) {
                $norm = Resolve-GrantPath $current
                if (-not (Test-GrantUnder $norm $ProfileRoot)) { break }
                $up.Add($norm)
                if ([string]::Equals($norm, $ProfileRoot, [StringComparison]::OrdinalIgnoreCase)) { break }
                $next = [IO.Path]::GetDirectoryName($current)
                if ([string]::IsNullOrEmpty($next) -or [string]::Equals($next, $current, [StringComparison]::OrdinalIgnoreCase)) { break }
                $current = $next
            }
            for ($i = $up.Count - 1; $i -ge 0; $i--) { $up[$i] }
        }

        function Add-ExpectedGrant($Rows, $Seen, [string]$Path, [string]$Spec) {
            $full = Resolve-GrantPath $Path
            if ([string]::IsNullOrEmpty($full)) { return }
            if ($Seen.Add($full + '|' + $Spec)) {
                $Rows.Add([pscustomobject]@{ path = $full; spec = $Spec })
            }
        }

        function New-ExpectedGrantRows {
            param(
                [string]$Repo,
                [string]$Worktree,
                [string]$WtName,
                [string]$RuntimeRoot,
                [string]$RuntimeVersion,
                $ReadList,
                [switch]$ReadOnly
            )
            $rows = New-Object System.Collections.Generic.List[object]
            $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            $worktreeSpec = if ($ReadOnly) { '(OI)(CI)RX' } else { '(OI)(CI)M' }
            $worktreeFull = Resolve-GrantPath $Worktree
            Add-ExpectedGrant $rows $seen $worktreeFull $worktreeSpec
            Add-ExpectedGrant $rows $seen (Join-Path $worktreeFull '.xagent\sandbox') '(OI)(CI)M'

            $gitDir = Resolve-GrantPath (Join-Path (Resolve-GrantPath $Repo) '.git')
            Add-ExpectedGrant $rows $seen $gitDir 'RX'
            if (Test-Path -LiteralPath $gitDir -PathType Container) {
                $sorted = New-Object System.Collections.Generic.List[System.IO.FileSystemInfo]
                foreach ($child in @(Get-ChildItem -LiteralPath $gitDir -Force)) { $sorted.Add($child) }
                if ($sorted.Count -gt 1) {
                    $sorted.Sort([System.Comparison[System.IO.FileSystemInfo]]{
                        param($Left, $Right)
                        [StringComparer]::OrdinalIgnoreCase.Compare($Left.Name, $Right.Name)
                    })
                }
                foreach ($child in $sorted) {
                    if ([string]::Equals($child.Name, 'worktrees', [StringComparison]::OrdinalIgnoreCase)) { continue }
                    $childSpec = if ($child.PSIsContainer) { '(OI)(CI)RX' } else { 'RX' }
                    Add-ExpectedGrant $rows $seen $child.FullName $childSpec
                }
            }
            Add-ExpectedGrant $rows $seen (Join-Path $gitDir 'worktrees') 'RA'
            Add-ExpectedGrant $rows $seen (Join-Path $gitDir "worktrees\$WtName") '(OI)(CI)M'
            foreach ($ancestor in @(Get-GrantAncestors $worktreeFull)) { Add-ExpectedGrant $rows $seen $ancestor 'RA' }
            foreach ($ancestor in @(Get-GrantAncestors $gitDir)) { Add-ExpectedGrant $rows $seen $ancestor 'RA' }

            $runtime = Resolve-GrantPath $RuntimeRoot
            $versionDir = Join-Path $runtime $RuntimeVersion
            Add-ExpectedGrant $rows $seen $runtime 'RA'
            Add-ExpectedGrant $rows $seen $versionDir '(OI)(CI)RX'
            Add-ExpectedGrant $rows $seen (Join-Path $versionDir '.running') '(OI)(CI)M'

            if ($null -ne $ReadList) {
                $profile = Get-GrantProfileRoot
                foreach ($entry in @($ReadList)) {
                    if ($null -eq $entry) { continue }
                    $raw = $entry.path
                    if ($null -eq $raw) { $raw = '' }
                    $entryPath = Resolve-GrantPath ([string]$raw)
                    Add-ExpectedGrant $rows $seen $entryPath '(OI)(CI)RX'
                    if ($profile -and (Test-GrantUnder $entryPath $profile)) {
                        foreach ($ancestor in @(Get-ProfileGrantChain $entryPath $profile)) {
                            Add-ExpectedGrant $rows $seen $ancestor 'RA'
                        }
                    }
                }
            }
            return ,$rows.ToArray()
        }

        function Format-GrantRows($Rows) {
            foreach ($row in @($Rows)) { '{0} | {1}' -f $row.path, $row.spec }
        }
    }

    AfterAll {
        $env:XAGENT_SANDBOX_ROOT = Join-Path $TestDrive 'root'
        $env:XAGENT_CURSOR_ROOT = Join-Path $TestDrive 'cursor'
        Import-Module $script:ModulePath -Force
    }

    It 'lists every worker grant and changes only the worktree spec for a read-only run' {
        $under = InModuleScope Sandbox -Parameters @{ Path = [string]$TestDrive } {
            param($Path)
            $profile = Get-SandboxProfileRoot
            if (-not $profile) { return $false }
            Test-SandboxPathUnder (Resolve-SandboxPath $Path) $profile
        }
        if (-not $under) { Set-ItResult -Skipped -Because 'TestDrive not under the user profile'; return }

        $packed = InModuleScope Sandbox -Parameters @{
            Repo = $script:GrantRepo
            Worktree = $script:GrantWorktree
            WtName = $script:GrantWtName
            RuntimeRoot = $script:GrantRuntime
            RuntimeVersion = $script:GrantVersion
            ReadEntry = $script:GrantReadEntry
        } {
            param($Repo, $Worktree, $WtName, $RuntimeRoot, $RuntimeVersion, $ReadEntry)
            $read = Test-SandboxReadList -Entries @([pscustomobject]@{ path = $ReadEntry })
            $worker = Get-SandboxGrantList -Repo $Repo -Worktree $Worktree -WtName $WtName -RuntimeRoot $RuntimeRoot -RuntimeVersion $RuntimeVersion -ReadList $read
            $readOnly = Get-SandboxGrantList -Repo $Repo -Worktree $Worktree -WtName $WtName -RuntimeRoot $RuntimeRoot -RuntimeVersion $RuntimeVersion -ReadList $read -ReadOnly
            [pscustomobject]@{ Read = $read; Worker = $worker; ReadOnly = $readOnly }
        }
        $readEntries = @($packed.Read)
        $workerRows = @($packed.Worker)
        $readOnlyRows = @($packed.ReadOnly)
        $expected = New-ExpectedGrantRows -Repo $script:GrantRepo -Worktree $script:GrantWorktree -WtName $script:GrantWtName -RuntimeRoot $script:GrantRuntime -RuntimeVersion $script:GrantVersion -ReadList $readEntries
        $expectedReadOnly = New-ExpectedGrantRows -Repo $script:GrantRepo -Worktree $script:GrantWorktree -WtName $script:GrantWtName -RuntimeRoot $script:GrantRuntime -RuntimeVersion $script:GrantVersion -ReadList $readEntries -ReadOnly
        @(Format-GrantRows $workerRows) | Should -Be @(Format-GrantRows $expected)
        @(Format-GrantRows $readOnlyRows) | Should -Be @(Format-GrantRows $expectedReadOnly)

        $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($row in $workerRows) {
            $keys.Add($row.path + '|' + $row.spec) | Should -BeTrue -Because "$($row.path) $($row.spec)"
        }

        $worktreePath = Resolve-GrantPath $script:GrantWorktree
        $changed = 0
        $workerRows.Count | Should -Be $readOnlyRows.Count
        for ($i = 0; $i -lt $workerRows.Count; $i++) {
            $readOnlyRows[$i].path | Should -Be $workerRows[$i].path
            if ([string]::Equals($workerRows[$i].path, $worktreePath, [StringComparison]::OrdinalIgnoreCase)) {
                $workerRows[$i].spec | Should -Be '(OI)(CI)M'
                $readOnlyRows[$i].spec | Should -Be '(OI)(CI)RX'
                $changed++
            } else {
                $readOnlyRows[$i].spec | Should -Be $workerRows[$i].spec
            }
        }
        $changed | Should -Be 1

        $gitDir = Resolve-GrantPath (Join-Path $script:GrantRepo '.git')
        foreach ($child in @(Get-ChildItem -LiteralPath $gitDir -Force)) {
            if ([string]::Equals($child.Name, 'worktrees', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $childPath = Resolve-GrantPath $child.FullName
            $spec = if ($child.PSIsContainer) { '(OI)(CI)RX' } else { 'RX' }
            $hits = @($workerRows | Where-Object { [string]::Equals($_.path, $childPath, [StringComparison]::OrdinalIgnoreCase) -and $_.spec -eq $spec })
            $hits.Count | Should -Be 1 -Because $child.Name
        }
        $wtb = Resolve-GrantPath (Join-Path $gitDir 'worktrees\wt-b')
        @($workerRows | Where-Object { [string]::Equals($_.path, $wtb, [StringComparison]::OrdinalIgnoreCase) -or $_.path.StartsWith($wtb + '\', [StringComparison]::OrdinalIgnoreCase) }).Count | Should -Be 0
        $wta = Resolve-GrantPath (Join-Path $gitDir 'worktrees\wt-a')
        $wta | Should -Be (Resolve-GrantPath (Join-Path $script:GrantRepo '.git\worktrees\wt-a'))
        $wtaHits = @($workerRows | Where-Object { [string]::Equals($_.path, $wta, [StringComparison]::OrdinalIgnoreCase) })
        $wtaHits.Count | Should -Be 1
        $wtaHits[0].spec | Should -Be '(OI)(CI)M'

        $ancestorPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($ancestor in @(Get-GrantAncestors $worktreePath)) { [void]$ancestorPaths.Add($ancestor) }
        foreach ($ancestor in @(Get-GrantAncestors $gitDir)) { [void]$ancestorPaths.Add($ancestor) }
        foreach ($ancestor in $ancestorPaths) {
            $hits = @($workerRows | Where-Object { $_.spec -eq 'RA' -and [string]::Equals($_.path, $ancestor, [StringComparison]::OrdinalIgnoreCase) })
            $hits.Count | Should -Be 1 -Because $ancestor
        }
        $drive = [IO.Path]::GetPathRoot($worktreePath)
        $workerRows.path | Should -Not -Contain $drive.TrimEnd('\', '/')
        $workerRows.path | Should -Not -Contain $drive

        $profile = Get-GrantProfileRoot
        $entryPath = Resolve-GrantPath ([string]$readEntries[0].path)
        $chain = @(Get-ProfileGrantChain $entryPath $profile)
        $chain.Count | Should -BeGreaterThan 0
        $chain[0] | Should -Be $profile
        foreach ($ancestor in $chain) {
            $hits = @($workerRows | Where-Object { $_.spec -eq 'RA' -and [string]::Equals($_.path, $ancestor, [StringComparison]::OrdinalIgnoreCase) })
            $hits.Count | Should -Be 1 -Because "read-list ancestor $ancestor"
        }
        $entryHits = @($workerRows | Where-Object { $_.spec -eq '(OI)(CI)RX' -and [string]::Equals($_.path, $entryPath, [StringComparison]::OrdinalIgnoreCase) })
        $entryHits.Count | Should -Be 1
    }

    It 'rejects a worktree name that is not a leaf' {
        foreach ($name in @('', '.', '..', 'a\b', 'a/b')) {
            $message = InModuleScope Sandbox -Parameters @{ Name = $name } {
                param($Name)
                try {
                    Get-SandboxGrantList -Repo 'D:\repo' -Worktree 'D:\wt' -WtName $Name -RuntimeRoot 'D:\rt' -RuntimeVersion 'v' -ReadList $null | Out-Null
                    return $null
                } catch {
                    return $_.Exception.Message
                }
            }
            $message | Should -Be "sandbox: invalid worktree name '$name'"
        }
    }

    It 'treats a null or empty read list alike and grants an empty .git' {
        $bare = InModuleScope Sandbox -Parameters @{
            Repo = $script:GrantRepo
            Worktree = $script:GrantWorktree
            WtName = $script:GrantWtName
            RuntimeRoot = $script:GrantRuntime
            RuntimeVersion = $script:GrantVersion
        } {
            param($Repo, $Worktree, $WtName, $RuntimeRoot, $RuntimeVersion)
            $fromNull = Get-SandboxGrantList -Repo $Repo -Worktree $Worktree -WtName $WtName -RuntimeRoot $RuntimeRoot -RuntimeVersion $RuntimeVersion -ReadList $null
            $fromEmpty = Get-SandboxGrantList -Repo $Repo -Worktree $Worktree -WtName $WtName -RuntimeRoot $RuntimeRoot -RuntimeVersion $RuntimeVersion -ReadList @()
            [pscustomobject]@{ FromNull = $fromNull; FromEmpty = $fromEmpty }
        }
        $expected = New-ExpectedGrantRows -Repo $script:GrantRepo -Worktree $script:GrantWorktree -WtName $script:GrantWtName -RuntimeRoot $script:GrantRuntime -RuntimeVersion $script:GrantVersion -ReadList $null
        @(Format-GrantRows $bare.FromNull) | Should -Be @(Format-GrantRows $expected)
        @(Format-GrantRows $bare.FromEmpty) | Should -Be @(Format-GrantRows $expected)
        $readPath = Resolve-GrantPath $script:GrantReadEntry
        @($bare.FromNull).path | Should -Not -Contain $readPath
        @($bare.FromEmpty).path | Should -Not -Contain $readPath

        $parent = Join-Path $TestDrive 'empty-git-parent'
        $repo = Join-Path $parent 'emptyrepo'
        $worktree = Join-Path $parent 'emptyrepo.xagent\task-1'
        $runtime = Join-Path $TestDrive 'empty-runtime'
        New-Item -ItemType Directory -Force -Path (Join-Path $repo '.git'), $worktree, (Join-Path $runtime 'ver') | Out-Null
        $got = InModuleScope Sandbox -Parameters @{
            Repo = $repo
            Worktree = $worktree
            RuntimeRoot = $runtime
        } {
            param($Repo, $Worktree, $RuntimeRoot)
            Get-SandboxGrantList -Repo $Repo -Worktree $Worktree -WtName 'wt-a' -RuntimeRoot $RuntimeRoot -RuntimeVersion 'ver' -ReadList @()
        }
        $expectedEmpty = New-ExpectedGrantRows -Repo $repo -Worktree $worktree -WtName 'wt-a' -RuntimeRoot $runtime -RuntimeVersion 'ver' -ReadList @()
        @(Format-GrantRows $got) | Should -Be @(Format-GrantRows $expectedEmpty)
        $gitDir = Resolve-GrantPath (Join-Path $repo '.git')
        $under = @($got | Where-Object { $_.path.StartsWith($gitDir + '\', [StringComparison]::OrdinalIgnoreCase) })
        @(Format-GrantRows $under) | Should -Be @(
            ((Resolve-GrantPath (Join-Path $gitDir 'worktrees')) + ' | RA')
            ((Resolve-GrantPath (Join-Path $gitDir 'worktrees\wt-a')) + ' | (OI)(CI)M')
        )
        @($got | Where-Object { [string]::Equals($_.path, $gitDir, [StringComparison]::OrdinalIgnoreCase) }).spec | Should -Be 'RX'
    }

    It 'round-trips the slot ledger for liveness and runtime version' {
        $sandboxDir = Join-Path $script:GrantRoot 'sandbox'
        if (Test-Path -LiteralPath $sandboxDir) { Remove-Item -LiteralPath $sandboxDir -Recurse -Force }
        $ledgerPath = Join-Path $sandboxDir 'slot-S.json'
        $packed = InModuleScope Sandbox -Parameters @{
            Path = $ledgerPath
            Worktree = $script:GrantWorktree
            Version = $script:GrantVersion
        } {
            param($Path, $Worktree, $Version)
            $parent = Split-Path -Parent $Path
            $parentExisted = Test-Path -LiteralPath $parent
            $start = (Get-Process -Id $PID).StartTime
            $one = [ordered]@{
                slot = 'S'
                sid = 'S-1-15-2-1'
                pid = $PID
                startTime = $start
                runtimeVersion = $Version
                worktree = $Worktree
                grants = @([pscustomobject]@{ path = 'D:\one'; spec = 'RX' })
                note = 'kept'
            }
            Write-SandboxLedger -Path $Path -Ledger $one
            $read = Read-SandboxLedger -Path $Path
            $text = [IO.File]::ReadAllText($Path)
            $bytes = [IO.File]::ReadAllBytes($Path)
            $none = [pscustomobject]@{
                slot = 'S'
                sid = 'S-1-15-2-1'
                pid = $PID
                startTime = $start
                runtimeVersion = $Version
                worktree = $Worktree
                grants = @()
                extra = 'object'
            }
            $none.PSObject.Properties['grants'].Value = New-Object object[] 0
            $nonePath = Join-Path $parent 'slot-T.json'
            Write-SandboxLedger -Path $nonePath -Ledger $none
            $readNone = Read-SandboxLedger -Path $nonePath
            [pscustomobject]@{
                ParentExisted = $parentExisted
                Stamp = $start.ToUniversalTime().ToString('o')
                Read = $read
                None = $readNone
                Text = $text
                Bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
                Live = (Test-LedgerProcessLive -LedgerPath $Path)
                Versions = (Get-LedgerRuntimeVersions -SandboxDir $parent)
            }
        }
        $packed.ParentExisted | Should -BeFalse
        $packed.Bom | Should -BeFalse
        $packed.Text.EndsWith("`n") | Should -BeTrue
        $packed.Text | Should -Match ([regex]::Escape($packed.Stamp))
        $packed.Read.slot | Should -Be 'S'
        $packed.Read.sid | Should -Be 'S-1-15-2-1'
        $packed.Read.pid | Should -Be $PID
        $packed.Read.runtimeVersion | Should -Be $script:GrantVersion
        $packed.Read.worktree | Should -Be $script:GrantWorktree
        $packed.Read.note | Should -Be 'kept'
        $packed.Read.grants -is [System.Array] | Should -BeTrue
        @($packed.Read.grants).Count | Should -Be 1
        $packed.Read.grants[0].path | Should -Be 'D:\one'
        $packed.Read.grants[0].spec | Should -Be 'RX'
        $gotStamp = if ($packed.Read.startTime -is [datetime]) {
            $packed.Read.startTime.ToUniversalTime().ToString('o')
        } else {
            ([datetime][string]$packed.Read.startTime).ToUniversalTime().ToString('o')
        }
        $gotStamp | Should -Be $packed.Stamp
        $packed.None.grants -is [System.Array] | Should -BeTrue
        @($packed.None.grants).Count | Should -Be 0
        $packed.None.extra | Should -Be 'object'
        $packed.Live | Should -BeTrue
        @($packed.Versions) | Should -Contain $script:GrantVersion
    }

    It 'names the first missing ledger field and does not write the file' {
        $path = Join-Path $TestDrive 'missing-field\slot-S.json'
        $message = InModuleScope Sandbox -Parameters @{ Path = $path } {
            param($Path)
            $ledger = @{
                sid = 'S-1-15-2-1'
                pid = 1
                startTime = [datetime]::UtcNow
                runtimeVersion = 'v'
                worktree = 'D:\wt'
            }
            try {
                Write-SandboxLedger -Path $Path -Ledger $ledger
                return $null
            } catch {
                return $_.Exception.Message
            }
        }
        $message | Should -Be "sandbox: ledger is missing field 'slot'"
        Test-Path -LiteralPath $path | Should -BeFalse

        $later = Join-Path $TestDrive 'missing-later\slot-S.json'
        $laterMessage = InModuleScope Sandbox -Parameters @{ Path = $later } {
            param($Path)
            $ledger = @{
                slot = 'S'
                sid = 'S-1-15-2-1'
                pid = 1
                worktree = 'D:\wt'
                grants = @()
            }
            try {
                Write-SandboxLedger -Path $Path -Ledger $ledger
                return $null
            } catch {
                return $_.Exception.Message
            }
        }
        $laterMessage | Should -Be "sandbox: ledger is missing field 'startTime'"
        Test-Path -LiteralPath $later | Should -BeFalse
    }

    It 'returns null for a missing or broken ledger and forces grants to an array' {
        $missing = InModuleScope Sandbox -Parameters @{ Path = (Join-Path $TestDrive 'no-such-ledger.json') } {
            param($Path)
            Read-SandboxLedger -Path $Path
        }
        $missing | Should -BeNullOrEmpty
        $brokenPath = Join-Path $TestDrive 'broken-ledger.json'
        [IO.File]::WriteAllText($brokenPath, '{')
        $broken = InModuleScope Sandbox -Parameters @{ Path = $brokenPath } {
            param($Path)
            Read-SandboxLedger -Path $Path
        }
        $broken | Should -BeNullOrEmpty

        $singlePath = Join-Path $TestDrive 'single-grant.json'
        $singleJson = @"
{
  "slot": "S",
  "sid": "S-1-5-18",
  "pid": 4,
  "startTime": "2026-01-02T03:04:05.0000000Z",
  "runtimeVersion": "v",
  "worktree": "D:\\wt",
  "note": "solo",
  "grants": { "path": "D:\\a", "spec": "RX" }
}
"@
        [IO.File]::WriteAllText($singlePath, $singleJson, [Text.UTF8Encoding]::new($false))
        $absentPath = Join-Path $TestDrive 'absent-grants.json'
        [IO.File]::WriteAllText($absentPath, '{"slot":"S","sid":"S-1-5-18","pid":4,"startTime":"2026-01-02T03:04:05.0000000Z","runtimeVersion":"v","worktree":"D:\\wt"}', [Text.UTF8Encoding]::new($false))
        $nullPath = Join-Path $TestDrive 'null-grants.json'
        [IO.File]::WriteAllText($nullPath, '{"slot":"S","sid":"S-1-5-18","pid":4,"startTime":"2026-01-02T03:04:05.0000000Z","runtimeVersion":"v","worktree":"D:\\wt","grants":null}', [Text.UTF8Encoding]::new($false))
        $parsed = InModuleScope Sandbox -Parameters @{ Single = $singlePath; Absent = $absentPath; NullGrants = $nullPath } {
            param($Single, $Absent, $NullGrants)
            [pscustomobject]@{
                Single = Read-SandboxLedger -Path $Single
                Absent = Read-SandboxLedger -Path $Absent
                NullGrants = Read-SandboxLedger -Path $NullGrants
            }
        }
        $parsed.Single.grants -is [System.Array] | Should -BeTrue
        @($parsed.Single.grants).Count | Should -Be 1
        $parsed.Single.grants[0].path | Should -Be 'D:\a'
        $parsed.Single.grants[0].spec | Should -Be 'RX'
        $parsed.Single.note | Should -Be 'solo'
        $parsed.Single.slot | Should -Be 'S'
        $parsed.Absent.grants -is [System.Array] | Should -BeTrue
        @($parsed.Absent.grants).Count | Should -Be 0
        $parsed.Absent.worktree | Should -Be 'D:\wt'
        $parsed.NullGrants.grants -is [System.Array] | Should -BeTrue
        @($parsed.NullGrants.grants).Count | Should -Be 0
    }

    It 'returns no failures when there is nothing to remove' {
        $packed = InModuleScope Sandbox {
            $thrown = $null
            try {
                Remove-SandboxGrants -Ledger ([pscustomobject]@{
                    sid = ''
                    grants = @([pscustomobject]@{ path = 'D:\a'; spec = 'R' })
                }) | Out-Null
            } catch {
                $thrown = $_.Exception.Message
            }
            $nullResult = Remove-SandboxGrants -Ledger $null
            $empty = Remove-SandboxGrants -Ledger ([pscustomobject]@{ sid = ''; grants = @() })
            $missing = Remove-SandboxGrants -Ledger ([pscustomobject]@{ sid = 'S-1-5-18' })
            [pscustomobject]@{
                NullCount = $(if ($null -eq $nullResult) { -1 } else { @($nullResult).Count })
                EmptyCount = $(if ($null -eq $empty) { -1 } else { @($empty).Count })
                MissingCount = $(if ($null -eq $missing) { -1 } else { @($missing).Count })
                Thrown = $thrown
            }
        }
        $packed.NullCount | Should -Be 0
        $packed.EmptyCount | Should -Be 0
        $packed.MissingCount | Should -Be 0
        $packed.Thrown | Should -Be 'sandbox: ledger has no sid'
    }

    It 'waits while another process holds the ACL lock before removing grants' {
        if ([XagentSandbox]::IsAppContainer()) { Set-ItResult -Skipped -Because 'an AppContainer cannot change file permissions'; return }
        $file = Join-Path $TestDrive 'acl-lock.txt'
        Set-Content -LiteralPath $file -Value 'x' -Encoding ascii
        $grantOut = @(& icacls.exe $file /grant '*S-1-15-2-1:(R)' 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "icacls grant failed ($LASTEXITCODE): $grantOut" }
        $holder = Join-Path $TestDrive 'acl-hold.ps1'
        $ready = Join-Path $TestDrive 'acl-hold.ready'
        Set-Content -LiteralPath $holder -Encoding utf8 -Value @(
            '$m = [Threading.Mutex]::new($false, ''Local\xagent-acl'')'
            '$null = $m.WaitOne()'
            ('Set-Content -LiteralPath ''{0}'' -Value x' -f $ready)
            'Start-Sleep -Seconds 3'
            '$m.ReleaseMutex()'
        )
        $p = Start-Process pwsh -ArgumentList '-NoProfile', '-File', $holder -WindowStyle Hidden -PassThru
        try {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $ready) -and $clock.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 100 }
            Test-Path -LiteralPath $ready | Should -BeTrue
            $clock.Restart()
            $failed = Remove-SandboxGrants -Ledger ([pscustomobject]@{ sid = 'S-1-15-2-1'; grants = @([pscustomobject]@{ path = $file; spec = '(R)' }) })
            $clock.Elapsed.TotalSeconds | Should -BeGreaterThan 1.5
            @($failed).Count | Should -Be 0
        } finally {
            $p | Wait-Process -Timeout 30 -ErrorAction SilentlyContinue
        }
    }

    It 'returns the one grant icacls cannot remove' {
        if ([XagentSandbox]::IsAppContainer()) { Set-ItResult -Skipped -Because 'an AppContainer cannot change file permissions'; return }
        $folder = Join-Path $TestDrive 'grant-remove'
        $file1 = Join-Path $folder 'file1.txt'
        $file2 = Join-Path $folder 'file2.txt'
        $file3 = Join-Path $folder 'file3.txt'
        $missing = Join-Path $folder 'missing.txt'
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        try {
            foreach ($file in @($file1, $file2, $file3)) {
                Set-Content -LiteralPath $file -Value 'x' -Encoding ascii
                $grantOut = @(& icacls.exe $file /grant '*S-1-15-2-1:(R)' 2>&1)
                if ($LASTEXITCODE -ne 0) { throw "icacls grant failed ($LASTEXITCODE): $grantOut" }
            }
            $denyOut = @(& icacls.exe $file2 /deny '*S-1-3-4:(WDAC)' 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "icacls deny failed ($LASTEXITCODE): $denyOut" }

            $ledgerPath = Join-Path $script:GrantRoot 'sandbox\slot-S.json'
            $failed = InModuleScope Sandbox -Parameters @{
                Path = $ledgerPath
                File1 = $file1
                File2 = $file2
                File3 = $file3
                Missing = $missing
                Worktree = $script:GrantWorktree
                Version = $script:GrantVersion
            } {
                param($Path, $File1, $File2, $File3, $Missing, $Worktree, $Version)
                $ledger = [ordered]@{
                    slot = 'S'
                    sid = 'S-1-15-2-1'
                    pid = $PID
                    startTime = (Get-Process -Id $PID).StartTime
                    runtimeVersion = $Version
                    worktree = $Worktree
                    grants = @(
                        [pscustomobject]@{ path = $File1; spec = 'R' }
                        [pscustomobject]@{ path = $File2; spec = 'R' }
                        [pscustomobject]@{ path = $Missing; spec = 'R' }
                        [pscustomobject]@{ path = $File3; spec = 'R' }
                    )
                }
                Write-SandboxLedger -Path $Path -Ledger $ledger
                $read = Read-SandboxLedger -Path $Path
                Remove-SandboxGrants -Ledger $read
            }
            $failedRows = @($failed)
            $failedRows.Count | Should -Be 1
            $failedRows[0].path | Should -Be $file2
            $failedRows[0].spec | Should -Be 'R'
            $failedRows[0].error | Should -Not -BeNullOrEmpty
            $failedRows[0].error | Should -Not -Be '<no output>'
            $failedRows[0].error | Should -Match 'Access is denied'
            @($failedRows.path) | Should -Not -Contain $missing
            @($failedRows.path) | Should -Not -Contain $file1
            @($failedRows.path) | Should -Not -Contain $file3
            foreach ($file in @($file1, $file3)) {
                $listed = (@(& icacls.exe $file 2>&1) | ForEach-Object { "$_" }) -join "`n"
                $listed | Should -Not -Match 'S-1-15-2-1'
                $listed | Should -Not -Match 'ALL APPLICATION PACKAGES'
            }
        } finally {
            if (Test-Path -LiteralPath $folder) {
                Remove-Item -LiteralPath $folder -Recurse -Force
            }
        }
    }
}

Describe 'slots and release' {
    BeforeDiscovery {
        $script:SlotContainerSkip = $false
        $script:SlotContainerReason = ''
        $nativePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../scripts/SandboxNative.cs'))
        if (-not ('XagentSandbox' -as [type])) {
            Add-Type -Path $nativePath
        }
        if ([XagentSandbox]::IsAppContainer()) {
            $script:SlotContainerSkip = $true
            $script:SlotContainerReason = 'already inside an AppContainer'
        } elseif ([Environment]::OSVersion.Version.Build -lt 26300) {
            $script:SlotContainerSkip = $true
            $script:SlotContainerReason = 'Windows build is older than 26300'
        } else {
            $subst = @{}
            foreach ($line in @(& subst.exe 2>&1)) {
                if ([string]$line -match '^([A-Za-z]):\\: => ') {
                    $subst[$Matches[1].ToUpperInvariant()] = $true
                }
            }
            $drives = @{}
            foreach ($drive in [IO.DriveInfo]::GetDrives()) {
                if ($drive.Name) { $drives[$drive.Name.Substring(0, 1).ToUpperInvariant()] = $true }
            }
            $free = 0
            foreach ($code in 68..90) {
                $letter = [string][char]$code
                if ($subst.ContainsKey($letter) -or $drives.ContainsKey($letter)) { continue }
                $free++
            }
            if ($free -lt 3) {
                $script:SlotContainerSkip = $true
                $script:SlotContainerReason = 'fewer than three free letters D-Z'
            }
        }
    }

    BeforeAll {
        $script:SlotRoot = Join-Path $TestDrive 'slot-root'
        $script:SlotCursor = Join-Path $TestDrive 'slot-cursor'
        $env:XAGENT_SANDBOX_ROOT = $script:SlotRoot
        $env:XAGENT_CURSOR_ROOT = $script:SlotCursor
        New-Item -ItemType Directory -Force -Path $script:SlotRoot, $script:SlotCursor | Out-Null
        Import-Module $script:ModulePath -Force
        $script:SlotChildren = New-Object System.Collections.Generic.List[System.Diagnostics.Process]
        $script:SlotRuntime = $null
        $script:SlotOne = $null
        $script:SlotTwo = $null

        function Test-AppContainerMapped([string]$Sid) {
            $key = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppContainer\Mappings\$Sid"
            return (Test-Path -LiteralPath $key)
        }

        function Start-SlotChild {
            param(
                [string[]]$MutexNames = @(),
                [string]$LedgerPath = '',
                [string]$Sid = '',
                [string]$GrantPath = '',
                [Parameter(Mandatory)][string]$ReadyFile
            )
            $argList = New-Object System.Collections.Generic.List[string]
            [void]$argList.Add('-NoProfile')
            [void]$argList.Add('-ExecutionPolicy')
            [void]$argList.Add('Bypass')
            [void]$argList.Add('-File')
            [void]$argList.Add($script:SlotChildScript)
            # pwsh -File binds only one argument to a [string[]], so names travel as one comma-separated value.
            if (@($MutexNames).Count -gt 0) {
                [void]$argList.Add('-MutexNames')
                [void]$argList.Add((@($MutexNames) -join ','))
            }
            if (-not [string]::IsNullOrWhiteSpace($LedgerPath)) {
                [void]$argList.Add('-LedgerPath')
                [void]$argList.Add($LedgerPath)
            }
            if (-not [string]::IsNullOrWhiteSpace($Sid)) {
                [void]$argList.Add('-Sid')
                [void]$argList.Add($Sid)
            }
            if (-not [string]::IsNullOrWhiteSpace($GrantPath)) {
                [void]$argList.Add('-GrantPath')
                [void]$argList.Add($GrantPath)
            }
            [void]$argList.Add('-ReadyFile')
            [void]$argList.Add($ReadyFile)
            $pwsh = (Get-Process -Id $PID).Path
            $proc = Start-Process -FilePath $pwsh -ArgumentList $argList.ToArray() -PassThru -WindowStyle Hidden -RedirectStandardOutput "$ReadyFile.out" -RedirectStandardError "$ReadyFile.err"
            [void]$script:SlotChildren.Add($proc)
            return $proc
        }

        function Wait-SlotReady($Process, [string]$ReadyFile) {
            $deadline = [datetime]::UtcNow.AddSeconds(15)
            while (-not (Test-Path -LiteralPath $ReadyFile)) {
                if ($Process.HasExited) { break }
                if ([datetime]::UtcNow -ge $deadline) { break }
                Start-Sleep -Milliseconds 50
            }
            if (Test-Path -LiteralPath $ReadyFile) { return }
            $err = ''
            $errPath = "$ReadyFile.err"
            if (Test-Path -LiteralPath $errPath) { $err = [IO.File]::ReadAllText($errPath) }
            $code = if ($Process.HasExited) { [string]$Process.ExitCode } else { 'still-running' }
            throw "slot child was not ready within 15s (exit $code). $err"
        }

        function Stop-SlotChild($Process) {
            if ($null -eq $Process) { return }
            try {
                if (-not $Process.HasExited) { $Process.Kill() }
            } catch { }
            try { $null = $Process.WaitForExit(10000) } catch { }
            try { $Process.Refresh() } catch { }
        }

        function Release-TestSlot($Slot) {
            if ($null -eq $Slot) { return }
            $mutex = $Slot.mutex
            if ($null -eq $mutex) { return }
            try { $mutex.ReleaseMutex() } catch { }
            $mutex.Dispose()
        }
    }

    AfterAll {
        $env:XAGENT_SANDBOX_ROOT = Join-Path $TestDrive 'root'
        $env:XAGENT_CURSOR_ROOT = Join-Path $TestDrive 'cursor'
        Import-Module $script:ModulePath -Force
    }

    It 'parses LoopbackExempt text and keeps only the requested slot SID' {
        $fixture = Join-Path $PSScriptRoot 'fixtures/loopback-exempt.txt'
        $text = [IO.File]::ReadAllText($fixture)
        $rows = @(InModuleScope Sandbox -Parameters @{ Text = $text } {
            param($Text)
            Get-SandboxLoopbackExemptions -Text $Text -Sids @('S-1-15-2-1111')
        })
        $rows.Count | Should -Be 1
        $rows[0].sid | Should -Be 'S-1-15-2-1111'
        $rows[0].command | Should -Be 'CheckNetIsolation LoopbackExempt -d -p=S-1-15-2-1111'
        @($rows.sid) | Should -Not -Contain 'S-1-15-2-2222'
    }

    It 'Remove-SandboxLetters does nothing when no letters are reserved' {
        $result = Remove-SandboxLetters
        $result.released -is [System.Array] | Should -BeTrue
        $result.exemptions -is [System.Array] | Should -BeTrue
        $result.leftoverGrants -is [System.Array] | Should -BeTrue
        @($result.released).Count | Should -Be 0
        @($result.exemptions).Count | Should -Be 0
        @($result.leftoverGrants).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox.json') | Should -BeFalse
    }

    It 'Get-SandboxSlot throws the same unreserved-letters message and maps nothing' {
        $expected = InModuleScope Sandbox { Get-NoLettersReservedMessage }
        $fromSlot = Get-ThrownMessage { Get-SandboxSlot -TimeoutSec 0 }
        $fromInit = Get-ThrownMessage { Initialize-SandboxLetters }
        $fromSlot | Should -Be $expected
        $fromInit | Should -Be $expected
        Test-Path -LiteralPath (Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox') | Should -BeFalse
    }

    It 'rejects a letters object that is not one runtime letter and two slots' {
        $path = Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox.json'
        [IO.File]::WriteAllText($path, '{"letters":{"runtime":"Z","slots":["Y"]},"read":[]}')
        try {
            Get-ThrownMessage { Get-SandboxSlot -TimeoutSec 0 } | Should -Be 'sandbox: sandbox.json letters must be a runtime letter and two slots'
            Get-ThrownMessage { Remove-SandboxLetters } | Should -Be 'sandbox: sandbox.json letters must be a runtime letter and two slots'
            Test-Path -LiteralPath (Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox') | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports an unreadable sandbox.json from Get-SandboxConfig' {
        $path = Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox.json'
        [IO.File]::WriteAllText($path, '{')
        try {
            $slotMessage = Get-ThrownMessage { Get-SandboxSlot -TimeoutSec 0 }
            $releaseMessage = Get-ThrownMessage { Remove-SandboxLetters }
            $slotMessage | Should -Match '^sandbox: cannot read sandbox.json \('
            $releaseMessage | Should -Be $slotMessage
        } finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    Context $(if ($script:SlotContainerSkip) { "reserved letters ($script:SlotContainerReason)" } else { 'reserved letters' }) -Skip:$script:SlotContainerSkip {
        BeforeAll {
            $free = @(Get-TestFreeLetters)
            if ($free.Count -lt 3) { throw 'sandbox: fewer than three free letters D-Z at reservation time' }
            $script:SlotRuntime = [string]$free[0]
            $script:SlotOne = [string]$free[1]
            $script:SlotTwo = [string]$free[2]
            Set-SandboxLetters -Letters @($script:SlotRuntime, $script:SlotOne, $script:SlotTwo)
            $script:SlotChildScript = Join-Path $TestDrive 'slot-child.ps1'
            $childSource = @'
param(
    [string[]]$MutexNames = @(),
    [string]$LedgerPath = '',
    [string]$Sid = '',
    [string]$GrantPath = '',
    [string]$ReadyFile = ''
)
$ErrorActionPreference = 'Stop'
$held = New-Object System.Collections.Generic.List[Threading.Mutex]
$names = New-Object System.Collections.Generic.List[string]
foreach ($item in @($MutexNames)) {
    foreach ($part in ([string]$item -split ',')) {
        if (-not [string]::IsNullOrWhiteSpace($part)) { $names.Add($part.Trim()) }
    }
}
foreach ($name in $names) {
    $mutex = [Threading.Mutex]::new($false, $name)
    $owned = $false
    try {
        $owned = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $owned = $true
    }
    if (-not $owned) {
        $mutex.Dispose()
        throw "could not take mutex $name"
    }
    $held.Add($mutex)
}
if (-not [string]::IsNullOrWhiteSpace($LedgerPath)) {
    $grantRows = @()
    if (-not [string]::IsNullOrWhiteSpace($GrantPath) -and -not [string]::IsNullOrWhiteSpace($Sid)) {
        $full = [IO.Path]::GetFullPath($GrantPath)
        $grantOutput = @(& icacls.exe $full /grant ("*${Sid}:(OI)(CI)RX") 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $text = (@($grantOutput) | ForEach-Object { "$_" }) -join ' '
            throw "icacls grant failed: $text"
        }
        $grantRows = @([pscustomobject]@{ path = $full; spec = '(OI)(CI)RX' })
    }
    if ($LedgerPath -notmatch 'slot-([A-Za-z])\.json$') { throw "unexpected ledger path $LedgerPath" }
    $slot = $Matches[1].ToUpperInvariant()
    $proc = Get-Process -Id $PID
    $worktree = if (-not [string]::IsNullOrWhiteSpace($GrantPath)) { [IO.Path]::GetFullPath($GrantPath) } else { $LedgerPath }
    $body = [ordered]@{
        slot = $slot
        sid = [string]$Sid
        pid = $PID
        startTime = $proc.StartTime.ToUniversalTime().ToString('o')
        runtimeVersion = 'test'
        worktree = $worktree
        grants = $grantRows
    }
    $parent = Split-Path -Parent $LedgerPath
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $json = ($body | ConvertTo-Json -Depth 6) + "`n"
    [IO.File]::WriteAllText($LedgerPath, $json, [Text.UTF8Encoding]::new($false))
}
if ([string]::IsNullOrWhiteSpace($ReadyFile)) { throw 'ReadyFile is required' }
$readyParent = Split-Path -Parent $ReadyFile
if (-not [string]::IsNullOrWhiteSpace($readyParent) -and -not (Test-Path -LiteralPath $readyParent)) {
    New-Item -ItemType Directory -Force -Path $readyParent | Out-Null
}
[IO.File]::WriteAllText($ReadyFile, "$PID`n", [Text.UTF8Encoding]::new($false))
while ($true) {
    Start-Sleep -Seconds 30
}
'@
            [IO.File]::WriteAllText($script:SlotChildScript, $childSource, [Text.UTF8Encoding]::new($false))
        }

        AfterAll {
            try {
                foreach ($proc in @($script:SlotChildren)) { Stop-SlotChild $proc }
            } finally {
                try { Remove-SandboxLetters | Out-Null } catch { }
                foreach ($letter in @($script:SlotRuntime, $script:SlotOne, $script:SlotTwo)) {
                    if ([string]::IsNullOrWhiteSpace([string]$letter)) { continue }
                    & subst.exe "${letter}:" '/D' 2>&1 | Out-Null
                }
                foreach ($letter in @($script:SlotOne, $script:SlotTwo)) {
                    if ([string]::IsNullOrWhiteSpace([string]$letter)) { continue }
                    try { [XagentSandbox]::DeleteProfile("xagent.slot-$letter") } catch { }
                }
            }
        }

        It 'reserves three mappings and two profiles, then release removes them' {
            $cursor = Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox\cursor'
            $idle = Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox\idle'
            $configPath = Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox.json'
            $sid1 = [XagentSandbox]::EnsureProfile("xagent.slot-$script:SlotOne")
            $sid1Again = [XagentSandbox]::EnsureProfile("xagent.slot-$script:SlotOne")
            $sid2 = [XagentSandbox]::EnsureProfile("xagent.slot-$script:SlotTwo")
            try {
                $sid1 | Should -Be $sid1Again
                (Test-AppContainerMapped $sid1) | Should -BeTrue
                (Test-AppContainerMapped $sid2) | Should -BeTrue
                Test-Path -LiteralPath (Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox') | Should -BeTrue
                $before = Get-TestSubstMap
                (Test-SameLetterTarget $before[$script:SlotRuntime] $cursor) | Should -BeTrue
                (Test-SameLetterTarget $before[$script:SlotOne] $idle) | Should -BeTrue
                (Test-SameLetterTarget $before[$script:SlotTwo] $idle) | Should -BeTrue

                InModuleScope Sandbox {
                    $cfg = Get-SandboxConfig
                    $cfg['read'] = @(@{ path = 'C:\Windows'; addToPath = $false })
                    Save-SandboxConfig $cfg
                }

                $result = Remove-SandboxLetters
                @($result.released) | Should -Be @($script:SlotRuntime, $script:SlotOne, $script:SlotTwo)
                $result.exemptions -is [System.Array] | Should -BeTrue
                $result.leftoverGrants -is [System.Array] | Should -BeTrue
                $after = Get-TestSubstMap
                $after.ContainsKey($script:SlotRuntime) | Should -BeFalse
                $after.ContainsKey($script:SlotOne) | Should -BeFalse
                $after.ContainsKey($script:SlotTwo) | Should -BeFalse
                Test-Path -LiteralPath (Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox') | Should -BeFalse
                (Test-AppContainerMapped $sid1) | Should -BeFalse
                (Test-AppContainerMapped $sid2) | Should -BeFalse
                $parsed = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
                $parsed.PSObject.Properties.Name | Should -Not -Contain 'letters'
                @($parsed.read).Count | Should -Be 1
                $parsed.read[0].path | Should -Be 'C:\Windows'
            } finally {
                Set-SandboxLetters -Letters @($script:SlotRuntime, $script:SlotOne, $script:SlotTwo)
            }
        }

        It 'refuses release while a slot mutex is held and leaves the mappings' {
            $ready = Join-Path $TestDrive 'ready-held'
            $proc = Start-SlotChild -MutexNames @("Local\xagent-slot-$script:SlotOne") -ReadyFile $ready
            try {
                Wait-SlotReady $proc $ready
                $before = Get-TestSubstMap
                $message = Get-ThrownMessage { Remove-SandboxLetters }
                $message | Should -Be 'sandbox: a slot is in use; release refused'
                $after = Get-TestSubstMap
                $cursor = Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox\cursor'
                $idle = Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox\idle'
                (Test-SameLetterTarget $after[$script:SlotRuntime] $cursor) | Should -BeTrue
                (Test-SameLetterTarget $after[$script:SlotOne] $idle) | Should -BeTrue
                (Test-SameLetterTarget $after[$script:SlotTwo] $idle) | Should -BeTrue
                (Test-SameLetterTarget $before[$script:SlotRuntime] $after[$script:SlotRuntime]) | Should -BeTrue
                Test-Path -LiteralPath (Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox') | Should -BeTrue
                $raw = [IO.File]::ReadAllText((Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox.json'))
                $raw | Should -Match '"letters"'
            } finally {
                Stop-SlotChild $proc
            }
        }

        It 'fails when both slots stay busy for the timeout' {
            $ready = Join-Path $TestDrive 'ready-busy-both'
            $proc = Start-SlotChild -MutexNames @(
                "Local\xagent-slot-$script:SlotOne"
                "Local\xagent-slot-$script:SlotTwo"
            ) -ReadyFile $ready
            $slot = $null
            try {
                Wait-SlotReady $proc $ready
                $message = $null
                $clock = [Diagnostics.Stopwatch]::StartNew()
                try {
                    $slot = Get-SandboxSlot -TimeoutSec 4
                } catch {
                    $message = $_.Exception.Message
                }
                $elapsed = $clock.Elapsed.TotalSeconds
                $message | Should -Be 'sandbox: no free slot (both slots busy)'
                $elapsed | Should -BeGreaterOrEqual 4
                $elapsed | Should -BeLessThan 7
            } finally {
                Release-TestSlot $slot
                Stop-SlotChild $proc
            }
        }

        It 'treats a ledger that names a live process as a busy slot' {
            $ready = Join-Path $TestDrive 'ready-live-ledger'
            $ledger = Join-Path $env:XAGENT_SANDBOX_ROOT "sandbox\slot-$script:SlotOne.json"
            $sid = [XagentSandbox]::EnsureProfile("xagent.slot-$script:SlotOne")
            $proc = Start-SlotChild -LedgerPath $ledger -Sid $sid -ReadyFile $ready
            $slot = $null
            try {
                Wait-SlotReady $proc $ready
                $slot = Get-SandboxSlot -TimeoutSec 5
                $slot.letter | Should -Be $script:SlotTwo
                $slot.container | Should -Be "xagent.slot-$script:SlotTwo"
                $slot.sid | Should -Be ([XagentSandbox]::EnsureProfile("xagent.slot-$script:SlotTwo"))
            } finally {
                Release-TestSlot $slot
                Stop-SlotChild $proc
                Remove-Item -LiteralPath $ledger -Force -ErrorAction SilentlyContinue
            }
        }

        It 'takes an abandoned slot and removes the dead run grants' {
            $ready = Join-Path $TestDrive 'ready-crash'
            $ledger = Join-Path $env:XAGENT_SANDBOX_ROOT "sandbox\slot-$script:SlotOne.json"
            $folder = Join-Path $TestDrive 'crash-folder'
            New-Item -ItemType Directory -Force -Path $folder | Out-Null
            $sid = [XagentSandbox]::EnsureProfile("xagent.slot-$script:SlotOne")
            $proc = Start-SlotChild -MutexNames @("Local\xagent-slot-$script:SlotOne") -LedgerPath $ledger -Sid $sid -GrantPath $folder -ReadyFile $ready
            $slot = $null
            try {
                Wait-SlotReady $proc $ready
                (Get-IcaclsText $folder) | Should -Match ([regex]::Escape($sid))
                Stop-SlotChild $proc
                $proc.HasExited | Should -BeTrue
                $slot = Get-SandboxSlot -TimeoutSec 5
                $slot.letter | Should -Be $script:SlotOne
                $slot.container | Should -Be "xagent.slot-$script:SlotOne"
                $slot.sid | Should -Be $sid
                (Get-IcaclsText $folder) | Should -Not -Match ([regex]::Escape($sid))
                Test-Path -LiteralPath $ledger | Should -BeFalse
            } finally {
                Stop-SlotChild $proc
                Release-TestSlot $slot
                if ($sid -and (Test-Path -LiteralPath $folder)) {
                    & icacls.exe $folder /remove ("*$sid") 2>&1 | Out-Null
                }
                Remove-Item -LiteralPath $ledger -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'run functions' {
    BeforeAll {
        $script:RunRoot = Join-Path $TestDrive 'run-root'
        $script:RunCursor = Join-Path $TestDrive 'run-cursor'
        $env:XAGENT_SANDBOX_ROOT = $script:RunRoot
        $env:XAGENT_CURSOR_ROOT = $script:RunCursor
        New-Item -ItemType Directory -Force -Path $script:RunRoot, $script:RunCursor | Out-Null
        Import-Module $script:ModulePath -Force

        function New-RunSlot {
            $name = 'Local\xagent-run-test-' + [guid]::NewGuid().ToString('N')
            $mutex = [Threading.Mutex]::new($false, $name)
            $owned = $false
            try {
                $owned = $mutex.WaitOne(0)
            } catch [System.Threading.AbandonedMutexException] {
                $owned = $true
            }
            if (-not $owned) {
                $mutex.Dispose()
                throw "could not take mutex $name"
            }
            return [pscustomobject]@{
                letter = 'Q'
                container = 'xagent.slot-Q'
                sid = 'S-1-15-2-1'
                mutex = $mutex
                MutexName = $name
            }
        }

        function Release-RunSlot($Slot) {
            if ($null -eq $Slot) { return }
            $mutex = $Slot.mutex
            if ($null -eq $mutex) { return }
            try { $mutex.ReleaseMutex() } catch { }
            try { $mutex.Dispose() } catch { }
        }

        function Test-RunMutexDisposed($Mutex) {
            try {
                $null = $Mutex.WaitOne(0)
                return $false
            } catch {
                return $true
            }
        }

        function Test-RunMutexFree([string]$Name) {
            $ps = [powershell]::Create()
            $null = $ps.AddScript({
                param($MutexName)
                $m = [Threading.Mutex]::new($false, $MutexName)
                $clean = $false
                $owned = $false
                try {
                    $clean = $m.WaitOne(0)
                    $owned = $clean
                } catch [System.Threading.AbandonedMutexException] {
                    $owned = $true
                    $clean = $false
                }
                if ($owned) {
                    try { $m.ReleaseMutex() } catch { }
                }
                $m.Dispose()
                return $clean
            }).AddArgument($Name)
            try {
                $result = @($ps.Invoke())
                if ($ps.HadErrors) {
                    $msg = @($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join ' '
                    throw $msg
                }
                return [bool]$result[0]
            } finally {
                $ps.Dispose()
            }
        }

        function Get-RunLedgerPath {
            return (Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox\slot-Q.json')
        }
    }

    AfterAll {
        $env:XAGENT_SANDBOX_ROOT = Join-Path $TestDrive 'root'
        $env:XAGENT_CURSOR_ROOT = Join-Path $TestDrive 'cursor'
        Import-Module $script:ModulePath -Force
    }

    It 'quotes arguments the same way as delegate.ps1 Quote' {
        $delegate = (Resolve-Path (Join-Path $PSScriptRoot '../scripts/delegate.ps1')).Path
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($delegate, [ref]$tokens, [ref]$errors)
        $fn = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Quote'
        }, $true)
        $fn | Should -Not -BeNullOrEmpty
        Invoke-Expression $fn.Extent.Text

        $samples = @(
            'plain',
            'has space',
            'has"quote',
            'trailing\',
            "trailing space\ ",
            'a\"b',
            ''
        )
        foreach ($sample in $samples) {
            $oracle = Quote $sample
            $got = InModuleScope Sandbox -Parameters @{ Sample = $sample } {
                param($Sample)
                ConvertTo-SandboxArgument $Sample
            }
            $got | Should -Be $oracle
        }
        $line = InModuleScope Sandbox {
            Get-SandboxCommandLine -Exe 'C:\Program Files\x.exe' -Arguments @('a', 'b c')
        }
        $line | Should -Be '"C:\Program Files\x.exe" a "b c"'
    }

    It 'returns an empty array and releases the mutex when there is no run and no ledger' {
        $slot = New-RunSlot
        try {
            $notes = Stop-SandboxRun -Run $null -Slot $slot
            $notes -is [array] | Should -BeTrue
            $notes.Count | Should -Be 0
            (Test-RunMutexDisposed $slot.mutex) | Should -BeTrue
            (Test-RunMutexFree $slot.MutexName) | Should -BeTrue
            $hasQ = InModuleScope Sandbox { [bool](Get-SubstMap).ContainsKey('Q') }
            $hasQ | Should -BeFalse
        } finally {
            Release-RunSlot $slot
        }

        $slot2 = New-RunSlot
        try {
            $notes2 = Stop-SandboxRun -Run $null -Slot $slot2 -Handle $null
            $notes2 -is [array] | Should -BeTrue
            $notes2.Count | Should -Be 0
        } finally {
            Release-RunSlot $slot2
        }
    }

    It 'writes a failed grant back and removes the one that succeeded' {
        if ([XagentSandbox]::IsAppContainer()) { Set-ItResult -Skipped -Because 'an AppContainer cannot change file permissions'; return }
        $a = [IO.Path]::GetFullPath((Join-Path $TestDrive 'grant-a.txt'))
        $b = [IO.Path]::GetFullPath((Join-Path $TestDrive 'grant-b.txt'))
        $wt = [IO.Path]::GetFullPath((Join-Path $TestDrive 'failed-grant-wt'))
        New-Item -ItemType Directory -Force -Path $wt | Out-Null
        [IO.File]::WriteAllText($a, 'a')
        [IO.File]::WriteAllText($b, 'b')
        $ledger = Get-RunLedgerPath
        $sid = 'S-1-15-2-1'
        $slot = New-RunSlot
        try {
            $grantA = @(& icacls.exe $a /grant '*S-1-15-2-1:(R)' 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "icacls grant a failed: $grantA" }
            $grantB = @(& icacls.exe $b /grant '*S-1-15-2-1:(R)' 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "icacls grant b failed: $grantB" }
            $deny = @(& icacls.exe $b /deny '*S-1-3-4:(WDAC)' 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "icacls deny b failed: $deny" }

            $start = (Get-Process -Id $PID).StartTime
            InModuleScope Sandbox -Parameters @{
                LedgerPath = $ledger
                Worktree = $wt
                GrantA = $a
                GrantB = $b
                ProcessId = $PID
                StartTime = $start
            } {
                param($LedgerPath, $Worktree, $GrantA, $GrantB, $ProcessId, $StartTime)
                Write-SandboxLedger -Path $LedgerPath -Ledger ([ordered]@{
                    slot = 'Q'
                    sid = 'S-1-15-2-1'
                    pid = $ProcessId
                    startTime = $StartTime
                    runtimeVersion = 'test'
                    worktree = $Worktree
                    grants = @(
                        [pscustomobject]@{ path = $GrantA; spec = '(R)' },
                        [pscustomobject]@{ path = $GrantB; spec = '(R)' }
                    )
                })
            }
            $before = InModuleScope Sandbox -Parameters @{ Path = $ledger } {
                param($Path)
                Read-SandboxLedger -Path $Path
            }

            $notes = Stop-SandboxRun -Run $null -Slot $slot
            $notes -is [array] | Should -BeTrue
            @($notes).Count | Should -Be 1
            $notes[0].StartsWith("grant not removed: $b") | Should -BeTrue

            Test-Path -LiteralPath $ledger | Should -BeTrue
            $after = InModuleScope Sandbox -Parameters @{ Path = $ledger } {
                param($Path)
                Read-SandboxLedger -Path $Path
            }
            $after.slot | Should -Be $before.slot
            $after.sid | Should -Be $before.sid
            $after.pid | Should -Be $before.pid
            $after.startTime | Should -Be $before.startTime
            $after.runtimeVersion | Should -Be $before.runtimeVersion
            $after.worktree | Should -Be $before.worktree
            @($after.grants).Count | Should -Be 1
            $after.grants[0].path | Should -Be $b
            $after.grants[0].spec | Should -Be '(R)'
            @($after.grants[0].PSObject.Properties.Name) | Should -Not -Contain 'error'

            $acl = ((@(& icacls.exe $a 2>&1) | ForEach-Object { "$_" }) -join "`n")
            $acl | Should -Not -Match ([regex]::Escape($sid))
        } finally {
            & icacls.exe $a /remove '*S-1-15-2-1' 2>&1 | Out-Null
            & icacls.exe $b /remove '*S-1-15-2-1' 2>&1 | Out-Null
            & icacls.exe $b /remove:d '*S-1-3-4' 2>&1 | Out-Null
            Remove-Item -LiteralPath $a, $b, $ledger -Force -ErrorAction SilentlyContinue
            Release-RunSlot $slot
        }
    }

    It 'keeps an unreadable ledger and notes it' {
        $ledger = Get-RunLedgerPath
        $dir = Split-Path -Parent $ledger
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        [IO.File]::WriteAllText($ledger, '{')
        $slot = New-RunSlot
        try {
            $notes = Stop-SandboxRun -Run $null -Slot $slot
            $notes -is [array] | Should -BeTrue
            @($notes).Count | Should -Be 1
            $notes[0] | Should -Be "remove grants: ledger unreadable $ledger"
            Test-Path -LiteralPath $ledger | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $ledger -Force -ErrorAction SilentlyContinue
            Release-RunSlot $slot
        }
    }

    It 'deletes auth.json from the run object and from a ledger worktree' {
        $wt = [IO.Path]::GetFullPath((Join-Path $TestDrive 'auth-wt'))
        $cursorDir = Join-Path $wt '.xagent\sandbox\home\AppData\Roaming\Cursor'
        New-Item -ItemType Directory -Force -Path $cursorDir | Out-Null
        $auth = Join-Path $cursorDir 'auth.json'
        $keep = Join-Path $cursorDir 'keep.json'
        [IO.File]::WriteAllText($auth, '{"token":"x"}')
        [IO.File]::WriteAllText($keep, '{"keep":true}')
        $ledger = Get-RunLedgerPath
        $slot = New-RunSlot
        try {
            $notes = Stop-SandboxRun -Run ([pscustomobject]@{ worktree = $wt }) -Slot $slot
            $notes -is [array] | Should -BeTrue
            $notes.Count | Should -Be 0
            Test-Path -LiteralPath $auth | Should -BeFalse
            Test-Path -LiteralPath $keep | Should -BeTrue
        } finally {
            Release-RunSlot $slot
        }

        [IO.File]::WriteAllText($auth, '{"token":"y"}')
        $slot2 = New-RunSlot
        try {
            $start = (Get-Process -Id $PID).StartTime
            InModuleScope Sandbox -Parameters @{
                LedgerPath = $ledger
                Worktree = $wt
                ProcessId = $PID
                StartTime = $start
            } {
                param($LedgerPath, $Worktree, $ProcessId, $StartTime)
                Write-SandboxLedger -Path $LedgerPath -Ledger ([ordered]@{
                    slot = 'Q'
                    sid = 'S-1-15-2-1'
                    pid = $ProcessId
                    startTime = $StartTime
                    runtimeVersion = 'test'
                    worktree = $Worktree
                    grants = @()
                })
            }
            $notes2 = Stop-SandboxRun -Run $null -Slot $slot2
            $notes2 -is [array] | Should -BeTrue
            $notes2.Count | Should -Be 0
            Test-Path -LiteralPath $auth | Should -BeFalse
            Test-Path -LiteralPath $keep | Should -BeTrue
            Test-Path -LiteralPath $ledger | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $ledger -Force -ErrorAction SilentlyContinue
            Release-RunSlot $slot2
        }
    }

    It 'throws when no letters are reserved and writes no ledger' {
        $slot = New-RunSlot
        try {
            $expected = InModuleScope Sandbox { Get-NoLettersReservedMessage }
            $message = Get-ThrownMessage {
                New-SandboxRun -Slot $slot -Runtime @{ root = 'D:\xagent-none\runtime'; version = 'test'; uv = '1.52.1'; patched = $false } -Repo 'D:\xagent-none\repo' -Worktree 'D:\xagent-none\wt' -WtName 'wt'
            }
            $message | Should -Be $expected
            Test-Path -LiteralPath (Get-RunLedgerPath) | Should -BeFalse
        } finally {
            Release-RunSlot $slot
        }
    }
}

# Pester keeps this scope for discovery only. BeforeDiscovery calls these helpers.
# The three the run recomputes are defined again in the file-level BeforeAll.
function Import-TestParseVersionString {
    $modulePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../scripts/Sandbox.psm1'))
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
        $output = @(& git -C $PSScriptRoot rev-parse --show-toplevel 2>&1)
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

function Get-TestFreeLetterCount {
    $subst = @{}
    foreach ($line in @(& subst.exe 2>&1)) {
        if ([string]$line -match '^([A-Za-z]):\\: => ') {
            $subst[$Matches[1].ToUpperInvariant()] = $true
        }
    }
    $drives = @{}
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        if ($drive.Name) { $drives[$drive.Name.Substring(0, 1).ToUpperInvariant()] = $true }
    }
    $free = 0
    foreach ($code in 68..90) {
        $letter = [string][char]$code
        if ($subst.ContainsKey($letter) -or $drives.ContainsKey($letter)) { continue }
        $free++
    }
    return $free
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

Describe 'run lifecycle' -Tag Sandbox {
    BeforeDiscovery {
        $script:RunSkip = $false
        $script:RunSkipReason = ''
        $script:RunRepoRoot = $null
        $script:RunRealVersionDir = $null
        $nativePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../scripts/SandboxNative.cs'))
        if (-not ('XagentSandbox' -as [type])) {
            Add-Type -Path $nativePath
        }
        if ([XagentSandbox]::IsAppContainer()) {
            $script:RunSkip = $true
            $script:RunSkipReason = 'already inside an AppContainer'
        } elseif ([Environment]::OSVersion.Version.Build -lt 26300) {
            $script:RunSkip = $true
            $script:RunSkipReason = 'Windows build is older than 26300'
        } elseif ((Get-TestFreeLetterCount) -lt 3) {
            $script:RunSkip = $true
            $script:RunSkipReason = 'fewer than three free letters D-Z'
        } else {
            $top = Get-TestGitTopLevel
            if (-not $top) {
                $script:RunSkip = $true
                $script:RunSkipReason = 'git rev-parse --show-toplevel failed'
            } elseif (Test-TestPathUnderUserProfile $top) {
                $script:RunSkip = $true
                $script:RunSkipReason = 'the repo root is under %USERPROFILE%'
                $script:RunRepoRoot = $top
            } elseif (-not (Test-TestDriveRootWritable $top)) {
                $script:RunSkip = $true
                $script:RunSkipReason = 'the repo drive root is not writable'
                $script:RunRepoRoot = $top
            } elseif (-not (Test-Path -LiteralPath 'C:\Program Files\PowerShell\7\pwsh.exe' -PathType Leaf)) {
                $script:RunSkip = $true
                $script:RunSkipReason = 'C:\Program Files\PowerShell\7\pwsh.exe is missing'
                $script:RunRepoRoot = $top
            } else {
                $script:RunRepoRoot = $top
                $versionDir = Get-TestRealCursorVersionDir
                if (-not $versionDir) {
                    $script:RunSkip = $true
                    $script:RunSkipReason = 'Cursor is not installed'
                } else {
                    $script:RunRealVersionDir = $versionDir
                }
            }
        }
        if ($script:RunSkip) {
            Write-Host "run lifecycle skipped: $script:RunSkipReason"
        }
    }

    BeforeAll {
        if ($script:RunSkip) { return }
        $script:RunLetters = $null
        $script:RunRuntime = $null
        $script:RunTestRoot = $null
        $script:RunRepo = $null
        $script:RunWorktree = $null
        $script:RunWtName = $null

        $script:RunRepoRoot = Get-TestGitTopLevel
        if (-not $script:RunRepoRoot) { throw 'git rev-parse --show-toplevel failed' }
        $script:RunRealVersionDir = Get-TestRealCursorVersionDir
        if (-not $script:RunRealVersionDir) { throw 'Cursor version folder was not found' }

        $env:XAGENT_SANDBOX_ROOT = Join-Path $TestDrive 'run-life-root'
        $env:XAGENT_CURSOR_ROOT = Join-Path $TestDrive 'run-life-cursor'
        New-Item -ItemType Directory -Force -Path $env:XAGENT_SANDBOX_ROOT, $env:XAGENT_CURSOR_ROOT | Out-Null
        Import-Module $script:ModulePath -Force

        $free = @(Get-TestFreeLetters)
        if ($free.Count -lt 3) { throw 'sandbox: fewer than three free letters D-Z at reservation time' }
        $script:RunLetters = @([string]$free[0], [string]$free[1], [string]$free[2])
        Set-SandboxLetters -Letters $script:RunLetters

        $versionName = Split-Path $script:RunRealVersionDir -Leaf
        $fakeCursor = Join-Path $TestDrive 'run-life-fake-cursor'
        $destDir = Join-Path $fakeCursor "versions\$versionName"
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RunRealVersionDir 'node.exe') -Destination (Join-Path $destDir 'node.exe') -Force
        $script:RunRuntime = Get-SandboxRuntime -CursorRoot $fakeCursor
        if (-not $script:RunRuntime.patched) {
            throw "runtime not patched: uv $($script:RunRuntime.uv)"
        }

        $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:RunTestRoot = Join-Path (Split-Path $script:RunRepoRoot -Qualifier) ('xagent-tests-' + $suffix)
        New-Item -ItemType Directory -Force -Path $script:RunTestRoot | Out-Null
        $script:RunRepo = Join-Path $script:RunTestRoot 'repo'
        New-Item -ItemType Directory -Force -Path $script:RunRepo | Out-Null

        function Invoke-RunGit {
            param([Parameter(Mandatory)][string[]]$ArgumentList)
            $output = @(& git @ArgumentList 2>&1)
            if ($LASTEXITCODE -ne 0) {
                $text = (@($output) | ForEach-Object { "$_" }) -join "`n"
                throw "git $($ArgumentList -join ' ') failed (${LASTEXITCODE}): $text"
            }
        }

        Invoke-RunGit -ArgumentList @('-C', $script:RunRepo, 'init', '--quiet')
        # Repo-local, so the container and the host agree. The container does not see the user's gitconfig.
        Invoke-RunGit -ArgumentList @('-C', $script:RunRepo, 'config', 'core.autocrlf', 'false')
        [IO.File]::WriteAllText((Join-Path $script:RunRepo 'README.txt'), 'readme-ok', [Text.UTF8Encoding]::new($false))
        Invoke-RunGit -ArgumentList @('-C', $script:RunRepo, 'add', '--', 'README.txt')
        Invoke-RunGit -ArgumentList @('-C', $script:RunRepo, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-m', 'init', '--quiet')
        $excludePath = Join-Path $script:RunRepo '.git\info\exclude'
        $excludeText = ''
        if (Test-Path -LiteralPath $excludePath) { $excludeText = [IO.File]::ReadAllText($excludePath) }
        if ($excludeText.Length -gt 0 -and -not $excludeText.EndsWith("`n")) { $excludeText += "`n" }
        $excludeText += ".xagent/`n"
        [IO.File]::WriteAllText($excludePath, $excludeText, [Text.UTF8Encoding]::new($false))

        $script:RunWorktree = Join-Path $script:RunTestRoot 'repo.xagent\task-1'
        Invoke-RunGit -ArgumentList @('-C', $script:RunRepo, 'worktree', 'add', $script:RunWorktree)
        $gitText = [IO.File]::ReadAllText((Join-Path $script:RunWorktree '.git'))
        if ($gitText -notmatch '(?m)^gitdir:\s*(.+?)\s*$') { throw "worktree .git has no gitdir: $gitText" }
        $script:RunWtName = [IO.Path]::GetFileName($Matches[1].Trim())
        if ([string]::IsNullOrWhiteSpace($script:RunWtName) -or $script:RunWtName -eq '.' -or $script:RunWtName -eq '..') {
            throw "unexpected worktree name '$script:RunWtName'"
        }

        $loginProfile = Join-Path $TestDrive 'run-life-login\profile'
        $loginAppData = Join-Path $TestDrive 'run-life-login\appdata'
        New-Item -ItemType Directory -Force -Path (Join-Path $loginProfile '.cursor'), (Join-Path $loginAppData 'Cursor') | Out-Null
        [IO.File]::WriteAllText((Join-Path $loginProfile '.cursor\cli-config.json'), '{}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $loginProfile '.gitconfig'), "[user]`r`n`tname = t`r`n`temail = t@t`r`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $loginAppData 'Cursor\auth.json'), '{"fake":true}', [Text.UTF8Encoding]::new($false))
        InModuleScope Sandbox -Parameters @{ LoginProfile = $loginProfile; LoginAppData = $loginAppData } {
            param($LoginProfile, $LoginAppData)
            $script:LoginProfile = $LoginProfile
            $script:LoginAppData = $LoginAppData
        }

        function Read-RunOutputText([string]$Path) {
            if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return '' }
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            $reader = New-Object IO.StreamReader($stream)
            try {
                return $reader.ReadToEnd()
            } finally {
                $reader.Dispose()
            }
        }

        # script=/child=/grandchild= lines. Ready only when both child= values agree and the three PIDs differ.
        function Read-SleeperPids([string]$Text) {
            $scriptPid = $null
            $grandchildPid = $null
            $childValues = New-Object System.Collections.Generic.List[int]
            foreach ($line in @($Text -split '\r?\n')) {
                if ($line -match '^script=(\d+)$') {
                    $scriptPid = [int]$Matches[1]
                } elseif ($line -match '^child=(\d+)$') {
                    $childValues.Add([int]$Matches[1])
                } elseif ($line -match '^grandchild=(\d+)$') {
                    $grandchildPid = [int]$Matches[1]
                }
            }
            $childPid = $null
            $ready = $false
            if ($null -ne $scriptPid -and $null -ne $grandchildPid -and $childValues.Count -gt 0) {
                $childPid = $childValues[0]
                $sameChild = $true
                foreach ($value in $childValues) {
                    if ($value -ne $childPid) { $sameChild = $false; break }
                }
                if ($sameChild) {
                    $distinct = @($scriptPid, $childPid, $grandchildPid) | Select-Object -Unique
                    $ready = @($distinct).Count -eq 3
                }
            }
            return [pscustomobject]@{
                Ready = $ready
                ScriptPid = $scriptPid
                ChildPid = $childPid
                GrandchildPid = $grandchildPid
            }
        }

        function Invoke-RunScript {
            param(
                [Parameter(Mandatory)][string]$Name,
                [Parameter(Mandatory)][string]$Body,
                [switch]$ReadOnly,
                [int]$TimeoutMs = 60000,
                [string]$Worktree,
                [string]$WtName
            )
            if ([string]::IsNullOrWhiteSpace($Worktree)) {
                $Worktree = $script:RunWorktree
                $WtName = $script:RunWtName
            } elseif ([string]::IsNullOrWhiteSpace($WtName)) {
                throw 'Invoke-RunScript -WtName is required with -Worktree'
            }
            $xagentDir = Join-Path $Worktree '.xagent'
            New-Item -ItemType Directory -Force -Path $xagentDir | Out-Null
            $scriptFile = Join-Path $xagentDir ($Name + '.ps1')
            [IO.File]::WriteAllText($scriptFile, $Body, [Text.UTF8Encoding]::new($false))

            $outDir = Join-Path $TestDrive 'run-life-out'
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
            $stdoutPath = Join-Path $outDir ($Name + '.out')
            $stderrPath = Join-Path $outDir ($Name + '.err')
            Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

            $slot = Get-SandboxSlot
            $run = $null
            $h = $null
            $timedOut = $false
            $exitCode = $null
            $thrown = $null
            try {
                $runArgs = @{
                    Slot = $slot
                    Runtime = $script:RunRuntime
                    Repo = $script:RunRepo
                    Worktree = $Worktree
                    WtName = $WtName
                }
                if ($ReadOnly) { $runArgs['ReadOnly'] = $true }
                $run = New-SandboxRun @runArgs
                $fileArg = '{0}:\.xagent\{1}.ps1' -f $run.slot, $Name
                $h = Start-SandboxProcess -Run $run -Exe 'C:\Program Files\PowerShell\7\pwsh.exe' -Arguments @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fileArg
                ) -StdoutPath $stdoutPath -StderrPath $stderrPath
                $finished = [XagentSandbox]::Wait($h, $TimeoutMs)
                if (-not $finished) {
                    [XagentSandbox]::Kill($h)
                    $timedOut = $true
                }
                $exitCode = [XagentSandbox]::Finish($h)
            } catch {
                $thrown = $_
            } finally {
                $notes = Stop-SandboxRun -Run $run -Slot $slot -Handle $h
            }
            if ($null -ne $thrown) { throw $thrown }
            return [pscustomobject]@{
                exitCode = $exitCode
                timedOut = $timedOut
                stdout = (Read-RunOutputText $stdoutPath)
                stderr = (Read-RunOutputText $stderrPath)
                notes = $notes
                run = $run
                slot = $slot
            }
        }

        function Get-RunAccessOutcomeFunction {
            return @'
function Get-RunAccessOutcome([string]$Path) {
    try {
        $null = [IO.File]::ReadAllBytes($Path)
        return 'ok'
    } catch {
        $current = $_.Exception
        while ($null -ne $current) {
            if ($current -is [System.UnauthorizedAccessException] -or $current -is [System.Security.SecurityException]) {
                return 'denied'
            }
            $current = $current.InnerException
        }
        $message = [string]$_.Exception.Message
        if ($message -match '(?i)denied') { return 'denied' }
        return 'error'
    }
}
'@
        }

        function New-RunSideWorktree {
            param([Parameter(Mandatory)][string]$Name)
            $path = Join-Path $script:RunTestRoot "repo.xagent\$Name"
            Invoke-RunGit -ArgumentList @('-C', $script:RunRepo, 'worktree', 'add', $path)
            try {
                $gitText = [IO.File]::ReadAllText((Join-Path $path '.git'))
                if ($gitText -notmatch '(?m)^gitdir:\s*(.+?)\s*$') { throw "worktree .git has no gitdir: $gitText" }
                $wtName = [IO.Path]::GetFileName($Matches[1].Trim())
                if ([string]::IsNullOrWhiteSpace($wtName) -or $wtName -eq '.' -or $wtName -eq '..') {
                    throw "unexpected worktree name '$wtName'"
                }
                return [pscustomobject]@{ Path = $path; WtName = $wtName }
            } catch {
                Remove-RunSideWorktree -Path $path
                throw
            }
        }

        function Remove-RunSideWorktree {
            param([string]$Path)
            if ([string]::IsNullOrWhiteSpace($Path)) { return }
            try { & git -C $script:RunRepo worktree remove --force $Path 2>&1 | Out-Null } catch { }
            if (Test-Path -LiteralPath $Path) {
                Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        if ($_.Attributes -band [IO.FileAttributes]::ReadOnly) {
                            $_.Attributes = $_.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
                        }
                    }
                try { Remove-Item -LiteralPath $Path -Recurse -Force } catch { }
                try { & git -C $script:RunRepo worktree prune 2>&1 | Out-Null } catch { }
            }
            $leaf = Split-Path $Path -Leaf
            if (-not [string]::IsNullOrWhiteSpace($leaf)) {
                try { & git -C $script:RunRepo branch -D $leaf 2>&1 | Out-Null } catch { }
            }
        }
    }

    AfterAll {
        if ($script:RunSkip) { return }
        try {
            try { Remove-SandboxLetters | Out-Null } catch { }
            finally {
                try {
                    if ($script:RunLetters) {
                        $letters = @($script:RunLetters)
                        foreach ($letter in $letters) {
                            if ([string]::IsNullOrWhiteSpace([string]$letter)) { continue }
                            & subst.exe "${letter}:" '/D' 2>&1 | Out-Null
                        }
                        foreach ($index in 1, 2) {
                            if ($index -ge $letters.Count) { continue }
                            $letter = [string]$letters[$index]
                            if ([string]::IsNullOrWhiteSpace($letter)) { continue }
                            try { [XagentSandbox]::DeleteProfile("xagent.slot-$letter") } catch { }
                        }
                    }
                } finally {
                    try {
                        if ($script:RunRepo -and $script:RunWorktree) {
                            & git -C $script:RunRepo worktree remove --force $script:RunWorktree 2>&1 | Out-Null
                        }
                    } catch { }
                    finally {
                        if ($script:RunTestRoot -and (Test-Path -LiteralPath $script:RunTestRoot)) {
                            Get-ChildItem -LiteralPath $script:RunTestRoot -Recurse -Force -File -ErrorAction SilentlyContinue |
                                ForEach-Object { $_.IsReadOnly = $false }
                            Remove-Item -LiteralPath $script:RunTestRoot -Recurse -Force
                        }
                    }
                }
            }
        } finally {
            $env:XAGENT_SANDBOX_ROOT = Join-Path $TestDrive 'root'
            $env:XAGENT_CURSOR_ROOT = Join-Path $TestDrive 'cursor'
            Import-Module $script:ModulePath -Force
        }
    }

    It 'runs a worker script in the container and cleans up' -Skip:$script:RunSkip {
        $runtimeLetter = $script:RunLetters[0]
        $nodeExe = '{0}:\{1}\node.exe' -f $runtimeLetter, $script:RunRuntime.version
        $js = 'const c=require(''child_process'').spawn(process.execPath,[''-e'',''console.log(\"piped-ok\")''],{stdio:''pipe''});let o='''';c.stdout.on(''data'',d=>o+=d);c.on(''close'',()=>console.log(o.trim()))'
        $jsForFile = $js.Replace("'", "''")
        $nodeLine = '$nodeOut = & ''NODEEXE'' -e ''JS'''
        $nodeLine = $nodeLine.Replace('NODEEXE', $nodeExe).Replace('JS', $jsForFile)
        $bodyLines = @(
            '$status = (git status --porcelain) -join '';'''
            'Write-Output "status=[$status]"'
            $nodeLine
            '$nodeText = "$nodeOut".Trim()'
            'Write-Output "node=$nodeText"'
            '$location = (Get-Location).Path'
            '$root = $location.TrimEnd(''\'')'
            '$readme = [IO.File]::ReadAllText(($root + ''\README.txt'')).Trim()'
            'Write-Output "readme=$readme"'
            'exit 0'
        )
        $r = Invoke-RunScript -Name 'worker' -Body ($bodyLines -join "`n")
        $because = "stderr: $($r.stderr)`nstdout: $($r.stdout)"
        $r.timedOut | Should -BeFalse -Because $because
        $r.exitCode | Should -Be 0 -Because $because
        $r.run.runtimeLetter | Should -Be $runtimeLetter -Because $because
        $lines = @($r.stdout -split "\r?\n" | Where-Object { $_ -ne '' })
        $lines | Should -Be @('status=[]', 'node=piped-ok', 'readme=readme-ok') -Because $because
        $r.notes -is [array] | Should -BeTrue -Because $because
        @($r.notes).Count | Should -Be 0 -Because $because

        $letter = [string]$r.run.slot
        $sandboxDir = Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox'
        Test-Path -LiteralPath (Join-Path $sandboxDir "slot-$letter.json") | Should -BeFalse -Because $because
        $runHome = Join-Path $script:RunWorktree '.xagent\sandbox\home'
        Test-Path -LiteralPath (Join-Path $runHome 'AppData\Roaming\Cursor\auth.json') | Should -BeFalse -Because $because
        $gitconfig = Join-Path $runHome '.gitconfig'
        Test-Path -LiteralPath $gitconfig | Should -BeTrue -Because $because
        (Get-Item -LiteralPath $gitconfig -Force).IsReadOnly | Should -BeTrue -Because $because
        $idle = Join-Path $sandboxDir 'idle'
        $map = Get-TestSubstMap
        (Test-SameLetterTarget $map[$letter] $idle) | Should -BeTrue -Because $because
        (Get-IcaclsText $script:RunWorktree) | Should -Not -Match ([regex]::Escape([string]$r.run.sid)) -Because $because
    }

    It 'a read-only run writes only its run home' -Skip:$script:RunSkip {
        $roOk = Join-Path $script:RunWorktree '.xagent\sandbox\home\ro-ok.txt'
        try {
            $bodyLines = @(
                'try {'
                '    [IO.File]::WriteAllText((Join-Path $env:USERPROFILE ''ro-ok.txt''), ''ok'')'
                '    Write-Output ''home=ok'''
                '} catch {'
                '    Write-Output ''home=denied'''
                '}'
                '$root = (Get-Location).Path.TrimEnd(''\'')'
                'try {'
                '    [IO.File]::WriteAllText(($root + ''\ro-new.txt''), ''new'')'
                '    Write-Output ''create=ok'''
                '} catch {'
                '    Write-Output ''create=denied'''
                '}'
                'try {'
                '    [IO.File]::AppendAllText(($root + ''\README.txt''), ''x'')'
                '    Write-Output ''modify=ok'''
                '} catch {'
                '    Write-Output ''modify=denied'''
                '}'
                '$status = (git status --porcelain --untracked-files=no) -join '';'''
                'Write-Output "status=[$status]"'
                'exit 0'
            )
            $r = Invoke-RunScript -Name 'readonly' -Body ($bodyLines -join "`n") -ReadOnly
            $because = "stderr: $($r.stderr)`nstdout: $($r.stdout)"
            $r.timedOut | Should -BeFalse -Because $because
            $r.exitCode | Should -Be 0 -Because $because
            $lines = @($r.stdout -split "\r?\n" | Where-Object { $_ -ne '' })
            $lines | Should -Be @('home=ok', 'create=denied', 'modify=denied', 'status=[]') -Because $because
            $r.notes -is [array] | Should -BeTrue -Because $because
            @($r.notes).Count | Should -Be 0 -Because $because
            Test-Path -LiteralPath (Join-Path $script:RunWorktree 'ro-new.txt') | Should -BeFalse -Because $because
            [IO.File]::ReadAllText((Join-Path $script:RunWorktree 'README.txt')) | Should -Be 'readme-ok' -Because $because
            Test-Path -LiteralPath $roOk | Should -BeTrue -Because $because
        } finally {
            try {
                if (Test-Path -LiteralPath $roOk) {
                    (Get-Item -LiteralPath $roOk -Force).IsReadOnly = $false
                    Remove-Item -LiteralPath $roOk -Force
                }
            } catch { }
        }
    }

    It 'Kill ends the whole process tree' -Skip:$script:RunSkip {
        # Redirects force CreateProcess rather than ShellExecute, so the child stays in the job.
        $writerLines = @(
            '$ErrorActionPreference = ''Stop'''
            'function Write-PidText([string]$Text) {'
            '    $path = Join-Path $env:USERPROFILE ''pids.txt'''
            '    for ($i = 0; $i -lt 50; $i++) {'
            '        try {'
            '            $stream = [IO.File]::Open($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)'
            '            try {'
            '                $bytes = [Text.Encoding]::UTF8.GetBytes($Text)'
            '                $stream.Write($bytes, 0, $bytes.Length)'
            '            } finally {'
            '                $stream.Dispose()'
            '            }'
            '            return'
            '        } catch {'
            '            Start-Sleep -Milliseconds 20'
            '        }'
            '    }'
            '    throw ''could not append pids.txt'''
            '}'
        )
        $childLines = @(
            '$out = Join-Path $env:USERPROFILE ''node.out'''
            '$err = Join-Path $env:USERPROFILE ''node.err'''
            '$node = Start-Process -FilePath ''NODEEXE'' -ArgumentList @(''-e'', ''setTimeout(()=>{},600000)'') -PassThru -RedirectStandardOutput $out -RedirectStandardError $err'
            'Start-Sleep -Milliseconds 200'
            'Write-PidText ("child=" + $PID + "`r`n" + "grandchild=" + $node.Id + "`r`n")'
            'Start-Sleep -Seconds 600'
        )
        $parentLines = @(
            '$out = Join-Path $env:USERPROFILE ''child.out'''
            '$err = Join-Path $env:USERPROFILE ''child.err'''
            '$child = Start-Process -FilePath ''PWSH'' -ArgumentList @(''-NoProfile'', ''-ExecutionPolicy'', ''Bypass'', ''-File'', ''CHILDFILE'') -PassThru -RedirectStandardOutput $out -RedirectStandardError $err'
            'Write-PidText ("script=" + $PID + "`r`n" + "child=" + $child.Id + "`r`n")'
            'Start-Sleep -Seconds 600'
        )

        $slot = $null
        $run = $null
        $h = $null
        $stopped = $false
        $scriptPid = $null
        $childPid = $null
        $grandPid = $null
        $runHome = Join-Path $script:RunWorktree '.xagent\sandbox\home'
        $pidsPath = Join-Path $runHome 'pids.txt'
        $stdoutPath = $null
        $stderrPath = $null
        try {
            $slot = Get-SandboxSlot
            $letter = [string]$slot.letter
            $runtimeLetter = $script:RunLetters[0]
            $nodeExe = '{0}:\{1}\node.exe' -f $runtimeLetter, $script:RunRuntime.version
            $childFile = '{0}:\.xagent\sleeper-child.ps1' -f $letter
            $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
            $xagentDir = Join-Path $script:RunWorktree '.xagent'
            New-Item -ItemType Directory -Force -Path $xagentDir | Out-Null
            $childBody = (($writerLines + $childLines) -join "`n").Replace('NODEEXE', $nodeExe)
            $parentBody = (($writerLines + $parentLines) -join "`n").Replace('PWSH', $pwsh).Replace('CHILDFILE', $childFile)
            [IO.File]::WriteAllText((Join-Path $xagentDir 'sleeper-child.ps1'), $childBody, [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $xagentDir 'sleeper.ps1'), $parentBody, [Text.UTF8Encoding]::new($false))

            $outDir = Join-Path $TestDrive 'run-life-out'
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
            $stdoutPath = Join-Path $outDir 'sleeper.out'
            $stderrPath = Join-Path $outDir 'sleeper.err'
            Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

            $run = New-SandboxRun -Slot $slot -Runtime $script:RunRuntime -Repo $script:RunRepo -Worktree $script:RunWorktree -WtName $script:RunWtName
            $fileArg = '{0}:\.xagent\sleeper.ps1' -f $run.slot
            $h = Start-SandboxProcess -Run $run -Exe $pwsh -Arguments @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fileArg
            ) -StdoutPath $stdoutPath -StderrPath $stderrPath

            $clock = [Diagnostics.Stopwatch]::StartNew()
            $pidText = ''
            $previous = $null
            $pidInfo = $null
            do {
                try {
                    $pidText = Read-RunOutputText $pidsPath
                } catch {
                    $pidText = ''
                }
                $pidInfo = Read-SleeperPids $pidText
                $scriptPid = $pidInfo.ScriptPid
                $childPid = $pidInfo.ChildPid
                $grandPid = $pidInfo.GrandchildPid
                $settled = $pidInfo.Ready -and $pidText -eq $previous -and $pidText.EndsWith("`n")
                if ($settled) { break }
                $previous = $pidText
                if ($clock.Elapsed.TotalMilliseconds -ge 30000) { break }
                Start-Sleep -Milliseconds 200
            } while ($true)

            $detail = @(
                ('stderr: ' + (Read-RunOutputText $stderrPath))
                ('pids: ' + $pidText)
                ('child.err: ' + (Read-RunOutputText (Join-Path $runHome 'child.err')))
                ('node.err: ' + (Read-RunOutputText (Join-Path $runHome 'node.err')))
            ) -join "`n"
            $settled | Should -BeTrue -Because $detail

            foreach ($procId in @($scriptPid, $childPid, $grandPid)) {
                $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
                $null -ne $proc | Should -BeTrue -Because "pid $procId is not running`n$detail"
            }
            $h.ProcessId | Should -BeIn @($scriptPid, $childPid, $grandPid) -Because $detail
            (Get-Process -Id $grandPid -ErrorAction SilentlyContinue).ProcessName | Should -Be 'node' -Because $detail
            (Get-Process -Id $childPid -ErrorAction SilentlyContinue).ProcessName | Should -Be 'pwsh' -Because $detail

            [XagentSandbox]::Kill($h)
            ([XagentSandbox]::Wait($h, 10000)) | Should -BeTrue -Because $detail

            $alive = @()
            $deadClock = [Diagnostics.Stopwatch]::StartNew()
            do {
                $alive = @()
                foreach ($procId in @($scriptPid, $childPid, $grandPid)) {
                    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
                    if ($null -ne $proc) { $alive += $procId }
                }
                if ($alive.Count -eq 0) { break }
                if ($deadClock.Elapsed.TotalMilliseconds -ge 10000) { break }
                Start-Sleep -Milliseconds 200
            } while ($true)
            @($alive).Count | Should -Be 0 -Because ("still running: " + ($alive -join ',') + "`n" + $detail)

            $null = [XagentSandbox]::Finish($h)
            $notes = Stop-SandboxRun -Run $run -Slot $slot -Handle $h
            $stopped = $true
            $notes -is [array] | Should -BeTrue -Because $detail
            @($notes).Count | Should -Be 0 -Because (($notes -join '; ') + "`n" + $detail)
        } finally {
            if (-not $stopped -and $null -ne $slot) {
                try { Stop-SandboxRun -Run $run -Slot $slot -Handle $h | Out-Null } catch { }
            }
            foreach ($procId in @($scriptPid, $childPid, $grandPid)) {
                if ($null -eq $procId) { continue }
                try {
                    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
                    if ($null -eq $proc) { continue }
                    if ($proc.ProcessName -ne 'pwsh' -and $proc.ProcessName -ne 'node') { continue }
                    Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
                } catch { }
            }
            foreach ($name in @('pids.txt', 'child.out', 'child.err', 'node.out', 'node.err')) {
                try {
                    $path = Join-Path $runHome $name
                    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
                } catch { }
            }
            foreach ($name in @('sleeper.ps1', 'sleeper-child.ps1')) {
                try {
                    Remove-Item -LiteralPath (Join-Path $script:RunWorktree ".xagent\$name") -Force -ErrorAction SilentlyContinue
                } catch { }
            }
        }
    }

    It 'a stuck grant keeps the ledger with only that entry' -Skip:$script:RunSkip {
        $stuck = [IO.Path]::GetFullPath((Join-Path $script:RunTestRoot 'stuck.txt'))
        $slot = $null
        $run = $null
        $h = $null
        $stopped = $false
        $sid = $null
        $ledgerPath = $null
        try {
            [IO.File]::WriteAllText($stuck, 'stuck', [Text.UTF8Encoding]::new($false))
            $slot = Get-SandboxSlot
            $run = New-SandboxRun -Slot $slot -Runtime $script:RunRuntime -Repo $script:RunRepo -Worktree $script:RunWorktree -WtName $script:RunWtName
            $sid = [string]$run.sid
            $letter = [string]$run.slot
            $sandboxDir = Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox'
            $ledgerPath = Join-Path $sandboxDir "slot-$letter.json"

            $grant = @(& icacls.exe $stuck /grant ("*${sid}:(R)") 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "icacls grant stuck failed (${LASTEXITCODE}): $grant" }

            InModuleScope Sandbox -Parameters @{ LedgerPath = $ledgerPath; StuckPath = $stuck } {
                param($LedgerPath, $StuckPath)
                $ledger = Read-SandboxLedger -Path $LedgerPath
                if ($null -eq $ledger) { throw "ledger missing: $LedgerPath" }
                $rows = New-Object System.Collections.Generic.List[object]
                foreach ($row in @($ledger.grants)) {
                    if ($null -ne $row) { $rows.Add($row) }
                }
                $rows.Add([pscustomobject]@{ path = $StuckPath; spec = '(R)' })
                $ledger.grants = $rows.ToArray()
                Write-SandboxLedger -Path $LedgerPath -Ledger $ledger
            }

            $deny = @(& icacls.exe $stuck /deny '*S-1-3-4:(WDAC)' 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "icacls deny stuck failed (${LASTEXITCODE}): $deny" }

            $notes = Stop-SandboxRun -Run $run -Slot $slot -Handle $h
            $stopped = $true
            $notes -is [array] | Should -BeTrue
            @($notes).Count | Should -Be 1
            $notes[0].StartsWith("grant not removed: $stuck") | Should -BeTrue -Because $notes[0]

            Test-Path -LiteralPath $ledgerPath | Should -BeTrue
            $after = InModuleScope Sandbox -Parameters @{ Path = $ledgerPath } {
                param($Path)
                Read-SandboxLedger -Path $Path
            }
            @($after.grants).Count | Should -Be 1
            $after.grants[0].path | Should -Be $stuck
            $after.grants[0].spec | Should -Be '(R)'
            $names = @($after.grants[0].PSObject.Properties.Name)
            @($names).Count | Should -Be 2
            $names | Should -Contain 'path'
            $names | Should -Contain 'spec'

            (Get-IcaclsText $script:RunWorktree) | Should -Not -Match ([regex]::Escape($sid))
            $idle = Join-Path $sandboxDir 'idle'
            (Test-SameLetterTarget (Get-TestSubstMap)[$letter] $idle) | Should -BeTrue
        } finally {
            if (-not $stopped -and $null -ne $slot) {
                try { Stop-SandboxRun -Run $run -Slot $slot -Handle $h | Out-Null } catch { }
            }
            try { & icacls.exe $stuck /remove:d '*S-1-3-4' 2>&1 | Out-Null } catch { }
            try {
                if (-not [string]::IsNullOrWhiteSpace($sid)) {
                    & icacls.exe $stuck /remove ("*$sid") 2>&1 | Out-Null
                }
            } catch { }
            try {
                if (Test-Path -LiteralPath $stuck) {
                    (Get-Item -LiteralPath $stuck -Force).IsReadOnly = $false
                    Remove-Item -LiteralPath $stuck -Force
                }
            } catch { }
            try {
                if (-not [string]::IsNullOrWhiteSpace($ledgerPath)) {
                    Remove-Item -LiteralPath $ledgerPath -Force -ErrorAction SilentlyContinue
                }
            } catch { }
        }
    }

    It 'the canary passes and leaves nothing behind' -Skip:$script:RunSkip {
        # Network is part of the canary. An offline machine fails this test; the assertion stays.
        $savedProfile = InModuleScope Sandbox { $script:LoginProfile }
        $savedCursor = InModuleScope Sandbox { $script:CursorRoot }
        $canaryProfile = Join-Path $TestDrive 'run-life-canary-profile'
        New-Item -ItemType Directory -Force -Path $canaryProfile | Out-Null
        # Get-SandboxRuntime with no -CursorRoot uses the module cursor root. The harness
        # leaves that folder empty and keeps node.exe in the fake cursor the cache was built from.
        $fakeCursor = Join-Path $TestDrive 'run-life-fake-cursor'
        $repoXagent = Join-Path $script:RunTestRoot 'repo.xagent'
        try {
            InModuleScope Sandbox -Parameters @{ Profile = $canaryProfile; Cursor = $fakeCursor } {
                param($Profile, $Cursor)
                $script:LoginProfile = $Profile
                $script:CursorRoot = $Cursor
            }
            $c = Invoke-SandboxCanary -Repo $script:RunRepo
            $because = ($c | ConvertTo-Json -Depth 5)
            $c.ok | Should -BeTrue -Because $because
            $c.results -is [System.Array] | Should -BeTrue -Because $because
            $c.cleanup -is [System.Array] | Should -BeTrue -Because $because
            $names = @($c.results | ForEach-Object { $_.name })
            $names | Should -Be @(
                'read-profile-canary',
                'read-repo-canary',
                'list-profile',
                'write-profile',
                'write-repo-beside',
                'write-worktree',
                'git-status',
                'git-diff',
                'git-log',
                'node-pipe',
                'network',
                'no-leak',
                'no-write-outside'
            ) -Because $because
            $canaryDirs = @(Get-ChildItem -LiteralPath $repoXagent -Force -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'canary-*' })
            @($canaryDirs).Count | Should -Be 0 -Because $because
            $listed = @(& git -C $script:RunRepo worktree list 2>&1)
            @($listed | Where-Object { "$_" -match 'canary-' }).Count | Should -Be 0 -Because $because
            $profileLeft = @(Get-ChildItem -LiteralPath $canaryProfile -Force -Filter 'xagent-canary-*.txt' -ErrorAction SilentlyContinue)
            $repoLeft = @(Get-ChildItem -LiteralPath $repoXagent -Force -Filter 'xagent-canary-*.txt' -ErrorAction SilentlyContinue)
            @($profileLeft).Count | Should -Be 0 -Because $because
            @($repoLeft).Count | Should -Be 0 -Because $because
            $sandboxDir = Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox'
            $ledgers = @(Get-ChildItem -LiteralPath $sandboxDir -Force -Filter 'slot-*.json' -ErrorAction SilentlyContinue)
            @($ledgers).Count | Should -Be 0 -Because $because
            $idle = Join-Path $sandboxDir 'idle'
            $map = Get-TestSubstMap
            (Test-SameLetterTarget $map[$script:RunLetters[1]] $idle) | Should -BeTrue -Because $because
            (Test-SameLetterTarget $map[$script:RunLetters[2]] $idle) | Should -BeTrue -Because $because
        } finally {
            InModuleScope Sandbox -Parameters @{ Profile = $savedProfile; Cursor = $savedCursor } {
                param($Profile, $Cursor)
                $script:LoginProfile = $Profile
                $script:CursorRoot = $Cursor
            }
        }
    }

    It 'a read-list entry under a profile-like path runs node with require' -Skip:$script:RunSkip {
        $folder = [IO.Path]::GetFullPath((Join-Path $TestDrive 'run-life-readlist'))
        $configPath = Join-Path $env:XAGENT_SANDBOX_ROOT 'sandbox.json'
        $readAdded = $false
        $savedJson = $null
        try {
            New-Item -ItemType Directory -Force -Path $folder | Out-Null
            $nodeSource = Join-Path (Join-Path $script:RunRuntime.root $script:RunRuntime.version) 'node.exe'
            Copy-Item -LiteralPath $nodeSource -Destination (Join-Path $folder 'node.exe') -Force
            [IO.File]::WriteAllText((Join-Path $folder 'lib.js'), "module.exports='lib-ok'", [Text.UTF8Encoding]::new($false))

            $savedJson = [IO.File]::ReadAllText($configPath)
            $cfg = $savedJson | ConvertFrom-Json
            $runtime = [string]$cfg.letters.runtime
            $slots = @($cfg.letters.slots | ForEach-Object { [string]$_ })
            $entry = @{ path = $folder; addToPath = $true } | ConvertTo-Json -Compress
            $updated = @"
{
  "letters": { "runtime": "$runtime", "slots": ["$($slots[0])", "$($slots[1])"] },
  "read": [$entry]
}
"@
            [IO.File]::WriteAllText($configPath, $updated, [Text.UTF8Encoding]::new($false))
            $readAdded = $true

            $tick = [char]96
            $js = 'console.log(require(String.raw' + $tick + $folder + '\lib.js' + $tick + '))'
            $nodeLit = (Join-Path $folder 'node.exe').Replace("'", "''")
            $jsLit = $js.Replace("'", "''")
            # Node 24 realpathSync lstats the drive root. The grant chain stops at the profile, so
            # --preserve-symlinks keeps require from walking above the folders it was given.
            $body = @"
`$nodeOut = & '$nodeLit' --preserve-symlinks -e '$jsLit'
`$nodeText = "`$nodeOut".Trim()
Write-Output "lib=`$nodeText"
exit 0
"@
            $r = Invoke-RunScript -Name 'readlist' -Body $body
            $because = "stderr: $($r.stderr)`nstdout: $($r.stdout)"
            $r.timedOut | Should -BeFalse -Because $because
            $r.exitCode | Should -Be 0 -Because $because
            $lines = @($r.stdout -split "\r?\n" | Where-Object { $_ -ne '' })
            $lines | Should -Be @('lib=lib-ok') -Because $because
            $r.notes -is [array] | Should -BeTrue -Because $because
            @($r.notes).Count | Should -Be 0 -Because $because
            # The folder is under the profile, so the run adds RA on each ancestor from the
            # profile root down and records it. Stop-SandboxRun removes those entries.
            (Get-IcaclsText $env:USERPROFILE) | Should -Not -Match ([regex]::Escape([string]$r.run.sid)) -Because $because
        } finally {
            if ($readAdded -and $null -ne $savedJson) {
                try { [IO.File]::WriteAllText($configPath, $savedJson, [Text.UTF8Encoding]::new($false)) } catch { }
            }
        }
    }

    It 'concurrent runs cannot read each other''s worktrees' -Skip:$script:RunSkip {
        $side = $null
        $slotA = $null
        $runA = $null
        $hA = $null
        $stoppedA = $false
        $stdoutPath = $null
        $stderrPath = $null
        try {
            $side = New-RunSideWorktree -Name 'task-2'
            $slotA = Get-SandboxSlot
            $letterA = [string]$slotA.letter
            $xagentDir = Join-Path $script:RunWorktree '.xagent'
            New-Item -ItemType Directory -Force -Path $xagentDir | Out-Null
            $parentBody = @(
                '$ErrorActionPreference = ''Stop'''
                '[IO.File]::WriteAllText((Join-Path $env:USERPROFILE ''a-ready.txt''), ''ready'')'
                'Start-Sleep -Seconds 600'
            ) -join "`n"
            [IO.File]::WriteAllText((Join-Path $xagentDir 'a-live.ps1'), $parentBody, [Text.UTF8Encoding]::new($false))
            $outDir = Join-Path $TestDrive 'run-life-out'
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
            $stdoutPath = Join-Path $outDir 'a-live.out'
            $stderrPath = Join-Path $outDir 'a-live.err'
            Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

            $runA = New-SandboxRun -Slot $slotA -Runtime $script:RunRuntime -Repo $script:RunRepo -Worktree $script:RunWorktree -WtName $script:RunWtName
            $fileArg = '{0}:\.xagent\a-live.ps1' -f $runA.slot
            $hA = Start-SandboxProcess -Run $runA -Exe 'C:\Program Files\PowerShell\7\pwsh.exe' -Arguments @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fileArg
            ) -StdoutPath $stdoutPath -StderrPath $stderrPath

            $readyPath = Join-Path $script:RunWorktree '.xagent\sandbox\home\a-ready.txt'
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $ready = $false
            do {
                if (Test-Path -LiteralPath $readyPath) { $ready = $true; break }
                if ($clock.Elapsed.TotalMilliseconds -ge 30000) { break }
                Start-Sleep -Milliseconds 200
            } while ($true)
            $readyDetail = @(
                ('stderr: ' + (Read-RunOutputText $stderrPath))
                ('stdout: ' + (Read-RunOutputText $stdoutPath))
            ) -join "`n"
            $ready | Should -BeTrue -Because $readyDetail

            $readme = (Join-Path $script:RunWorktree 'README.txt').Replace("'", "''")
            $byLetter = ('{0}:\README.txt' -f $letterA).Replace("'", "''")
            $body = (Get-RunAccessOutcomeFunction) + "`n" + @"
Write-Output ('byPath=' + (Get-RunAccessOutcome '$readme'))
Write-Output ('byLetter=' + (Get-RunAccessOutcome '$byLetter'))
exit 0
"@
            # A has already called New-SandboxRun. Get-SandboxSlot inside this Invoke-RunScript
            # sees A's ledger, whose pid is this live Pester process, and treats that slot as busy.
            # The mutex is re-entrant on this thread, so the mutex alone would not make the slot busy.
            $rB = Invoke-RunScript -Name 'peer-read' -Body $body -Worktree $side.Path -WtName $side.WtName
            $because = "stderr: $($rB.stderr)`nstdout: $($rB.stdout)"
            $rB.timedOut | Should -BeFalse -Because $because
            $rB.exitCode | Should -Be 0 -Because $because
            $lines = @($rB.stdout -split "\r?\n" | Where-Object { $_ -ne '' })
            $lines | Should -Be @('byPath=denied', 'byLetter=denied') -Because $because

            [XagentSandbox]::Kill($hA)
            $null = [XagentSandbox]::Finish($hA)
            $notesA = Stop-SandboxRun -Run $runA -Slot $slotA -Handle $hA
            $stoppedA = $true
            $notesA -is [array] | Should -BeTrue
            @($notesA).Count | Should -Be 0 -Because ($notesA -join '; ')
        } finally {
            if (-not $stoppedA -and $null -ne $slotA) {
                try { if ($null -ne $hA) { [XagentSandbox]::Kill($hA) } } catch { }
                try { Stop-SandboxRun -Run $runA -Slot $slotA -Handle $hA | Out-Null } catch { }
            }
            if ($null -ne $side) { Remove-RunSideWorktree -Path $side.Path }
            try {
                Remove-Item -LiteralPath (Join-Path $script:RunWorktree '.xagent\a-live.ps1') -Force -ErrorAction SilentlyContinue
            } catch { }
        }
    }

    It 'New-SandboxRun waits while another process holds the ACL lock' -Skip:$script:RunSkip {
        # Two runs granting on the same shared folders at once dropped each other's entries
        # (2026-11-16: about 1 in 13 concurrent starts failed with MODULE_NOT_FOUND).
        $holder = Join-Path $TestDrive 'acl-hold-run.ps1'
        $ready = Join-Path $TestDrive 'acl-hold-run.ready'
        Set-Content -LiteralPath $holder -Encoding utf8 -Value @(
            '$m = [Threading.Mutex]::new($false, ''Local\xagent-acl'')'
            '$null = $m.WaitOne()'
            ('Set-Content -LiteralPath ''{0}'' -Value x' -f $ready)
            'Start-Sleep -Seconds 3'
            '$m.ReleaseMutex()'
        )
        $p = Start-Process pwsh -ArgumentList '-NoProfile', '-File', $holder -WindowStyle Hidden -PassThru
        $slot = $null; $run = $null
        try {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $ready) -and $clock.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 100 }
            Test-Path -LiteralPath $ready | Should -BeTrue
            $slot = Get-SandboxSlot
            $clock.Restart()
            $run = New-SandboxRun -Slot $slot -Runtime $script:RunRuntime -Repo $script:RunRepo -Worktree $script:RunWorktree -WtName $script:RunWtName
            $clock.Elapsed.TotalSeconds | Should -BeGreaterThan 1.5
        } finally {
            if ($null -ne $slot) { try { Stop-SandboxRun -Run $run -Slot $slot -Handle $null | Out-Null } catch { } }
            $p | Wait-Process -Timeout 30 -ErrorAction SilentlyContinue
        }
    }

    It 'a later run in the same slot cannot read the previous run''s worktree' -Skip:$script:RunSkip {
        # Get-SandboxSlot tries slots in order. After run 1 releases its slot, run 2 lands
        # on slots[0] again. This fails if that ordering changes.
        $side = $null
        try {
            $r1 = Invoke-RunScript -Name 'same-slot-1' -Body "Write-Output 'held'`nexit 0"
            $because1 = "stderr: $($r1.stderr)`nstdout: $($r1.stdout)"
            $r1.timedOut | Should -BeFalse -Because $because1
            $r1.exitCode | Should -Be 0 -Because $because1

            $side = New-RunSideWorktree -Name 'task-2'
            $readme = (Join-Path $script:RunWorktree 'README.txt').Replace("'", "''")
            $body = (Get-RunAccessOutcomeFunction) + "`n" + @"
Write-Output ('prev=' + (Get-RunAccessOutcome '$readme'))
exit 0
"@
            $r2 = Invoke-RunScript -Name 'same-slot-2' -Body $body -Worktree $side.Path -WtName $side.WtName
            $because2 = "stderr: $($r2.stderr)`nstdout: $($r2.stdout)"
            $r2.timedOut | Should -BeFalse -Because $because2
            $r2.exitCode | Should -Be 0 -Because $because2
            ([string]$r2.run.slot) | Should -Be ([string]$r1.run.slot) -Because $because2
            $lines = @($r2.stdout -split "\r?\n" | Where-Object { $_ -ne '' })
            $lines | Should -Be @('prev=denied') -Because $because2
        } finally {
            if ($null -ne $side) { Remove-RunSideWorktree -Path $side.Path }
        }
    }
    It 'Invoke-SandboxCommand returns both streams in order' -Skip:$script:RunSkip {
        $r = Invoke-SandboxCommand -Repo $script:RunRepo -Worktree $script:RunWorktree -Runtime $script:RunRuntime -RunName 'isc-streams' -TimeoutSec 60 `
            -Command "[Console]::Out.WriteLine('stdout-line'); [Console]::Error.WriteLine('stderr-line'); exit 0"
        $stdoutPath = Join-Path $script:RunRepo '.xagent\runs\isc-streams\stdout.txt'
        Test-Path -LiteralPath $stdoutPath | Should -BeTrue
        $r.status | Should -Be 'ran'
        $r.exitCode | Should -Be 0
        $r.output | Should -Be @('stdout-line', 'stderr-line')
    }

    It 'Invoke-SandboxCommand passes a quote and a semicolon' -Skip:$script:RunSkip {
        $r = Invoke-SandboxCommand -Repo $script:RunRepo -Worktree $script:RunWorktree -Runtime $script:RunRuntime -RunName 'isc-quote' -TimeoutSec 60 `
            -Command "Write-Output 'a""b'; exit 3"
        $stdoutPath = Join-Path $script:RunRepo '.xagent\runs\isc-quote\stdout.txt'
        Test-Path -LiteralPath $stdoutPath | Should -BeTrue
        $r.status | Should -Be 'ran'
        $r.exitCode | Should -Be 3
        $r.output[0] | Should -Be 'a"b'
    }

    It 'Invoke-SandboxCommand times out' -Skip:$script:RunSkip {
        $r = Invoke-SandboxCommand -Repo $script:RunRepo -Worktree $script:RunWorktree -Runtime $script:RunRuntime -RunName 'isc-timeout' -TimeoutSec 2 `
            -Command 'Start-Sleep 30'
        $stdoutPath = Join-Path $script:RunRepo '.xagent\runs\isc-timeout\stdout.txt'
        Test-Path -LiteralPath $stdoutPath | Should -BeTrue
        $r.status | Should -Be 'timeout'
        $r.exitCode | Should -Be $null
    }
}

Describe 'Sandbox environment paths' {
    BeforeAll {
        $script:EpRoot = Join-Path $TestDrive 'envpaths-root'
        $env:XAGENT_SANDBOX_ROOT = $script:EpRoot
        $env:XAGENT_CURSOR_ROOT = Join-Path $TestDrive 'envpaths-cursor'
        New-Item -ItemType Directory -Force -Path $script:EpRoot, $env:XAGENT_CURSOR_ROOT | Out-Null
        Import-Module $script:ModulePath -Force

        $script:EpRepoParent = Join-Path $TestDrive 'envpaths-repos'
        $script:EpRepoName = 'envrepo'
        $script:EpRepo = Join-Path $script:EpRepoParent $script:EpRepoName
        $script:EpWorktree = Join-Path $script:EpRepoParent ($script:EpRepoName + '.xagent\task-env')
        $script:EpRuntime = Join-Path $TestDrive 'envpaths-runtime'
        $script:EpVersion = 'env-ver'
        $script:EpWtName = 'wt-env'
        $git = Join-Path $script:EpRepo '.git'
        foreach ($dir in @('objects', 'refs', 'worktrees\wt-env')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $git $dir) | Out-Null
        }
        Set-Content -LiteralPath (Join-Path $git 'HEAD') -Value 'x' -Encoding ascii
        New-Item -ItemType Directory -Force -Path $script:EpWorktree, (Join-Path $script:EpRuntime $script:EpVersion) | Out-Null

        $script:EpFixture = Join-Path $TestDrive 'envpaths-fixture'
        $script:EpA = Join-Path $script:EpFixture 'a'
        $script:EpB = Join-Path $script:EpA 'b'
        $script:EpLeaf = Join-Path $script:EpB 'c'
        New-Item -ItemType Directory -Force -Path $script:EpLeaf | Out-Null

        function Resolve-EpPath([string]$Path) {
            if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
            return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
        }

        function Get-EpRowsUnder([object[]]$Rows, [string]$Root) {
            $norm = Resolve-EpPath $Root
            $prefix = $norm + '\'
            foreach ($row in @($Rows)) {
                if ([string]::Equals($row.path, $norm, [StringComparison]::OrdinalIgnoreCase)) { $row }
                elseif ($row.path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $row }
            }
        }

        function Format-EpRows($Rows) {
            foreach ($row in @($Rows)) { '{0} | {1}' -f $row.path, $row.spec }
        }
    }

    AfterAll {
        $env:XAGENT_SANDBOX_ROOT = Join-Path $TestDrive 'root'
        $env:XAGENT_CURSOR_ROOT = Join-Path $TestDrive 'cursor'
        Import-Module $script:ModulePath -Force
    }

    It 'adds an environment path RX row and ancestor RA rows in order' {
        $leaf = Resolve-EpPath $script:EpLeaf
        $packed = InModuleScope Sandbox -Parameters @{
            Repo = $script:EpRepo
            Worktree = $script:EpWorktree
            WtName = $script:EpWtName
            RuntimeRoot = $script:EpRuntime
            RuntimeVersion = $script:EpVersion
            Leaf = $leaf
        } {
            param($Repo, $Worktree, $WtName, $RuntimeRoot, $RuntimeVersion, $Leaf)
            Get-SandboxGrantList -Repo $Repo -Worktree $Worktree -WtName $WtName -RuntimeRoot $RuntimeRoot -RuntimeVersion $RuntimeVersion -ReadList $null -EnvPaths @(
                $null
                [pscustomobject]@{ path = $Leaf }
            )
        }
        $under = @(Get-EpRowsUnder $packed $script:EpFixture)
        $b = Resolve-EpPath $script:EpB
        $a = Resolve-EpPath $script:EpA
        $fixture = Resolve-EpPath $script:EpFixture
        @(Format-EpRows $under) | Should -Be @(
            "$leaf | (OI)(CI)RX"
            "$b | RA"
            "$a | RA"
            "$fixture | RA"
        )
    }

    It 'refuses a missing environment path with and without a project' {
        $missing = Join-Path $TestDrive 'envpaths-missing-dir'
        $withProj = InModuleScope Sandbox -Parameters @{
            Repo = $script:EpRepo
            Path = $missing
        } {
            param($Repo, $Path)
            try {
                Get-SandboxGrantList -Repo $Repo -Worktree 'D:\wt' -WtName 'w' -RuntimeRoot 'D:\rt' -RuntimeVersion 'v' -ReadList $null -EnvPaths @(
                    [pscustomobject]@{ path = $Path; project = 'myproj' }
                ) | Out-Null
                return $null
            } catch { return $_.Exception.Message }
        }
        $withProj | Should -Be "sandbox: environment path '$missing' does not exist; run -SandboxEnv -Repo $($script:EpRepo) -Apply -Rebuild myproj"

        $plain = InModuleScope Sandbox -Parameters @{ Repo = $script:EpRepo; Path = $missing } {
            param($Repo, $Path)
            try {
                Get-SandboxGrantList -Repo $Repo -Worktree 'D:\wt' -WtName 'w' -RuntimeRoot 'D:\rt' -RuntimeVersion 'v' -ReadList $null -EnvPaths @(
                    [pscustomobject]@{ path = $Path }
                ) | Out-Null
                return $null
            } catch { return $_.Exception.Message }
        }
        $plain | Should -Be "sandbox: environment path '$missing' does not exist; run -SandboxEnv -Repo $($script:EpRepo) -Apply"
    }

    It 'leaves grant rows unchanged when EnvPaths is omitted' {
        $bare = InModuleScope Sandbox -Parameters @{
            Repo = $script:EpRepo
            Worktree = $script:EpWorktree
            WtName = $script:EpWtName
            RuntimeRoot = $script:EpRuntime
            RuntimeVersion = $script:EpVersion
        } {
            param($Repo, $Worktree, $WtName, $RuntimeRoot, $RuntimeVersion)
            $common = @{
                Repo = $Repo
                Worktree = $Worktree
                WtName = $WtName
                RuntimeRoot = $RuntimeRoot
                RuntimeVersion = $RuntimeVersion
                ReadList = $null
            }
            $without = Get-SandboxGrantList @common
            $nullParam = Get-SandboxGrantList @common -EnvPaths $null
            [pscustomobject]@{ Without = $without; NullParam = $nullParam }
        }
        @(Format-EpRows $bare.Without) | Should -Be @(Format-EpRows $bare.NullParam)
    }

    It 'sets XAGENT_WORKTREE through Get-SandboxRunExtraEnv without mutating the caller hashtable' {
        $caller = @{ FOO = 'bar' }
        $copyBefore = $caller.Clone()
        $with = InModuleScope Sandbox -Parameters @{ Table = $caller.Clone() } {
            param($Table)
            Get-SandboxRunExtraEnv -ExtraEnv $Table -Letter 'S' -WithWorktree $true
        }
        $with['XAGENT_WORKTREE'] | Should -Be 'S:\'
        $with['FOO'] | Should -Be 'bar'

        $without = InModuleScope Sandbox {
            Get-SandboxRunExtraEnv -ExtraEnv @{ FOO = 'bar' } -Letter 'S' -WithWorktree $false
        }
        $without.ContainsKey('XAGENT_WORKTREE') | Should -BeFalse
        $caller.Keys | Should -Be $copyBefore.Keys
        $caller['FOO'] | Should -Be 'bar'

        $thrown = InModuleScope Sandbox {
            try {
                Get-SandboxRunExtraEnv -ExtraEnv @{ XAGENT_WORKTREE = 'X:\' } -Letter 'S' -WithWorktree $false | Out-Null
                return $null
            } catch { return $_.Exception.Message }
        }
        $thrown | Should -Be 'sandbox: extra environment variable XAGENT_WORKTREE is set by New-SandboxRun'
    }

    It 'exports Resolve-SandboxReadEntry' {
        Get-Command -Module Sandbox -Name Resolve-SandboxReadEntry | Should -Not -BeNullOrEmpty
    }
}

Describe 'Sandbox extra environment' {
    BeforeAll {
        Import-Module $script:ModulePath -Force
        $script:EnvBasePath = 'C:\Windows\System32;C:\Windows;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Program Files\PowerShell\7;C:\Program Files\Git\cmd'

        function Get-EnvMap([string[]]$Block) {
            $map = @{}
            foreach ($item in @($Block)) {
                $pair = $item -split '=', 2
                $map[$pair[0]] = $pair[1]
            }
            return $map
        }
    }

    It 'appends PathSuffix after read-list addToPath entries and skips empty suffixes' {
        $tool = Join-Path $TestDrive 'suffix-tool'
        New-Item -ItemType Directory -Force -Path $tool | Out-Null
        $toolPath = [IO.Path]::GetFullPath($tool).TrimEnd('\', '/')
        $suffixA = Join-Path $TestDrive 'suffix-a'
        $suffixB = Join-Path $TestDrive 'suffix-b'
        New-Item -ItemType Directory -Force -Path $suffixA, $suffixB | Out-Null
        $got = InModuleScope Sandbox -Parameters @{
            Tool = $toolPath
            SuffixA = $suffixA
            SuffixB = $suffixB
        } {
            param($Tool, $SuffixA, $SuffixB)
            $read = Test-SandboxReadList -Entries @([pscustomobject]@{ path = $Tool; addToPath = $true })
            Get-SandboxEnvironment -Slot 'S' -ReadList $read -PathSuffix @($SuffixA, '   ', $SuffixB)
        }
        $map = Get-EnvMap $got
        $map['PATH'] | Should -Be ($script:EnvBasePath + ';' + $toolPath + ';' + $suffixA + ';' + $suffixB)
    }

    It 'adds ExtraEnv names and refuses overrides of built-in names' {
        $got = InModuleScope Sandbox {
            Get-SandboxEnvironment -Slot 'S' -ReadList $null -ExtraEnv @{ UV_FROZEN = 1; MY_FLAG = 'yes' }
        }
        $map = Get-EnvMap $got
        $map['UV_FROZEN'] | Should -Be '1'
        $map['MY_FLAG'] | Should -Be 'yes'

        foreach ($case in @(
                @{ Key = 'PATH'; Spell = 'PATH' }
                @{ Key = 'path'; Spell = 'path' }
            )) {
            $message = InModuleScope Sandbox -Parameters @{ Key = $case.Key } {
                param($Key)
                try {
                    $extra = @{}
                    $extra[$Key] = 'x'
                    Get-SandboxEnvironment -Slot 'S' -ReadList $null -ExtraEnv $extra | Out-Null
                    return $null
                } catch { return $_.Exception.Message }
            }
            $message | Should -Be "sandbox: extra environment variable $($case.Spell) is already set"
        }
    }

    It 'matches the baseline environment when neither extra parameter is passed' {
        $today = InModuleScope Sandbox {
            Get-SandboxEnvironment -Slot 'S' -ReadList $null
        }
        $again = InModuleScope Sandbox {
            Get-SandboxEnvironment -Slot 'S' -ReadList $null -ExtraEnv $null -PathSuffix $null
        }
        @($today) | Should -Be @($again)
    }
}

Describe 'Sandbox lock helper' {
    BeforeAll { Import-Module $script:ModulePath -Force }

    It 'returns the script block output' {
        $out = Invoke-SandboxLocked -Name ('Local\xagent-test-{0}' -f [guid]::NewGuid()) -TimeoutSec 5 -TimeoutMessage 'timed' -ScriptBlock { 'hello', 42 }
        $out | Should -BeExactly @('hello', 42)
    }

    It 'throws the timeout message when the mutex is held' {
        $name = 'Local\xagent-test-{0}' -f [guid]::NewGuid()
        $job = Start-Job -ScriptBlock {
            param($mutexName)
            $m = [Threading.Mutex]::new($true, $mutexName)
            Start-Sleep -Seconds 60
            $m.ReleaseMutex()
            $m.Dispose()
        } -ArgumentList $name
        try {
            $held = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not [Threading.Mutex]::TryOpenExisting($name, [ref]$held) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
            if ($null -ne $held) { $held.Dispose() }
            Start-Sleep -Milliseconds 300
            $msg = 'lock test timeout {0}' -f [guid]::NewGuid()
            $clock = [Diagnostics.Stopwatch]::StartNew()
            { Invoke-SandboxLocked -Name $name -TimeoutSec 2 -TimeoutMessage $msg -ScriptBlock { 'x' } } | Should -Throw $msg
            $clock.Elapsed.TotalSeconds | Should -BeGreaterThan 1
        } finally {
            Stop-Job $job -ErrorAction SilentlyContinue | Out-Null
            Remove-Job $job -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }

    It 'takes over an abandoned mutex' {
        $name = 'Local\xagent-test-{0}' -f [guid]::NewGuid()
        $job = Start-Job -ScriptBlock {
            param($mutexName)
            $null = [Threading.Mutex]::new($true, $mutexName)
        } -ArgumentList $name
        Wait-Job $job | Out-Null
        Remove-Job $job -Force
        Start-Sleep -Milliseconds 200
        Invoke-SandboxLocked -Name $name -TimeoutSec 5 -TimeoutMessage 'timed' -ScriptBlock { 'ok' } | Should -Be 'ok'
    }
}

Describe 'Sandbox worktree delete' {
    BeforeAll { Import-Module $script:ModulePath -Force }

    It 'skips reparse points during worktree cleanup' {
        $target = Join-Path $TestDrive ('wt-del-target-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        $root = Join-Path $TestDrive ('wt-del-root-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        $roFile = Join-Path $target 'ro.txt'
        Set-Content -LiteralPath $roFile -Value 'keep' -Encoding utf8
        (Get-Item -LiteralPath $roFile).IsReadOnly = $true
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        try {
            $null = New-Item -ItemType Junction -Path (Join-Path $root 'link') -Target $target -ErrorAction Stop
        } catch {
            Set-ItResult -Skipped -Because 'cannot create a junction here'
            return
        }
        InModuleScope Sandbox -Parameters @{ Path = $root } { Clear-SandboxWorktreeForDelete $Path }
        Test-Path -LiteralPath $root | Should -BeFalse
        Test-Path -LiteralPath $target | Should -BeTrue
        Test-Path -LiteralPath $roFile | Should -BeTrue
        (Get-Item -LiteralPath $roFile).IsReadOnly | Should -BeTrue
    }
}
