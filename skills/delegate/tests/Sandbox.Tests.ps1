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
        [XagentSandbox]::IsAppContainer() | Should -BeFalse
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
}
