#Requires -Modules @{ModuleName='Pester';ModuleVersion='5.5'}

BeforeAll {
    function New-SandboxEnvTestRepo {
        $dir = Join-Path $TestDrive ("repo-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        & git -C $dir init -b main 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
        & git -C $dir config user.name test
        & git -C $dir config user.email test@example.invalid
        & git -C $dir config commit.gpgsign false
        & git -C $dir config core.autocrlf false
        return $dir
    }
    function Set-SandboxEnvRepoFile {
        param([string]$Repo, [string]$RelativePath, [string]$Content)
        $full = Join-Path $Repo ($RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $full
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        [IO.File]::WriteAllText($full, $Content, [Text.UTF8Encoding]::new($false))
    }
    function Add-SandboxEnvRepoCommit {
        param([string]$Repo, [string]$Message = 'commit')
        & git -C $Repo add -A 2>&1 | Out-Null
        & git -C $Repo commit -m $Message 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'git commit --trailer "Co-authored-by: Cursor <cursoragent@cursor.com>" failed' }
        return (& git -C $Repo rev-parse HEAD).Trim()
    }
    $script:FixtureRoot = (Resolve-Path (Join-Path $PSScriptRoot 'fixtures/sandbox-env')).Path
    $script:ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '../scripts/SandboxEnv.psm1')).Path
    $script:FakeUvCmd = Join-Path $script:FixtureRoot 'fake-uv.cmd'
    $script:SavedEnv = @{}
    foreach ($name in @('XAGENT_SANDBOX_ROOT','XAGENT_CURSOR_ROOT','XAGENT_UV_PATH','FAKE_UV_FAIL','FAKE_UV_LOG','FAKE_UV_VERSION','UV_PYTHON_INSTALL_DIR','UV_PROJECT_ENVIRONMENT','PATH')) {
        $script:SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    $env:XAGENT_SANDBOX_ROOT = Join-Path $TestDrive 'sbx-root'
    $env:XAGENT_CURSOR_ROOT = Join-Path $TestDrive 'cursor-root'
    New-Item -ItemType Directory -Force -Path $env:XAGENT_SANDBOX_ROOT, $env:XAGENT_CURSOR_ROOT | Out-Null
    Import-Module $script:ModulePath -Force

    function Enter-SandboxEnvApplyUv {
        param([Parameter(Mandatory)][string]$LogFile)
        $env:XAGENT_UV_PATH = $script:FakeUvCmd
        $env:FAKE_UV_LOG = $LogFile
        Remove-Item Env:FAKE_UV_FAIL -ErrorAction SilentlyContinue
        Remove-Item Env:FAKE_UV_VERSION -ErrorAction SilentlyContinue
    }

    function Exit-SandboxEnvApplyUv {
        $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH']
        $env:FAKE_UV_LOG = $script:SavedEnv['FAKE_UV_LOG']
        $env:FAKE_UV_FAIL = $script:SavedEnv['FAKE_UV_FAIL']
        $env:FAKE_UV_VERSION = $script:SavedEnv['FAKE_UV_VERSION']
        $env:PATH = $script:SavedEnv['PATH']
    }

    function Get-SandboxEnvTestRoot {
        param([Parameter(Mandatory)][string]$Repo)
        Join-Path (Split-Path -Parent $Repo) "$((Split-Path -Leaf $Repo)).xagent\.envs"
    }

    function Set-EnvStampAge {
        param([string]$StampPath, [int]$Days)
        if (-not (Test-Path -LiteralPath $StampPath)) { New-Item -ItemType File -Force -Path $StampPath | Out-Null }
        (Get-Item -LiteralPath $StampPath -Force).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-$Days)
    }

    function Copy-RepoToWorktree {
        param([string]$Repo, [string]$Dest)
        New-Item -ItemType Directory -Force -Path $Dest | Out-Null
        Get-ChildItem -LiteralPath $Repo -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Dest $_.Name) -Recurse -Force
        }
    }
}

AfterAll {
    Remove-Module SandboxEnv, Sandbox -Force -ErrorAction SilentlyContinue
    foreach ($name in $script:SavedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $script:SavedEnv[$name], 'Process') }
}
Describe 'Get-SandboxTomlValue' {
    It 'reads top-level and sectioned keys' {
        InModuleScope SandboxEnv {
            $top = "requires-python = `">=3.11`"`n`n[[package]]`nname = `"x`""
            Get-SandboxTomlValue -Text $top -Section '' -Key 'requires-python' | Should -Be '>=3.11'
            $proj = '[project]' + [char]10 + 'name = "app"'
            Get-SandboxTomlValue -Text $proj -Section 'project' -Key 'name' | Should -Be 'app'
        }
    }
    It 'does not return a key from the wrong section' {
        InModuleScope SandboxEnv {
            $text = '[other]' + [char]10 + 'name = "wrong"' + [char]10 + '[project]' + [char]10 + 'name = "right"'
            Get-SandboxTomlValue -Text $text -Section 'project' -Key 'name' | Should -Be 'right'
            Get-SandboxTomlValue -Text $text -Section 'other' -Key 'name' | Should -Be 'wrong'
        }
    }
    It 'ignores comment lines' {
        InModuleScope SandboxEnv {
            $text = '# name = "comment"' + [char]10 + 'requires-python = ">=3.11"'
            Get-SandboxTomlValue -Text $text -Section '' -Key 'requires-python' | Should -Be '>=3.11'
            Get-SandboxTomlValue -Text $text -Section '' -Key 'name' | Should -BeNullOrEmpty
        }
    }
}

Describe 'Test-SandboxTomlSection' {
    It 'detects section headers' {
        InModuleScope SandboxEnv {
            $text = '[project]' + [char]10 + 'name = "x"'
            Test-SandboxTomlSection -Text $text -Section 'project' | Should -Be $true
            Test-SandboxTomlSection -Text $text -Section 'tool.uv.workspace' | Should -Be $false
        }
    }
}

Describe 'Get-SandboxEnvProjects discovery' {
    It 'finds projects sorted ordinally' {
        $repo = New-SandboxEnvTestRepo
        $lock = 'version = 1' + [char]10 + 'requires-python = ">=3.11"'
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $lock
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'src/a/uv.lock' -Content $lock
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'B/uv.lock' -Content $lock
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath '_x/uv.lock' -Content $lock
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'a/uv.lock' -Content $lock
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'only-req/requirements-dev.txt' -Content 'pkg'
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'only-req/.python-version' -Content '3.12'
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'locked/uv.lock' -Content $lock
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'locked/nested/pyproject.toml' -Content ('[project]'+[char]10+'name="n"')
        $ws = '[tool.uv.workspace]'+[char]10+'members=["x"]'+[char]10+'[project]'+[char]10+'requires-python=">=3.11"'
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'ws/pyproject.toml' -Content $ws
        $sha = Add-SandboxEnvRepoCommit -Repo $repo
        $projects = Get-SandboxEnvProjects -Repo $repo -Commit $sha
        @($projects.project) | Should -Be @('.','B','_x','a','locked','only-req','src/a','ws')
        ($projects | Where-Object project -eq 'only-req').kind | Should -Be 'resolve'
        ($projects | Where-Object project -eq 'ws').reason | Should -Be 'workspace'
        ($projects | Where-Object project -eq 'locked/nested') | Should -BeNullOrEmpty
    }
    It 'has nested lock projects' {
        $repo = New-SandboxEnvTestRepo
        $lock = 'version = 1' + [char]10 + 'requires-python = ">=3.11"'
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $lock
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'src/a/uv.lock' -Content $lock
        $sha = Add-SandboxEnvRepoCommit -Repo $repo
        @(Get-SandboxEnvProjects -Repo $repo -Commit $sha).Count | Should -Be 2
    }
    It 'orders B, _x, a ordinally among lock projects' {
        $repo = New-SandboxEnvTestRepo
        $lock = 'version = 1' + [char]10 + 'requires-python = ">=3.11"'
        foreach ($name in @('B', 'a', '_x')) {
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath "$name/uv.lock" -Content $lock
        }
        $sha = Add-SandboxEnvRepoCommit -Repo $repo
        @((Get-SandboxEnvProjects -Repo $repo -Commit $sha).project) | Should -Be @('B', '_x', 'a')
    }
    It 'finds resolve project from requirements-dev and .python-version' {
        $repo = New-SandboxEnvTestRepo
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'only-req/requirements-dev.txt' -Content "pkg`n"
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'only-req/.python-version' -Content '3.12'
        $sha = Add-SandboxEnvRepoCommit -Repo $repo
        $p = Get-SandboxEnvProjects -Repo $repo -Commit $sha | Where-Object project -eq 'only-req'
        $p.kind | Should -Be 'resolve'
        $p.status | Should -BeNullOrEmpty
        $p.request | Should -Be '3.12'
    }
    It 'does not treat pyproject under a lock folder as a project' {
        $repo = New-SandboxEnvTestRepo
        $lock = 'version = 1' + [char]10 + 'requires-python = ">=3.11"'
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'locked/uv.lock' -Content $lock
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'locked/nested/pyproject.toml' -Content ('[project]' + [char]10 + 'name="n"')
        $sha = Add-SandboxEnvRepoCommit -Repo $repo
        Get-SandboxEnvProjects -Repo $repo -Commit $sha | Where-Object project -eq 'locked/nested' | Should -BeNullOrEmpty
    }
    It 'marks workspace pyproject as unsupported' {
        $repo = New-SandboxEnvTestRepo
        $ws = '[tool.uv.workspace]' + [char]10 + 'members=["x"]' + [char]10 + '[project]' + [char]10 + 'requires-python=">=3.11"'
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'ws/pyproject.toml' -Content $ws
        $sha = Add-SandboxEnvRepoCommit -Repo $repo
        $p = Get-SandboxEnvProjects -Repo $repo -Commit $sha | Where-Object project -eq 'ws'
        $p.status | Should -Be 'unsupported'
        $p.reason | Should -Be 'workspace'
    }
}

Describe 'hash inputs and interpreter' {
    It 'unchanged hash at commit after working tree edit' {
        $repo = New-SandboxEnvTestRepo
        $lock = 'version = 1' + [char]10 + 'requires-python = ">=3.11"'
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $lock
        $sha = Add-SandboxEnvRepoCommit -Repo $repo
        $h0 = (Get-SandboxEnvProjects -Repo $repo -Commit $sha)[0].hash
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content ($lock + 'x')
        (Get-SandboxEnvProjects -Repo $repo -Commit $sha)[0].hash | Should -Be $h0
    }
    It 'gives the same project hash for autocrlf true and false clones' {
        $source = New-SandboxEnvTestRepo
        $lock = 'version = 1' + [char]10 + 'requires-python = ">=3.11"'
        Set-SandboxEnvRepoFile -Repo $source -RelativePath 'uv.lock' -Content $lock
        $sha = Add-SandboxEnvRepoCommit -Repo $source
        $wtLf = Join-Path $TestDrive ("wt-lf-{0}" -f [guid]::NewGuid())
        $wtCrlf = Join-Path $TestDrive ("wt-crlf-{0}" -f [guid]::NewGuid())
        & git -C $source worktree add $wtLf $sha 2>&1 | Out-Null
        & git -C $source worktree add $wtCrlf $sha 2>&1 | Out-Null
        try {
            $lfPath = Join-Path $wtLf 'uv.lock'
            $crlfPath = Join-Path $wtCrlf 'uv.lock'
            [IO.File]::WriteAllText($crlfPath, ($lock -replace "`n", "`r`n"), [Text.UTF8Encoding]::new($false))
            [IO.File]::ReadAllBytes($lfPath) -contains 13 | Should -Be $false
            [IO.File]::ReadAllBytes($crlfPath) -contains 13 | Should -Be $true
            $hLf = (Get-SandboxEnvProjects -Repo $wtLf -Commit $sha)[0].hash
            $hCrlf = (Get-SandboxEnvProjects -Repo $wtCrlf -Commit $sha)[0].hash
            $hLf | Should -Be $hCrlf
        } finally {
            & git -C $source worktree remove -f $wtLf 2>&1 | Out-Null
            & git -C $source worktree remove -f $wtCrlf 2>&1 | Out-Null
        }
    }
    It 'gives the same hash for identical inputs in different folders' {
        $repo = New-SandboxEnvTestRepo
        $toml = '[project]' + [char]10 + 'name="a"' + [char]10 + 'requires-python=">=3.11"' + [char]10 + 'readme="README.md"'
        foreach ($dir in @('pa', 'pb')) {
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath "$dir/pyproject.toml" -Content $toml
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath "$dir/README.md" -Content 'same'
        }
        $sha = Add-SandboxEnvRepoCommit -Repo $repo
        $ps = Get-SandboxEnvProjects -Repo $repo -Commit $sha
        ($ps | Where-Object project -eq 'pa').hash | Should -Be ($ps | Where-Object project -eq 'pb').hash
    }
    It 'gives different hashes when one input byte differs' {
        $repo = New-SandboxEnvTestRepo
        $toml = '[project]' + [char]10 + 'name="a"' + [char]10 + 'requires-python=">=3.11"' + [char]10 + 'readme="README.md"'
        foreach ($dir in @('pa', 'pb')) {
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath "$dir/pyproject.toml" -Content $toml
        }
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'pa/README.md' -Content 'same'
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'pb/README.md' -Content 'same!'
        $sha = Add-SandboxEnvRepoCommit -Repo $repo
        $ps = Get-SandboxEnvProjects -Repo $repo -Commit $sha
        ($ps | Where-Object project -eq 'pa').hash | Should -Not -Be ($ps | Where-Object project -eq 'pb').hash
    }
    It 'includes readme and license file inputs from pyproject' {
        $repo = New-SandboxEnvTestRepo
        $py = '[project]' + [char]10 + 'name="s"' + [char]10 + 'requires-python=">=3.11"' + [char]10 + 'readme="README.md"' + [char]10 + 'license = { file = "LICENSE" }'
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'lic/pyproject.toml' -Content $py
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'lic/README.md' -Content 'r'
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'lic/LICENSE' -Content 'l'
        $sha = Add-SandboxEnvRepoCommit -Repo $repo
        $inputs = (Get-SandboxEnvProjects -Repo $repo -Commit $sha | Where-Object project -eq 'lic').inputs
        $inputs | Should -Contain 'lic/README.md'
        $inputs | Should -Contain 'lic/LICENSE'
    }
    It 'includes license from compact inline table syntax' {
        $repo = New-SandboxEnvTestRepo
        $py = '[project]' + [char]10 + 'name="s"' + [char]10 + 'requires-python=">=3.11"' + [char]10 + 'license = {file="LICENSE"}'
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'cmp/pyproject.toml' -Content $py
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'cmp/LICENSE' -Content 'l'
        $sha = Add-SandboxEnvRepoCommit -Repo $repo
        $inputs = (Get-SandboxEnvProjects -Repo $repo -Commit $sha | Where-Object project -eq 'cmp').inputs
        $inputs | Should -Contain 'cmp/LICENSE'
    }
    It 'includes parent .python-version once in inputs' {
        $repo = New-SandboxEnvTestRepo
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.11'
        $py = '[project]' + [char]10 + 'name="s"' + [char]10 + 'requires-python=">=3.12"'
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'sub/deep/pyproject.toml' -Content $py
        $sha = Add-SandboxEnvRepoCommit -Repo $repo
        $p = Get-SandboxEnvProjects -Repo $repo -Commit $sha | Where-Object project -eq 'sub/deep'
        $p.inputs | Should -Contain '.python-version'
        @($p.inputs | Where-Object { $_ -eq '.python-version' }).Count | Should -Be 1
        $p.request | Should -Be '3.11'
    }
    It 'keeps hash at commit and tracks inputs' {
        $repo = New-SandboxEnvTestRepo
        $lock = 'version = 1' + [char]10 + 'requires-python = ">=3.11"'
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $lock
        $sha = Add-SandboxEnvRepoCommit -Repo $repo
        $h0 = (Get-SandboxEnvProjects -Repo $repo -Commit $sha)[0].hash
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content ($lock + ' ')
        (Get-SandboxEnvProjects -Repo $repo -Commit $sha)[0].hash | Should -Be $h0
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.10'
        $py = '[project]'+[char]10+'name="s"'+[char]10+'requires-python=">=3.11"'+[char]10+'readme="README.md"'+[char]10+'license = {file="LICENSE"}'
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'sub/pyproject.toml' -Content $py
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'sub/README.md' -Content 'x'
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'sub/LICENSE' -Content 'x'
        $sha2 = Add-SandboxEnvRepoCommit -Repo $repo
        $p = Get-SandboxEnvProjects -Repo $repo -Commit $sha2 | Where-Object project -eq 'sub'
        $p.inputs | Should -Contain 'sub/LICENSE'
        $p.request | Should -Be '3.10'
    }
    It 'parses requires-python variants' {
        $repo = New-SandboxEnvTestRepo
        $gtToml = "[project]$([char]10)requires-python = `">3.11`""
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'gt/pyproject.toml' -Content $gtToml
        $geToml = "[project]$([char]10)requires-python = `">=3.11, <4`""
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'ge/pyproject.toml' -Content $geToml
        $unkToml = "[project]$([char]10)requires-python = `"nope`""
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'unk/pyproject.toml' -Content $unkToml
        $sha = Add-SandboxEnvRepoCommit -Repo $repo
        $ps = Get-SandboxEnvProjects -Repo $repo -Commit $sha
        ($ps | Where-Object { $_.project -eq 'gt' }).request | Should -Be '3.12'
        ($ps | Where-Object { $_.project -eq 'ge' }).request | Should -Be '3.11'
        ($ps | Where-Object { $_.project -eq 'unk' }).reason | Should -Be 'python-version-unknown'
    }
    It 'maps >=3.11 requires-python to 3.11' {
        $repo = New-SandboxEnvTestRepo
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'ge2/pyproject.toml' -Content ("[project]$([char]10)requires-python = `">=3.11`"")
        $sha = Add-SandboxEnvRepoCommit -Repo $repo
        (Get-SandboxEnvProjects -Repo $repo -Commit $sha | Where-Object project -eq 'ge2').request | Should -Be '3.11'
    }
    It 'maps ~=3.12 requires-python to 3.12' {
        $repo = New-SandboxEnvTestRepo
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'til/pyproject.toml' -Content ("[project]$([char]10)requires-python = `"~=3.12`"")
        $sha = Add-SandboxEnvRepoCommit -Repo $repo
        (Get-SandboxEnvProjects -Repo $repo -Commit $sha | Where-Object project -eq 'til').request | Should -Be '3.12'
    }
    It 'maps ==3.12.* requires-python to 3.12' {
        $repo = New-SandboxEnvTestRepo
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'star/pyproject.toml' -Content ("[project]$([char]10)requires-python = `"==3.12.*`"")
        $sha = Add-SandboxEnvRepoCommit -Repo $repo
        (Get-SandboxEnvProjects -Repo $repo -Commit $sha | Where-Object project -eq 'star').request | Should -Be '3.12'
    }
    It 'maps ==3.12.4 requires-python to 3.12' {
        $repo = New-SandboxEnvTestRepo
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'exact/pyproject.toml' -Content ("[project]$([char]10)requires-python = `"==3.12.4`"")
        $sha = Add-SandboxEnvRepoCommit -Repo $repo
        (Get-SandboxEnvProjects -Repo $repo -Commit $sha | Where-Object project -eq 'exact').request | Should -Be '3.12'
    }
}

Describe 'Get-SandboxUvPath' {
    It 'returns null when XAGENT_UV_PATH is empty and PATH has no uv' {
        try {
            $empty = Join-Path $TestDrive 'empty-path'
            New-Item -ItemType Directory -Force -Path $empty | Out-Null
            Remove-Item Env:XAGENT_UV_PATH -ErrorAction SilentlyContinue
            $env:PATH = $empty
            Get-SandboxUvPath | Should -BeNullOrEmpty
        } finally {
            $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH']
            $env:PATH = $script:SavedEnv['PATH']
        }
    }
}

Describe 'Invoke-SandboxUv' {
    It 'returns --version stdout as a one-element array' {
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $r = Invoke-SandboxUv -Arguments '--version'
            $r.exitCode | Should -Be 0
            $r.stdout.Count | Should -Be 1
            $r.stdout[0] | Should -Be 'uv 0.0.0-fake'
        } finally { $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH'] }
    }
    It 'passes Environment to the process and restores afterwards' {
        $logFile = Join-Path $TestDrive ("uv-log-{0}.txt" -f [guid]::NewGuid())
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $prev = [Environment]::GetEnvironmentVariable('FAKE_UV_LOG', 'Process')
            $null = Invoke-SandboxUv -Arguments '--version' -Environment @{ FAKE_UV_LOG = $logFile }
            Test-Path -LiteralPath $logFile | Should -Be $true
            (Get-Content -LiteralPath $logFile -Raw).Trim() | Should -Be '--version'
            $after = [Environment]::GetEnvironmentVariable('FAKE_UV_LOG', 'Process')
            if ($null -eq $prev) { [string]::IsNullOrEmpty($after) | Should -Be $true } else { $after | Should -Be $prev }
        } finally {
            $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH']
            [Environment]::SetEnvironmentVariable('FAKE_UV_LOG', $script:SavedEnv['FAKE_UV_LOG'], 'Process')
        }
    }
    It 'uses fake uv' {
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $r = Invoke-SandboxUv -Arguments '--version'
            $r.exitCode | Should -Be 0
            $r.stdout | Should -Be @('uv 0.0.0-fake')
        } finally { $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH'] }
    }
    It 'fails sync when configured' {
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $env:FAKE_UV_FAIL = 'sync'
            $r = Invoke-SandboxUv -Arguments @('sync')
            $r.exitCode | Should -Be 1
            $r.stderr | Should -Be @('fake failure')
        } finally {
            $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH']
            $env:FAKE_UV_FAIL = $script:SavedEnv['FAKE_UV_FAIL']
        }
    }
    It 'throws when uv missing' {
        try {
            $empty = Join-Path $TestDrive 'no-uv'
            New-Item -ItemType Directory -Force -Path $empty | Out-Null
            Remove-Item Env:XAGENT_UV_PATH -ErrorAction SilentlyContinue
            $env:PATH = $empty
            { Invoke-SandboxUv -Arguments '--version' } | Should -Throw 'sandbox: uv not found'
        } finally {
            $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH']
            $env:PATH = $script:SavedEnv['PATH']
        }
    }
}

Describe 'errors' {
    It 'throws on invalid commit' {
        $repo = New-SandboxEnvTestRepo
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content 'version = 1'
        Add-SandboxEnvRepoCommit -Repo $repo | Out-Null
        { Get-SandboxEnvProjects -Repo $repo -Commit 'bad' } | Should -Throw '*sandbox: cannot read bad in*'
    }
}

Describe 'Read-SandboxEnvsIndex' {
    It 'returns empty index without warning when envs.json is missing' {
        InModuleScope SandboxEnv {
            $root = Join-Path $TestDrive 'envs-missing'
            New-Item -ItemType Directory -Force -Path $root | Out-Null
            $r = Read-SandboxEnvsIndex -EnvsRoot $root
            $r.warning | Should -BeNullOrEmpty
            $r.index.approved | Should -BeNullOrEmpty
            $r.index.envs.Count | Should -Be 0
        }
    }
    It 'returns empty index with warning when envs.json is invalid' {
        InModuleScope SandboxEnv {
            $root = Join-Path $TestDrive 'envs-bad'
            New-Item -ItemType Directory -Force -Path $root | Out-Null
            [IO.File]::WriteAllText((Join-Path $root 'envs.json'), 'not json', [Text.UTF8Encoding]::new($false))
            $r = Read-SandboxEnvsIndex -EnvsRoot $root
            $r.warning | Should -Be 'envs.json unreadable; rebuilding on -Apply'
        }
    }
    It 'reads a valid envs.json' {
        InModuleScope SandboxEnv {
            $root = Join-Path $TestDrive 'envs-ok'
            New-Item -ItemType Directory -Force -Path $root | Out-Null
            $json = '{"version":1,"approved":"2020-01-01T00:00:00","uv":"x","uvVersion":"1","pythons":{},"envs":{},"failed":{}}'
            [IO.File]::WriteAllText((Join-Path $root 'envs.json'), $json, [Text.UTF8Encoding]::new($false))
            $r = Read-SandboxEnvsIndex -EnvsRoot $root
            $r.warning | Should -BeNullOrEmpty
            $r.index.approved | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Get-SandboxEnvsRoot' {
    It 'points at sibling repo.xagent\.envs' {
        InModuleScope SandboxEnv {
            $repo = (Resolve-Path $TestDrive).Path
            Get-SandboxEnvsRoot -Repo $repo | Should -Be (Join-Path (Split-Path $repo -Parent) "$(Split-Path $repo -Leaf).xagent\.envs")
        }
    }
}

Describe 'sandbox env status' {
    BeforeAll { $script:FixtureLock = Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'uv.lock') -Raw }
    It 'marks ready when index and python.exe exist' {
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $script:FixtureLock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $projs = Get-SandboxEnvProjects -Repo $repo -Commit $sha
            $h = $projs[0].hash
            $name = "py3.12-$($h.Substring(0,12))"
            $envsRoot = Join-Path (Split-Path $repo -Parent) "$(Split-Path $repo -Leaf).xagent\.envs"
            $index = @{ approved = 't'; uv = 'x'; uvVersion = '1'; pythons = @{}; envs = @{}; failed = @{} }
            $index.envs[$h] = @{ name = $name; projects = @('.'); kind = 'lock'; python = '3.12'; bytes = 10; built = (Get-Date).ToUniversalTime().ToString('o') }
            New-Item -ItemType Directory -Force -Path (Join-Path $envsRoot $name 'Scripts') | Out-Null
            [IO.File]::WriteAllText((Join-Path $envsRoot $name 'Scripts\python.exe'), '', [Text.UTF8Encoding]::new($false))
            $st = @(InModuleScope SandboxEnv -ArgumentList (,$projs), $index, $envsRoot, $env:XAGENT_UV_PATH { param($p,$i,$r,$u) Get-SandboxEnvStatuses -Projects $p -Index $i -EnvsRoot $r -UvPath $u })
            $st[0]['status'] | Should -Be 'ready'
        } finally { $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH'] }
    }
    It 'falls back to missing when python.exe is absent' {
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $script:FixtureLock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $projs = Get-SandboxEnvProjects -Repo $repo -Commit $sha
            $h = $projs[0].hash
            $name = "py3.12-$($h.Substring(0,12))"
            $envsRoot = Join-Path (Split-Path $repo -Parent) "$(Split-Path $repo -Leaf).xagent\.envs"
            $index = @{ approved = 't'; uv = 'x'; uvVersion = '1'; pythons = @{}; envs = @{}; failed = @{} }
            $index.envs[$h] = @{ name = $name; projects = @('.'); kind = 'lock'; python = '3.12'; bytes = 10; built = (Get-Date).ToUniversalTime().ToString('o') }
            $st = @(InModuleScope SandboxEnv -ArgumentList (,$projs), $index, $envsRoot, $env:XAGENT_UV_PATH { param($p,$i,$r,$u) Get-SandboxEnvStatuses -Projects $p -Index $i -EnvsRoot $r -UvPath $u })
            $st[0]['status'] | Should -Be 'missing'
        } finally { $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH'] }
    }
    It 'reports install-failed with error reason' {
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $script:FixtureLock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $projs = Get-SandboxEnvProjects -Repo $repo -Commit $sha
            $h = $projs[0].hash
            $envsRoot = Join-Path (Split-Path $repo -Parent) "$(Split-Path $repo -Leaf).xagent\.envs"
            $index = @{ approved = 't'; uv = 'x'; uvVersion = '1'; pythons = @{}; envs = @{}; failed = @{} }
            $index.failed[$h] = @{ at = 't'; error = 'uv sync failed' }
            $st = @(InModuleScope SandboxEnv -ArgumentList (,$projs), $index, $envsRoot, $env:XAGENT_UV_PATH { param($p,$i,$r,$u) Get-SandboxEnvStatuses -Projects $p -Index $i -EnvsRoot $r -UvPath $u })
            $st[0]['status'] | Should -Be 'install-failed'
            $st[0]['reason'] | Should -Be 'uv sync failed'
        } finally { $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH'] }
    }
    It 'reports stale when another hash lists the project' {
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $script:FixtureLock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $projs = Get-SandboxEnvProjects -Repo $repo -Commit $sha
            $envsRoot = Join-Path (Split-Path $repo -Parent) "$(Split-Path $repo -Leaf).xagent\.envs"
            $index = @{ approved = 't'; uv = 'x'; uvVersion = '1'; pythons = @{}; envs = @{}; failed = @{} }
            $index.envs['otherhash00000000000000000000000000000000000000000000000'] = @{ name = 'py3.12-deadbeef0000'; projects = @('.'); kind = 'lock'; python = '3.12'; bytes = 1; built = (Get-Date).ToUniversalTime().ToString('o') }
            $st = @(InModuleScope SandboxEnv -ArgumentList (,$projs), $index, $envsRoot, $env:XAGENT_UV_PATH { param($p,$i,$r,$u) Get-SandboxEnvStatuses -Projects $p -Index $i -EnvsRoot $r -UvPath $u })
            $st[0]['status'] | Should -Be 'stale'
        } finally { $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH'] }
    }
    It 'reports missing with empty index' {
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $script:FixtureLock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $projs = Get-SandboxEnvProjects -Repo $repo -Commit $sha
            $envsRoot = Join-Path (Split-Path $repo -Parent) "$(Split-Path $repo -Leaf).xagent\.envs"
            $index = @{ approved = $null; uv = $null; uvVersion = $null; pythons = @{}; envs = @{}; failed = @{} }
            $st = @(InModuleScope SandboxEnv -ArgumentList (,$projs), $index, $envsRoot, $env:XAGENT_UV_PATH { param($p,$i,$r,$u) Get-SandboxEnvStatuses -Projects $p -Index $i -EnvsRoot $r -UvPath $u })
            $st[0]['status'] | Should -Be 'missing'
        } finally { $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH'] }
    }
    It 'marks every project uv-missing when uv is absent' {
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $script:FixtureLock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $projs = Get-SandboxEnvProjects -Repo $repo -Commit $sha
            $envsRoot = Join-Path (Split-Path $repo -Parent) "$(Split-Path $repo -Leaf).xagent\.envs"
            $index = @{ approved = $null; uv = $null; uvVersion = $null; pythons = @{}; envs = @{}; failed = @{} }
            $empty = Join-Path $TestDrive 'empty-path-status'
            New-Item -ItemType Directory -Force -Path $empty | Out-Null
            Remove-Item Env:XAGENT_UV_PATH -ErrorAction SilentlyContinue
            $env:PATH = $empty
            Get-SandboxUvPath | Should -BeNullOrEmpty
            $st = @(InModuleScope SandboxEnv -ArgumentList (,$projs), $index, $envsRoot { param($p,$i,$r) Get-SandboxEnvStatuses -Projects $p -Index $i -EnvsRoot $r -UvPath $null })
            $st[0]['reason'] | Should -Be 'uv-missing'
        } finally {
            $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH']
            $env:PATH = $script:SavedEnv['PATH']
        }
    }
}

Describe 'Get-SandboxEnvEstimate' {
    BeforeAll { $script:FixtureLock = Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'uv.lock') -Raw }
    It 'computes bytes from fixture lock for 3.12' {
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $script:FixtureLock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $projs = Get-SandboxEnvProjects -Repo $repo -Commit $sha
            $index = @{ approved = $null; pythons = @{}; envs = @{}; failed = @{} }
            $xr = Join-Path $TestDrive 'x'
            $st = @(InModuleScope SandboxEnv -ArgumentList (,$projs), $index, $xr, $env:XAGENT_UV_PATH { param($p,$i,$r,$u) Get-SandboxEnvStatuses -Projects $p -Index $i -EnvsRoot $r -UvPath $u })
            $est = InModuleScope SandboxEnv -ArgumentList $repo, $sha, $st, $index { param($rp,$c,$s,$i) Get-SandboxEnvEstimate -Repo $rp -Commit $c -Statuses $s -Index $i }
            $want = [long][math]::Round((2400 + 800) * 2.5) + 100000000
            $est.bytes | Should -Be $want
            $est.interpreters | Should -Be @('3.12')
        } finally { $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH'] }
    }
    It 'returns null bytes for resolve project' {
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'req/requirements.txt' -Content 'x'
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'req/.python-version' -Content '3.12'
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $projs = Get-SandboxEnvProjects -Repo $repo -Commit $sha
            $index = @{ approved = 't'; pythons = @{}; envs = @{}; failed = @{} }
            $xr = Join-Path $TestDrive 'x'
            $st = @(InModuleScope SandboxEnv -ArgumentList (,$projs), $index, $xr, $env:XAGENT_UV_PATH { param($p,$i,$r,$u) Get-SandboxEnvStatuses -Projects $p -Index $i -EnvsRoot $r -UvPath $u })
            $bytes = InModuleScope SandboxEnv -ArgumentList $repo, $sha, $st, $index { param($rp,$c,$s,$i) (Get-SandboxEnvEstimate -Repo $rp -Commit $c -Statuses $s -Index $i).bytes }
            $bytes | Should -BeNullOrEmpty
        } finally { $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH'] }
    }
    It 'lists a source-only package without a size as unknown' {
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $repo = New-SandboxEnvTestRepo
            $lock = $script:FixtureLock + "`n[[package]]`nname = `"src-only`"`nversion = `"1`"`nsource = { registry = `"https://pypi.org/simple`" }`n"
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $lock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $projs = Get-SandboxEnvProjects -Repo $repo -Commit $sha
            $index = @{ approved = $null; pythons = @{}; envs = @{}; failed = @{} }
            $xr = Join-Path $TestDrive 'x'
            $st = @(InModuleScope SandboxEnv -ArgumentList (,$projs), $index, $xr, $env:XAGENT_UV_PATH { param($p,$i,$r,$u) Get-SandboxEnvStatuses -Projects $p -Index $i -EnvsRoot $r -UvPath $u })
            $est = InModuleScope SandboxEnv -ArgumentList $repo, $sha, $st, $index { param($rp,$c,$s,$i) Get-SandboxEnvEstimate -Repo $rp -Commit $c -Statuses $s -Index $i }
            $est.bytes | Should -Not -BeNullOrEmpty
            @($est.unknown) | Should -Be @('src-only')
        } finally { $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH'] }
    }
    It 'counts an sdist size and lists a sized-less Windows wheel as unknown' {
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $repo = New-SandboxEnvTestRepo
            $lock = "version = 1`nrequires-python = `">=3.12`"`n`n[[package]]`nname = `"nosize`"`nversion = `"1`"`nsource = { registry = `"https://example.invalid/simple`" }`nwheels = [`n    { url = `"https://example.invalid/nosize-1-cp312-cp312-win_amd64.whl`", hash = `"sha256:00`" },`n]`n`n[[package]]`nname = `"sdonly`"`nversion = `"1`"`nsource = { registry = `"https://pypi.org/simple`" }`nsdist = { url = `"https://example.invalid/sdonly-1.tar.gz`", hash = `"sha256:00`", size = 4000 }`n"
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $lock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $r = Get-SandboxEnvReport -Repo $repo -Ref $sha
            $r.proposal.estimateBytes | Should -Be ([long][math]::Round(4000 * 2.5) + 100000000)
            @($r.proposal.unknownSize) | Should -Be @('nosize')
            $r.proposal.text | Should -Match 'plus nosize \(size not recorded in uv\.lock\)'
        } finally { $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH'] }
    }

    It 'counts each hash once when two projects share it' {
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $repo = New-SandboxEnvTestRepo
            $toml = '[project]' + [char]10 + 'name="same"' + [char]10 + 'requires-python=">=3.12"'
            foreach ($dir in @('a','b')) {
                Set-SandboxEnvRepoFile -Repo $repo -RelativePath "$dir/uv.lock" -Content $script:FixtureLock
                Set-SandboxEnvRepoFile -Repo $repo -RelativePath "$dir/.python-version" -Content '3.12'
                Set-SandboxEnvRepoFile -Repo $repo -RelativePath "$dir/pyproject.toml" -Content $toml
            }
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $r = Get-SandboxEnvReport -Repo $repo -Ref $sha
            ($r.proposal.envs | Measure-Object).Count | Should -Be 1
            $r.proposal.estimateBytes | Should -Be ([long][math]::Round((2400 + 800) * 2.5) + 100000000)
        } finally { $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH'] }
    }
}

Describe 'Test-SandboxEnvNeedsApproval' {
    It 'is true when approved is null' {
        InModuleScope SandboxEnv { Test-SandboxEnvNeedsApproval -Approved $null -EstimateBytes 100 | Should -Be $true }
    }
    It 'is false with approved and small estimate' {
        InModuleScope SandboxEnv { Test-SandboxEnvNeedsApproval -Approved 't' -EstimateBytes 100 | Should -Be $false }
    }
    It 'is true with approved and estimate over 5 GB' {
        InModuleScope SandboxEnv { Test-SandboxEnvNeedsApproval -Approved 't' -EstimateBytes 5000000001 | Should -Be $true }
    }
    It 'is false with approved and null estimate' {
        InModuleScope SandboxEnv { Test-SandboxEnvNeedsApproval -Approved 't' -EstimateBytes $null | Should -Be $false }
    }
}

Describe 'Get-SandboxEnvReport' {
    BeforeAll { $script:FixtureLock = Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'uv.lock') -Raw }
    It 'returns expected keys and null proposal when ready' {
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $script:FixtureLock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $projs = Get-SandboxEnvProjects -Repo $repo -Commit $sha
            $h = $projs[0].hash
            $name = "py3.12-$($h.Substring(0,12))"
            $envsRoot = Join-Path (Split-Path $repo -Parent) "$(Split-Path $repo -Leaf).xagent\.envs"
            New-Item -ItemType Directory -Force -Path (Join-Path $envsRoot $name 'Scripts') | Out-Null
            [IO.File]::WriteAllText((Join-Path $envsRoot $name 'Scripts\python.exe'), '', [Text.UTF8Encoding]::new($false))
            $json = (@{ version = 1; approved = '2020-01-01'; uv = 'x'; uvVersion = '1'; pythons = @{ '3.12.7' = 'p' }; envs = @{ $h = @{ name = $name; projects = @('.'); kind = 'lock'; python = '3.12.7'; bytes = 250; built = (Get-Date).ToUniversalTime().ToString('o') } }; failed = @{} } | ConvertTo-Json -Compress -Depth 6)
            New-Item -ItemType Directory -Force -Path $envsRoot | Out-Null
            [IO.File]::WriteAllText((Join-Path $envsRoot 'envs.json'), $json, [Text.UTF8Encoding]::new($false))
            $r = Get-SandboxEnvReport -Repo $repo -Ref $sha
            $r.ok | Should -Be $true
            $r.envsBytes | Should -Be 250
            $r.approved | Should -Be $true
            $r.proposal | Should -BeNullOrEmpty
            ($r.PSObject.Properties.Name -contains 'warning') | Should -Be $false
        } finally { $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH'] }
    }
    It 'includes warning only for unreadable envs.json' {
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content ('version = 1' + [char]10 + 'requires-python = ">=3.11"')
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $envsRoot = Join-Path (Split-Path $repo -Parent) "$(Split-Path $repo -Leaf).xagent\.envs"
            New-Item -ItemType Directory -Force -Path $envsRoot | Out-Null
            [IO.File]::WriteAllText((Join-Path $envsRoot 'envs.json'), '{', [Text.UTF8Encoding]::new($false))
            $r = Get-SandboxEnvReport -Repo $repo -Ref $sha
            $r.warning | Should -Be 'envs.json unreadable; rebuilding on -Apply'
        } finally { $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH'] }
    }
    It 'builds proposal text for missing project' {
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $script:FixtureLock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $r = Get-SandboxEnvReport -Repo $repo -Ref $sha
            $r.proposal.text | Should -Match 'Build 1 environment \(\.\)'
            $r.proposal.needsApproval | Should -Be $true
        } finally { $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH'] }
    }
    It 'throws for unknown ref' {
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content ('version = 1' + [char]10 + 'requires-python = ">=3.11"')
            Add-SandboxEnvRepoCommit -Repo $repo | Out-Null
            { Get-SandboxEnvReport -Repo $repo -Ref 'not-a-ref' } | Should -Throw '*sandbox: cannot read not-a-ref in*'
        } finally { $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH'] }
    }
    It 'uses size and time unknown when estimate is null' {
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'only-req/requirements.txt' -Content 'pkg'
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'only-req/.python-version' -Content '3.12'
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $r = Get-SandboxEnvReport -Repo $repo -Ref $sha
            $r.proposal.text | Should -Match 'size and time unknown'
        } finally { $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH'] }
    }
}

Describe 'Test-SandboxWheelMatches' {
    It 'accepts abi3 win_amd64 wheels' {
        InModuleScope SandboxEnv { Test-SandboxWheelMatches -FileName 'pkg-1.0-cp39-abi3-win_amd64.whl' -Request '3.12' | Should -Be $true }
    }
}

Describe 'Invoke-SandboxEnvApply' {
    It 'builds a lock project and copies uv, inputs, and envs.json' {
        $log = Join-Path $TestDrive ("uvlog-{0}.txt" -f [guid]::NewGuid())
        try {
            Enter-SandboxEnvApplyUv -LogFile $log
            $repo = New-SandboxEnvTestRepo
            $uvLock = "version = 1`nrequires-python = `">=3.12`"`n"
            $uvToml = "[[index]]`nurl = `"https://example.invalid/simple`"`nname = `"copied-index`"`n"
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $uvLock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.toml' -Content $uvToml
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content "3.12`n"
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $r = Invoke-SandboxEnvApply -Repo $repo -Ref 'HEAD'
            $discovered = @(Get-SandboxEnvProjects -Repo $repo -Commit $sha)
            $hash = [string]$discovered[0].hash
            $name = "py3.12-$($hash.Substring(0, 12))"
            $envsRoot = Get-SandboxEnvTestRoot -Repo $repo

            $r.built -is [System.Array] | Should -BeTrue
            @($r.built).Count | Should -Be 1
            $r.built[0].env | Should -Be $name
            @($r.built[0].projects) | Should -Be @('.')
            $r.built[0].bytes | Should -BeGreaterThan 0
            $r.built[0].seconds | Should -BeOfType [int]
            @($r.failedNow).Count | Should -Be 0
            @($r.pruned).Count | Should -Be 0
            $r.warning | Should -BeNullOrEmpty

            $raw = [IO.File]::ReadAllText((Join-Path $envsRoot 'envs.json'))
            $raw | Should -Match '"projects"\s*:\s*\['
            $idx = $raw | ConvertFrom-Json -AsHashtable
            $idx.version | Should -Be 1
            $idx.approved | Should -Not -BeNullOrEmpty
            $idx.uvVersion | Should -Be 'uv 0.0.0-fake'
            $idx.uv | Should -Be (Join-Path $envsRoot 'bin\uv.exe')
            $entry = $idx.envs[$hash]
            $entry.name | Should -Be $name
            $entry.projects -is [string] | Should -BeFalse
            @($entry.projects) | Should -Be @('.')
            $entry.python | Should -Be '3.12.99'
            $entry.kind | Should -Be 'lock'
            $entry.bytes | Should -BeGreaterThan 0
            $idx.pythons.ContainsKey('3.12.99') | Should -BeTrue
            [string]$idx.pythons['3.12.99'] | Should -Match 'cpython-3\.12-fake'

            $fakeBytes = [IO.File]::ReadAllBytes($script:FakeUvCmd)
            $copiedBytes = [IO.File]::ReadAllBytes((Join-Path $envsRoot 'bin\uv.exe'))
            [Convert]::ToBase64String($copiedBytes) | Should -Be ([Convert]::ToBase64String($fakeBytes))
            [IO.File]::ReadAllText((Join-Path $envsRoot "$name\Scripts\python.exe")) | Should -Be 'fake'

            $work = Join-Path $envsRoot "work\$name"
            [IO.File]::ReadAllText((Join-Path $work 'uv.lock')) | Should -Be $uvLock
            [IO.File]::ReadAllText((Join-Path $work 'uv.toml')) | Should -Be $uvToml

            $logText = [IO.File]::ReadAllText($log)
            $logText | Should -Match '(?m)^python install 3.12\r?$'
            $logText | Should -Match '(?m)^python find 3.12\r?$'
            $logText | Should -Match '(?m)^sync --frozen --no-install-project --python 3.12.99\r?$'
        } finally { Exit-SandboxEnvApplyUv }
    }

    It 'builds nothing on a second apply and keeps the first approved time' {
        $log = Join-Path $TestDrive ("uvlog-{0}.txt" -f [guid]::NewGuid())
        try {
            Enter-SandboxEnvApplyUv -LogFile $log
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content "version = 1`nrequires-python = `">=3.12`"`n"
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content "3.12`n"
            Add-SandboxEnvRepoCommit -Repo $repo | Out-Null
            $first = Invoke-SandboxEnvApply -Repo $repo -Ref 'HEAD'
            @($first.built).Count | Should -Be 1
            $envsRoot = Get-SandboxEnvTestRoot -Repo $repo
            $approved = ([IO.File]::ReadAllText((Join-Path $envsRoot 'envs.json')) | ConvertFrom-Json -AsHashtable).approved
            $second = Invoke-SandboxEnvApply -Repo $repo -Ref 'HEAD'
            @($second.built).Count | Should -Be 0
            @($second.failedNow).Count | Should -Be 0
            @($second.pruned).Count | Should -Be 0
            $second.built -is [System.Array] | Should -BeTrue
            $second.failedNow -is [System.Array] | Should -BeTrue
            $second.pruned -is [System.Array] | Should -BeTrue
            $second.pruned.Count | Should -Be 0
            $again = ([IO.File]::ReadAllText((Join-Path $envsRoot 'envs.json')) | ConvertFrom-Json -AsHashtable).approved
            $again | Should -Be $approved
        } finally { Exit-SandboxEnvApplyUv }
    }

    It 'locks then syncs a resolve project that has pyproject.toml' {
        $log = Join-Path $TestDrive ("uvlog-{0}.txt" -f [guid]::NewGuid())
        try {
            Enter-SandboxEnvApplyUv -LogFile $log
            $repo = New-SandboxEnvTestRepo
            $py = "[project]`nname = `"app`"`nversion = `"0.1.0`"`nrequires-python = `">=3.12`"`n"
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'app/pyproject.toml' -Content $py
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'app/.python-version' -Content "3.12`n"
            Add-SandboxEnvRepoCommit -Repo $repo | Out-Null
            $r = Invoke-SandboxEnvApply -Repo $repo -Ref 'HEAD'
            @($r.built).Count | Should -Be 1
            $logText = [IO.File]::ReadAllText($log)
            $lockAt = $logText.IndexOf('lock --python 3.12.99')
            $syncAt = $logText.IndexOf('sync --frozen --no-install-project --python 3.12.99')
            $lockAt | Should -BeGreaterThan -1
            $syncAt | Should -BeGreaterThan $lockAt
        } finally { Exit-SandboxEnvApplyUv }
    }

    It 'creates a venv and pip-installs requirements files in name order' {
        $log = Join-Path $TestDrive ("uvlog-{0}.txt" -f [guid]::NewGuid())
        try {
            Enter-SandboxEnvApplyUv -LogFile $log
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'reqproj/requirements.txt' -Content "pkg-z`n"
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'reqproj/requirements-b.txt' -Content "pkg-b`n"
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'reqproj/requirements-a.txt' -Content "pkg-a`n"
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'reqproj/.python-version' -Content "3.12`n"
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $r = Invoke-SandboxEnvApply -Repo $repo -Ref 'HEAD'
            @($r.built).Count | Should -Be 1
            $hash = [string](@(Get-SandboxEnvProjects -Repo $repo -Commit $sha) | Where-Object { $_.project -eq 'reqproj' }).hash
            $name = "py3.12-$($hash.Substring(0, 12))"
            $envsRoot = Get-SandboxEnvTestRoot -Repo $repo
            [IO.File]::ReadAllText((Join-Path $envsRoot "$name\Scripts\python.exe")) | Should -Be 'fake'
            $logText = [IO.File]::ReadAllText($log)
            $venvAt = $logText.IndexOf('venv --python ')
            $pipA = $logText.IndexOf('requirements-a.txt')
            $pipB = $logText.IndexOf('requirements-b.txt')
            $pipT = $logText.IndexOf('requirements.txt')
            $venvAt | Should -BeGreaterThan -1
            $pipA | Should -BeGreaterThan $venvAt
            $pipB | Should -BeGreaterThan $pipA
            $pipT | Should -BeGreaterThan $pipB
            @($logText -split "`n" | Where-Object { $_ -like 'pip install*' }).Count | Should -Be 3
        } finally { Exit-SandboxEnvApplyUv }
    }

    It 'writes a pth for build-system projects and skips projects without one' {
        $log = Join-Path $TestDrive ("uvlog-{0}.txt" -f [guid]::NewGuid())
        try {
            Enter-SandboxEnvApplyUv -LogFile $log
            $repo = New-SandboxEnvTestRepo
            $withBuild = "[project]`nname = `"app`"`nversion = `"0.1.0`"`nrequires-python = `">=3.12`"`n`n[build-system]`nrequires = [`"hatchling`"]`nbuild-backend = `"hatchling.build`"`n"
            $noBuild = "[project]`nname = `"plain`"`nversion = `"0.1.0`"`nrequires-python = `">=3.12`"`n"
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content "3.12`n"
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'pyproject.toml' -Content $withBuild
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'src/app.py' -Content "x = 1`n"
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'pkg/pyproject.toml' -Content ($withBuild.Replace('name = "app"', 'name = "pkgapp"'))
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'pkg/src/app.py' -Content "y = 1`n"
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'pkg/.python-version' -Content "3.12`n"
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'plain/pyproject.toml' -Content $noBuild
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'plain/.python-version' -Content "3.12`n"
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $r = Invoke-SandboxEnvApply -Repo $repo -Ref 'HEAD'
            @($r.built).Count | Should -Be 3
            $envsRoot = Get-SandboxEnvTestRoot -Repo $repo
            $rootLine = "import os, sys; w = os.environ.get('XAGENT_WORKTREE'); w and sys.path.append(os.path.join(w, r'src'))"
            $pkgLine = "import os, sys; w = os.environ.get('XAGENT_WORKTREE'); w and sys.path.append(os.path.join(w, r'pkg\src'))"
            foreach ($p in @(Get-SandboxEnvProjects -Repo $repo -Commit $sha)) {
                $name = "py3.12-$($p.hash.Substring(0, 12))"
                $pth = Join-Path $envsRoot "$name\Lib\site-packages\_xagent_1.pth"
                if ($p.project -eq '.') {
                    [IO.File]::ReadAllText($pth).Trim() | Should -Be $rootLine
                    [IO.File]::ReadAllText($pth) | Should -Be ($rootLine + "`n")
                } elseif ($p.project -eq 'pkg') {
                    [IO.File]::ReadAllText($pth).Trim() | Should -Be $pkgLine
                } elseif ($p.project -eq 'plain') {
                    Test-Path -LiteralPath $pth | Should -BeFalse
                    @(Get-ChildItem -LiteralPath (Join-Path $envsRoot "$name\Lib\site-packages") -Filter '_xagent_*.pth' -ErrorAction SilentlyContinue).Count | Should -Be 0
                }
            }
        } finally { Exit-SandboxEnvApplyUv }
    }

    It 'records a failed build and a later apply clears it' {
        $log = Join-Path $TestDrive ("uvlog-{0}.txt" -f [guid]::NewGuid())
        try {
            Enter-SandboxEnvApplyUv -LogFile $log
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content "version = 1`nrequires-python = `">=3.12`"`n"
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content "3.12`n"
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $env:FAKE_UV_FAIL = 'sync'
            $r = Invoke-SandboxEnvApply -Repo $repo -Ref 'HEAD'
            $hash = [string](@(Get-SandboxEnvProjects -Repo $repo -Commit $sha))[0].hash
            $name = "py3.12-$($hash.Substring(0, 12))"
            $envsRoot = Get-SandboxEnvTestRoot -Repo $repo
            @($r.failedNow).Count | Should -Be 1
            $r.failedNow -is [System.Array] | Should -BeTrue
            $r.failedNow[0].env | Should -Be $name
            $r.failedNow[0].error | Should -Match 'fake failure'
            @($r.built).Count | Should -Be 0
            Test-Path -LiteralPath (Join-Path $envsRoot $name) | Should -BeFalse
            $idx = [IO.File]::ReadAllText((Join-Path $envsRoot 'envs.json')) | ConvertFrom-Json -AsHashtable
            $idx.approved | Should -BeNullOrEmpty
            $idx.failed[$hash].error | Should -Be $r.failedNow[0].error
            $idx.failed[$hash].error | Should -Match 'fake failure'

            Remove-Item Env:FAKE_UV_FAIL
            $r2 = Invoke-SandboxEnvApply -Repo $repo -Ref 'HEAD'
            @($r2.built).Count | Should -Be 1
            @($r2.failedNow).Count | Should -Be 0
            $idx2 = [IO.File]::ReadAllText((Join-Path $envsRoot 'envs.json')) | ConvertFrom-Json -AsHashtable
            $idx2.failed.ContainsKey($hash) | Should -BeFalse
            $idx2.envs.ContainsKey($hash) | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $envsRoot "$name\Scripts\python.exe") | Should -BeTrue
            $idx2.approved | Should -Not -BeNullOrEmpty
        } finally { Exit-SandboxEnvApplyUv }
    }

    It 'reports name-clash and leaves the other environment folder untouched' {
        $log = Join-Path $TestDrive ("uvlog-{0}.txt" -f [guid]::NewGuid())
        try {
            Enter-SandboxEnvApplyUv -LogFile $log
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content "version = 1`nrequires-python = `">=3.12`"`n"
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content "3.12`n"
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $hash = [string](@(Get-SandboxEnvProjects -Repo $repo -Commit $sha))[0].hash
            $name = "py3.12-$($hash.Substring(0, 12))"
            $other = 'b' * 64
            $envsRoot = Get-SandboxEnvTestRoot -Repo $repo
            $envDir = Join-Path $envsRoot $name
            New-Item -ItemType Directory -Force -Path $envDir | Out-Null
            [IO.File]::WriteAllText((Join-Path $envDir 'marker.txt'), 'keep-me', [Text.UTF8Encoding]::new($false))
            $payload = [ordered]@{
                version   = 1
                approved  = $null
                uv        = $null
                uvVersion = $null
                pythons   = @{}
                envs      = @{ $other = [ordered]@{ name = $name; projects = @('other'); kind = 'lock'; python = '3.12'; bytes = 1; built = (Get-Date).ToUniversalTime().ToString('o') } }
                failed    = @{}
            }
            New-Item -ItemType Directory -Force -Path $envsRoot | Out-Null
            [IO.File]::WriteAllText((Join-Path $envsRoot 'envs.json'), (ConvertTo-Json -InputObject $payload -Depth 8), [Text.UTF8Encoding]::new($false))
            $r = Invoke-SandboxEnvApply -Repo $repo -Ref 'HEAD'
            @($r.failedNow).Count | Should -Be 1
            $r.failedNow[0].error | Should -Be 'name-clash'
            @($r.built).Count | Should -Be 0
            [IO.File]::ReadAllText((Join-Path $envDir 'marker.txt')) | Should -Be 'keep-me'
            $idx = [IO.File]::ReadAllText((Join-Path $envsRoot 'envs.json')) | ConvertFrom-Json -AsHashtable
            $idx.failed[$hash].error | Should -Be 'name-clash'
            $r.failedNow[0].error | Should -Be $idx.failed[$hash].error
            $idx.envs.ContainsKey($other) | Should -BeTrue
            $idx.approved | Should -BeNullOrEmpty
        } finally { Exit-SandboxEnvApplyUv }
    }

    It 'rebuilds one project and keeps the first approved time' {
        $log = Join-Path $TestDrive ("uvlog-{0}.txt" -f [guid]::NewGuid())
        try {
            Enter-SandboxEnvApplyUv -LogFile $log
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content "version = 1`nrequires-python = `">=3.12`"`n"
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content "3.12`n"
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $r1 = Invoke-SandboxEnvApply -Repo $repo -Ref 'HEAD'
            @($r1.built).Count | Should -Be 1
            $hash = [string](@(Get-SandboxEnvProjects -Repo $repo -Commit $sha))[0].hash
            $name = "py3.12-$($hash.Substring(0, 12))"
            $envsRoot = Get-SandboxEnvTestRoot -Repo $repo
            $approved = ([IO.File]::ReadAllText((Join-Path $envsRoot 'envs.json')) | ConvertFrom-Json -AsHashtable).approved
            [IO.File]::WriteAllText((Join-Path $envsRoot "$name\marker.txt"), 'old', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $envsRoot "work\$name\marker.txt"), 'old-work', [Text.UTF8Encoding]::new($false))
            New-Item -ItemType Directory -Force -Path (Join-Path $envsRoot 'linked') | Out-Null
            [IO.File]::WriteAllText((Join-Path $envsRoot "linked\$name"), 'stamp', [Text.UTF8Encoding]::new($false))
            $r2 = Invoke-SandboxEnvApply -Repo $repo -Ref 'HEAD' -Rebuild '.'
            @($r2.built).Count | Should -Be 1
            $r2.built[0].env | Should -Be $name
            Test-Path -LiteralPath (Join-Path $envsRoot "$name\marker.txt") | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $envsRoot "work\$name\marker.txt") | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $envsRoot "linked\$name") | Should -BeFalse
            [IO.File]::ReadAllText((Join-Path $envsRoot "$name\Scripts\python.exe")) | Should -Be 'fake'
            $approved2 = ([IO.File]::ReadAllText((Join-Path $envsRoot 'envs.json')) | ConvertFrom-Json -AsHashtable).approved
            $approved2 | Should -Be $approved
        } finally { Exit-SandboxEnvApplyUv }
    }

    It 'throws for an unknown or unsupported rebuild project' {
        $log = Join-Path $TestDrive ("uvlog-{0}.txt" -f [guid]::NewGuid())
        try {
            Enter-SandboxEnvApplyUv -LogFile $log
            $missing = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $missing -RelativePath 'uv.lock' -Content "version = 1`nrequires-python = `">=3.12`"`n"
            Set-SandboxEnvRepoFile -Repo $missing -RelativePath '.python-version' -Content "3.12`n"
            Add-SandboxEnvRepoCommit -Repo $missing | Out-Null
            { Invoke-SandboxEnvApply -Repo $missing -Ref 'HEAD' -Rebuild 'no-such' } | Should -Throw '*no project no-such at HEAD*'

            $wsRepo = New-SandboxEnvTestRepo
            $ws = "[tool.uv.workspace]`nmembers = [`"x`"]`n[project]`nrequires-python = `">=3.11`"`n"
            Set-SandboxEnvRepoFile -Repo $wsRepo -RelativePath 'ws/pyproject.toml' -Content $ws
            Add-SandboxEnvRepoCommit -Repo $wsRepo | Out-Null
            { Invoke-SandboxEnvApply -Repo $wsRepo -Ref 'HEAD' -Rebuild 'ws' } | Should -Throw '*ws is unsupported (workspace)*'
        } finally { Exit-SandboxEnvApplyUv }
    }

    It 'warns and writes nothing when uv is missing' {
        $repo = New-SandboxEnvTestRepo
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content "version = 1`nrequires-python = `">=3.12`"`n"
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content "3.12`n"
        Add-SandboxEnvRepoCommit -Repo $repo | Out-Null
        $empty = Join-Path $TestDrive 'empty-uv-path'
        New-Item -ItemType Directory -Force -Path $empty | Out-Null
        try {
            Remove-Item Env:XAGENT_UV_PATH -ErrorAction SilentlyContinue
            $env:PATH = $empty
            $r = Invoke-SandboxEnvApply -Repo $repo -Ref 'HEAD'
            $r.warning | Should -Be 'uv not found; nothing built'
            @($r.built).Count | Should -Be 0
            @($r.failedNow).Count | Should -Be 0
            @($r.pruned).Count | Should -Be 0
            $r.built -is [System.Array] | Should -BeTrue
            Test-Path -LiteralPath (Get-SandboxEnvTestRoot -Repo $repo) | Should -BeFalse
        } finally { Exit-SandboxEnvApplyUv }
    }
}

Describe 'Invoke-SandboxEnvApply prune' {
    BeforeAll { $script:FixtureLock = Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'uv.lock') -Raw }
    It 'prunes a stale environment with old stamp and built, removes stamp and orphan python' {
        $log = Join-Path $TestDrive ("uvlog-{0}.txt" -f [guid]::NewGuid())
        try {
            Enter-SandboxEnvApplyUv -LogFile $log
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $script:FixtureLock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            Invoke-SandboxEnvApply -Repo $repo -Ref HEAD | Out-Null
            $envsRoot = Get-SandboxEnvTestRoot -Repo $repo
            $proj = Get-SandboxEnvProjects -Repo $repo -Commit $sha
            $oldHash = [string]$proj[0].hash
            $oldName = "py3.12-$($oldHash.Substring(0,12))"
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content ($script:FixtureLock + "`n")
            Add-SandboxEnvRepoCommit -Repo $repo -Message 'bump lock' | Out-Null
            $idxPath = Join-Path $envsRoot 'envs.json'
            $idx = [IO.File]::ReadAllText($idxPath) | ConvertFrom-Json -AsHashtable
            $idx.envs[$oldHash].built = ([DateTime]::UtcNow.AddDays(-15)).ToString('o')
            [IO.File]::WriteAllText($idxPath, (ConvertTo-Json -InputObject $idx -Depth 8), [Text.UTF8Encoding]::new($false))
            New-Item -ItemType Directory -Force -Path (Join-Path $envsRoot 'linked') | Out-Null
            Set-EnvStampAge -StampPath (Join-Path $envsRoot "linked\$oldName") -Days 15
            $orphanPy = Join-Path $envsRoot 'python\orphan-cpython'
            New-Item -ItemType Directory -Force -Path $orphanPy | Out-Null
            $idx = [IO.File]::ReadAllText($idxPath) | ConvertFrom-Json -AsHashtable
            $idx.pythons['9.99.99'] = $orphanPy
            [IO.File]::WriteAllText($idxPath, (ConvertTo-Json -InputObject $idx -Depth 8), [Text.UTF8Encoding]::new($false))
            $r = Invoke-SandboxEnvApply -Repo $repo -Ref HEAD
            @($r.pruned | Where-Object { $_.env -ceq $oldName }).Count | Should -Be 1
            $r.pruned | Where-Object { $_.env -ceq $oldName } | ForEach-Object { $_.bytes | Should -BeGreaterThan 0 }
            Test-Path -LiteralPath (Join-Path $envsRoot $oldName) | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $envsRoot "linked\$oldName") | Should -BeFalse
            Test-Path -LiteralPath $orphanPy | Should -BeFalse
            ($idx = [IO.File]::ReadAllText($idxPath) | ConvertFrom-Json -AsHashtable).pythons.ContainsKey('9.99.99') | Should -BeFalse
        } finally { Exit-SandboxEnvApplyUv }
    }
    It 'keeps stale environment with a fresh linked stamp' {
        $log = Join-Path $TestDrive ("uvlog-{0}.txt" -f [guid]::NewGuid())
        try {
            Enter-SandboxEnvApplyUv -LogFile $log
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $script:FixtureLock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            Invoke-SandboxEnvApply -Repo $repo -Ref HEAD | Out-Null
            $envsRoot = Get-SandboxEnvTestRoot -Repo $repo
            $oldHash = [string](Get-SandboxEnvProjects -Repo $repo -Commit $sha)[0].hash
            $oldName = "py3.12-$($oldHash.Substring(0,12))"
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content ($script:FixtureLock + ' ')
            Add-SandboxEnvRepoCommit -Repo $repo | Out-Null
            $idxPath = Join-Path $envsRoot 'envs.json'
            $idx = [IO.File]::ReadAllText($idxPath) | ConvertFrom-Json -AsHashtable
            $idx.envs[$oldHash].built = ([DateTime]::UtcNow.AddDays(-15)).ToString('o')
            [IO.File]::WriteAllText($idxPath, (ConvertTo-Json -InputObject $idx -Depth 8), [Text.UTF8Encoding]::new($false))
            New-Item -ItemType File -Force -Path (Join-Path $envsRoot "linked\$oldName") | Out-Null
            [IO.File]::WriteAllText((Join-Path $envsRoot "$oldName\keep.txt"), 'stay', [Text.UTF8Encoding]::new($false))
            $r = Invoke-SandboxEnvApply -Repo $repo -Ref HEAD
            @($r.pruned | Where-Object { $_.env -ceq $oldName }).Count | Should -Be 0
            [IO.File]::ReadAllText((Join-Path $envsRoot "$oldName\keep.txt")) | Should -Be 'stay'
        } finally { Exit-SandboxEnvApplyUv }
    }
    It 'keeps never-linked environment built today and removes stale failed records' {
        $log = Join-Path $TestDrive ("uvlog-{0}.txt" -f [guid]::NewGuid())
        try {
            Enter-SandboxEnvApplyUv -LogFile $log
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $script:FixtureLock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            Invoke-SandboxEnvApply -Repo $repo -Ref HEAD | Out-Null
            $envsRoot = Get-SandboxEnvTestRoot -Repo $repo
            $oldHash = [string](Get-SandboxEnvProjects -Repo $repo -Commit $sha)[0].hash
            $oldName = "py3.12-$($oldHash.Substring(0,12))"
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content ($script:FixtureLock + 'x')
            Add-SandboxEnvRepoCommit -Repo $repo | Out-Null
            $idxPath = Join-Path $envsRoot 'envs.json'
            $idx = [IO.File]::ReadAllText($idxPath) | ConvertFrom-Json -AsHashtable
            $idx.failed[$oldHash] = @{ at = 't'; error = 'old' }
            [IO.File]::WriteAllText($idxPath, (ConvertTo-Json -InputObject $idx -Depth 8), [Text.UTF8Encoding]::new($false))
            $r = Invoke-SandboxEnvApply -Repo $repo -Ref HEAD
            @($r.pruned | Where-Object { $_.env -ceq $oldName }).Count | Should -Be 0
            Test-Path -LiteralPath (Join-Path $envsRoot $oldName) | Should -BeTrue
            ([IO.File]::ReadAllText($idxPath) | ConvertFrom-Json -AsHashtable).failed.ContainsKey($oldHash) | Should -BeFalse
        } finally { Exit-SandboxEnvApplyUv }
    }
    It 'treats unparseable built with no stamp as old enough to prune' {
        $log = Join-Path $TestDrive ("uvlog-{0}.txt" -f [guid]::NewGuid())
        try {
            Enter-SandboxEnvApplyUv -LogFile $log
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $script:FixtureLock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            Invoke-SandboxEnvApply -Repo $repo -Ref HEAD | Out-Null
            $envsRoot = Get-SandboxEnvTestRoot -Repo $repo
            $oldHash = [string](Get-SandboxEnvProjects -Repo $repo -Commit $sha)[0].hash
            $oldName = "py3.12-$($oldHash.Substring(0,12))"
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content ($script:FixtureLock + 'z')
            Add-SandboxEnvRepoCommit -Repo $repo | Out-Null
            $idxPath = Join-Path $envsRoot 'envs.json'
            $idx = [IO.File]::ReadAllText($idxPath) | ConvertFrom-Json -AsHashtable
            $idx.envs[$oldHash].built = 'not-a-date'
            [IO.File]::WriteAllText($idxPath, (ConvertTo-Json -InputObject $idx -Depth 8), [Text.UTF8Encoding]::new($false))
            $r = Invoke-SandboxEnvApply -Repo $repo -Ref HEAD
            @($r.pruned | Where-Object { $_.env -ceq $oldName }).Count | Should -Be 1
        } finally { Exit-SandboxEnvApplyUv }
    }
    It 'keeps current environment even when linked stamp is old' {
        $log = Join-Path $TestDrive ("uvlog-{0}.txt" -f [guid]::NewGuid())
        try {
            Enter-SandboxEnvApplyUv -LogFile $log
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $script:FixtureLock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
            Add-SandboxEnvRepoCommit -Repo $repo | Out-Null
            Invoke-SandboxEnvApply -Repo $repo -Ref HEAD | Out-Null
            $envsRoot = Get-SandboxEnvTestRoot -Repo $repo
            $sha = (git -C $repo rev-parse HEAD).Trim()
            $hash = [string](Get-SandboxEnvProjects -Repo $repo -Commit $sha)[0].hash
            $name = "py3.12-$($hash.Substring(0,12))"
            New-Item -ItemType File -Force -Path (Join-Path $envsRoot "linked\$name") | Out-Null
            Set-EnvStampAge -StampPath (Join-Path $envsRoot "linked\$name") -Days 15
            [IO.File]::WriteAllText((Join-Path $envsRoot "$name\stay.txt"), 'ok', [Text.UTF8Encoding]::new($false))
            $r = Invoke-SandboxEnvApply -Repo $repo -Ref HEAD
            @($r.pruned | Where-Object { $_.env -ceq $name }).Count | Should -Be 0
            [IO.File]::ReadAllText((Join-Path $envsRoot "$name\stay.txt")) | Should -Be 'ok'
        } finally { Exit-SandboxEnvApplyUv }
    }
}

Describe 'Test-SandboxEnvReady' {
    BeforeAll { $script:FixtureLock = Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'uv.lock') -Raw }
    It 'is ready for a repo without Python projects' {
        $repo = New-SandboxEnvTestRepo
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'README.md' -Content 'n'
        $sha = Add-SandboxEnvRepoCommit -Repo $repo
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $r = Test-SandboxEnvReady -Repo $repo -Commit $sha
            $r.ready | Should -Be $true
            $r.message | Should -BeNullOrEmpty
        } finally { $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH'] }
    }
    It 'blocks missing before apply and is ready after' {
        $log = Join-Path $TestDrive ("uvlog-{0}.txt" -f [guid]::NewGuid())
        try {
            Enter-SandboxEnvApplyUv -LogFile $log
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $script:FixtureLock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $before = Test-SandboxEnvReady -Repo $repo -Commit $sha
            $before.ready | Should -Be $false
            $before.message | Should -Match '^sandbox: environment not ready: \. \(missing\); run -SandboxEnv -Repo'
            $before.message | Should -Match 'Build 1 environment'
            Invoke-SandboxEnvApply -Repo $repo -Ref HEAD | Out-Null
            $after = Test-SandboxEnvReady -Repo $repo -Commit $sha
            $after.ready | Should -Be $true
            $after.message | Should -BeNullOrEmpty
        } finally { Exit-SandboxEnvApplyUv }
    }
    It 'blocks ready projects when envs uv copy is missing' {
        $log = Join-Path $TestDrive ("uvlog-{0}.txt" -f [guid]::NewGuid())
        try {
            Enter-SandboxEnvApplyUv -LogFile $log
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $script:FixtureLock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            Invoke-SandboxEnvApply -Repo $repo -Ref HEAD | Out-Null
            $uvExe = Join-Path (Get-SandboxEnvTestRoot -Repo $repo) 'bin\uv.exe'
            Remove-Item -LiteralPath $uvExe -Force
            $r = Test-SandboxEnvReady -Repo $repo -Commit $sha
            $r.ready | Should -Be $false
            ($r.projects | Where-Object { $_.status -ceq 'uv-copy-missing' }).Count | Should -BeGreaterThan 0
        } finally { Exit-SandboxEnvApplyUv }
    }
    It 'does not block workspace projects' {
        try {
            $env:XAGENT_UV_PATH = $script:FakeUvCmd
            $repo = New-SandboxEnvTestRepo
            $ws = '[tool.uv.workspace]' + [char]10 + 'members=["x"]' + [char]10 + '[project]' + [char]10 + 'requires-python=">=3.11"'
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'ws/pyproject.toml' -Content $ws
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            $r = Test-SandboxEnvReady -Repo $repo -Commit $sha
            $r.ready | Should -Be $true
        } finally { $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH'] }
    }
    It 'reports uv-missing when uv is absent' {
        $repo = New-SandboxEnvTestRepo
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $script:FixtureLock
        Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
        $sha = Add-SandboxEnvRepoCommit -Repo $repo
        $empty = Join-Path $TestDrive 'empty-uv-ready'
        New-Item -ItemType Directory -Force -Path $empty | Out-Null
        try {
            Remove-Item Env:XAGENT_UV_PATH -ErrorAction SilentlyContinue
            $gitDir = Split-Path (Get-Command git -ErrorAction Stop).Source -Parent
            $env:PATH = "$gitDir;$empty"
            $r = Test-SandboxEnvReady -Repo $repo -Commit $sha
            $r.ready | Should -Be $false
            ($r.projects | Where-Object { $_.reason -ceq 'uv-missing' }).Count | Should -BeGreaterThan 0
            $r.message | Should -Match '\-Apply\.$'
        } finally {
            $env:XAGENT_UV_PATH = $script:SavedEnv['XAGENT_UV_PATH']
            $env:PATH = $script:SavedEnv['PATH']
        }
    }
}

Describe 'Add-SandboxEnvLinks' {
    BeforeAll { $script:FixtureLock = Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'uv.lock') -Raw }
    It 'creates junctions and returns paths, suffix, and env vars' {
        $log = Join-Path $TestDrive ("uvlog-{0}.txt" -f [guid]::NewGuid())
        try {
            Enter-SandboxEnvApplyUv -LogFile $log
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $script:FixtureLock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            Invoke-SandboxEnvApply -Repo $repo -Ref HEAD | Out-Null
            $ready = Test-SandboxEnvReady -Repo $repo -Commit $sha
            $wt = Join-Path $TestDrive ("wt-{0}" -f [guid]::NewGuid())
            Copy-RepoToWorktree -Repo $repo -Dest $wt
            try {
                $links = Add-SandboxEnvLinks -Repo $repo -Worktree $wt -Projects $ready.projects
            } catch {
                Set-ItResult -Skipped -Because 'cannot create a junction here'
                return
            }
            $envsRoot = Get-SandboxEnvTestRoot -Repo $repo
            $venv = Join-Path $wt '.venv'
            (Get-Item -LiteralPath $venv -Force).LinkType -ceq 'Junction' | Should -Be $true
            Test-Path -LiteralPath (Join-Path $envsRoot 'linked') | Should -BeTrue
            @($links.envPaths).Count | Should -BeGreaterOrEqual 2
            $links.pathSuffix | Should -Be @("$envsRoot\bin")
            $links.extraEnv.UV_FROZEN | Should -Be '1'
            $links.extraEnv.UV_NO_SYNC | Should -Be '1'
            $links.extraEnv.UV_PYTHON_DOWNLOADS | Should -Be 'never'
            $links2 = Add-SandboxEnvLinks -Repo $repo -Worktree $wt -Projects $ready.projects
            (Get-Item -LiteralPath $venv -Force).LinkType -ceq 'Junction' | Should -Be $true
            $links2.envPaths.Count | Should -BeGreaterOrEqual 2
        } finally { Exit-SandboxEnvApplyUv }
    }
    It 'returns empty outputs when no ready projects' {
        $repo = New-SandboxEnvTestRepo
        $wt = Join-Path $TestDrive 'plain-wt'
        New-Item -ItemType Directory -Force -Path $wt | Out-Null
        $r = Add-SandboxEnvLinks -Repo $repo -Worktree $wt -Projects @([ordered]@{ project='.'; status='missing' })
        @($r.envPaths).Count | Should -Be 0
        @($r.pathSuffix).Count | Should -Be 0
        $r.extraEnv.Count | Should -Be 0
        @($r.notes).Count | Should -Be 0
    }
    It 'leaves a real .venv folder and adds a note' {
        $log = Join-Path $TestDrive ("uvlog-{0}.txt" -f [guid]::NewGuid())
        try {
            Enter-SandboxEnvApplyUv -LogFile $log
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $script:FixtureLock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            Invoke-SandboxEnvApply -Repo $repo -Ref HEAD | Out-Null
            $ready = Test-SandboxEnvReady -Repo $repo -Commit $sha
            $wt = Join-Path $TestDrive ("wt-real-{0}" -f [guid]::NewGuid())
            Copy-RepoToWorktree -Repo $repo -Dest $wt
            New-Item -ItemType Directory -Force -Path (Join-Path $wt '.venv') | Out-Null
            try { $links = Add-SandboxEnvLinks -Repo $repo -Worktree $wt -Projects $ready.projects } catch { Set-ItResult -Skipped -Because 'cannot create a junction here'; return }
            @($links.notes | Where-Object { $_ -like '*.venv in .*real folder*' }).Count | Should -BeGreaterThan 0
            (Get-Item -LiteralPath (Join-Path $wt '.venv')).LinkType | Should -BeNullOrEmpty
        } finally { Exit-SandboxEnvApplyUv }
    }
}

Describe 'Remove-SandboxEnvLinks' {
    BeforeAll { $script:FixtureLock = Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'uv.lock') -Raw }
    It 'removes junctions and preserves environment data' {
        $log = Join-Path $TestDrive ("uvlog-{0}.txt" -f [guid]::NewGuid())
        try {
            Enter-SandboxEnvApplyUv -LogFile $log
            $repo = New-SandboxEnvTestRepo
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $script:FixtureLock
            Set-SandboxEnvRepoFile -RelativePath '.python-version' -Content '3.12' -Repo $repo
            $sha = Add-SandboxEnvRepoCommit -Repo $repo
            Invoke-SandboxEnvApply -Repo $repo -Ref HEAD | Out-Null
            $ready = Test-SandboxEnvReady -Repo $repo -Commit $sha
            $wt = Join-Path $TestDrive ("wt-rm-{0}" -f [guid]::NewGuid())
            Copy-RepoToWorktree -Repo $repo -Dest $wt
            try { Add-SandboxEnvLinks -Repo $repo -Worktree $wt -Projects $ready.projects | Out-Null } catch { Set-ItResult -Skipped -Because 'cannot create a junction here'; return }
            $envsRoot = Get-SandboxEnvTestRoot -Repo $repo
            $discovered = @(Get-SandboxEnvProjects -Repo $repo -Commit $sha)[0]
            $envName = "py3.12-$(([string]$discovered.hash).Substring(0,12))"
            $marker = Join-Path $envsRoot "$envName\Scripts\python.exe"
            Test-Path -LiteralPath $marker | Should -BeTrue
            $n = Remove-SandboxEnvLinks -Worktree $wt
            $n | Should -BeGreaterOrEqual 1
            Test-Path -LiteralPath (Join-Path $wt '.venv') | Should -BeFalse
            Test-Path -LiteralPath $marker | Should -BeTrue
        } finally { Exit-SandboxEnvApplyUv }
    }
    It 'leaves real .venv folders and returns count on plain folder' {
        $folder = Join-Path $TestDrive ("plain-{0}" -f [guid]::NewGuid())
        $repo = New-SandboxEnvTestRepo
        $log = Join-Path $TestDrive ("uvlog-{0}.txt" -f [guid]::NewGuid())
        try {
            Enter-SandboxEnvApplyUv -LogFile $log
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath 'uv.lock' -Content $script:FixtureLock
            Set-SandboxEnvRepoFile -Repo $repo -RelativePath '.python-version' -Content '3.12'
            Add-SandboxEnvRepoCommit -Repo $repo | Out-Null
            Invoke-SandboxEnvApply -Repo $repo -Ref 'HEAD' | Out-Null
            $envsRoot = Get-SandboxEnvTestRoot -Repo $repo
            $name = ([IO.File]::ReadAllText((Join-Path $envsRoot 'envs.json')) | ConvertFrom-Json).envs.PSObject.Properties | Select-Object -First 1 | ForEach-Object { $_.Value.name }
            New-Item -ItemType Directory -Force -Path $folder | Out-Null
            try { $null = New-Item -ItemType Junction -Path (Join-Path $folder '.venv') -Target (Join-Path $envsRoot $name) } catch { Set-ItResult -Skipped -Because 'cannot create a junction here'; return }
            New-Item -ItemType Directory -Force -Path (Join-Path $folder 'real\.venv') | Out-Null
            $count = Remove-SandboxEnvLinks -Worktree $folder
            $count | Should -Be 1
            Test-Path -LiteralPath (Join-Path $folder 'real\.venv') | Should -BeTrue
        } finally { Exit-SandboxEnvApplyUv }
    }
}

Describe 'Remove-SandboxEnvLinks dangling junction' {
    It 'removes a .venv junction whose target no longer exists' {
        $wt = Join-Path $TestDrive ('dangle-wt-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        $target = Join-Path $TestDrive ('dangle-target-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $wt, $target | Out-Null
        $link = Join-Path $wt '.venv'
        try {
            New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null
        } catch {
            Set-ItResult -Skipped -Because 'cannot create a junction here'
            return
        }
        Remove-Item -LiteralPath $target -Recurse -Force
        (Remove-SandboxEnvLinks -Worktree $wt) | Should -Be 1
        $null -eq (Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue) | Should -BeTrue
    }
}
