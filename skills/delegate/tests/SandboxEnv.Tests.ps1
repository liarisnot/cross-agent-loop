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
    foreach ($name in @('XAGENT_SANDBOX_ROOT','XAGENT_CURSOR_ROOT','XAGENT_UV_PATH','FAKE_UV_FAIL','FAKE_UV_LOG','UV_PYTHON_INSTALL_DIR','UV_PROJECT_ENVIRONMENT','PATH')) {
        $script:SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    $env:XAGENT_SANDBOX_ROOT = Join-Path $TestDrive 'sbx-root'
    $env:XAGENT_CURSOR_ROOT = Join-Path $TestDrive 'cursor-root'
    New-Item -ItemType Directory -Force -Path $env:XAGENT_SANDBOX_ROOT, $env:XAGENT_CURSOR_ROOT | Out-Null
    Import-Module $script:ModulePath -Force
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
            $index.envs[$h] = @{ name = $name; projects = @('.'); kind = 'lock'; python = '3.12'; bytes = 10; built = 't' }
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
            $index.envs[$h] = @{ name = $name; projects = @('.'); kind = 'lock'; python = '3.12'; bytes = 10; built = 't' }
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
            $index.envs['otherhash00000000000000000000000000000000000000000000000'] = @{ name = 'py3.12-deadbeef0000'; projects = @('.'); kind = 'lock'; python = '3.12'; bytes = 1; built = 't' }
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
            $json = (@{ version = 1; approved = '2020-01-01'; uv = 'x'; uvVersion = '1'; pythons = @{ '3.12.7' = 'p' }; envs = @{ $h = @{ name = $name; projects = @('.'); kind = 'lock'; python = '3.12.7'; bytes = 250; built = 't' } }; failed = @{} } | ConvertTo-Json -Compress -Depth 6)
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
