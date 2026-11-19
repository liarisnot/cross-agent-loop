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
