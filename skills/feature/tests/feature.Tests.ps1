#Requires -Modules @{ModuleName='Pester';ModuleVersion='5.5'}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:SchemaDir = Join-Path $PSScriptRoot '../schemas'
    $script:SamplesDir = Join-Path $PSScriptRoot 'fixtures/samples'
    $script:TemplatesDir = Join-Path $PSScriptRoot '../templates'
    $script:RunsJsonl = Join-Path $PSScriptRoot 'fixtures/runs.jsonl'
}

Describe 'schemas' {
    $schemaFiles = @(
        'feature.schema.json',
        'plan.schema.json',
        'state.schema.json',
        'status.schema.json',
        'schedule.schema.json',
        'verify.schema.json'
    )

    It 'schema file <_> is valid JSON and declares draft 2020-12' -ForEach $schemaFiles {
        $path = Join-Path $script:SchemaDir $_
        $text = Get-Content -Raw -LiteralPath $path
        { $text | ConvertFrom-Json } | Should -Not -Throw
        $obj = $text | ConvertFrom-Json
        $obj.'$schema' | Should -Be 'https://json-schema.org/draft/2020-12/schema'
        $obj.title | Should -Not -BeNullOrEmpty
    }

    $validSamples = @(
        'feature.json',
        'plan.json',
        'state.json',
        'status-selected.json',
        'status-none.json',
        'schedule.json',
        'verify.json'
    )

    It 'valid sample <_> passes its schema' -ForEach $validSamples {
        $path = Join-Path $script:SamplesDir $_
        $json = Get-Content -Raw -LiteralPath $path
        $name = Get-SampleSchemaName $_
        Test-Schema -Json $json -SchemaName $name | Should -BeTrue
    }

    $invalidSamples = @(
        'plan-bad-id.json',
        'plan-extra-field.json',
        'plan-empty-files.json',
        'feature-done-stage.json',
        'status-missing-stage.json',
        'schedule-bad-cap.json'
    )

    It 'invalid sample <_> fails its schema' -ForEach $invalidSamples {
        $path = Join-Path $script:SamplesDir $_
        $json = Get-Content -Raw -LiteralPath $path
        $name = Get-SampleSchemaName $_
        Test-Schema -Json $json -SchemaName $name | Should -BeFalse
    }
}

Describe 'templates' {
    It 'decisions.md starts with # Decisions: <name>' {
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:TemplatesDir 'decisions.md')
        $text.StartsWith('# Decisions: <name>') | Should -BeTrue
    }

    It 'task.md contains required sections' {
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:TemplatesDir 'task.md')
        $text | Should -Match '# Task <id>: <title>'
        $text | Should -Match '## Goal'
        $text | Should -Match '## Scope'
        $text | Should -Match '## Constraints'
        $text | Should -Match '## Acceptance criteria'
        $text | Should -Match '## Context'
    }

    It 'task.md keeps its six headings and the sandbox line' {
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:TemplatesDir 'task.md')
        $lines = $text -split "\r?\n"
        $headings = @($lines | Where-Object { $_ -match '^#' })
        $headings | Should -BeExactly @(
            '# Task <id>: <title>'
            '## Goal'
            '## Scope'
            '## Constraints'
            '## Acceptance criteria'
            '## Context'
        )
        $sandboxLine = @'
You run in a sandbox: only this worktree, your home and temp folders, and installed tools are readable, and you cannot commit. Don't work around access errors; report them. `taskkill.exe` hangs here: use `Stop-Process -Force`.
'@
        $text.Contains($sandboxLine.TrimEnd()) | Should -BeTrue
        $constraintsIdx = [array]::IndexOf($lines, '## Constraints')
        $acceptanceIdx = [array]::IndexOf($lines, '## Acceptance criteria')
        $sandboxIdx = $lines.IndexOf($sandboxLine.TrimEnd())
        $sandboxIdx | Should -BeGreaterThan $constraintsIdx
        $sandboxIdx | Should -BeLessThan $acceptanceIdx
    }
}

Describe 'fixtures' {
    $lines = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/runs.jsonl'))

    It 'runs.jsonl line parses and has valid usage' -ForEach $lines {
        $obj = $_ | ConvertFrom-Json
        $obj.PSObject.Properties['feature'] | Should -Not -BeNullOrEmpty
        $obj.feature | Should -Not -BeNullOrEmpty
        $expected = $obj.usage.input + $obj.usage.output + $obj.usage.reasoning
        $obj.usage.total | Should -Be $expected
    }
}

Describe 'helpers' {
    It 'New-TestRepo returns a folder on main with one commit' {
        $repo = New-TestRepo
        Test-Path $repo | Should -BeTrue
        $branch = & git -C $repo rev-parse --abbrev-ref HEAD
        $branch | Should -Be 'main'
        $count = & git -C $repo rev-list --count HEAD
        [int]$count | Should -Be 1
    }

    It 'Invoke-Feature uses WorkingDirectory and keeps stderr separate from JSON' {
        $stub = Join-Path $TestDrive 'stub-feature.ps1'
        @'
[Console]::Error.WriteLine('warn')
@{ ok = $true; cwd = (Get-Location).Path } | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath $stub
        $repo = New-TestRepo
        $repoResolved = (Resolve-Path -LiteralPath $repo).Path
        $r = Invoke-Feature -ScriptPath $stub -Arguments @() -WorkingDirectory $repo
        $r.ExitCode | Should -Be 0
        $r.Json.ok | Should -BeTrue
        $r.Json.cwd | Should -Be $repoResolved
        $r.Stderr | Should -Match 'warn'
    }

    It 'Invoke-FeatureInProcess matches child process for setup and leaves no lock or strict-mode leak' {
        $repo = New-TestRepo
        $good = Invoke-FeatureInProcess @('new', '-Name', 'ipgood', '-Repo', $repo) -WorkingDirectory $repo
        $good.ExitCode | Should -Be 0
        $good.Json.ok | Should -BeTrue
        Test-Path (Join-Path $repo '.xagent/features/ipgood/.lock') | Should -BeFalse

        $bad = Invoke-FeatureInProcess @('new', '-Name', 'Bad_Name', '-Repo', $repo) -WorkingDirectory $repo
        $bad.ExitCode | Should -Be 1
        $bad.Json.ok | Should -BeFalse
        $bad.Json.error | Should -Not -BeNullOrEmpty
        Test-Path (Join-Path $repo '.xagent/features/Bad_Name/.lock') | Should -BeFalse

        { $null.Foo } | Should -Not -Throw

        $dec = Invoke-Feature @('decision', '-Kind', 'decision', '-Text', 'ok', '-Repo', $repo, '-Name', 'ipgood') -WorkingDirectory $repo
        $dec.ExitCode | Should -Be 0
        $dec.Json.ok | Should -BeTrue
    }
}

Describe 'path rules (unit)' {
    BeforeAll {
        . (Get-FeatureFunctionScript -Name @(
                'Normalize-ScopePath', 'Convert-ScopeGlobToRegex', 'Test-PathInScope',
                'Get-OverlapKey', 'Test-OverlapKeysOverlap'
            ))
    }

    $pathCases = @(
        @{ entry = 'src/test*.ts'; path = 'src/testing.ts'; expected = $true },
        @{ entry = 'src/test*.ts'; path = 'src/other.ts'; expected = $false },
        @{ entry = 'src/test*.ts'; path = 'src/sub/test1.ts'; expected = $false },
        @{ entry = 'docs/'; path = 'docs/a/b.md'; expected = $true },
        @{ entry = 'docs/'; path = 'src/docs/x.md'; expected = $false },
        @{ entry = 'src/**/x.ts'; path = 'src/x.ts'; expected = $true },
        @{ entry = 'src/**/x.ts'; path = 'src/a/b/x.ts'; expected = $true },
        @{ entry = 'src/**/x.ts'; path = 'src/y.ts'; expected = $false },
        @{ entry = 'src/a.ts'; path = 'Src/A.ts'; expected = $true },
        @{ entry = './src/a.ts'; path = 'src/a.ts'; expected = $true },
        @{ entry = 'src\a.ts'; path = 'src/a.ts'; expected = $true },
        @{ entry = 'src/a[1].ts'; path = 'src/a[1].ts'; expected = $true },
        @{ entry = 'src/a[1].ts'; path = 'src/a1.ts'; expected = $false },
        @{ entry = 'src/a[1]*.ts'; path = 'src/a[1]x.ts'; expected = $true },
        @{ entry = 'src/a[1]*.ts'; path = 'src/a1x.ts'; expected = $false },
        @{ entry = 'src/a?.ts'; path = 'src/ab.ts'; expected = $true },
        @{ entry = 'src/a?.ts'; path = 'src/a/.ts'; expected = $false }
    )

    It 'Test-PathInScope -Path <path> -ScopeFiles @(<entry>) returns <expected>' -ForEach $pathCases {
        Test-PathInScope -Path $_.path -ScopeFiles @($_.entry) | Should -Be $_.expected
    }

    $overlapKeyCases = @(
        @{ entry = 'src/test*.ts'; key = 'src/' },
        @{ entry = '**'; key = '' },
        @{ entry = '*.md'; key = '' },
        @{ entry = 'docs/**/x.md'; key = 'docs/' },
        @{ entry = 'src/a.ts'; key = 'src/a.ts' },
        @{ entry = 'Src\A.ts'; key = 'src/a.ts' }
    )

    It 'Get-OverlapKey <entry> returns <key>' -ForEach $overlapKeyCases {
        Get-OverlapKey $_.entry | Should -Be $_.key
    }

    $overlapCases = @(
        @{ a = 'src/a.ts'; b = 'src/a.ts'; expected = $true },
        @{ a = 'src/'; b = 'src/x/y.ts'; expected = $true },
        @{ a = '**'; b = 'src/a.ts'; expected = $true },
        @{ a = '*.md'; b = 'src/a.ts'; expected = $true },
        @{ a = 'src/test*.ts'; b = 'src/testing.ts'; expected = $true },
        @{ a = 'src/a/*'; b = 'src/b/x.ts'; expected = $false },
        @{ a = 'src/a.ts'; b = 'src/a.tsx'; expected = $false }
    )

    It 'Test-OverlapKeysOverlap (Get-OverlapKey <a>) (Get-OverlapKey <b>) returns <expected>' -ForEach $overlapCases {
        Test-OverlapKeysOverlap (Get-OverlapKey $_.a) (Get-OverlapKey $_.b) | Should -Be $_.expected
    }
}

Describe 'commit message (unit)' {
    BeforeAll {
        . (Get-FeatureFunctionScript -Name @('Limit-CommitMessage'))
    }

    It 'leaves a 72-character message unchanged' {
        $msg = 'a' * 72
        Limit-CommitMessage $msg | Should -Be $msg
        (Limit-CommitMessage $msg).Length | Should -Be 72
    }

    It 'word-breaks a long design commit subject' {
        $msg = "feature(subtract-divide): design $([char]0x2013) Overview, Problem, Goals, Non-Goals, Open Questions"
        $got = Limit-CommitMessage $msg
        $want = "feature(subtract-divide): design $([char]0x2013) Overview, Problem, Goals, Non-Goals$([char]0x2026)"
        $got | Should -Be $want
        $got.Length | Should -BeLessOrEqual 72
    }

    It 'uses 71 characters plus ellipsis when no break space' {
        $msg = ('x' * 100)
        $got = Limit-CommitMessage $msg
        $got | Should -Be (('x' * 71) + [char]0x2026)
        $got.Length | Should -Be 72
    }

    It 'never returns more than 72 characters' {
        $cases = @(
            'a' * 72
            "feature(subtract-divide): design $([char]0x2013) Overview, Problem, Goals, Non-Goals, Open Questions"
            ('x' * 100)
            ('word ' * 30)
        )
        foreach ($msg in $cases) {
            (Limit-CommitMessage $msg).Length | Should -BeLessOrEqual 72
        }
    }
}

Describe 'cache path (unit)' {
    BeforeAll {
        . (Get-FeatureFunctionScript -Name @('Test-CachePath'))
    }

    $trueCases = @(
        'src/__pycache__/m.cpython-314.pyc'
        'stray.pyc'
        '.pytest_cache/v/x'
        '.mypy_cache/x'
        '.ruff_cache/x'
    )
    It 'Test-CachePath returns true for <_>' -ForEach $trueCases {
        Test-CachePath $_ | Should -BeTrue
    }

    $falseCases = @(
        'pycache.py'
        'my__pycache__x/a.py'
        'src/a.py'
    )
    It 'Test-CachePath returns false for <_>' -ForEach $falseCases {
        Test-CachePath $_ | Should -BeFalse
    }
}

Describe 'feature.ps1 new' {
    It 'refuses a dirty tree' {
        $repo = New-TestRepo
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'dirty'
        $r = Invoke-Feature @('new', '-Name', 'alpha', '-Repo', $repo) -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
        $r.Json.ok | Should -BeFalse
    }

    It 'refuses a bad name' {
        $repo = New-TestRepo
        $r = Invoke-Feature @('new', '-Name', 'Bad-Name', '-Repo', $repo) -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
        $r.Json.ok | Should -BeFalse
    }

    It 'refuses a second feature in progress' {
        $repo = New-TestRepo
        Assert-FeatureOk (Invoke-Feature @('new', '-Name', 'one', '-Repo', $repo) -WorkingDirectory $repo)
        $r = Invoke-Feature @('new', '-Name', 'two', '-Repo', $repo) -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
        $r.Json.ok | Should -BeFalse
        $r.Json.error | Should -Match 'another feature is in progress'
    }

    It 'allows new after first feature is abandoned' {
        $repo = New-TestRepo
        Assert-FeatureOk (Invoke-Feature @('new', '-Name', 'first', '-Repo', $repo) -WorkingDirectory $repo)
        Assert-FeatureOk (Invoke-Feature @('stage', '-To', 'abandoned', '-Repo', $repo, '-Name', 'first') -WorkingDirectory $repo)
        $r = Invoke-Feature @('new', '-Name', 'second', '-Repo', $repo) -WorkingDirectory $repo
        $r.Json.ok | Should -BeTrue
        $r.Json.name | Should -Be 'second'
    }

    It 'creates branch, feature.json, and decisions template' {
        $repo = New-TestRepo
        $r = Invoke-Feature @('new', '-Name', 'demo', '-Repo', $repo) -WorkingDirectory $repo
        $r.ExitCode | Should -Be 0
        $r.Json.ok | Should -BeTrue
        $r.Json.branch | Should -Be 'feature/demo'
        & git -C $repo rev-parse --abbrev-ref HEAD | Should -Be 'feature/demo'
        $featJson = & git -C $repo show 'HEAD:docs/features/demo/feature.json'
        Test-Schema -Json $featJson -SchemaName 'feature' | Should -BeTrue
        ($featJson | ConvertFrom-Json).designDoc | Should -Be 'docs/designs/demo.md'
        ($featJson | ConvertFrom-Json).checkin | Should -Be 'on-problems'
        $dec = (& git -C $repo show 'HEAD:docs/features/demo/decisions.md') -join "`n"
        $dec.StartsWith('# Decisions: demo') | Should -BeTrue
    }
    It 'records default designDoc and designDocExists false without -DesignDoc' {
        $repo = New-TestRepo
        $r = Invoke-Feature @('new', '-Name', 'alpha', '-Repo', $repo) -WorkingDirectory $repo
        Assert-FeatureOk $r
        $r.Json.designDoc | Should -Be 'docs/designs/alpha.md'
        $r.Json.designDocExists | Should -BeFalse
        $featJson = & git -C $repo show 'HEAD:docs/features/alpha/feature.json'
        ($featJson | ConvertFrom-Json).designDoc | Should -Be 'docs/designs/alpha.md'
    }

    It 'refuses new when default design doc is committed on main' {
        $repo = New-TestRepo
        $designPath = Join-Path $repo 'docs/designs/alpha.md'
        New-Item -ItemType Directory -Force (Split-Path $designPath) | Out-Null
        Set-Content -LiteralPath $designPath -Value '# alpha'
        & git -C $repo add docs/designs/alpha.md 2>&1 | Out-Null
        & git -C $repo commit -m 'add design' 2>&1 | Out-Null
        $r = Invoke-Feature @('new', '-Name', 'alpha', '-Repo', $repo) -WorkingDirectory $repo
        $r.Json.ok | Should -BeFalse
        $r.Json.error | Should -Match 'already exists; pass -DesignDoc'
        & git -C $repo show-ref --verify --quiet refs/heads/feature/alpha 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
        Test-Path -LiteralPath (Join-Path $repo '.xagent/features/alpha') | Should -BeFalse
    }

    It 'refuses new when default design doc is untracked' {
        $repo = New-TestRepo
        $designPath = Join-Path $repo 'docs/designs/alpha.md'
        New-Item -ItemType Directory -Force (Split-Path $designPath) | Out-Null
        Set-Content -LiteralPath $designPath -Value '# alpha'
        $r = Invoke-Feature @('new', '-Name', 'alpha', '-Repo', $repo) -WorkingDirectory $repo
        $r.Json.ok | Should -BeFalse
        $r.Json.error | Should -Match 'already exists; pass -DesignDoc'
        & git -C $repo show-ref --verify --quiet refs/heads/feature/alpha 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
        Test-Path -LiteralPath (Join-Path $repo '.xagent/features/alpha') | Should -BeFalse
    }

    It 'adopts committed custom design doc without changing or committing it' {
        $repo = New-TestRepo
        $rel = 'docs/design/Voice Cloning.md'
        $designPath = Join-Path $repo $rel
        New-Item -ItemType Directory -Force (Split-Path $designPath) | Out-Null
        Set-Content -LiteralPath $designPath -Value '# voice' -NoNewline
        $before = [IO.File]::ReadAllBytes($designPath)
        & git -C $repo add $rel 2>&1 | Out-Null
        & git -C $repo commit -m 'add voice doc' 2>&1 | Out-Null
        $r = Invoke-Feature @('new', '-Name', 'alpha', '-DesignDoc', 'docs/design/Voice Cloning.md', '-Repo', $repo) -WorkingDirectory $repo
        Assert-FeatureOk $r
        $r.Json.designDoc | Should -Be 'docs/design/Voice Cloning.md'
        $r.Json.designDocExists | Should -BeTrue
        $featJson = & git -C $repo show 'HEAD:docs/features/alpha/feature.json'
        ($featJson | ConvertFrom-Json).designDoc | Should -Be 'docs/design/Voice Cloning.md'
        [IO.File]::ReadAllBytes($designPath) | Should -Be $before
        @(& git -C $repo log --format=%H main..feature/alpha -- 'docs/design/Voice Cloning.md') | Should -Be @()
    }

    It 'records normalized custom designDoc when the file does not exist' {
        $repo = New-TestRepo
        $r = Invoke-Feature @('new', '-Name', 'alpha', '-DesignDoc', 'research\idea.md', '-Repo', $repo) -WorkingDirectory $repo
        Assert-FeatureOk $r
        $r.Json.designDoc | Should -Be 'research/idea.md'
        $r.Json.designDocExists | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $repo 'research/idea.md') | Should -BeFalse
        $featJson = & git -C $repo show 'HEAD:docs/features/alpha/feature.json'
        ($featJson | ConvertFrom-Json).designDoc | Should -Be 'research/idea.md'
    }

    It 'adopts untracked design doc and commit-design can commit it' {
        $repo = New-TestRepo
        $rel = 'notes/plan.md'
        $planPath = Join-Path $repo $rel
        New-Item -ItemType Directory -Force (Split-Path $planPath) | Out-Null
        Set-Content -LiteralPath $planPath -Value '# plan'
        $r = Invoke-Feature @('new', '-Name', 'alpha', '-DesignDoc', 'notes/plan.md', '-Repo', $repo) -WorkingDirectory $repo
        Assert-FeatureOk $r
        $r.Json.designDocExists | Should -BeTrue
        & git -C $repo rev-parse --abbrev-ref HEAD | Should -Be 'feature/alpha'
        Add-Content -LiteralPath $planPath -Value 'imported line'
        Assert-FeatureOk (Invoke-Feature @('commit-design', '-Section', 'imported', '-Repo', $repo) -WorkingDirectory $repo)
        ((& git -C $repo show 'feature/alpha:notes/plan.md') -join "
") | Should -Match 'imported line'
    }

    It 'rejects invalid -DesignDoc paths' -ForEach @(
        @{ Path = '../outside.md'; ExpectedError = 'must be a repo-relative path' }
        @{ Path = 'docs/../x.md'; ExpectedError = 'must be a repo-relative path' }
        @{ Path = '/x.md'; ExpectedError = 'must be a repo-relative path' }
        @{ Path = 'C:/x.md'; ExpectedError = 'must be a repo-relative path' }
        @{ Path = "a.md`nb.md"; ExpectedError = 'must be a single line' }
        @{ Path = 'docs/x.txt'; ExpectedError = 'must be a .md file' }
    ) {
        $repo = New-TestRepo
        $r = Invoke-Feature @('new', '-Name', 'alpha', '-DesignDoc', $_.Path, '-Repo', $repo) -WorkingDirectory $repo
        $r.Json.ok | Should -BeFalse
        $r.Json.error | Should -Match $_.ExpectedError
    }

    It 'treats whitespace -DesignDoc as not given' {
        $repo = New-TestRepo
        $r = Invoke-Feature @('new', '-Name', 'alpha', '-DesignDoc', ' ', '-Repo', $repo) -WorkingDirectory $repo
        Assert-FeatureOk $r
        $featJson = & git -C $repo show 'HEAD:docs/features/alpha/feature.json'
        ($featJson | ConvertFrom-Json).designDoc | Should -Be 'docs/designs/alpha.md'
    }
}

Describe 'feature.ps1 stage and gate' {
    It 'moves design to design-review without a gate' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'sg' -Stage 'design'
        $r = Invoke-Feature @('stage', '-To', 'design-review', '-Repo', $repo, '-Name', 'sg') -WorkingDirectory $repo
        $r.Json.to | Should -Be 'design-review'
    }

    It 'fails advancing to plan without design-locked' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'sg' -Stage 'design-review'
        $r = Invoke-Feature @('stage', '-To', 'plan', '-Repo', $repo, '-Name', 'sg') -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
    }

    It 'fails gate in wrong stage' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'sg' -Stage 'design'
        $r = Invoke-Feature @('gate', '-Gate', 'design-locked', '-Quote', 'nope', '-Repo', $repo, '-Name', 'sg') -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
    }

    It 'fails -Checkin with gate other than plan-approved' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'sg' -Stage 'design-review'
        $designPath = Join-Path $repo 'docs/designs/sg.md'
        New-Item -ItemType Directory -Force (Split-Path $designPath) | Out-Null
        Set-Content -LiteralPath $designPath -Value 'd'
        Assert-FeatureOk (Invoke-Feature @('commit-design', '-Section', 's', '-Repo', $repo, '-Name', 'sg') -WorkingDirectory $repo)
        $r = Invoke-Feature @('gate', '-Gate', 'design-locked', '-Quote', 'ok', '-Checkin', 'every-phase', '-Repo', $repo, '-Name', 'sg') -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
    }

    It 'records gate quote, time, sha, and design blob' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'sg' -Stage 'design-review'
        $designPath = Join-Path $repo 'docs/designs/sg.md'
        New-Item -ItemType Directory -Force (Split-Path $designPath) | Out-Null
        Set-Content -LiteralPath $designPath -Value 'design body'
        Assert-FeatureOk (Invoke-Feature @('commit-design', '-Section', 'body', '-Repo', $repo, '-Name', 'sg') -WorkingDirectory $repo)
        $tipBefore = & git -C $repo rev-parse feature/sg
        $r = Invoke-Feature @('gate', '-Gate', 'design-locked', '-Quote', 'ship it', '-Repo', $repo, '-Name', 'sg') -WorkingDirectory $repo
        $r.Json.sha | Should -Be $tipBefore
        $feat = (& git -C $repo show 'HEAD:docs/features/sg/feature.json' | ConvertFrom-Json)
        $feat.gates.'design-locked'.quote | Should -Be 'ship it'
        $feat.gates.'design-locked'.sha | Should -Be $tipBefore
        $feat.gates.'design-locked'.designBlob | Should -Not -BeNullOrEmpty
        $atVal = $feat.gates.'design-locked'.at
        $atStr = if ($atVal -is [datetime]) { $atVal.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { [string]$atVal }
        $atStr | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
    }

    It 'requires design-locked again after going back from plan' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'sg' -Stage 'plan'
        Assert-FeatureOk (Invoke-Feature @('stage', '-To', 'design-review', '-Repo', $repo, '-Name', 'sg') -WorkingDirectory $repo)
        $r = Invoke-Feature @('stage', '-To', 'plan', '-Repo', $repo, '-Name', 'sg') -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
    }

    It 'abandoned switches to main when clean and stays when dirty' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'ab1' -Stage 'design'
        Assert-FeatureOk (Invoke-Feature @('stage', '-To', 'abandoned', '-Repo', $repo, '-Name', 'ab1') -WorkingDirectory $repo)
        & git -C $repo rev-parse --abbrev-ref HEAD | Should -Be 'main'

        New-FeatureAtStage -Repo $repo -Name 'ab2' -Stage 'design'
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'dirty'
        $r = Invoke-Feature @('stage', '-To', 'abandoned', '-Repo', $repo, '-Name', 'ab2') -WorkingDirectory $repo
        $r.Json.ok | Should -BeTrue
        & git -C $repo rev-parse --abbrev-ref HEAD | Should -Be 'feature/ab2'
    }

    It 'records go-back stage line as from -> to: reason' -Tag 'Slow' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'st6' -Stage 'signoff'
        Assert-FeatureOk (Invoke-Feature @(
                'stage', '-To', 'plan', '-Reason', 'go back to the plan', '-Repo', $repo, '-Name', 'st6'
            ) -WorkingDirectory $repo)
        $dec = (& git -C $repo show 'HEAD:docs/features/st6/decisions.md') -join "`n"
        $dec | Should -Match '\[stage\] signoff -> plan: go back to the plan'
    }

    It 'records abandon with reason as from -> abandoned: reason' -Tag 'Slow' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'st6a' -Stage 'design'
        Assert-FeatureOk (Invoke-Feature @(
                'stage', '-To', 'abandoned', '-Reason', 'abandon this feature', '-Repo', $repo, '-Name', 'st6a'
            ) -WorkingDirectory $repo)
        $dec = (& git -C $repo show 'feature/st6a:docs/features/st6a/decisions.md') -join "`n"
        $dec | Should -Match '\[stage\] design -> abandoned: abandon this feature'
    }

    It 'records stage move without reason as from -> to' -Tag 'Slow' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'st6b' -Stage 'design'
        Assert-FeatureOk (Invoke-Feature @('stage', '-To', 'design-review', '-Repo', $repo, '-Name', 'st6b') -WorkingDirectory $repo)
        $dec = (& git -C $repo show 'HEAD:docs/features/st6b/decisions.md') -join "`n"
        $dec | Should -Match '\[stage\] design -> design-review'
    }
}

Describe 'feature.ps1 commit-design and commit-records' {
    It 'commit-design stages only the design doc' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'cd' -Stage 'design'
        $design = Join-Path $repo 'docs/designs/cd.md'
        New-Item -ItemType Directory -Force (Split-Path $design) | Out-Null
        Set-Content -LiteralPath $design -Value 'v1'
        $noise = Join-Path $repo 'README.md'
        Set-Content -LiteralPath $noise -Value 'changed'
        & git -C $repo add README.md
        $r = Invoke-Feature @('commit-design', '-Section', 'Overview', '-Repo', $repo, '-Name', 'cd') -WorkingDirectory $repo
        $r.Json.ok | Should -BeTrue
        $names = @(& git -C $repo show --name-only --pretty=format: HEAD)
        $names | Should -Be @('docs/designs/cd.md')
    }

    It 'commit-records stages only docs/features/<name>/' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'cr' -Stage 'design'
        $rev = Join-Path $repo 'docs/features/cr/reviews/raw/x.md'
        New-Item -ItemType Directory -Force (Split-Path $rev) | Out-Null
        Set-Content -LiteralPath $rev -Value 'raw'
        $design = Join-Path $repo 'docs/designs/cr.md'
        New-Item -ItemType Directory -Force (Split-Path $design) | Out-Null
        Set-Content -LiteralPath $design -Value 'mut'
        & git -C $repo add docs/designs/cr.md
        $r = Invoke-Feature @('commit-records', '-Message', 'review: x', '-Repo', $repo, '-Name', 'cr') -WorkingDirectory $repo
        $names = @(& git -C $repo show --name-only --pretty=format: HEAD)
        $names | Should -Be @('docs/features/cr/reviews/raw/x.md')
    }
}

Describe 'feature.ps1 checkin' {
    It 'preserves non-ASCII gate quote after checkin rewrites feature.json' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'utf' -Stage 'design-review'
        $designPath = Join-Path $repo 'docs/designs/utf.md'
        New-Item -ItemType Directory -Force (Split-Path $designPath) | Out-Null
        Set-Content -LiteralPath $designPath -Value 'design body'
        Assert-FeatureOk (Invoke-Feature @('commit-design', '-Section', 'body', '-Repo', $repo, '-Name', 'utf') -WorkingDirectory $repo)
        $quote = "caf$([char]0xE9) $([char]0x2014) ok"
        Assert-FeatureOk (Invoke-Feature @('gate', '-Gate', 'design-locked', '-Quote', $quote, '-Repo', $repo, '-Name', 'utf') -WorkingDirectory $repo)
        Assert-FeatureOk (Invoke-Feature @('checkin', '-Mode', 'every-phase', '-Repo', $repo, '-Name', 'utf') -WorkingDirectory $repo)
        $feat = (& git -C $repo show 'HEAD:docs/features/utf/feature.json' | ConvertFrom-Json)
        $feat.gates.'design-locked'.quote | Should -Be $quote
    }

    It 'switches checkin mode both ways' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'ck' -Stage 'design'
        $r1 = Invoke-Feature @('checkin', '-Mode', 'every-phase', '-Repo', $repo, '-Name', 'ck') -WorkingDirectory $repo
        $r1.Json.mode | Should -Be 'every-phase'
        $r2 = Invoke-Feature @('checkin', '-Mode', 'on-problems', '-Repo', $repo, '-Name', 'ck') -WorkingDirectory $repo
        $r2.Json.mode | Should -Be 'on-problems'
    }
}

Describe 'feature.ps1 decision' {
    It 'writes decision line format' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'dc' -Stage 'design'
        $r = Invoke-Feature @('decision', '-Kind', 'round', '-Text', 't1: x', '-Repo', $repo, '-Name', 'dc') -WorkingDirectory $repo
        $r.Json.line | Should -Match '^- \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \[round\] t1: x$'
    }

    It 'resume without open stop fails' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'st' -Stage 'design'
        $r = Invoke-Feature @('decision', '-Kind', 'resume', '-Text', 'go', '-Repo', $repo, '-Name', 'st') -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
    }

    It 'decision text mentioning [stop] does not open a stop' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'ds' -Stage 'design'
        Assert-FeatureOk (Invoke-Feature @('decision', '-Kind', 'decision', '-Text', 'mentions [stop] here', '-Repo', $repo, '-Name', 'ds') -WorkingDirectory $repo)
        $r = Invoke-Feature @('decision', '-Kind', 'resume', '-Text', 'go', '-Repo', $repo, '-Name', 'ds') -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
    }

    It 'stop then resume succeeds and second resume fails' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'st' -Stage 'design'
        Assert-FeatureOk (Invoke-Feature @('decision', '-Kind', 'stop', '-Text', 'p1: wait', '-Repo', $repo, '-Name', 'st') -WorkingDirectory $repo)
        Assert-FeatureOk (Invoke-Feature @('decision', '-Kind', 'resume', '-Text', 'go', '-Repo', $repo, '-Name', 'st') -WorkingDirectory $repo)
        $r = Invoke-Feature @('decision', '-Kind', 'resume', '-Text', 'again', '-Repo', $repo, '-Name', 'st') -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
    }
}

Describe 'feature.ps1 reaudit' {
    It 'appends reaudit line in design-review' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'ra' -Stage 'design-review'
        $r = Invoke-Feature @('reaudit', '-Phase', '5', '-Repo', $repo, '-Name', 'ra') -WorkingDirectory $repo
        $r.Json.line | Should -Match '\[reaudit\] d1: phase 5$'
    }

    It 'fails reaudit in design' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'ra' -Stage 'design'
        $r = Invoke-Feature @('reaudit', '-Phase', '1', '-Repo', $repo, '-Name', 'ra') -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
    }
}

Describe 'feature.ps1 lock' {
    It 'blocks when lock matches running pid and start time' -Tag 'Slow' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'lk' -Stage 'design'
        $lockDir = Join-Path $repo '.xagent/features/lk'
        $holder = Start-Process -PassThru -WindowStyle Hidden -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120')
        try {
            Start-Sleep -Milliseconds 300
            $holder.Refresh()
            $start = $holder.StartTime.ToUniversalTime().ToString('o')
            $body = (@{ pid = $holder.Id; startTime = $start } | ConvertTo-Json -Compress)
            Set-Content -LiteralPath (Join-Path $lockDir '.lock') -Value $body -NoNewline
            $r = Invoke-Feature @('decision', '-Kind', 'decision', '-Text', 'blocked', '-Repo', $repo, '-Name', 'lk') -WorkingDirectory $repo
            $r.ExitCode | Should -Be 1
            $r.Json.error | Should -Match 'another session is working on this feature'
        } finally {
            Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'takes over stale lock (dead pid)' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'lk2' -Stage 'design'
        $lockDir = Join-Path $repo '.xagent/features/lk2'
        $body = '{"pid":999999,"startTime":"2020-01-01T00:00:00.0000000Z"}'
        Set-Content -LiteralPath (Join-Path $lockDir '.lock') -Value $body -NoNewline
        $r = Invoke-Feature @('decision', '-Kind', 'decision', '-Text', 'ok', '-Repo', $repo, '-Name', 'lk2') -WorkingDirectory $repo
        $r.Json.ok | Should -BeTrue
    }

    It 'takes over lock with different start time' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'lk3' -Stage 'design'
        $lockDir = Join-Path $repo '.xagent/features/lk3'
        $body = (@{ pid = $PID; startTime = '2019-06-01T00:00:00.0000000Z' } | ConvertTo-Json -Compress)
        Set-Content -LiteralPath (Join-Path $lockDir '.lock') -Value $body -NoNewline
        $r = Invoke-Feature @('decision', '-Kind', 'decision', '-Text', 'ok', '-Repo', $repo, '-Name', 'lk3') -WorkingDirectory $repo
        $r.Json.ok | Should -BeTrue
    }
}

Describe 'feature.ps1 file encoding' {
    It 'feature.json and decisions.md have no CR or BOM' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'enc' -Stage 'design'
        Assert-FeatureOk (Invoke-Feature @('decision', '-Kind', 'decision', '-Text', 'note', '-Repo', $repo, '-Name', 'enc') -WorkingDirectory $repo)
        $featBytes = [IO.File]::ReadAllBytes((Join-Path $repo 'docs/features/enc/feature.json'))
        $decBytes = [IO.File]::ReadAllBytes((Join-Path $repo 'docs/features/enc/decisions.md'))
        $featBytes[0] | Should -Not -Be 0xEF
        $decBytes[0] | Should -Not -Be 0xEF
        [Text.Encoding]::UTF8.GetString($featBytes) | Should -Not -Match "`r"
        [Text.Encoding]::UTF8.GetString($decBytes) | Should -Not -Match "`r"
    }
}

Describe 'feature.ps1 selection' {
    It 'rule 2 selects feature from checked-out branch without -Name' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'sel2' -Stage 'design'
        $r = Invoke-Feature @('decision', '-Kind', 'decision', '-Text', 'x', '-Repo', $repo) -WorkingDirectory $repo
        $r.Json.ok | Should -BeTrue
        $r.Json.name | Should -Be 'sel2'
    }

    It 'rule 3 selects sole in-progress feature when on main' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'sel3' -Stage 'design'
        & git -C $repo switch main
        $r = Invoke-Feature @('decision', '-Kind', 'decision', '-Text', 'x', '-Repo', $repo) -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'check out feature/sel3 first'
    }

    It 'fails with no feature selected when -Name omitted and none apply' {
        $repo = New-TestRepo
        $r = Invoke-Feature @('decision', '-Kind', 'decision', '-Text', 'x', '-Repo', $repo) -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'no feature selected'
    }
}

Describe 'feature.ps1 lock release' {
    It 'removes .lock after a successful write' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'lr' -Stage 'design'
        $lockPath = Join-Path $repo '.xagent/features/lr/.lock'
        Assert-FeatureOk (Invoke-Feature @('decision', '-Kind', 'decision', '-Text', 'note', '-Repo', $repo, '-Name', 'lr') -WorkingDirectory $repo)
        Test-Path -LiteralPath $lockPath | Should -BeFalse
    }
}

Describe 'feature.ps1 errors' {
    It 'unknown subcommand exits 1 with ok false' {
        $repo = New-TestRepo
        $r = Invoke-Feature @('nope', '-Repo', $repo) -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
        $r.Json.ok | Should -BeFalse
        $r.Json.error | Should -Not -BeNullOrEmpty
    }

    It 'write on another branch fails' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'br' -Stage 'design'
        & git -C $repo switch main
        $r = Invoke-Feature @('decision', '-Kind', 'decision', '-Text', 'x', '-Repo', $repo, '-Name', 'br') -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'check out feature/br first'
    }
}

Describe 'feature.ps1 plan' {
    It 'imports a valid two-phase plan' {
        $repo = New-TestRepo
        $r = Import-TestPlan -Repo $repo -Name 'pl1' -Plan (Get-StandardTwoPhasePlan)
        $r.Json.ok | Should -BeTrue
        $r.Json.phases | Should -Be 2
        $r.Json.tasks | Should -Be 3
        $feat = (& git -C $repo show 'HEAD:docs/features/pl1/feature.json' | ConvertFrom-Json)
        Test-Schema -Json ($feat | ConvertTo-Json -Depth 12) -SchemaName 'feature' | Should -BeTrue
        $feat.phases[0].tasks[0].delegateTaskId | Should -Be 'pl1-t1'
        $md = (& git -C $repo show 'HEAD:docs/features/pl1/plan.md') -join "`n"
        $md | Should -Match '# Plan: pl1'
        $md | Should -Match '## Phase 1'
        $md | Should -Match '## Phase 2'
        $md | Should -Match '\| t1 \|'
        $md | Should -Match '\| t2 \|'
        $md | Should -Match '\| t3 \|'
        $md | Should -Match '\*\*t1\.\*\*'
        $md | Should -Match '\*\*t2\.\*\*'
        $md | Should -Match '\*\*t3\.\*\*'
    }

    It 'commits dependsOn and files as arrays for a one-task plan' {
        $repo = New-TestRepo
        $plan = @{
            summary = 'one task'
            phases  = @(@{
                    n = 1; rationale = 'r'; test = 't'
                    tasks = @(@{
                            id = 'solo'; title = 'solo'; dependsOn = @(); files = @('src/a.ts')
                            test = 't'; profile = 'code'; brief = 'b'
                        })
                })
        }
        Import-TestPlan -Repo $repo -Name 'one' -Plan $plan | Out-Null
        $raw = (& git -C $repo show 'HEAD:docs/features/one/feature.json') -join "`n"
        $raw | Should -Match '"dependsOn": \[\]'
        $feat = $raw | ConvertFrom-Json -AsHashtable
        $task = $feat.phases[0].tasks[0]
        $task.dependsOn -is [array] | Should -BeTrue
        $task.dependsOn.Count | Should -Be 0
        $task.files -is [array] | Should -BeTrue
        $task.files.Count | Should -Be 1
        $task.files[0] | Should -Be 'src/a.ts'
    }

    It 'delegateTaskId uses 12-character name cut for long names' {
        $repo = New-TestRepo
        $name = 'averyveryverylongname'
        $plan = Get-StandardTwoPhasePlan
        Import-TestPlan -Repo $repo -Name $name -Plan $plan | Out-Null
        $feat = (& git -C $repo show "HEAD:docs/features/$name/feature.json" | ConvertFrom-Json)
        $feat.phases[0].tasks[0].delegateTaskId | Should -Be 'averyveryver-t1'
    }

    It 'delegateTaskId strips trailing hyphen from 12-char cut' {
        $repo = New-TestRepo
        $name = 'abcdefghijk-x'
        Import-TestPlan -Repo $repo -Name $name -Plan (Get-StandardTwoPhasePlan) | Out-Null
        $feat = (& git -C $repo show "HEAD:docs/features/$name/feature.json" | ConvertFrom-Json)
        $feat.phases[0].tasks[0].delegateTaskId | Should -Be 'abcdefghijk-t1'
    }

    It 'rejects task id longer than 20 characters' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'badid' -Stage 'plan'
        $plan = Get-StandardTwoPhasePlan
        $plan.phases[0].tasks[0].id = 'abcdefghijklmnopqrstu'
        $path = Join-Path $TestDrive 'bad-id.json'
        New-PlanFile -Path $path -Plan $plan
        $r = Invoke-Feature @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'badid') -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'plan does not match plan.schema.json'
    }

    It 'rejects duplicate task id' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'dup' -Stage 'plan'
        $plan = @{
            summary = 'x'
            phases  = @(@{
                    n = 1; rationale = 'r'; test = 't'
                    tasks = @(
                        @{ id = 'x'; title = 'a'; dependsOn = @(); files = @('a'); test = 't'; profile = 'code'; brief = 'b' },
                        @{ id = 'x'; title = 'b'; dependsOn = @(); files = @('b'); test = 't'; profile = 'code'; brief = 'b' }
                    )
                })
        }
        $path = Join-Path $TestDrive 'dup.json'
        New-PlanFile -Path $path -Plan $plan
        $r = Invoke-Feature @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'dup') -WorkingDirectory $repo
        $r.Json.error | Should -Match 'duplicate task id x'
    }

    It 'rejects unknown dependency' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'unk' -Stage 'plan'
        $plan = @{
            summary = 'x'
            phases  = @(@{
                    n = 1; rationale = 'r'; test = 't'
                    tasks = @(@{ id = 'a'; title = 'a'; dependsOn = @('missing'); files = @('a'); test = 't'; profile = 'code'; brief = 'b' })
                })
        }
        $path = Join-Path $TestDrive 'unk.json'
        New-PlanFile -Path $path -Plan $plan
        $r = Invoke-Feature @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'unk') -WorkingDirectory $repo
        $r.Json.error | Should -Match 'unknown dependency missing in a'
    }

    It 'rejects dependency in a later phase' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'late' -Stage 'plan'
        $plan = @{
            summary = 'x'
            phases  = @(
                @{ n = 1; rationale = 'r'; test = 't'; tasks = @(@{ id = 'a'; title = 'a'; dependsOn = @('b'); files = @('a'); test = 't'; profile = 'code'; brief = 'b' }) },
                @{ n = 2; rationale = 'r'; test = 't'; tasks = @(@{ id = 'b'; title = 'b'; dependsOn = @(); files = @('b'); test = 't'; profile = 'code'; brief = 'b' }) }
            )
        }
        $path = Join-Path $TestDrive 'late.json'
        New-PlanFile -Path $path -Plan $plan
        $r = Invoke-Feature @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'late') -WorkingDirectory $repo
        $r.Json.error | Should -Match 'a depends on b in a later phase'
    }

    It 'rejects a two-task dependency cycle' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'cyc' -Stage 'plan'
        $plan = @{
            summary = 'x'
            phases  = @(@{
                    n = 1; rationale = 'r'; test = 't'
                    tasks = @(
                        @{ id = 'a'; title = 'a'; dependsOn = @('b'); files = @('a'); test = 't'; profile = 'code'; brief = 'b' },
                        @{ id = 'b'; title = 'b'; dependsOn = @('a'); files = @('b'); test = 't'; profile = 'code'; brief = 'b' }
                    )
                })
        }
        $path = Join-Path $TestDrive 'cyc.json'
        New-PlanFile -Path $path -Plan $plan
        $r = Invoke-Feature @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'cyc') -WorkingDirectory $repo
        $r.Json.error | Should -Match 'dependency cycle involving'
    }

    It 'rejects phase numbers with a gap' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'gap' -Stage 'plan'
        $plan = @{
            summary = 'x'
            phases  = @(
                @{ n = 1; rationale = 'r'; test = 't'; tasks = @(@{ id = 'a'; title = 'a'; dependsOn = @(); files = @('a'); test = 't'; profile = 'code'; brief = 'b' }) },
                @{ n = 3; rationale = 'r'; test = 't'; tasks = @(@{ id = 'b'; title = 'b'; dependsOn = @(); files = @('b'); test = 't'; profile = 'code'; brief = 'b' }) }
            )
        }
        $path = Join-Path $TestDrive 'gap.json'
        New-PlanFile -Path $path -Plan $plan
        $r = Invoke-Feature @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'gap') -WorkingDirectory $repo
        $r.Json.error | Should -Match 'phases must be numbered 1..N'
    }

    It 'fails plan in design stage' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'ds' -Stage 'design'
        $path = Join-Path $TestDrive 'p.json'
        New-PlanFile -Path $path -Plan (Get-StandardTwoPhasePlan)
        $r = Invoke-Feature @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'ds') -WorkingDirectory $repo
        $r.Json.error | Should -Match 'only allowed in stage plan'
    }

    It 'keeps existing delegateTaskId on re-plan' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'reid' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        $featPath = Join-Path $repo 'docs/features/reid/feature.json'
        $feat = Get-Content -Raw $featPath | ConvertFrom-Json
        $feat.phases[0].tasks[0].delegateTaskId = 'custom-id'
        Write-FeatureJsonFileLocal $featPath $feat
        Assert-FeatureOk (Invoke-Feature @('commit-records', '-Message', 'custom delegate id', '-Repo', $repo, '-Name', 'reid') -WorkingDirectory $repo)
        $path = Join-Path $TestDrive 'replan.json'
        New-PlanFile -Path $path -Plan (Get-StandardTwoPhasePlan)
        Assert-FeatureOk (Invoke-Feature @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'reid') -WorkingDirectory $repo)
        $feat2 = (& git -C $repo show 'HEAD:docs/features/reid/feature.json' | ConvertFrom-Json)
        ($feat2.phases[0].tasks | Where-Object { $_.id -eq 't1' }).delegateTaskId | Should -Be 'custom-id'
    }

    It 'rejects re-plan that drops a merged task' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'rm' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        & git -C $repo commit --allow-empty -m 'merge t1' -m 'Xagent-Task: t1' | Out-Null
        $plan = Get-StandardTwoPhasePlan
        $plan.phases[0].tasks = @($plan.phases[0].tasks | Where-Object { $_.id -ne 't1' })
        $path = Join-Path $TestDrive 'rm.json'
        New-PlanFile -Path $path -Plan $plan
        $statePath = Join-Path $repo '.xagent/features/rm/state.json'
        if (Test-Path $statePath) { Remove-Item $statePath -Force }
        $r = Invoke-Feature @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'rm') -WorkingDirectory $repo
        $r.Json.error | Should -Match 'task t1 is already merged'
    }

    It 'rejects re-plan that changes merged task brief' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'rb' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        & git -C $repo commit --allow-empty -m 'merge t1' -m 'Xagent-Task: t1' | Out-Null
        $plan = Get-StandardTwoPhasePlan
        $plan.phases[0].tasks[0].brief = 'changed brief'
        $path = Join-Path $TestDrive 'rb.json'
        New-PlanFile -Path $path -Plan $plan
        $r = Invoke-Feature @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'rb') -WorkingDirectory $repo
        $r.Json.error | Should -Match 'task t1 is already merged'
    }

    It 'allows re-plan that keeps merged task and changes another' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'rok' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        & git -C $repo commit --allow-empty -m 'merge t1' -m 'Xagent-Task: t1' | Out-Null
        $plan = Get-StandardTwoPhasePlan
        $plan.phases[0].tasks[1].brief = 'updated t2 brief'
        $path = Join-Path $TestDrive 'rok.json'
        New-PlanFile -Path $path -Plan $plan
        $r = Invoke-Feature @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'rok') -WorkingDirectory $repo
        $r.Json.ok | Should -BeTrue
    }

    It 'plan.md renders empty dependsOn as em dash' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'em' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        $md = (& git -C $repo show 'HEAD:docs/features/em/plan.md') -join "`n"
        $dep = (($md -split "`n" | Where-Object { $_ -match '^\| t1 \|' } | Select-Object -First 1) -split '\|')[3].Trim()
        [int][char]$dep | Should -Be 0x2014
    }

    It 'plan.md joins files with br and escapes pipe in title' {
        $repo = New-TestRepo
        $plan = Get-StandardTwoPhasePlan
        $plan.phases[0].tasks[0].files = @('a', 'b')
        $plan.phases[0].tasks[0].title = 'pi|pe'
        Import-TestPlan -Repo $repo -Name 'mdr' -Plan $plan | Out-Null
        $md = (& git -C $repo show 'HEAD:docs/features/mdr/plan.md') -join "`n"
        $md | Should -Match 'a<br>b'
        $md | Should -Match 'pi\\\|pe'
    }

    It 'plan.md has no CR or BOM' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'encp' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        $bytes = [IO.File]::ReadAllBytes((Join-Path $repo 'docs/features/encp/plan.md'))
        $bytes[0] | Should -Not -Be 0xEF
        [Text.Encoding]::UTF8.GetString($bytes) | Should -Not -Match "`r"
    }

    It 'orders phases by n in feature.json and plan.md when input is reversed' {
        $repo = New-TestRepo
        $plan = Get-StandardTwoPhasePlan
        $plan.phases = @($plan.phases[1], $plan.phases[0])
        Import-TestPlan -Repo $repo -Name 'ord' -Plan $plan | Out-Null
        $feat = (& git -C $repo show 'HEAD:docs/features/ord/feature.json' | ConvertFrom-Json)
        $feat.phases[0].n | Should -Be 1
        $feat.phases[1].n | Should -Be 2
        $md = (& git -C $repo show 'HEAD:docs/features/ord/plan.md') -join "`n"
        ($md.IndexOf('## Phase 1')) | Should -BeLessThan ($md.IndexOf('## Phase 2'))
    }

    It 'rejects duplicate phase numbers' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'dpn' -Stage 'plan'
        $plan = @{
            summary = 'x'
            phases  = @(
                @{ n = 1; rationale = 'r'; test = 't'; tasks = @(@{ id = 'a'; title = 'a'; dependsOn = @(); files = @('a'); test = 't'; profile = 'code'; brief = 'b' }) },
                @{ n = 1; rationale = 'r'; test = 't'; tasks = @(@{ id = 'b'; title = 'b'; dependsOn = @(); files = @('b'); test = 't'; profile = 'code'; brief = 'b' }) }
            )
        }
        $path = Join-Path $TestDrive 'dpn.json'
        New-PlanFile -Path $path -Plan $plan
        $r = Invoke-Feature @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'dpn') -WorkingDirectory $repo
        $r.Json.error | Should -Match 'phases must be numbered 1..N'
    }

    It 'rejects self-dependency' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'self' -Stage 'plan'
        $plan = @{
            summary = 'x'
            phases  = @(@{
                    n = 1; rationale = 'r'; test = 't'
                    tasks = @(@{ id = 'a'; title = 'a'; dependsOn = @('a'); files = @('a'); test = 't'; profile = 'code'; brief = 'b' })
                })
        }
        $path = Join-Path $TestDrive 'self.json'
        New-PlanFile -Path $path -Plan $plan
        $r = Invoke-Feature @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'self') -WorkingDirectory $repo
        $r.Json.error | Should -Match 'dependency cycle involving a'
    }

    It 'rejected plan leaves HEAD feature.json plan.md and input file unchanged' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'nu' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        $head1 = & git -C $repo rev-parse HEAD
        $md1 = & git -C $repo show 'HEAD:docs/features/nu/plan.md'
        $path = Join-Path $TestDrive 'nu-bad.json'
        New-PlanFile -Path $path -Plan @{
            summary = 'x'
            phases  = @(@{
                    n = 1; rationale = 'r'; test = 't'
                    tasks = @(
                        @{ id = 'a'; title = 'a'; dependsOn = @('b'); files = @('a'); test = 't'; profile = 'code'; brief = 'b' },
                        @{ id = 'b'; title = 'b'; dependsOn = @('a'); files = @('b'); test = 't'; profile = 'code'; brief = 'b' }
                    )
                })
        }
        $null = Invoke-Feature @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'nu') -WorkingDirectory $repo
        & git -C $repo rev-parse HEAD | Should -Be $head1
        (& git -C $repo show 'HEAD:docs/features/nu/plan.md') | Should -Be $md1
        Test-Path -LiteralPath $path | Should -BeTrue
    }

    It 'plan on main fails branch check' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'mainp' -Stage 'plan'
        & git -C $repo switch main
        $path = Join-Path $TestDrive 'mainp.json'
        New-PlanFile -Path $path -Plan (Get-StandardTwoPhasePlan)
        $r = Invoke-Feature @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'mainp') -WorkingDirectory $repo
        $r.Json.error | Should -Match 'check out feature/mainp first'
    }

    It 'fails when PlanFile is missing' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'nop' -Stage 'plan'
        $r = Invoke-Feature @('plan', '-Repo', $repo, '-Name', 'nop') -WorkingDirectory $repo
        $r.Json.error | Should -Match 'PlanFile is required'
    }

    It 'fails when plan file does not exist' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'nof' -Stage 'plan'
        $r = Invoke-Feature @('plan', '-PlanFile', 'nope.json', '-Repo', $repo, '-Name', 'nof') -WorkingDirectory $repo
        $r.Json.error | Should -Match 'plan file not found'
    }

    It 'fails when plan file is not valid JSON' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'badj' -Stage 'plan'
        $path = Join-Path $TestDrive 'badj.txt'
        Set-Content -LiteralPath $path -Value 'not json' -NoNewline
        $r = Invoke-Feature @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'badj') -WorkingDirectory $repo
        $r.Json.error | Should -Match 'plan file is not valid JSON'
    }

    It 'in build, replacing pending t3 with t3a and t3b succeeds' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'bsplit' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        Move-FeatureToBuildStage -Repo $repo -Name 'bsplit'
        $plan = Get-StandardTwoPhasePlan
        $plan.phases[1].tasks = @(
            @{ id = 't3a'; title = 'Task 3a'; dependsOn = @('t2'); files = @('docs/readme.md'); test = 'npm test'; profile = 'code'; brief = 'Split a.' },
            @{ id = 't3b'; title = 'Task 3b'; dependsOn = @('t3a'); files = @('docs/readme.md'); test = 'npm test'; profile = 'code'; brief = 'Split b.' }
        )
        $path = Join-Path $TestDrive 'bsplit.json'
        New-PlanFile -Path $path -Plan $plan
        $r = Invoke-FeatureInProcess @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'bsplit') -WorkingDirectory $repo
        $r.Json.ok | Should -BeTrue
        $r.Json.stage | Should -Be 'build'
        $feat = (& git -C $repo show 'HEAD:docs/features/bsplit/feature.json' | ConvertFrom-Json)
        $ids = @($feat.phases[1].tasks | ForEach-Object { $_.id })
        $ids | Should -Contain 't3a'
        $ids | Should -Contain 't3b'
        $ids | Should -Not -Contain 't3'
        $feat.gates.'plan-approved' | Should -Not -BeNullOrEmpty
        $feat.stage | Should -Be 'build'
    }

    It 'in build, changing phase 2 rationale fails' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'bph' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        Move-FeatureToBuildStage -Repo $repo -Name 'bph'
        $plan = Get-StandardTwoPhasePlan
        $plan.phases[1].rationale = 'changed rationale'
        $path = Join-Path $TestDrive 'bph.json'
        New-PlanFile -Path $path -Plan $plan
        $r = Invoke-FeatureInProcess @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'bph') -WorkingDirectory $repo
        $r.Json.error | Should -Match 'phase 2 must stay unchanged'
    }

    It 'in build, with t1 running, changing t1 brief fails' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'brun' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        Move-FeatureToBuildStage -Repo $repo -Name 'brun'
        Set-TaskState -Repo $repo -Name 'brun' -States @{ t1 = 'running' }
        $plan = Get-StandardTwoPhasePlan
        $plan.phases[0].tasks[0].brief = 'changed brief'
        $path = Join-Path $TestDrive 'brun.json'
        New-PlanFile -Path $path -Plan $plan
        $r = Invoke-FeatureInProcess @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'brun') -WorkingDirectory $repo
        $r.Json.error | Should -Match 'task t1 is running and must stay unchanged'
    }

    It 'in build, with t3 failed, changing t3 brief succeeds' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'bfail' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        Move-FeatureToBuildStage -Repo $repo -Name 'bfail'
        Set-TaskState -Repo $repo -Name 'bfail' -States @{ t3 = 'failed' }
        $plan = Get-StandardTwoPhasePlan
        $plan.phases[1].tasks[0].brief = 'updated failed task'
        $path = Join-Path $TestDrive 'bfail.json'
        New-PlanFile -Path $path -Plan $plan
        $r = Invoke-FeatureInProcess @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'bfail') -WorkingDirectory $repo
        $r.Json.ok | Should -BeTrue
        $r.Json.stage | Should -Be 'build'
    }

    It 'in build, changing t3 files to docs/other.md fails' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'bfile' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        Move-FeatureToBuildStage -Repo $repo -Name 'bfile'
        $plan = Get-StandardTwoPhasePlan
        $plan.phases[1].tasks[0].files = @('docs/other.md')
        $path = Join-Path $TestDrive 'bfile.json'
        New-PlanFile -Path $path -Plan $plan
        $r = Invoke-FeatureInProcess @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'bfile') -WorkingDirectory $repo
        $r.Json.error | Should -Match "task t3 file docs/other.md is outside phase 2's declared files"
    }

    It 'in build, t3 files docs/ allows docs/sub/x.md' {
        $repo = New-TestRepo
        $plan0 = Get-StandardTwoPhasePlan
        $plan0.phases[1].tasks[0].files = @('docs/')
        Import-TestPlan -Repo $repo -Name 'bpfx' -Plan $plan0 | Out-Null
        Move-FeatureToBuildStage -Repo $repo -Name 'bpfx'
        $plan = Get-StandardTwoPhasePlan
        $plan.phases[1].tasks[0].files = @('docs/sub/x.md')
        $path = Join-Path $TestDrive 'bpfx.json'
        New-PlanFile -Path $path -Plan $plan
        $r = Invoke-FeatureInProcess @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'bpfx') -WorkingDirectory $repo
        $r.Json.ok | Should -BeTrue
    }

    It 'in build, t3 files *.md allows src/x.md' {
        $repo = New-TestRepo
        $plan0 = Get-StandardTwoPhasePlan
        $plan0.phases[1].tasks[0].files = @('*.md')
        Import-TestPlan -Repo $repo -Name 'bglob' -Plan $plan0 | Out-Null
        Move-FeatureToBuildStage -Repo $repo -Name 'bglob'
        $plan = Get-StandardTwoPhasePlan
        $plan.phases[1].tasks[0].files = @('src/x.md')
        $path = Join-Path $TestDrive 'bglob.json'
        New-PlanFile -Path $path -Plan $plan
        $r = Invoke-FeatureInProcess @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'bglob') -WorkingDirectory $repo
        $r.Json.ok | Should -BeTrue
    }

    It 'in build, with t2 in-review, changing t2 brief fails' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'brev' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        Move-FeatureToBuildStage -Repo $repo -Name 'brev'
        Set-TaskState -Repo $repo -Name 'brev' -States @{ t2 = 'in-review' }
        $plan = Get-StandardTwoPhasePlan
        $plan.phases[0].tasks[1].brief = 'changed'
        $path = Join-Path $TestDrive 'brev.json'
        New-PlanFile -Path $path -Plan $plan
        $r = Invoke-FeatureInProcess @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'brev') -WorkingDirectory $repo
        $r.Json.error | Should -Match 'task t2 is in-review and must stay unchanged'
    }

    It 'in build, with t2 running, moving t2 to phase 2 fails' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'bmove' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        Move-FeatureToBuildStage -Repo $repo -Name 'bmove'
        Set-TaskState -Repo $repo -Name 'bmove' -States @{ t2 = 'running' }
        $plan = Get-StandardTwoPhasePlan
        $t2 = $plan.phases[0].tasks | Where-Object { $_.id -eq 't2' }
        $t3 = $plan.phases[1].tasks[0]
        $plan.phases[0].tasks = @($plan.phases[0].tasks | Where-Object { $_.id -ne 't2' })
        $plan.phases[1].tasks = @($t2, $t3)
        $path = Join-Path $TestDrive 'bmove.json'
        New-PlanFile -Path $path -Plan $plan
        $r = Invoke-FeatureInProcess @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'bmove') -WorkingDirectory $repo
        $r.Json.error | Should -Match 'task t2 is running and must stay unchanged'
    }

    It 'in build, re-importing standard plan with reversed phase order succeeds' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'brevph' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        Move-FeatureToBuildStage -Repo $repo -Name 'brevph'
        $plan = Get-StandardTwoPhasePlan
        $plan.phases = @($plan.phases[1], $plan.phases[0])
        $path = Join-Path $TestDrive 'brevph.json'
        New-PlanFile -Path $path -Plan $plan
        $r = Invoke-FeatureInProcess @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'brevph') -WorkingDirectory $repo
        $r.Json.ok | Should -BeTrue
        $r.Json.stage | Should -Be 'build'
    }

    It 'in build, a plan with only phase 1 fails' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'boneph' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        Move-FeatureToBuildStage -Repo $repo -Name 'boneph'
        $plan = Get-StandardTwoPhasePlan
        $plan.phases = @($plan.phases[0])
        $path = Join-Path $TestDrive 'boneph.json'
        New-PlanFile -Path $path -Plan $plan
        $r = Invoke-FeatureInProcess @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'boneph') -WorkingDirectory $repo
        $r.Json.error | Should -Match 'the phases must stay unchanged'
    }

    It 'in stage plan, output has stage plan' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'stout' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        $path = Join-Path $TestDrive 'stout.json'
        New-PlanFile -Path $path -Plan (Get-StandardTwoPhasePlan)
        $r = Invoke-FeatureInProcess @('plan', '-PlanFile', $path, '-Repo', $repo, '-Name', 'stout') -WorkingDirectory $repo
        $r.Json.ok | Should -BeTrue
        $r.Json.stage | Should -Be 'plan'
    }
}

Describe 'feature.ps1 schedule' {
    It 'returns empty tasks when feature has no plan' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'npl' -Stage 'plan'
        $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'npl') -WorkingDirectory $repo
        $r.Json.liveRuns | Should -Be 0
        $r.Json.cap | Should -Be 2
        $r.Json.tasks | Should -Be @()
        Test-Schema -Json ($r.Json | ConvertTo-Json -Depth 6) -SchemaName 'schedule' | Should -BeTrue
    }

    It 'dependency gating returns only ready task' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'dep' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        $r1 = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'dep') -WorkingDirectory $repo
        $r1.Json.tasks.id | Should -Be @('t1')
        Set-TaskState -Repo $repo -Name 'dep' -States @{ t1 = 'merged' }
        $r2 = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'dep') -WorkingDirectory $repo
        $r2.Json.tasks.id | Should -Be @('t2')
    }

    It 'overlap: equal paths' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'ov1' -Plan (New-OverlapTestPlan -FileA 'src/x.ts' -FileB 'src/x.ts') | Out-Null
        Set-TaskState -Repo $repo -Name 'ov1' -States @{ ta = 'running' }
        $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'ov1') -WorkingDirectory $repo
        $r.Json.tasks | Should -Be @()
    }

    It 'overlap: src/a.ts vs src/a.tsx does not overlap' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'ov7' -Plan (New-OverlapTestPlan -FileA 'src/a.ts' -FileB 'src/a.tsx') | Out-Null
        Set-TaskState -Repo $repo -Name 'ov7' -States @{ ta = 'running' }
        $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'ov7') -WorkingDirectory $repo
        $r.Json.tasks.id | Should -Be @('tb')
    }

    It 'returns two non-overlapping ready tasks' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'two' -Plan (New-OverlapTestPlan -FileA 'src/a.ts' -FileB 'src/b.ts') | Out-Null
        $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'two') -WorkingDirectory $repo
        $r.Json.tasks.id | Should -Be @('ta', 'tb')
    }

    It 'returns only first when two pending tasks overlap each other' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'fov' -Plan (New-OverlapTestPlan -FileA 'src/' -FileB 'src/x.ts') | Out-Null
        $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'fov') -WorkingDirectory $repo
        $r.Json.tasks.id | Should -Be @('ta')
    }

    It 'cap blocks tasks when two live runs exist for feature' -Tag 'Slow' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'cap' -Plan (New-OverlapTestPlan -FileA 'a' -FileB 'b') | Out-Null
        $holder = Start-Process -PassThru -WindowStyle Hidden -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60')
        try {
            Start-Sleep -Milliseconds 300
            $holder.Refresh()
            $start = $holder.StartTime.ToUniversalTime().ToString('o')
            $runDir = Join-Path $repo '.xagent/runs/s1'
            New-Item -ItemType Directory -Force $runDir | Out-Null
            $body = (@{ pid = $holder.Id; startTime = $start; feature = 'cap' } | ConvertTo-Json -Compress)
            Set-Content -LiteralPath (Join-Path $runDir 'a.pid') -Value $body -NoNewline
            Set-Content -LiteralPath (Join-Path $runDir 'b.pid') -Value $body -NoNewline
            $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'cap') -WorkingDirectory $repo
            $r.Json.liveRuns | Should -Be 2
            $r.Json.tasks | Should -Be @()
        } finally {
            Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'live run count ignores pid files for another feature' -Tag 'Slow' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'cap2' -Plan (New-OverlapTestPlan -FileA 'a' -FileB 'b') | Out-Null
        $holder = Start-Process -PassThru -WindowStyle Hidden -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60')
        try {
            Start-Sleep -Milliseconds 300
            $holder.Refresh()
            $start = $holder.StartTime.ToUniversalTime().ToString('o')
            $runDir = Join-Path $repo '.xagent/runs/s2'
            New-Item -ItemType Directory -Force $runDir | Out-Null
            $body = (@{ pid = $holder.Id; startTime = $start; feature = 'other' } | ConvertTo-Json -Compress)
            Set-Content -LiteralPath (Join-Path $runDir 'x.pid') -Value $body -NoNewline
            Set-Content -LiteralPath (Join-Path $runDir 'y.pid') -Value $body -NoNewline
            $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'cap2') -WorkingDirectory $repo
            $r.Json.liveRuns | Should -Be 0
        } finally {
            Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'mismatched start time is not live' -Tag 'Slow' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'cap3' -Plan (New-OverlapTestPlan -FileA 'a' -FileB 'b') | Out-Null
        $holder = Start-Process -PassThru -WindowStyle Hidden -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60')
        try {
            Start-Sleep -Milliseconds 300
            $runDir = Join-Path $repo '.xagent/runs/s3'
            New-Item -ItemType Directory -Force $runDir | Out-Null
            $body = (@{ pid = $holder.Id; startTime = '2019-01-01T00:00:00.0000000Z'; feature = 'cap3' } | ConvertTo-Json -Compress)
            Set-Content -LiteralPath (Join-Path $runDir 'z.pid') -Value $body -NoNewline
            $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'cap3') -WorkingDirectory $repo
            $r.Json.liveRuns | Should -Be 0
            $r.Json.tasks.id | Should -Be @('ta', 'tb')
        } finally {
            Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'open stop returns empty tasks' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'stp' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        Assert-FeatureOk (Invoke-Feature @('decision', '-Kind', 'stop', '-Text', 'wait', '-Repo', $repo, '-Name', 'stp') -WorkingDirectory $repo)
        $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'stp') -WorkingDirectory $repo
        $r.Json.tasks | Should -Be @()
    }

    It 'returns delegateTaskId and model from models.json' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'mod' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'mod') -WorkingDirectory $repo
        $t1 = $r.Json.tasks | Where-Object { $_.id -eq 't1' } | Select-Object -First 1
        $t1.delegateTaskId | Should -Be 'mod-t1'
        $t1.model | Should -Be 'composer-2.5'
        Set-TaskState -Repo $repo -Name 'mod' -States @{ t1 = 'merged' }
        $r2 = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'mod') -WorkingDirectory $repo
        $t2 = $r2.Json.tasks | Where-Object { $_.id -eq 't2' } | Select-Object -First 1
        $t2.model | Should -Be 'grok-4.7-high'
    }

    It 'advances to phase 2 when phase 1 is merged' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'ph2' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        Set-TaskState -Repo $repo -Name 'ph2' -States @{ t1 = 'merged'; t2 = 'merged' }
        $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'ph2') -WorkingDirectory $repo
        $r.Json.tasks.id | Should -Be @('t3')
    }

    It 'does not return failed tasks' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'fail' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        Set-TaskState -Repo $repo -Name 'fail' -States @{ t1 = 'failed' }
        $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'fail') -WorkingDirectory $repo
        $r.Json.tasks.id | Should -Not -Contain 't1'
    }

    It 'returns one task when one live run and two ready tasks' -Tag 'Slow' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'one' -Plan (New-OverlapTestPlan -FileA 'a' -FileB 'b') | Out-Null
        $holder = Start-Process -PassThru -WindowStyle Hidden -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60')
        try {
            Start-Sleep -Milliseconds 300
            $holder.Refresh()
            $start = $holder.StartTime.ToUniversalTime().ToString('o')
            $runDir = Join-Path $repo '.xagent/runs/one'
            New-Item -ItemType Directory -Force $runDir | Out-Null
            $body = (@{ pid = $holder.Id; startTime = $start; feature = 'one' } | ConvertTo-Json -Compress)
            Set-Content -LiteralPath (Join-Path $runDir 'r.pid') -Value $body -NoNewline
            $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'one') -WorkingDirectory $repo
            $r.Json.liveRuns | Should -Be 1
            $r.Json.tasks.Count | Should -Be 1
        } finally {
            Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'overlap against in-review task' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'rev' -Plan (New-OverlapTestPlan -FileA 'src/x.ts' -FileB 'src/x.ts') | Out-Null
        Set-TaskState -Repo $repo -Name 'rev' -States @{ ta = 'in-review' }
        $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'rev') -WorkingDirectory $repo
        $r.Json.tasks | Should -Be @()
    }

    It 'is read-only and works from main' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'ro' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        $stateBefore = Test-Path (Join-Path $repo '.xagent/features/ro/state.json')
        & git -C $repo switch main
        $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'ro') -WorkingDirectory $repo
        $r.Json.ok | Should -BeTrue
        Test-Path (Join-Path $repo '.xagent/features/ro/.lock') | Should -BeFalse
        if (-not $stateBefore) {
            Test-Path (Join-Path $repo '.xagent/features/ro/state.json') | Should -BeFalse
        }
    }

    It 'fails for missing feature branch' {
        $repo = New-TestRepo
        $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'ghost') -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'no feature ghost'
    }

    It 'returns array-shaped tasks and files for a one-task plan' {
        $repo = New-TestRepo
        $plan = @{
            summary = 'one task'
            phases  = @(@{
                    n = 1; rationale = 'r'; test = 't'
                    tasks = @(@{
                            id = 'solo'; title = 'solo'; dependsOn = @(); files = @('src/a.ts')
                            test = 't'; profile = 'code'; brief = 'b'
                        })
                })
        }
        Import-TestPlan -Repo $repo -Name 'sched1' -Plan $plan | Out-Null
        $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'sched1') -WorkingDirectory $repo
        Test-Schema -Json $r.Raw -SchemaName 'schedule' | Should -BeTrue
        $r.Json.tasks -is [array] | Should -BeTrue
        $r.Json.tasks.Count | Should -Be 1
        $r.Json.tasks[0].files -is [array] | Should -BeTrue
        $r.Json.tasks[0].files[0] | Should -Be 'src/a.ts'
    }

    It 'schedule -Repo on repo subfolder matches repo root' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'subsch' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        $sub = Join-Path $repo 'docs/sub'
        New-Item -ItemType Directory -Force -Path $sub | Out-Null
        $rRoot = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'subsch') -WorkingDirectory $repo
        $rSub = Invoke-Feature @('schedule', '-Repo', $sub, '-Name', 'subsch') -WorkingDirectory $sub
        $rSub.Json.tasks.id | Should -Be $rRoot.Json.tasks.id
    }
}

Describe 'feature.ps1 task' {
    It 'sets status, sessionId, resultFile, worktree, baseSha and validates state.json' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'tsk' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        $base = & git -C $repo rev-parse 'feature/tsk'
        $r = Invoke-Feature @(
            'task', '-Repo', $repo, '-Name', 'tsk', '-Task', 't1',
            '-Status', 'running', '-SessionId', 's1', '-ResultFile', '/r.json',
            '-Worktree', 'D:/wt', '-BaseSha', $base
        ) -WorkingDirectory $repo
        $r.Json.ok | Should -BeTrue
        $statePath = Join-Path $repo '.xagent/features/tsk/state.json'
        $stateJson = Get-Content -Raw -LiteralPath $statePath
        Test-Schema -Json $stateJson -SchemaName 'state' | Should -BeTrue
        $r.Json.state.status | Should -Be 'running'
        $r.Json.state.sessionId | Should -Be 's1'
    }

    It 'stores worktree as absolute path with forward slashes' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'wtrel' -Plan (New-OneTaskPlan) | Out-Null
        $rel = Join-Path $repo 'sub\wt'
        New-Item -ItemType Directory -Force (Split-Path $rel) | Out-Null
        $base = & git -C $repo rev-parse 'feature/wtrel'
        $r = Invoke-Feature @(
            'task', '-Repo', $repo, '-Name', 'wtrel', '-Task', 't1',
            '-Worktree', $rel, '-BaseSha', $base
        ) -WorkingDirectory $repo
        $r.Json.state.worktree | Should -Match '^[A-Za-z]:/'
        $r.Json.state.worktree | Should -Not -Match '\\'
    }

    It 'only changes passed fields' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'part' -Plan (New-OneTaskPlan) | Out-Null
        Assert-FeatureOk (Invoke-Feature @('task', '-Repo', $repo, '-Name', 'part', '-Task', 't1', '-SessionId', 'keep') -WorkingDirectory $repo)
        $r = Invoke-Feature @('task', '-Repo', $repo, '-Name', 'part', '-Task', 't1', '-Status', 'running') -WorkingDirectory $repo
        $r.Json.state.sessionId | Should -Be 'keep'
        $r = Invoke-Feature @('task', '-Repo', $repo, '-Name', 'part', '-Task', 't1', '-SessionId', '', '-BaseSha', '') -WorkingDirectory $repo
        $r.Json.state.sessionId | Should -BeNullOrEmpty
        $r.Json.state.baseSha | Should -BeNullOrEmpty
    }

    It 'succeeds with no field params and prints default record' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'def' -Plan (New-OneTaskPlan) | Out-Null
        $r = Invoke-Feature @('task', '-Repo', $repo, '-Name', 'def', '-Task', 't1') -WorkingDirectory $repo
        $r.Json.ok | Should -BeTrue
        $r.Json.state.status | Should -Be 'pending'
        $r.Json.state.failures | Should -Be 0
    }

    It 'keeps another task record and lastReconcile' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'keep' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        Set-TaskState -Repo $repo -Name 'keep' -States @{ t2 = 'in-review' }
        $statePath = Join-Path $repo '.xagent/features/keep/state.json'
        $lr = (Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json).lastReconcile
        Assert-FeatureOk (Invoke-Feature @('task', '-Repo', $repo, '-Name', 'keep', '-Task', 't1', '-Status', 'running') -WorkingDirectory $repo)
        $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        $state.tasks.t2.status | Should -Be 'in-review'
        $state.lastReconcile | Should -Be $lr
    }

    It 'increments failures on failed and not when already failed' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'fail' -Plan (New-OneTaskPlan) | Out-Null
        Assert-FeatureOk (Invoke-Feature @('task', '-Repo', $repo, '-Name', 'fail', '-Task', 't1', '-Status', 'failed') -WorkingDirectory $repo)
        Invoke-Feature @('task', '-Repo', $repo, '-Name', 'fail', '-Task', 't1', '-Status', 'failed') -WorkingDirectory $repo | Out-Null
        $n = (Invoke-Feature @('task', '-Repo', $repo, '-Name', 'fail', '-Task', 't1') -WorkingDirectory $repo).Json.state.failures
        $n | Should -Be 1
        Assert-FeatureOk (Invoke-Feature @('task', '-Repo', $repo, '-Name', 'fail', '-Task', 't1', '-Status', 'pending') -WorkingDirectory $repo)
        Assert-FeatureOk (Invoke-Feature @('task', '-Repo', $repo, '-Name', 'fail', '-Task', 't1', '-Status', 'failed') -WorkingDirectory $repo)
        $n2 = (Invoke-Feature @('task', '-Repo', $repo, '-Name', 'fail', '-Task', 't1') -WorkingDirectory $repo).Json.state.failures
        $n2 | Should -Be 2
    }

    It 'fails on invalid status, unknown task, bad BaseSha, missing Task' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'err' -Plan (New-OneTaskPlan) | Out-Null
        $base = & git -C $repo rev-parse 'feature/err'
        (Invoke-Feature @('task', '-Repo', $repo, '-Name', 'err', '-Task', 't1', '-Status', 'bogus') -WorkingDirectory $repo).Json.error | Should -Match 'invalid status'
        (Invoke-Feature @('task', '-Repo', $repo, '-Name', 'err', '-Task', 'nope') -WorkingDirectory $repo).Json.error | Should -Match 'unknown task'
        (Invoke-Feature @('task', '-Repo', $repo, '-Name', 'err', '-Task', 't1', '-BaseSha', 'bad') -WorkingDirectory $repo).Json.error | Should -Match 'invalid -BaseSha'
        (Invoke-Feature @('task', '-Repo', $repo, '-Name', 'err') -WorkingDirectory $repo).Json.error | Should -Match '-Task is required'
    }

    It 'does not change git HEAD or porcelain and works on main' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'mainok' -Plan (New-OneTaskPlan) | Out-Null
        & git -C $repo switch main 2>&1 | Out-Null
        $headBefore = & git -C $repo rev-parse HEAD
        $porcBefore = & git -C $repo status --porcelain
        Assert-FeatureOk (Invoke-Feature @('task', '-Repo', $repo, '-Name', 'mainok', '-Task', 't1', '-Status', 'running') -WorkingDirectory $repo)
        & git -C $repo rev-parse HEAD | Should -Be $headBefore
        @(& git -C $repo status --porcelain) | Should -Be @($porcBefore | Where-Object { $_ })
    }
}

Describe 'feature.ps1 verify' {
    It 'lists committed and uncommitted in-scope changes' -Tag 'Slow' {
        $repo = New-TestRepo
        $wt = $null
        try {
            $ctx = New-TaskWorktree -Repo $repo -Name 'vc1' -Files @('src/a.ts')
            $wt = (Get-TaskWorktreeRoot $ctx)
            New-Item -ItemType Directory -Force (Join-Path $wt 'src') | Out-Null
            Set-Content -LiteralPath (Join-Path $wt 'src/a.ts') -Value 'a' -NoNewline
            & git -C $wt add src/a.ts 2>&1 | Out-Null
            & git -C $wt commit -m c 2>&1 | Out-Null
            Set-Content -LiteralPath (Join-Path $wt 'src/a.ts') -Value 'b'
            $r = Invoke-Feature @('verify', '-Repo', $repo, '-Name', 'vc1', '-Task', 't1') -WorkingDirectory $repo
            Test-Schema -Json $r.Raw -SchemaName 'verify' | Should -BeTrue
            $r.Json.inScope | Should -BeTrue
            $r.Json.changed | Should -Contain 'src/a.ts'
            $r.Json.changed.Count | Should -BeGreaterOrEqual 1
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
    }

    It 'flags in-scope and out-of-scope changed files' -Tag 'Slow' {
        $repo = New-TestRepo
        $wt = $null
        try {
            $ctx = New-TaskWorktree -Repo $repo -Name 'vscope' -Files @('src/test*.ts')
            $wt = (Get-TaskWorktreeRoot $ctx)
            New-Item -ItemType Directory -Force (Join-Path $wt 'src') | Out-Null
            Set-Content -LiteralPath (Join-Path $wt 'src/testing.ts') -Value 'in' -NoNewline
            Set-Content -LiteralPath (Join-Path $wt 'src/other.ts') -Value 'out' -NoNewline
            & git -C $wt add src/testing.ts src/other.ts 2>&1 | Out-Null
            & git -C $wt commit -m c 2>&1 | Out-Null
            $r = Invoke-Feature @('verify', '-Repo', $repo, '-Name', 'vscope', '-Task', 't1') -WorkingDirectory $repo
            $r.Json.inScope | Should -Be $false
            $r.Json.changed | Should -Contain 'src/testing.ts'
            $r.Json.changed | Should -Contain 'src/other.ts'
            $r.Json.outOfScope | Should -Be @('src/other.ts')
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
    }

    It 'puts untracked cache in ignoredCaches not changed' -Tag 'Slow' {
        $repo = New-TestRepo
        $wt = $null
        try {
            $ctx = New-TaskWorktree -Repo $repo -Name 'vigc' -Files @('calc.py')
            $wt = (Get-TaskWorktreeRoot $ctx)
            Set-Content (Join-Path $wt 'calc.py') -Value 'x' -NoNewline
            & git -C $wt add calc.py 2>&1 | Out-Null
            & git -C $wt commit -m c 2>&1 | Out-Null
            New-Item -ItemType Directory -Force (Join-Path $wt '__pycache__') | Out-Null
            Set-Content (Join-Path $wt '__pycache__/calc.cpython-314.pyc') -Value 'z'
            $r = Invoke-Feature @('verify', '-Repo', $repo, '-Name', 'vigc', '-Task', 't1') -WorkingDirectory $repo
            $r.Json.inScope | Should -BeTrue
            $r.Json.changed | Should -Contain 'calc.py'
            $r.Json.changed | Should -Not -Contain '__pycache__/calc.cpython-314.pyc'
            $r.Json.outOfScope | Should -Not -Contain '__pycache__/calc.cpython-314.pyc'
            $r.Json.ignoredCaches | Should -Contain '__pycache__/calc.cpython-314.pyc'
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
    }

    It 'still lists tracked modified pyc in changed and outOfScope' -Tag 'Slow' {
        $repo = New-TestRepo
        $wt = $null
        try {
            Import-TestPlan -Repo $repo -Name 'vtrp' -Plan (New-OneTaskPlan -Files @('calc.py')) | Out-Null
            New-Item -ItemType Directory -Force (Join-Path $repo 'bin') | Out-Null
            Set-Content (Join-Path $repo 'bin/legacy.pyc') -Value 'v1' -NoNewline
            & git -C $repo add bin/legacy.pyc 2>&1 | Out-Null
            & git -C $repo commit -m 'track pyc' 2>&1 | Out-Null
            $ctx = New-TaskWorktree -Repo $repo -Name 'vtrp' -Files @('calc.py') -NoRecord -SkipPlanImport
            $wt = (Get-TaskWorktreeRoot $ctx)
            Assert-FeatureOk (Invoke-Feature @(
                    'task', '-Repo', $repo, '-Name', 'vtrp', '-Task', 't1',
                    '-Worktree', $wt, '-BaseSha', $ctx.BaseSha
                ) -WorkingDirectory $repo)
            Set-Content (Join-Path $wt 'calc.py') -Value 'ok' -NoNewline
            & git -C $wt add calc.py 2>&1 | Out-Null
            & git -C $wt commit -m c 2>&1 | Out-Null
            Set-Content (Join-Path $wt 'bin/legacy.pyc') -Value 'v2' -NoNewline
            $r = Invoke-Feature @('verify', '-Repo', $repo, '-Name', 'vtrp', '-Task', 't1') -WorkingDirectory $repo
            $r.Json.changed | Should -Contain 'bin/legacy.pyc'
            $r.Json.outOfScope | Should -Contain 'bin/legacy.pyc'
            $r.Json.inScope | Should -BeFalse
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
    }

    It 'counts untracked, ignores __pycache__ and .xagent' -Tag 'Slow' {
        $repo = New-TestRepo
        $wt = $null
        try {
            Import-TestPlan -Repo $repo -Name 'vu' -Plan (New-OneTaskPlan -Files @('src/a.ts')) | Out-Null
            Set-Content (Join-Path $repo '.gitignore') -Value '__pycache__/'
            & git -C $repo add .gitignore 2>&1 | Out-Null
            & git -C $repo commit -m 'ignore pycache' 2>&1 | Out-Null
            $ctx = New-TaskWorktree -Repo $repo -Name 'vu' -Files @('src/a.ts') -NoRecord -SkipPlanImport
            $wt = (Get-TaskWorktreeRoot $ctx)
            Assert-FeatureOk (Invoke-Feature @(
                    'task', '-Repo', $repo, '-Name', 'vu', '-Task', 't1',
                    '-Worktree', $wt, '-BaseSha', $ctx.BaseSha
                ) -WorkingDirectory $repo)
            New-Item -ItemType Directory -Force (Join-Path $wt 'src') | Out-Null
            Set-Content (Join-Path $wt 'src/new.ts') -Value 'n'
            New-Item -ItemType Directory -Force (Join-Path $wt 'src/__pycache__') | Out-Null
            Set-Content (Join-Path $wt 'src/__pycache__/z.pyc') -Value 'z'
            New-Item -ItemType Directory -Force (Join-Path $wt '.xagent') | Out-Null
            Set-Content (Join-Path $wt '.xagent/local.json') -Value '{}'
            $r = Invoke-Feature @('verify', '-Repo', $repo, '-Name', 'vu', '-Task', 't1') -WorkingDirectory $repo
            $r.Json.changed | Should -Contain 'src/new.ts'
            $r.Json.changed | Should -Not -Contain 'src/__pycache__/z.pyc'
            $r.Json.changed | Should -Not -Contain '.xagent/local.json'
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
    }

    It 'serializes changed as JSON array for zero or one element' -Tag 'Slow' {
        $repo = New-TestRepo
        $wt = $null
        try {
            $ctx = New-TaskWorktree -Repo $repo -Name 'varr' -Files @('only.ts')
            $wt = (Get-TaskWorktreeRoot $ctx)
            Set-Content (Join-Path $wt 'only.ts') -Value '1' -NoNewline
            & git -C $wt add only.ts 2>&1 | Out-Null
            & git -C $wt commit -m c 2>&1 | Out-Null
            $r = Invoke-Feature @('verify', '-Repo', $repo, '-Name', 'varr', '-Task', 't1') -WorkingDirectory $repo
            $r.Raw | Should -Match '"changed":\["only\.ts"\]'
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
        $repo2 = New-TestRepo
        $wt2 = $null
        try {
            $wt2 = Get-TaskWorktreeRoot (New-TaskWorktree -Repo $repo2 -Name 'vempty' -Files @('none.ts'))
            $r2 = Invoke-Feature @('verify', '-Repo', $repo2, '-Name', 'vempty', '-Task', 't1') -WorkingDirectory $repo2
            $r2.Raw | Should -Match '"changed":\[\]'
        } finally {
            if ($wt2) { Remove-TaskWorktree -Repo $repo2 -WtRoot $wt2 }
        }
    }

    It 'runs test command and records pass or fail with exit 0 on verify' -Tag 'Slow' {
        $repo = New-TestRepo
        $wt = $null
        try {
            $ctx = New-TaskWorktree -Repo $repo -Name 'vtpass' -Test 'pwsh -NoProfile -c "exit 0"'
            $wt = (Get-TaskWorktreeRoot $ctx)
            $r = Invoke-Feature @('verify', '-Repo', $repo, '-Name', 'vtpass', '-Task', 't1') -WorkingDirectory $repo
            $r.ExitCode | Should -Be 0
            $r.Json.test.passed | Should -BeTrue
            $r.Json.test.exitCode | Should -Be 0
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
        $repo2 = New-TestRepo
        $wt = $null
        try {
            $ctx = New-TaskWorktree -Repo $repo2 -Name 'vtfail' -Test 'pwsh -NoProfile -c "exit 3"'
            $wt = (Get-TaskWorktreeRoot $ctx)
            $r = Invoke-Feature @('verify', '-Repo', $repo2, '-Name', 'vtfail', '-Task', 't1') -WorkingDirectory $repo2
            $r.ExitCode | Should -Be 0
            $r.Json.test.passed | Should -BeFalse
            $r.Json.test.exitCode | Should -Be 3
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo2 -WtRoot $wt }
        }
    }

    It 'captures hello in tail' -Tag 'Slow' {
        $repo = New-TestRepo
        $wt = $null
        try {
            $ctx = New-TaskWorktree -Repo $repo -Name 'vtail' -Test 'pwsh -NoProfile -c "Write-Output hello"'
            $wt = (Get-TaskWorktreeRoot $ctx)
            $r = Invoke-Feature @('verify', '-Repo', $repo, '-Name', 'vtail', '-Task', 't1') -WorkingDirectory $repo
            $r.Json.test.tail | Should -Match 'hello'
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
    }

    It 'times out and kills process tree' -Tag 'Slow' {
        $repo = New-TestRepo
        $wt = $null
        $sleeperPid = $null
        try {
            $cmd = 'pwsh -NoProfile -c ''$PID | Set-Content sleeper.pid; Start-Sleep 30'''
            $ctx = New-TaskWorktree -Repo $repo -Name 'vto' -Test $cmd
            $wt = (Get-TaskWorktreeRoot $ctx)
            $r = Invoke-Feature @('verify', '-Repo', $repo, '-Name', 'vto', '-Task', 't1', '-TimeoutSec', '5') -WorkingDirectory $repo
            $r.Json.test.exitCode | Should -Be -1
            $r.Json.test.passed | Should -BeFalse
            $r.Json.test.tail | Should -Match 'timed out after 5 s'
            $pidFile = Join-Path $wt 'sleeper.pid'
            if (Test-Path -LiteralPath $pidFile) {
                $sleeperPid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
            }
            if (-not $sleeperPid) { Set-ItResult -Failed -Because 'sleeper.pid missing' }
            $running = Get-Process -Id $sleeperPid -ErrorAction SilentlyContinue
            $running | Should -BeNullOrEmpty
        } finally {
            if ($sleeperPid) {
                Stop-Process -Id $sleeperPid -Force -ErrorAction SilentlyContinue
            }
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
    }

    It 'stores verify in state without changing status' -Tag 'Slow' {
        $repo = New-TestRepo
        $wt = $null
        try {
            $ctx = New-TaskWorktree -Repo $repo -Name 'vst' -Files @('src/a.ts') -NoRecord
            $wt = (Get-TaskWorktreeRoot $ctx)
            $base = & git -C $repo rev-parse 'feature/vst'
            Assert-FeatureOk (Invoke-Feature @(
                    'task', '-Repo', $repo, '-Name', 'vst', '-Task', 't1',
                    '-Worktree', $wt, '-BaseSha', $base, '-Status', 'in-review'
                ) -WorkingDirectory $repo)
            Invoke-Feature @('verify', '-Repo', $repo, '-Name', 'vst', '-Task', 't1') -WorkingDirectory $repo | Out-Null
            $state = Get-Content -Raw (Join-Path $repo '.xagent/features/vst/state.json') | ConvertFrom-Json
            $state.tasks.t1.verify | Should -Not -BeNullOrEmpty
            $state.tasks.t1.status | Should -Be 'in-review'
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
    }

    It 'does not change worktree git status or HEAD' -Tag 'Slow' {
        $repo = New-TestRepo
        $wt = $null
        try {
            $ctx = New-TaskWorktree -Repo $repo -Name 'vwt' -Test 'pwsh -NoProfile -c "exit 0"'
            $wt = (Get-TaskWorktreeRoot $ctx)
            $head = & git -C $wt rev-parse HEAD
            $porc = & git -C $wt status --porcelain
            Invoke-Feature @('verify', '-Repo', $repo, '-Name', 'vwt', '-Task', 't1') -WorkingDirectory $repo | Out-Null
            & git -C $wt rev-parse HEAD | Should -Be $head
            @(& git -C $wt status --porcelain) | Should -Be @($porc | Where-Object { $_ })
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
    }

    It 'fails without worktree and when folder missing' -Tag 'Slow' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'vnowt' -Plan (New-OneTaskPlan) | Out-Null
        (Invoke-Feature @('verify', '-Repo', $repo, '-Name', 'vnowt', '-Task', 't1') -WorkingDirectory $repo).Json.error | Should -Match 'no worktree in state'
        $repo2 = New-TestRepo
        $ctx = New-TaskWorktree -Repo $repo2 -Name 'vgone' -NoRecord
        $base = $ctx.BaseSha
        Assert-FeatureOk (Invoke-Feature @(
                'task', '-Repo', $repo2, '-Name', 'vgone', '-Task', 't1',
                '-Worktree', (Get-TaskWorktreeRoot $ctx), '-BaseSha', $base
            ) -WorkingDirectory $repo2)
        Remove-TaskWorktree -Repo $repo2 -WtRoot (Get-TaskWorktreeRoot $ctx)
        (Invoke-Feature @('verify', '-Repo', $repo2, '-Name', 'vgone', '-Task', 't1') -WorkingDirectory $repo2).Json.error | Should -Match 'worktree not found'
    }

    It 'computes changed before test writes out.txt' -Tag 'Slow' {
        $repo = New-TestRepo
        $wt = $null
        try {
            $test = 'pwsh -NoProfile -c "Set-Content out.txt x"'
            $ctx = New-TaskWorktree -Repo $repo -Name 'vpre' -Test $test
            $wt = (Get-TaskWorktreeRoot $ctx)
            $r = Invoke-Feature @('verify', '-Repo', $repo, '-Name', 'vpre', '-Task', 't1') -WorkingDirectory $repo
            $r.Json.changed | Should -Not -Contain 'out.txt'
            Test-Path (Join-Path $wt 'out.txt') | Should -BeTrue
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
    }

    It 'fails invalid TimeoutSec, unknown task, missing Task' -Tag 'Slow' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'verr' -Plan (New-OneTaskPlan) | Out-Null
        foreach ($t in @('0', '-1', 'abc')) {
            (Invoke-Feature @('verify', '-Repo', $repo, '-Name', 'verr', '-Task', 't1', '-TimeoutSec', $t) -WorkingDirectory $repo).Json.error | Should -Match 'invalid -TimeoutSec'
        }
        (Invoke-Feature @('verify', '-Repo', $repo, '-Name', 'verr', '-Task', 'nope') -WorkingDirectory $repo).Json.error | Should -Match 'unknown task'
        (Invoke-Feature @('verify', '-Repo', $repo, '-Name', 'verr') -WorkingDirectory $repo).Json.error | Should -Match '-Task is required'
    }
}

Describe 'feature.ps1 merge' {
    It 'merges task branch with trailer and updates state' -Tag 'Slow' {
        $repo = New-TestRepo
        $wt = $null
        try {
            $ctx = New-TaskWorktree -Repo $repo -Name 'mg1'
            $wt = (Get-TaskWorktreeRoot $ctx)
            New-Item -ItemType Directory -Force (Join-Path $wt 'src') | Out-Null
            Set-Content (Join-Path $wt 'src/a.ts') -Value 'ok' -NoNewline
            & git -C $wt add src/a.ts 2>&1 | Out-Null
            & git -C $wt commit -m 'task change' 2>&1 | Out-Null
            & git -C $repo switch "feature/mg1" 2>&1 | Out-Null
            Test-Path (Join-Path $repo '.git/MERGE_HEAD') | Should -BeFalse
            $r = Invoke-Feature @('merge', '-Repo', $repo, '-Name', 'mg1', '-Task', 't1', '-Message', 'merge t1') -WorkingDirectory $repo
            $r.Json.ok | Should -BeTrue
            $parents = @(& git -C $repo rev-parse HEAD^@)
            $parents.Count | Should -Be 2
            (& git -C $repo log -1 --format=%s) | Should -Be 'merge t1'
            $taskTrailer = @(& git -C $repo log -1 --format='%(trailers:key=Xagent-Task,valueonly)') | Where-Object { $_ } | Select-Object -First 1
            $taskTrailer | Should -Be 't1'
            $st = Get-Content -Raw (Join-Path $repo '.xagent/features/mg1/state.json') | ConvertFrom-Json
            $st.tasks.t1.status | Should -Be 'merged'
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
    }

    It 'rejects re-plan change to merged task' -Tag 'Slow' {
        $repo = New-TestRepo
        $wt = $null
        try {
            $ctx = New-TaskWorktree -Repo $repo -Name 'mgplan'
            $wt = (Get-TaskWorktreeRoot $ctx)
            New-Item -ItemType Directory -Force (Join-Path $wt 'src') | Out-Null
            Set-Content (Join-Path $wt 'src/a.ts') -Value 'x' -NoNewline
            & git -C $wt add src/a.ts 2>&1 | Out-Null
            & git -C $wt commit -m c 2>&1 | Out-Null
            & git -C $repo switch 'feature/mgplan' 2>&1 | Out-Null
            Assert-FeatureOk (Invoke-Feature @('merge', '-Repo', $repo, '-Name', 'mgplan', '-Task', 't1', '-Message', 'm') -WorkingDirectory $repo)
            $plan = New-OneTaskPlan
            $plan.phases[0].tasks[0].brief = 'changed'
            $planPath = Join-Path $TestDrive 'replan.json'
            New-PlanFile -Path $planPath -Plan $plan
            $r = Invoke-Feature @('plan', '-PlanFile', $planPath, '-Repo', $repo, '-Name', 'mgplan') -WorkingDirectory $repo
            $r.Json.error | Should -Match 'already merged'
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
    }

    It 'refuses merge when feature repo working tree is dirty' -Tag 'Slow' {
        $repo = New-TestRepo
        $ctx = New-TaskWorktree -Repo $repo -Name 'mgdirty'
        $wt = (Get-TaskWorktreeRoot $ctx)
        try {
            Set-Content (Join-Path $repo 'README.md') -Value 'dirty'
            (Invoke-Feature @('merge', '-Repo', $repo, '-Name', 'mgdirty', '-Task', 't1', '-Message', 'm') -WorkingDirectory $repo).Json.error | Should -Match 'working tree is not clean'
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
    }

    It 'refuses merge when main is checked out' -Tag 'Slow' {
        $repo = New-TestRepo
        $ctx = New-TaskWorktree -Repo $repo -Name 'mgmain'
        $wt = (Get-TaskWorktreeRoot $ctx)
        try {
            & git -C $repo switch main 2>&1 | Out-Null
            (Invoke-Feature @('merge', '-Repo', $repo, '-Name', 'mgmain', '-Task', 't1', '-Message', 'm') -WorkingDirectory $repo).Json.error | Should -Match 'check out feature/'
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
    }

    It 'refuses merge when task branch is missing' -Tag 'Slow' {
        $repo = New-TestRepo
        $ctx = New-TaskWorktree -Repo $repo -Name 'mgnobr'
        $wt = (Get-TaskWorktreeRoot $ctx)
        try {
            & git -C $repo switch 'feature/mgnobr' 2>&1 | Out-Null
            Remove-TaskWorktree -Repo $repo -WtRoot $wt
            $wt = $null
            & git -C $repo branch -D $ctx.AgentBranch 2>&1 | Out-Null
            (Invoke-Feature @('merge', '-Repo', $repo, '-Name', 'mgnobr', '-Task', 't1', '-Message', 'm') -WorkingDirectory $repo).Json.error | Should -Match 'no branch'
        } finally {
            if ($wt -and (Test-Path $wt)) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
    }

    It 'refuses merge when task branch is already merged' -Tag 'Slow' {
        $repo = New-TestRepo
        $ctx = New-TaskWorktree -Repo $repo -Name 'mgdone'
        $wt = (Get-TaskWorktreeRoot $ctx)
        try {
            New-Item -ItemType Directory -Force (Join-Path $wt 'src') | Out-Null
            Set-Content (Join-Path $wt 'src/a.ts') -Value 'c' -NoNewline
            & git -C $wt add src/a.ts 2>&1 | Out-Null
            & git -C $wt commit -m c 2>&1 | Out-Null
            & git -C $repo switch 'feature/mgdone' 2>&1 | Out-Null
            Assert-FeatureOk (Invoke-Feature @('merge', '-Repo', $repo, '-Name', 'mgdone', '-Task', 't1', '-Message', 'm') -WorkingDirectory $repo)
            (Invoke-Feature @('merge', '-Repo', $repo, '-Name', 'mgdone', '-Task', 't1', '-Message', 'm') -WorkingDirectory $repo).Json.error | Should -Match 'already merged'
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
    }

    It 'refuses merge when worktree has uncommitted changes' -Tag 'Slow' {
        $repo = New-TestRepo
        $ctx = New-TaskWorktree -Repo $repo -Name 'mgun' -NoRecord
        $wt = (Get-TaskWorktreeRoot $ctx)
        try {
            $base = $ctx.BaseSha
            Assert-FeatureOk (Invoke-Feature @(
                    'task', '-Repo', $repo, '-Name', 'mgun', '-Task', 't1',
                    '-Worktree', $wt, '-BaseSha', $base
                ) -WorkingDirectory $repo)
            New-Item -ItemType Directory -Force (Join-Path $wt 'src') | Out-Null
            Set-Content (Join-Path $wt 'src/a.ts') -Value 'x' -NoNewline
            & git -C $wt add src/a.ts 2>&1 | Out-Null
            & git -C $wt commit -m 'agent work' 2>&1 | Out-Null
            Set-Content (Join-Path $wt 'untracked.txt') -Value 'u'
            & git -C $repo switch 'feature/mgun' 2>&1 | Out-Null
            (Invoke-Feature @('merge', '-Repo', $repo, '-Name', 'mgun', '-Task', 't1', '-Message', 'm') -WorkingDirectory $repo).Json.error | Should -Match 'uncommitted changes'
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
    }

    It 'allows merge with untracked cache left in worktree' -Tag 'Slow' {
        $repo = New-TestRepo
        $ctx = New-TaskWorktree -Repo $repo -Name 'mgcache' -NoRecord
        $wt = (Get-TaskWorktreeRoot $ctx)
        try {
            $base = $ctx.BaseSha
            Assert-FeatureOk (Invoke-Feature @(
                    'task', '-Repo', $repo, '-Name', 'mgcache', '-Task', 't1',
                    '-Worktree', $wt, '-BaseSha', $base
                ) -WorkingDirectory $repo)
            New-Item -ItemType Directory -Force (Join-Path $wt 'src') | Out-Null
            Set-Content (Join-Path $wt 'src/a.ts') -Value 'x' -NoNewline
            & git -C $wt add src/a.ts 2>&1 | Out-Null
            & git -C $wt commit -m 'agent work' 2>&1 | Out-Null
            New-Item -ItemType Directory -Force (Join-Path $wt '__pycache__') | Out-Null
            Set-Content (Join-Path $wt '__pycache__/x.pyc') -Value 'c'
            & git -C $repo switch 'feature/mgcache' 2>&1 | Out-Null
            $r = Invoke-Feature @('merge', '-Repo', $repo, '-Name', 'mgcache', '-Task', 't1', '-Message', 'm') -WorkingDirectory $repo
            $r.Json.ok | Should -BeTrue
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
    }

    It 'aborts on conflict and keeps HEAD clean' -Tag 'Slow' {
        $repo = New-TestRepo
        $wt = $null
        try {
            $ctx = New-TaskWorktree -Repo $repo -Name 'mgc'
            $wt = (Get-TaskWorktreeRoot $ctx)
            New-Item -ItemType Directory -Force (Join-Path $repo 'src') | Out-Null
            Set-Content (Join-Path $repo 'src/a.ts') -Value 'feature' -NoNewline
            & git -C $repo add src/a.ts 2>&1 | Out-Null
            & git -C $repo commit -m 'on feature' 2>&1 | Out-Null
            New-Item -ItemType Directory -Force (Join-Path $wt 'src') | Out-Null
            Set-Content (Join-Path $wt 'src/a.ts') -Value 'agent' -NoNewline
            & git -C $wt add src/a.ts 2>&1 | Out-Null
            & git -C $wt commit -m 'on agent' 2>&1 | Out-Null
            $headBefore = & git -C $repo rev-parse HEAD
            $r = Invoke-Feature @('merge', '-Repo', $repo, '-Name', 'mgc', '-Task', 't1', '-Message', 'm') -WorkingDirectory $repo
            $r.Json.error | Should -Match 'merge conflict in'
            $r.Json.error | Should -Match 'src/a.ts'
            & git -C $repo rev-parse HEAD | Should -Be $headBefore
            & git -C $repo rev-parse -q --verify MERGE_HEAD 2>&1 | Out-Null
            $LASTEXITCODE | Should -Not -Be 0
            @(& git -C $repo status --porcelain) | Where-Object { $_ } | Should -BeNullOrEmpty
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
    }

    It 'fails on missing Message, unknown task, merge in progress' -Tag 'Slow' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'mge' -Plan (New-OneTaskPlan) | Out-Null
        (Invoke-Feature @('merge', '-Repo', $repo, '-Name', 'mge', '-Task', 't1') -WorkingDirectory $repo).Json.error | Should -Match '-Message is required'
        (Invoke-Feature @('merge', '-Repo', $repo, '-Name', 'mge', '-Task', 'nope', '-Message', 'm') -WorkingDirectory $repo).Json.error | Should -Match 'unknown task'
        $repo2 = New-TestRepo
        $ctx = New-TaskWorktree -Repo $repo2 -Name 'mginp' -NoRecord
        $wt = (Get-TaskWorktreeRoot $ctx)
        try {
            New-Item -ItemType Directory -Force (Join-Path $repo2 'src') | Out-Null
            New-Item -ItemType Directory -Force (Join-Path $wt 'src') | Out-Null
            Set-Content (Join-Path $repo2 'src/x.ts') -Value 'x' -NoNewline
            Set-Content (Join-Path $wt 'src/x.ts') -Value 'y' -NoNewline
            & git -C $repo2 add src/x.ts 2>&1 | Out-Null
            & git -C $wt add src/x.ts 2>&1 | Out-Null
            & git -C $repo2 commit -m f 2>&1 | Out-Null
            & git -C $wt commit -m a 2>&1 | Out-Null
            & git -C $repo2 switch 'feature/mginp' 2>&1 | Out-Null
            & git -C $repo2 merge $ctx.AgentBranch 2>&1 | Out-Null
            (Invoke-Feature @('merge', '-Repo', $repo2, '-Name', 'mginp', '-Task', 't1', '-Message', 'm') -WorkingDirectory $repo2).Json.error | Should -Match 'merge is in progress'
            & git -C $repo2 merge --abort 2>&1 | Out-Null
        } finally {
            Remove-TaskWorktree -Repo $repo2 -WtRoot $wt
        }
    }

    It 'keeps other task state and lastReconcile after merge' -Tag 'Slow' {
        $repo = New-TestRepo
        $wt = $null
        try {
            Import-TestPlan -Repo $repo -Name 'mgkeep' -Plan (Get-StandardTwoPhasePlan) | Out-Null
            Set-TaskState -Repo $repo -Name 'mgkeep' -States @{ t2 = 'running' }
            $ctx = New-TaskWorktree -Repo $repo -Name 'mgkeep' -Files @('src/a.ts') -SkipPlanImport
            $wt = (Get-TaskWorktreeRoot $ctx)
            New-Item -ItemType Directory -Force (Join-Path $wt 'src') | Out-Null
            Set-Content (Join-Path $wt 'src/a.ts') -Value 'z' -NoNewline
            & git -C $wt add src/a.ts 2>&1 | Out-Null
            & git -C $wt commit -m c 2>&1 | Out-Null
            & git -C $repo switch 'feature/mgkeep' 2>&1 | Out-Null
            $lr = (Get-Content -Raw (Join-Path $repo '.xagent/features/mgkeep/state.json') | ConvertFrom-Json).lastReconcile
            Assert-FeatureOk (Invoke-Feature @('merge', '-Repo', $repo, '-Name', 'mgkeep', '-Task', 't1', '-Message', 'm') -WorkingDirectory $repo)
            $state = Get-Content -Raw (Join-Path $repo '.xagent/features/mgkeep/state.json') | ConvertFrom-Json
            $state.tasks.t1.status | Should -Be 'merged'
            $state.tasks.t2.status | Should -Be 'running'
            $state.lastReconcile | Should -Be $lr
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
    }
}

Describe 'feature.ps1 status' {
    It 'reports no features when the repo has none' {
        $repo = New-TestRepo
        $j = Invoke-StatusOk $repo
        $j.selected | Should -BeNullOrEmpty
        $j.features | Should -Be @()
    }

    It 'selects via -Cwd, lists two in progress on main, and sole in-progress feature' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'sela' -Stage 'design'
        & git -C $repo switch main 2>&1 | Out-Null
        $j = Invoke-StatusOk $repo -Extra @('-Cwd', $repo, '-Name', 'sela')
        $j.selected | Should -Be 'sela'
        New-FeatureBranchByHand -Repo $repo -Name 'selb'
        $j2 = Invoke-StatusOk $repo
        $j2.selected | Should -BeNullOrEmpty
        @($j2.features).Count | Should -Be 2
        & git -C $repo switch 'feature/sela' 2>&1 | Out-Null
        Assert-FeatureOk (Invoke-Feature @('stage', '-To', 'abandoned', '-Repo', $repo, '-Name', 'sela') -WorkingDirectory $repo)
        & git -C $repo switch 'feature/selb' 2>&1 | Out-Null
        Assert-FeatureOk (Invoke-Feature @('stage', '-To', 'abandoned', '-Repo', $repo, '-Name', 'selb') -WorkingDirectory $repo)
        New-FeatureAtStage -Repo $repo -Name 'selc' -Stage 'design'
        & git -C $repo switch main 2>&1 | Out-Null
        $j3 = Invoke-StatusOk $repo
        $j3.selected | Should -Be 'selc'
    }

    It 'skips abandoned feature checked out and uses sole in-progress rule' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'abad' -Stage 'design'
        Assert-FeatureOk (Invoke-Feature @('stage', '-To', 'abandoned', '-Repo', $repo, '-Name', 'abad') -WorkingDirectory $repo)
        New-FeatureAtStage -Repo $repo -Name 'live' -Stage 'design'
        & git -C $repo switch 'feature/abad' 2>&1 | Out-Null
        $j = Invoke-StatusOk $repo -Extra @('-Cwd', $repo)
        $j.selected | Should -Be 'live'
    }

    It 'reports design stage defaults, treeClean, branch, and detached HEAD' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'dsn' -Stage 'design'
        # A log folder that exists, so the result does not depend on the machine's %LOCALAPPDATA%\xagent.
        $prevLog = $env:XAGENT_LOG_DIR
        $env:XAGENT_LOG_DIR = Join-Path $TestDrive ('log-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $env:XAGENT_LOG_DIR | Out-Null
        try { $j = Invoke-StatusOk $repo -Extra @('-Name', 'dsn') }
        finally { if ($null -eq $prevLog) { Remove-Item Env:XAGENT_LOG_DIR -ErrorAction SilentlyContinue } else { $env:XAGENT_LOG_DIR = $prevLog } }
        $j.phase | Should -BeNullOrEmpty
        $j.tasks | Should -Be @()
        $j.reviewRuns | Should -Be @()
        $j.waitingOn | Should -BeNullOrEmpty
        $j.nextAction | Should -Be 'Draft the next design section and get it approved.'
        $j.lastDecisions | Should -Be @()
        $j.warnings | Should -Be @()
        $j.treeClean | Should -BeTrue
        $j.branch | Should -Be 'feature/dsn'
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'dirty'
        (Invoke-StatusOk $repo -Extra @('-Name', 'dsn')).treeClean | Should -BeFalse
        & git -C $repo switch --detach 2>&1 | Out-Null
        (Invoke-StatusOk $repo -Extra @('-Name', 'dsn')).branch | Should -Be ''
    }

    It 'lists ten design review runs with models and standards in design-review' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'drev' -Stage 'design-review'
        $j = Invoke-StatusOk $repo -Extra @('-Name', 'drev')
        $j.waitingOn.gate | Should -Be 'design-locked'
        @($j.reviewRuns).Count | Should -Be 10
        @($j.reviewRuns | Select-Object -ExpandProperty id -Unique).Count | Should -Be 10
        ($j.reviewRuns | Where-Object { $_.persona -eq 'zoom_out' }).Count | Should -Be 2
        ($j.reviewRuns | Where-Object { $_.persona -eq 'style' }).Count | Should -Be 2
        ($j.reviewRuns | Where-Object { $_.persona -eq 'zoom_out' } | Select-Object -First 1).standard | Should -Be 'zoom-out-standard.md'
        ($j.reviewRuns | Where-Object { $_.persona -eq 'comprehension' } | Select-Object -First 1).standard | Should -BeNullOrEmpty
    }

    It 'tracks review done state, reaudit rows, and review number after synthesis' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'rprog' -Stage 'design-review'
        $models = Get-Content -Raw (Join-Path $PSScriptRoot '../../delegate/models.json') | ConvertFrom-Json
        $prefix = 'rprog'
        $id1 = "$prefix-d1-zo-p5"
        $id2 = "$prefix-d1-ic-p5"
        $rawDir = Join-Path $repo "docs/features/rprog/reviews/raw"
        New-Item -ItemType Directory -Force $rawDir | Out-Null
        Set-Content -LiteralPath (Join-Path $rawDir "$id1.md") -Value 'r'
        Set-Content -LiteralPath (Join-Path $rawDir "$id2.md") -Value 'r'
        & git -C $repo add docs/features/rprog/reviews/raw 2>&1 | Out-Null
        & git -C $repo commit -m 'raw reviews' 2>&1 | Out-Null
        $j = Invoke-StatusOk $repo -Extra @('-Name', 'rprog')
        ($j.reviewRuns | Where-Object { $_.id -eq $id1 }).done | Should -BeTrue
        ($j.reviewRuns | Where-Object { $_.id -eq $id2 }).done | Should -BeTrue
        Assert-FeatureOk (Invoke-Feature @('reaudit', '-Phase', '7', '-Repo', $repo, '-Name', 'rprog') -WorkingDirectory $repo)
        $j2 = Invoke-StatusOk $repo -Extra @('-Name', 'rprog')
        @($j2.reviewRuns | Where-Object { $_.id -match '-r1$' }).Count | Should -Be 3
        $syn = Join-Path $repo 'docs/features/rprog/reviews/design-1.md'
        New-Item -ItemType Directory -Force (Split-Path $syn) | Out-Null
        Set-Content -LiteralPath $syn -Value '# design review 1'
        & git -C $repo add docs/features/rprog/reviews/design-1.md 2>&1 | Out-Null
        & git -C $repo commit -m 'design synthesis' 2>&1 | Out-Null
        $j3 = Invoke-StatusOk $repo -Extra @('-Name', 'rprog')
        ($j3.reviewRuns | Select-Object -First 1).id | Should -Match '-d2-'
        @($j2.reviewRuns).Count | Should -BeGreaterThan 10
        $models | Out-Null
    }


    It 'lists only reaudit rows for a partial design-review round after synthesis' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'part' -Stage 'design-review'
        $syn = Join-Path $repo 'docs/features/part/reviews/design-1.md'
        New-Item -ItemType Directory -Force (Split-Path $syn) | Out-Null
        Set-Content -LiteralPath $syn -Value '# design review 1'
        & git -C $repo add docs/features/part/reviews/design-1.md 2>&1 | Out-Null
        & git -C $repo commit -m 'design synthesis' 2>&1 | Out-Null
        Assert-FeatureOk (Invoke-Feature @('reaudit', '-Phase', '9', '-Repo', $repo, '-Name', 'part') -WorkingDirectory $repo)
        $j = Invoke-StatusOk $repo -Extra @('-Name', 'part')
        @($j.reviewRuns).Count | Should -Be 3
        @($j.reviewRuns | Where-Object { $_.id -match '-d2-.*-p9-r1$' }).Count | Should -Be 3
        @($j.reviewRuns | Where-Object { $_.id -notmatch '-r1$' }).Count | Should -Be 0
    }

    It 'lists all base design-review runs when a new round has no reaudit' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'base2' -Stage 'design-review'
        $syn = Join-Path $repo 'docs/features/base2/reviews/design-1.md'
        New-Item -ItemType Directory -Force (Split-Path $syn) | Out-Null
        Set-Content -LiteralPath $syn -Value '# design review 1'
        & git -C $repo add docs/features/base2/reviews/design-1.md 2>&1 | Out-Null
        & git -C $repo commit -m 'design synthesis' 2>&1 | Out-Null
        $j = Invoke-StatusOk $repo -Extra @('-Name', 'base2')
        @($j.reviewRuns).Count | Should -Be 10
        @($j.reviewRuns | Where-Object { $_.id -match '-d2-' -and $_.id -notmatch '-r\d+$' }).Count | Should -Be 10
    }

    It 'lists only reaudit rows for a partial plan round after synthesis' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'pprt' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        $syn = Join-Path $repo 'docs/features/pprt/reviews/plan-1.md'
        New-Item -ItemType Directory -Force (Split-Path $syn) | Out-Null
        Set-Content -LiteralPath $syn -Value '# plan review 1'
        & git -C $repo add docs/features/pprt/reviews/plan-1.md 2>&1 | Out-Null
        & git -C $repo commit -m 'plan synthesis' 2>&1 | Out-Null
        Assert-FeatureOk (Invoke-Feature @('reaudit', '-Phase', '1', '-Repo', $repo, '-Name', 'pprt') -WorkingDirectory $repo)
        $j = Invoke-StatusOk $repo -Extra @('-Name', 'pprt')
        @($j.reviewRuns).Count | Should -Be 2
        @($j.reviewRuns | Where-Object { $_.id -match '-p2-.*-r1$' }).Count | Should -Be 2
        @($j.reviewRuns | Where-Object { $_.id -notmatch '-r1$' }).Count | Should -Be 0
    }
    It 'reports plan stage phase, tasks, plan review runs, and plan gate' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'plst' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        $j = Invoke-StatusOk $repo -Extra @('-Name', 'plst')
        $j.phase.current | Should -Be 1
        $j.phase.total | Should -Be 2
        @($j.tasks).Count | Should -Be 3
        $j.tasks[0].delegateTaskId | Should -Be 'plst-t1'
        @($j.reviewRuns).Count | Should -Be 2
        $j.reviewRuns[0].id | Should -Be 'plst-p1-cm'
        $j.reviewRuns[0].phase | Should -BeNullOrEmpty
        $j.waitingOn.gate | Should -Be 'plan-approved'
    }

    It 'derives task status, waitingOn.running array, merged trailers, and phase current' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'tsk' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        Set-TaskState -Repo $repo -Name 'tsk' -States @{ t2 = 'running' }
        $j = Invoke-StatusOk $repo -Extra @('-Name', 'tsk')
        $j.tasks[1].status | Should -Be 'running'
        $j.waitingOn.running | Should -Be @('tsk-t2')
        $j.waitingOn.running -is [array] | Should -BeTrue
        & git -C $repo switch 'feature/tsk' 2>&1 | Out-Null
        Set-Content (Join-Path $repo 'm.txt') -Value 'x' -NoNewline
        & git -C $repo add m.txt 2>&1 | Out-Null
        & git -C $repo commit -m 'merge t1' -m 'Xagent-Task: t1' 2>&1 | Out-Null
        $j2 = Invoke-StatusOk $repo -Extra @('-Name', 'tsk')
        ($j2.tasks | Where-Object { $_.id -eq 't1' }).status | Should -Be 'merged'
        ($j2.tasks | Where-Object { $_.id -eq 't2' }).status | Should -Be 'running'
        Set-TaskState -Repo $repo -Name 'tsk' -States @{ t1 = 'merged'; t2 = 'merged' }
        $j3 = Invoke-StatusOk $repo -Extra @('-Name', 'tsk')
        $j3.phase.current | Should -Be 2
    }

    It 'counts councils and rounds from decisions and survives missing state.json' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'crc' -Plan (New-OneTaskPlan -TaskId 't1') | Out-Null
        $lines = @(
            '- 2026-01-01T00:00:00Z [round] t1: a'
            '- 2026-01-01T00:01:00Z [round] t1: b'
            '- 2026-01-01T00:02:00Z [council] t1: c'
            '- 2026-01-01T00:03:00Z [round] t1: d'
            '- 2026-01-01T00:04:00Z [round] t10: e'
        )
        $dec = Join-Path $repo 'docs/features/crc/decisions.md'
        [IO.File]::AppendAllText($dec, ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
        & git -C $repo add docs/features/crc/decisions.md 2>&1 | Out-Null
        & git -C $repo commit -m 'decision lines' 2>&1 | Out-Null
        $j = Invoke-StatusOk $repo -Extra @('-Name', 'crc')
        $j.tasks[0].councils | Should -Be 1
        $j.tasks[0].rounds | Should -Be 1
        Remove-Item -LiteralPath (Join-Path $repo '.xagent/features/crc/state.json') -Force -ErrorAction SilentlyContinue
        $j2 = Invoke-StatusOk $repo -Extra @('-Name', 'crc')
        $j2.tasks[0].councils | Should -Be 1
        $j2.tasks[0].rounds | Should -Be 1
    }

    It 'reports open stop and clears after resume' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'stp' -Plan (New-OneTaskPlan) | Out-Null
        Assert-FeatureOk (Invoke-Feature @('decision', '-Kind', 'stop', '-Text', 't1: second failure', '-Repo', $repo, '-Name', 'stp') -WorkingDirectory $repo)
        $j = Invoke-StatusOk $repo -Extra @('-Name', 'stp')
        $j.waitingOn.stop | Should -Be 't1: second failure'
        $j.nextAction | Should -Match 'problem stop'
        Remove-Item -LiteralPath (Join-Path $repo '.xagent/features/stp/state.json') -Force -ErrorAction SilentlyContinue
        $j2 = Invoke-StatusOk $repo -Extra @('-Name', 'stp')
        $j2.waitingOn.stop | Should -Be 't1: second failure'
        Assert-FeatureOk (Invoke-Feature @('decision', '-Kind', 'resume', '-Text', 'ok', '-Repo', $repo, '-Name', 'stp') -WorkingDirectory $repo)
        $j3 = Invoke-StatusOk $repo -Extra @('-Name', 'stp')
        $j3.waitingOn.stop | Should -BeNullOrEmpty
    }

    It 'sums tokens from XAGENT_LOG_DIR and warns when log dir missing' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'alpha' -Stage 'design'
        $logDir = Join-Path $TestDrive ("log-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Force $logDir | Out-Null
        Copy-Item -LiteralPath $script:RunsJsonl -Destination (Join-Path $logDir 'runs.jsonl')
        $prev = $env:XAGENT_LOG_DIR
        try {
            $env:XAGENT_LOG_DIR = $logDir
            $j = Invoke-StatusOk $repo -Extra @('-Name', 'alpha')
            $j.tokens.total | Should -Be 13175
            $j.tokens.input | Should -Be 3500
        }
        finally {
            if ($null -eq $prev) { Remove-Item Env:XAGENT_LOG_DIR -ErrorAction SilentlyContinue } else { $env:XAGENT_LOG_DIR = $prev }
        }
        $bad = Join-Path $TestDrive "missing-$([guid]::NewGuid())"
        $prev2 = $env:XAGENT_LOG_DIR
        try {
            $env:XAGENT_LOG_DIR = $bad
            $j2 = Invoke-StatusOk $repo -Extra @('-Name', 'alpha')
            $j2.tokens | Should -BeNullOrEmpty
            ($j2.warnings -join ' ') | Should -Match 'usage log not readable'
        }
        finally {
            if ($null -eq $prev2) { Remove-Item Env:XAGENT_LOG_DIR -ErrorAction SilentlyContinue } else { $env:XAGENT_LOG_DIR = $prev2 }
        }
    }

    It 'sets diffTouchesRuleFiles for cursor rules changes' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'diff' -Stage 'design'
        & git -C $repo switch 'feature/diff' 2>&1 | Out-Null
        $rule = Join-Path $repo '.cursor/rules/x.md'
        New-Item -ItemType Directory -Force (Split-Path $rule) | Out-Null
        Set-Content -LiteralPath $rule -Value 'r' -NoNewline
        & git -C $repo add .cursor/rules/x.md 2>&1 | Out-Null
        & git -C $repo commit -m 'rule' 2>&1 | Out-Null
        (Invoke-StatusOk $repo -Extra @('-Name', 'diff')).diffTouchesRuleFiles | Should -BeTrue
        $repo2 = New-TestRepo
        New-FeatureAtStage -Repo $repo2 -Name 'diff2' -Stage 'design'
        & git -C $repo2 switch 'feature/diff2' 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $repo2 'other.txt') -Value 'o' -NoNewline
        & git -C $repo2 add other.txt 2>&1 | Out-Null
        & git -C $repo2 commit -m 'other' 2>&1 | Out-Null
        (Invoke-StatusOk $repo2 -Extra @('-Name', 'diff2')).diffTouchesRuleFiles | Should -BeFalse
    }

    It 'returns the last three committed decision lines' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'ld' -Stage 'design'
        1..5 | ForEach-Object {
            Assert-FeatureOk (Invoke-Feature @('decision', '-Kind', 'decision', '-Text', "n$_", '-Repo', $repo, '-Name', 'ld') -WorkingDirectory $repo)
        }
        $j = Invoke-StatusOk $repo -Extra @('-Name', 'ld')
        @($j.lastDecisions).Count | Should -Be 3
        $j.lastDecisions[0] | Should -Match '\[decision\] n3'
        $j.lastDecisions[2] | Should -Match '\[decision\] n5'
    }

    It 'is read-only on main with -Name and does not add lock or state' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'ro' -Stage 'design'
        & git -C $repo switch main 2>&1 | Out-Null
        $head = & git -C $repo rev-parse HEAD
        $porc = @(& git -C $repo status --porcelain)
        Invoke-StatusOk $repo -Extra @('-Name', 'ro') | Out-Null
        & git -C $repo rev-parse HEAD | Should -Be $head
        @(& git -C $repo status --porcelain) | Should -Be $porc
        Test-Path (Join-Path $repo '.xagent/features/ro/state.json') | Should -BeFalse
        Test-Path (Join-Path $repo '.xagent/features/ro/.lock') | Should -BeFalse
    }

    It 'fails for unknown and invalid feature names' {
        $repo = New-TestRepo
        $r1 = Invoke-Feature @('status', '-Repo', $repo, '-Name', 'nope') -WorkingDirectory $repo
        $r1.ExitCode | Should -Be 1
        $r1.Json.error | Should -Match 'no feature'
        $r2 = Invoke-Feature @('status', '-Repo', $repo, '-Name', 'Bad_Name') -WorkingDirectory $repo
        $r2.ExitCode | Should -Be 1
        $r2.Json.error | Should -Match 'invalid feature name'
    }

    It 'reports signoff review run, gate, and next actions' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'sig' -Stage 'signoff'
        $models = Get-Content -Raw (Join-Path $PSScriptRoot '../../delegate/models.json') | ConvertFrom-Json
        $j = Invoke-StatusOk $repo -Extra @('-Name', 'sig')
        @($j.reviewRuns).Count | Should -Be 1
        $j.reviewRuns[0].id | Should -Be 'sig-s1-dr'
        $j.reviewRuns[0].persona | Should -Be 'drift_report'
        $j.reviewRuns[0].model | Should -Be ([string]$models.seats.judgement[0])
        $j.reviewRuns[0].standard | Should -BeNullOrEmpty
        $j.reviewRuns[0].done | Should -BeFalse
        $j.waitingOn.gate | Should -Be 'signed-off'
        $j.nextAction | Should -Match 'sign off'
        Assert-FeatureOk (Invoke-Feature @('gate', '-Gate', 'signed-off', '-Quote', 'ok', '-Repo', $repo, '-Name', 'sig') -WorkingDirectory $repo)
        (Invoke-StatusOk $repo -Extra @('-Name', 'sig')).nextAction | Should -Match 'Run finish'
    }

    It 'reports abandoned and done features' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'abn' -Stage 'design'
        Assert-FeatureOk (Invoke-Feature @('stage', '-To', 'abandoned', '-Repo', $repo, '-Name', 'abn') -WorkingDirectory $repo)
        $ja = Invoke-StatusOk $repo -Extra @('-Name', 'abn')
        $ja.waitingOn | Should -BeNullOrEmpty
        $ja.nextAction | Should -Match 'abandoned'
        New-FeatureAtStage -Repo $repo -Name 'donef' -Stage 'signoff'
        Assert-FeatureOk (Invoke-Feature @('gate', '-Gate', 'signed-off', '-Quote', 'ship', '-Repo', $repo, '-Name', 'donef') -WorkingDirectory $repo)
        & git -C $repo switch main 2>&1 | Out-Null
        & git -C $repo merge --no-ff 'feature/donef' -m 'merge donef' 2>&1 | Out-Null
        $jd = Invoke-StatusOk $repo -Extra @('-Name', 'donef')
        $jd.stage | Should -Be 'signoff'
        ($jd.warnings -join ' ') | Should -Match 'is done'
        $jd.waitingOn | Should -BeNullOrEmpty
        @($jd.reviewRuns).Count | Should -Be 0
        $jd.nextAction | Should -Match 'done and merged'
        $jn = Invoke-StatusOk $repo
        ($jn.features | Where-Object { $_.name -eq 'donef' }).stage | Should -Be 'done'
    }
    It 'status returns designDoc from feature.json' {
        $repo = New-TestRepo
        Assert-FeatureOk (Invoke-Feature @('new', '-Name', 'alpha', '-DesignDoc', 'docs/design/x.md', '-Repo', $repo) -WorkingDirectory $repo)
        $j = Invoke-StatusOk $repo -Extra @('-Name', 'alpha')
        $j.designDoc | Should -Be 'docs/design/x.md'
    }

    It 'status -Repo on repo subfolder matches repo root' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'subst' -Plan (Get-StandardTwoPhasePlan) | Out-Null
        $sub = Join-Path $repo 'docs/sub'
        New-Item -ItemType Directory -Force -Path $sub | Out-Null
        $jRoot = Invoke-StatusOk $repo -Extra @('-Name', 'subst')
        $jSub = Invoke-Feature @('status', '-Repo', $sub, '-Name', 'subst') -WorkingDirectory $sub
        $jSub.ExitCode | Should -Be 0
        $jSub.Json.ok | Should -BeTrue
        $jSub.Json.stage | Should -Be $jRoot.stage
        $jSub.Json.designDoc | Should -Be $jRoot.designDoc
    }

    It 'status -Repo on nonexistent path returns ok false' {
        $repo = New-TestRepo
        $bad = Join-Path $TestDrive ('missing-' + [guid]::NewGuid().ToString('N'))
        $r = Invoke-Feature @('status', '-Repo', $bad) -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
        $r.Json.ok | Should -BeFalse
    }
}

Describe 'feature.ps1 reconcile' {
    It 'trailer merges become merged and second reconcile is unchanged' -Tag 'Slow' {
        $repo = New-TestRepo
        $wt = $null
        try {
            $ctx = New-TaskWorktree -Repo $repo -Name 'rct1'
            $wt = (Get-TaskWorktreeRoot $ctx)
            New-Item -ItemType Directory -Force (Join-Path $wt 'src') | Out-Null
            Set-Content (Join-Path $wt 'src/a.ts') -Value 'ok' -NoNewline
            & git -C $wt add src/a.ts 2>&1 | Out-Null
            & git -C $wt commit -m 'change' 2>&1 | Out-Null
            & git -C $repo switch 'feature/rct1' 2>&1 | Out-Null
            Assert-FeatureOk (Invoke-Feature @('merge', '-Repo', $repo, '-Name', 'rct1', '-Task', 't1', '-Message', 'm') -WorkingDirectory $repo)
            Set-TaskState -Repo $repo -Name 'rct1' -States @{ t1 = 'pending' }
            $j = Invoke-ReconcileOk $repo 'rct1'
            @($j.changes).Count | Should -Be 1
            $j.changes[0].task | Should -Be 't1'
            $j.changes[0].from | Should -Be 'pending'
            $j.changes[0].to | Should -Be 'merged'
            & git -C $repo branch -D $ctx.AgentBranch 2>&1 | Out-Null
            (Invoke-ReconcileOk $repo 'rct1').changes | Should -Be @()
        } finally {
            if ($wt) { Remove-TaskWorktree -Repo $repo -WtRoot $wt }
        }
    }

    It 'reports merged-without-trailer and keeps merged status' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'rctr' -Plan (New-OneTaskPlan) | Out-Null
        Set-TaskState -Repo $repo -Name 'rctr' -States @{ t1 = 'merged' }
        $j = Invoke-ReconcileOk $repo 'rctr'
        $j.contradictions.Count | Should -Be 1
        $j.contradictions[0].kind | Should -Be 'merged-without-trailer'
        $j.contradictions[0].message | Should -Match 'task t1'
        (Get-Content -Raw (Join-Path $repo '.xagent/features/rctr/state.json') | ConvertFrom-Json).tasks.t1.status | Should -Be 'merged'
    }

    It 'branch-missing with state or fails without' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'rcbr' -Plan (New-OneTaskPlan) | Out-Null
        Set-TaskState -Repo $repo -Name 'rcbr' -States @{ t1 = 'pending' }
        & git -C $repo switch main 2>&1 | Out-Null
        & git -C $repo branch -D 'feature/rcbr' 2>&1 | Out-Null
        $before = Get-Content -Raw (Join-Path $repo '.xagent/features/rcbr/state.json')
        $j = Invoke-ReconcileOk $repo 'rcbr'
        $j.contradictions.Count | Should -Be 1
        $j.contradictions[0].kind | Should -Be 'branch-missing'
        $j.changes | Should -Be @()
        Get-Content -Raw (Join-Path $repo '.xagent/features/rcbr/state.json') | Should -Be $before
        Remove-Item -LiteralPath (Join-Path $repo '.xagent/features/rcbr/state.json') -Force
        $r = Invoke-Feature @('reconcile', '-Repo', $repo, '-Name', 'rcbr') -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'no feature'
    }

    It 'wrong-branch on main still reconciles trailer merge' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'rcwb' -Plan (New-OneTaskPlan) | Out-Null
        & git -C $repo switch 'feature/rcwb' 2>&1 | Out-Null
        Set-Content (Join-Path $repo 'x.txt') -Value 'm' -NoNewline
        & git -C $repo add x.txt 2>&1 | Out-Null
        & git -C $repo commit -m 'm' -m 'Xagent-Task: t1' 2>&1 | Out-Null
        Set-TaskState -Repo $repo -Name 'rcwb' -States @{ t1 = 'pending' }
        & git -C $repo switch main 2>&1 | Out-Null
        $j = Invoke-ReconcileOk $repo 'rcwb'
        ($j.contradictions | Where-Object { $_.kind -eq 'wrong-branch' }).Count | Should -Be 1
        ($j.changes | Where-Object { $_.to -eq 'merged' }).task | Should -Be 't1'
    }

    It 'reports merge-in-progress and wrong-branch' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'rcmg' -Stage 'design'
        & git -C $repo switch main 2>&1 | Out-Null
        & git -C $repo switch -c side 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'side' -NoNewline
        & git -C $repo commit -am 'side' 2>&1 | Out-Null
        & git -C $repo switch main 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'main' -NoNewline
        & git -C $repo commit -am 'main' 2>&1 | Out-Null
        & git -C $repo merge side 2>&1 | Out-Null
        try {
            $j = Invoke-ReconcileOk $repo 'rcmg'
            ($j.contradictions | Where-Object { $_.kind -eq 'merge-in-progress' }).Count | Should -Be 1
            ($j.contradictions | Where-Object { $_.kind -eq 'wrong-branch' }).Count | Should -Be 1
        } finally {
            & git -C $repo merge --abort 2>&1 | Out-Null
        }
    }

    It 'reports merged-without-signoff' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'rcms' -Stage 'build'
        & git -C $repo switch main 2>&1 | Out-Null
        & git -C $repo merge --no-ff 'feature/rcms' -m 'merge feature' 2>&1 | Out-Null
        & git -C $repo switch 'feature/rcms' 2>&1 | Out-Null
        $j = Invoke-ReconcileOk $repo 'rcms'
        $j.contradictions.Count | Should -Be 1
        $j.contradictions[0].kind | Should -Be 'merged-without-signoff'
    }

    It 'running with no run folder becomes failed and is not scheduled' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'rcfd' -Plan (New-OneTaskPlan) | Out-Null
        Set-TaskState -Repo $repo -Name 'rcfd' -States @{ t1 = 'running' }
        $j = Invoke-ReconcileOk $repo 'rcfd'
        $j.changes[0].to | Should -Be 'failed'
        $st = Get-Content -Raw (Join-Path $repo '.xagent/features/rcfd/state.json') | ConvertFrom-Json
        $st.tasks.t1.failures | Should -Be 1
        (Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'rcfd') -WorkingDirectory $repo).Json.tasks | Should -Be @()
    }

    It 'finished stdout moves to in-review; empty stdout alone is failed' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'rcfin' -Plan (New-OneTaskPlan) | Out-Null
        $d = Get-PlanDelegateTaskId $repo 'rcfin' 't1'
        Write-DelegateRunStdout -Repo $repo -DelegateId $d -Stamp '20260101-100000' -Content ''
        Write-DelegateRunStdout -Repo $repo -DelegateId $d -Stamp '20260101-110000' -Content '{"ok":true}'
        Set-TaskState -Repo $repo -Name 'rcfin' -States @{ t1 = 'running' }
        (Invoke-ReconcileOk $repo 'rcfin').changes[0].to | Should -Be 'in-review'
        $repo2 = New-TestRepo
        Import-TestPlan -Repo $repo2 -Name 'rcfem' -Plan (New-OneTaskPlan) | Out-Null
        $d2 = Get-PlanDelegateTaskId $repo2 'rcfem' 't1'
        Write-DelegateRunStdout -Repo $repo2 -DelegateId $d2 -Stamp '20260101-100000' -Content ''
        Set-TaskState -Repo $repo2 -Name 'rcfem' -States @{ t1 = 'running' }
        (Invoke-ReconcileOk $repo2 'rcfem').changes[0].to | Should -Be 'failed'
    }

    It 'records stop on second failure or stop-not-recorded on main' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'rcst' -Plan (New-OneTaskPlan) | Out-Null
        $d = Get-PlanDelegateTaskId $repo 'rcst' 't1'
        Set-TaskState -Repo $repo -Name 'rcst' -States @{ t1 = 'running' } -FailureCounts @{ t1 = 1 }
        $j = Invoke-ReconcileOk $repo 'rcst'
        $j.changes[0].to | Should -Be 'failed'
        (Get-Content -Raw (Join-Path $repo 'docs/features/rcst/decisions.md')) | Should -Match '\[stop\] t1: failed twice'
        (Invoke-StatusOk $repo -Extra @('-Name', 'rcst')).waitingOn.stop | Should -Be 't1: failed twice'
        $repo2 = New-TestRepo
        Import-TestPlan -Repo $repo2 -Name 'rcstm' -Plan (New-OneTaskPlan) | Out-Null
        Set-TaskState -Repo $repo2 -Name 'rcstm' -States @{ t1 = 'running' } -FailureCounts @{ t1 = 1 }
        & git -C $repo2 switch main 2>&1 | Out-Null
        $j2 = Invoke-ReconcileOk $repo2 'rcstm'
        ($j2.contradictions | Where-Object { $_.kind -eq 'stop-not-recorded' }).Count | Should -Be 1
        $decOnBranch = (& git -C $repo2 show 'feature/rcstm:docs/features/rcstm/decisions.md') -join "`n"
        $decOnBranch | Should -Not -Match '\[stop\] t1: failed twice'
    }

    It 'live preflight run stays preflight' -Tag 'Slow' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'rclv' -Plan (New-OneTaskPlan) | Out-Null
        $d = Get-PlanDelegateTaskId $repo 'rclv' 't1'
        $holder = Start-Process -PassThru -WindowStyle Hidden -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120')
        try {
            Start-Sleep -Milliseconds 400
            $holder.Refresh()
            $start = $holder.StartTime.ToUniversalTime().ToString('o')
            Write-DelegateRunPid -Repo $repo -DelegateId $d -Stamp '20260101-100000' -RunSuffix '-pr' -Body @{
                pid       = $holder.Id
                startTime = $start
                feature   = 'rclv'
            }
            Set-TaskState -Repo $repo -Name 'rclv' -States @{ t1 = 'preflight' }
            (Invoke-ReconcileOk $repo 'rclv').changes | Should -Be @()
            (Get-Content -Raw (Join-Path $repo '.xagent/features/rclv/state.json') | ConvertFrom-Json).tasks.t1.status | Should -Be 'preflight'
            Get-Process -Id $holder.Id -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        } finally {
            Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'kills orphaned child or leaves reused pid alone' -Tag 'Slow' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'rcor' -Plan (New-OneTaskPlan) | Out-Null
        $d = Get-PlanDelegateTaskId $repo 'rcor' 't1'
        $deadPid = 999999
        $deadStart = '2019-01-01T00:00:00.0000000Z'
        $child = Start-Process -PassThru -WindowStyle Hidden -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120')
        try {
            Start-Sleep -Milliseconds 400
            $child.Refresh()
            $childStart = $child.StartTime.ToUniversalTime().ToString('o')
            Write-DelegateRunPid -Repo $repo -DelegateId $d -Stamp '20260101-100000' -Body @{
                pid             = $deadPid
                startTime       = $deadStart
                childPid        = $child.Id
                childStartTime  = $childStart
                feature         = 'rcor'
            }
            Set-TaskState -Repo $repo -Name 'rcor' -States @{ t1 = 'running' }
            (Invoke-ReconcileOk $repo 'rcor').changes[0].to | Should -Be 'failed'
            Get-Process -Id $child.Id -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            $child2 = Start-Process -PassThru -WindowStyle Hidden -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120')
            try {
                Start-Sleep -Milliseconds 400
                $child2.Refresh()
                Write-DelegateRunPid -Repo $repo -DelegateId $d -Stamp '20260101-110000' -Body @{
                    pid            = $deadPid
                    startTime      = $deadStart
                    childPid       = $child2.Id
                    childStartTime = '2019-01-01T00:00:00.0000000Z'
                    feature        = 'rcor'
                }
                Set-TaskState -Repo $repo -Name 'rcor' -States @{ t1 = 'running' }
                Invoke-ReconcileOk $repo 'rcor' | Out-Null
                Get-Process -Id $child2.Id -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            } finally {
                Stop-Process -Id $child2.Id -Force -ErrorAction SilentlyContinue
            }
        } finally {
            Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'invalid state.json fails without changing file' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'rcinv' -Plan (New-OneTaskPlan) | Out-Null
        $path = Join-Path $repo '.xagent/features/rcinv/state.json'
        [IO.File]::WriteAllText($path, 'not json', [Text.UTF8Encoding]::new($false))
        $r = Invoke-Feature @('reconcile', '-Repo', $repo, '-Name', 'rcinv') -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'state.json is not valid'
        Get-Content -Raw $path | Should -Be 'not json'
    }

    It 'rebuilds lost tasks and keeps sessionId on reconcile' {
        $repo = New-TestRepo
        $twoTask = Get-StandardTwoPhasePlan
        $twoTask.phases = @($twoTask.phases[0])
        Import-TestPlan -Repo $repo -Name 'rcrb' -Plan $twoTask | Out-Null
        & git -C $repo switch 'feature/rcrb' 2>&1 | Out-Null
        & git -C $repo commit --allow-empty -m 'm' -m 'Xagent-Task: t1' 2>&1 | Out-Null
        Remove-Item -LiteralPath (Join-Path $repo '.xagent/features/rcrb/state.json') -Force -ErrorAction SilentlyContinue
        $j = Invoke-ReconcileOk $repo 'rcrb'
        $j.lost | Should -Be @('t2')
        $j.lost -is [array] | Should -BeTrue
        $st = Get-Content -Raw (Join-Path $repo '.xagent/features/rcrb/state.json') | ConvertFrom-Json
        $st.tasks.t1.status | Should -Be 'merged'
        $st.tasks.t2.status | Should -Be 'pending'
        $st.lastReconcile | Should -Not -BeNullOrEmpty
        $sid = 'sess-keep-1'
        Set-TaskState -Repo $repo -Name 'rcrb' -States @{ t1 = 'merged'; t2 = 'pending' } -ExtraFields @{
            t2 = @{ sessionId = $sid }
        }
        Invoke-ReconcileOk $repo 'rcrb' | Out-Null
        $st2 = Get-Content -Raw (Join-Path $repo '.xagent/features/rcrb/state.json') | ConvertFrom-Json
        $st2.tasks.t2.sessionId | Should -Be $sid
    }

    It 'reconcile running in-review fills worktree fields from worker stdout and worktree dir' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'rcir' -Plan (New-OneTaskPlan) | Out-Null
        $d = Get-PlanDelegateTaskId $repo 'rcir' 't1'
        Write-DelegateRunStdout -Repo $repo -DelegateId $d -Stamp '20260101-120000' -Content '{"session_id":"s-123","result":"x"}'
        $repoPath = [IO.Path]::GetFullPath($repo)
        $wt = Join-Path (Join-Path (Split-Path $repoPath -Parent) "$(Split-Path $repoPath -Leaf).xagent") $d
        $xa = Join-Path $wt '.xagent'
        New-Item -ItemType Directory -Force -Path $xa | Out-Null
        $baseSha = ('a' * 40)
        [IO.File]::WriteAllText((Join-Path $xa 'base.sha'), $baseSha, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $xa 'result.json'), '{}', [Text.UTF8Encoding]::new($false))
        Set-TaskState -Repo $repo -Name 'rcir' -States @{ t1 = 'running' }
        (Invoke-ReconcileOk $repo 'rcir').changes[0].to | Should -Be 'in-review'
        $st = Get-Content -Raw (Join-Path $repo '.xagent/features/rcir/state.json') | ConvertFrom-Json
        $st.tasks.t1.sessionId | Should -Be 's-123'
        $st.tasks.t1.worktree | Should -Match ("\.xagent/{0}$" -f [regex]::Escape($d))
        $st.tasks.t1.worktree | Should -Not -Match '\\'
        $st.tasks.t1.baseSha | Should -Be $baseSha
        $st.tasks.t1.resultFile | Should -Match "/\.xagent/result\.json$"
    }

    It 'reconcile running in-review without worktree dir keeps sessionId only' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'rcnw' -Plan (New-OneTaskPlan) | Out-Null
        $d = Get-PlanDelegateTaskId $repo 'rcnw' 't1'
        Write-DelegateRunStdout -Repo $repo -DelegateId $d -Stamp '20260101-120000' -Content '{"session_id":"s-only","result":"x"}'
        Set-TaskState -Repo $repo -Name 'rcnw' -States @{ t1 = 'running' }
        (Invoke-ReconcileOk $repo 'rcnw').changes[0].to | Should -Be 'in-review'
        $st = Get-Content -Raw (Join-Path $repo '.xagent/features/rcnw/state.json') | ConvertFrom-Json
        $st.tasks.t1.sessionId | Should -Be 's-only'
        $st.tasks.t1.worktree | Should -BeNullOrEmpty
        $st.tasks.t1.baseSha | Should -BeNullOrEmpty
        $st.tasks.t1.resultFile | Should -BeNullOrEmpty
    }

    It 'reconcile running keeps preset worktree and does not fill baseSha from derived path' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'rcpw' -Plan (New-OneTaskPlan) | Out-Null
        $d = Get-PlanDelegateTaskId $repo 'rcpw' 't1'
        Write-DelegateRunStdout -Repo $repo -DelegateId $d -Stamp '20260101-120000' -Content '{"session_id":"s-pw","result":"x"}'
        $repoPath = [IO.Path]::GetFullPath($repo)
        $wt = Join-Path (Join-Path (Split-Path $repoPath -Parent) "$(Split-Path $repoPath -Leaf).xagent") $d
        $xa = Join-Path $wt '.xagent'
        New-Item -ItemType Directory -Force -Path $xa | Out-Null
        [IO.File]::WriteAllText((Join-Path $xa 'base.sha'), ('b' * 40), [Text.UTF8Encoding]::new($false))
        Set-TaskState -Repo $repo -Name 'rcpw' -States @{ t1 = 'running' } -ExtraFields @{ t1 = @{ worktree = 'X:/given' } }
        (Invoke-ReconcileOk $repo 'rcpw').changes[0].to | Should -Be 'in-review'
        $st = Get-Content -Raw (Join-Path $repo '.xagent/features/rcpw/state.json') | ConvertFrom-Json
        $st.tasks.t1.worktree | Should -Be 'X:/given'
        $st.tasks.t1.baseSha | Should -BeNullOrEmpty
        $st.tasks.t1.sessionId | Should -Be 's-pw'
    }

    It 'reconcile running fails when only preflight stdout is finished' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'rcpr' -Plan (New-OneTaskPlan) | Out-Null
        $d = Get-PlanDelegateTaskId $repo 'rcpr' 't1'
        Write-DelegateRunStdout -Repo $repo -DelegateId $d -Stamp '20260101-120000' -RunSuffix '-pr' -Content '{"session_id":"s-pr","result":"x"}'
        Set-TaskState -Repo $repo -Name 'rcpr' -States @{ t1 = 'running' }
        $j = Invoke-ReconcileOk $repo 'rcpr'
        $j.changes[0].to | Should -Be 'failed'
        $st = Get-Content -Raw (Join-Path $repo '.xagent/features/rcpr/state.json') | ConvertFrom-Json
        $st.tasks.t1.failures | Should -Be 1
    }

    It 'reconcile preflight finished stdout returns to pending without failure stop' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'rcpf' -Plan (New-OneTaskPlan) | Out-Null
        $d = Get-PlanDelegateTaskId $repo 'rcpf' 't1'
        Write-DelegateRunStdout -Repo $repo -DelegateId $d -Stamp '20260101-120000' -RunSuffix '-pc' -Content '{"session_id":"s-pc","result":"x"}'
        Set-TaskState -Repo $repo -Name 'rcpf' -States @{ t1 = 'preflight' }
        $j = Invoke-ReconcileOk $repo 'rcpf'
        $j.changes[0].from | Should -Be 'preflight'
        $j.changes[0].to | Should -Be 'pending'
        $st = Get-Content -Raw (Join-Path $repo '.xagent/features/rcpf/state.json') | ConvertFrom-Json
        $st.tasks.t1.failures | Should -Be 0
        (Get-Content -Raw (Join-Path $repo 'docs/features/rcpf/decisions.md')) | Should -Not -Match '\[stop\]'
    }

    It 'reconcile preflight with empty stdout in -pr dir fails and increments failures' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'rcpe' -Plan (New-OneTaskPlan) | Out-Null
        $d = Get-PlanDelegateTaskId $repo 'rcpe' 't1'
        Write-DelegateRunStdout -Repo $repo -DelegateId $d -Stamp '20260101-120000' -RunSuffix '-pr' -Content ''
        Set-TaskState -Repo $repo -Name 'rcpe' -States @{ t1 = 'preflight' }
        $j = Invoke-ReconcileOk $repo 'rcpe'
        $j.changes[0].to | Should -Be 'failed'
        $st = Get-Content -Raw (Join-Path $repo '.xagent/features/rcpe/state.json') | ConvertFrom-Json
        $st.tasks.t1.failures | Should -Be 1
    }

}

Describe 'feature.ps1 finish' {
    It 'refuses without signed-off, dirty tree, and wrong branch' {
        $repo1 = New-TestRepo
        New-FeatureAtStage -Repo $repo1 -Name 'finr1' -Stage 'signoff'
        $r1 = Invoke-Feature @('finish', '-Repo', $repo1, '-Name', 'finr1') -WorkingDirectory $repo1
        $r1.ExitCode | Should -Be 1
        $r1.Json.error | Should -Match 'signed-off is not recorded'
        Test-Path (Join-Path $repo1 '.xagent/features/finr1/.lock') | Should -BeFalse

        $repo2 = New-TestRepo
        New-FeatureAtStage -Repo $repo2 -Name 'finr2' -Stage 'signoff'
        Assert-FeatureOk (Invoke-Feature @('gate', '-Gate', 'signed-off', '-Quote', 'ok', '-Repo', $repo2, '-Name', 'finr2') -WorkingDirectory $repo2)
        Set-Content -LiteralPath (Join-Path $repo2 'README.md') -Value 'dirty' -NoNewline
        $r2 = Invoke-Feature @('finish', '-Repo', $repo2, '-Name', 'finr2') -WorkingDirectory $repo2
        $r2.ExitCode | Should -Be 1
        $r2.Json.error | Should -Match 'working tree is not clean'
        Test-Path (Join-Path $repo2 '.xagent/features/finr2/.lock') | Should -BeFalse

        $repo3 = New-TestRepo
        New-FeatureAtStage -Repo $repo3 -Name 'finr3' -Stage 'signoff'
        Assert-FeatureOk (Invoke-Feature @('gate', '-Gate', 'signed-off', '-Quote', 'ok', '-Repo', $repo3, '-Name', 'finr3') -WorkingDirectory $repo3)
        & git -C $repo3 switch main 2>&1 | Out-Null
        $r3 = Invoke-Feature @('finish', '-Repo', $repo3, '-Name', 'finr3') -WorkingDirectory $repo3
        $r3.ExitCode | Should -Be 1
        $r3.Json.error | Should -Match 'check out feature/'
        Test-Path (Join-Path $repo3 '.xagent/features/finr3/.lock') | Should -BeFalse
    }

    It 'succeeds right after signed-off' -Tag 'Slow' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'finok' -Stage 'signoff'
        Assert-FeatureOk (Invoke-Feature @('gate', '-Gate', 'signed-off', '-Quote', 'ship', '-Repo', $repo, '-Name', 'finok') -WorkingDirectory $repo)
        $featHead = & git -C $repo rev-parse 'feature/finok'
        $r = Assert-FeatureOk (Invoke-Feature @('finish', '-Repo', $repo, '-Name', 'finok') -WorkingDirectory $repo)
        (& git -C $repo rev-parse --abbrev-ref HEAD) | Should -Be 'main'
        $parents = @(& git -C $repo rev-parse HEAD^@)
        $parents.Count | Should -Be 2
        $parents | Should -Contain $featHead
        $st = Invoke-StatusOk $repo -Extra @('-Name', 'finok')
        ($st.warnings -join ' ') | Should -Match 'feature finok is done'
        $jn = Invoke-StatusOk $repo
        ($jn.features | Where-Object { $_.name -eq 'finok' }).stage | Should -Be 'done'
        Assert-FeatureOk (Invoke-Feature @('new', '-Name', 'finother', '-Repo', $repo) -WorkingDirectory $repo)
    }

    It 'refuses when files change after sign-off' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'fincg' -Stage 'signoff'
        Assert-FeatureOk (Invoke-Feature @('gate', '-Gate', 'signed-off', '-Quote', 'ok', '-Repo', $repo, '-Name', 'fincg') -WorkingDirectory $repo)
        Set-Content -LiteralPath (Join-Path $repo 'src-extra.txt') -Value 'x' -NoNewline
        & git -C $repo add src-extra.txt 2>&1 | Out-Null
        & git -C $repo commit -m 'outside feature folder' 2>&1 | Out-Null
        $r = Invoke-Feature @('finish', '-Repo', $repo, '-Name', 'fincg') -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'changed since sign-off'
        $r.Json.error | Should -Match 'src-extra.txt'

        $repo2 = New-TestRepo
        New-FeatureAtStage -Repo $repo2 -Name 'findsg' -Stage 'signoff'
        Assert-FeatureOk (Invoke-Feature @('gate', '-Gate', 'signed-off', '-Quote', 'ok', '-Repo', $repo2, '-Name', 'findsg') -WorkingDirectory $repo2)
        Set-Content -LiteralPath (Join-Path $repo2 'docs/designs/findsg.md') -Value '# changed' -NoNewline
        & git -C $repo2 add docs/designs/findsg.md 2>&1 | Out-Null
        & git -C $repo2 commit -m 'design tweak' 2>&1 | Out-Null
        $r2 = Invoke-Feature @('finish', '-Repo', $repo2, '-Name', 'findsg') -WorkingDirectory $repo2
        $r2.ExitCode | Should -Be 1
        $r2.Json.error | Should -Match 'changed since sign-off'
        $r2.Json.error | Should -Match 'docs/designs/findsg.md'
    }

    It 'refuses when design blob differs from design-locked' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'findb' -Stage 'signoff'
        Set-Content -LiteralPath (Join-Path $repo 'docs/designs/findb.md') -Value '# revised' -NoNewline
        Assert-FeatureOk (Invoke-FeatureInProcess @('commit-design', '-Section', 'rev', '-Repo', $repo, '-Name', 'findb') -WorkingDirectory $repo)
        Assert-FeatureOk (Invoke-Feature @('gate', '-Gate', 'signed-off', '-Quote', 'ok', '-Repo', $repo, '-Name', 'findb') -WorkingDirectory $repo)
        $r = Invoke-Feature @('finish', '-Repo', $repo, '-Name', 'findb') -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'design changed since design-locked'
    }

    It 'clears signed-off on merge conflict' -Tag 'Slow' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'fincon' -Stage 'signoff'
        & git -C $repo switch main 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'main-line' -NoNewline
        & git -C $repo add README.md 2>&1 | Out-Null
        & git -C $repo commit -m 'main readme' 2>&1 | Out-Null
        & git -C $repo switch 'feature/fincon' 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'feature-line' -NoNewline
        & git -C $repo add README.md 2>&1 | Out-Null
        & git -C $repo commit -m 'feature readme' 2>&1 | Out-Null
        $mainBefore = & git -C $repo rev-parse main
        Assert-FeatureOk (Invoke-Feature @('gate', '-Gate', 'signed-off', '-Quote', 'ok', '-Repo', $repo, '-Name', 'fincon') -WorkingDirectory $repo)
        $r = Invoke-Feature @('finish', '-Repo', $repo, '-Name', 'fincon') -WorkingDirectory $repo
        $r.ExitCode | Should -Be 1
        $r.Json.error | Should -Match 'merge conflict in README.md'
        (& git -C $repo rev-parse --abbrev-ref HEAD) | Should -Be 'feature/fincon'
        & git -C $repo rev-parse main | Should -Be $mainBefore
        & git -C $repo rev-parse -q --verify MERGE_HEAD 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
        @(& git -C $repo status --porcelain) | Where-Object { $_ } | Should -BeNullOrEmpty
        $featJson = (& git -C $repo show 'HEAD:docs/features/fincon/feature.json') -join "`n"
        $feat = $featJson | ConvertFrom-Json
        $feat.gates.PSObject.Properties['signed-off'] | Should -BeNullOrEmpty
        (Get-Content -Raw (Join-Path $repo 'docs/features/fincon/decisions.md')) | Should -Match 'finish: merge conflict'
    }

    It 'lists done feature after feature branch is deleted' {
        $repo = New-TestRepo
        New-FeatureAtStage -Repo $repo -Name 'finbd' -Stage 'signoff'
        Assert-FeatureOk (Invoke-Feature @('gate', '-Gate', 'signed-off', '-Quote', 'ship', '-Repo', $repo, '-Name', 'finbd') -WorkingDirectory $repo)
        Assert-FeatureOk (Invoke-Feature @('finish', '-Repo', $repo, '-Name', 'finbd') -WorkingDirectory $repo)
        & git -C $repo branch -D 'feature/finbd' 2>&1 | Out-Null
        $jn = Invoke-StatusOk $repo
        ($jn.features | Where-Object { $_.name -eq 'finbd' }).stage | Should -Be 'done'
    }

    It 'does not list main-only feature without signed-off' {
        $repo = New-TestRepo
        $dir = Join-Path $repo 'docs/features/ghost'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $feat = @{ stage = 'build'; gates = @{} } | ConvertTo-Json -Compress
        Set-Content -LiteralPath (Join-Path $dir 'feature.json') -Value $feat -NoNewline
        & git -C $repo add docs/features/ghost 2>&1 | Out-Null
        & git -C $repo commit -m 'ghost' 2>&1 | Out-Null
        $jn = Invoke-StatusOk $repo
        $jn.features | Where-Object { $_.name -eq 'ghost' } | Should -BeNullOrEmpty
    }
}

Describe 'feature.ps1 doctor' {
    BeforeAll {
        . (Get-FeatureFunctionScript -Name @('Get-DoctorSandboxDetail'))
    }

    It 'builds the sandbox detail' {
        $emptyLetters = @{
            reserved = $false
            runtime  = $null
            slots    = [string[]]::new(0)
            states   = @{}
        }
        $support1 = @{
            ok            = $false
            build         = 26300
            cursorVersion = $null
            uv            = $null
            patternCount  = $null
            letters       = $emptyLetters
            problems      = @()
        }
        Get-DoctorSandboxDetail $support1 | Should -Be 'build 26300; cursor not found; letters not reserved (run delegate.ps1 -SandboxCheck -Reserve with three free letters)'

        $support2 = @{
            ok            = $true
            build         = 26300
            cursorVersion = '2026.11.13-eacade1'
            uv            = '1.52.1'
            patternCount  = 1
            letters       = @{
                reserved = $true
                runtime  = 'Z'
                slots    = @('Y', 'X')
                states   = @{ Z = 'ours'; Y = 'ours' }
            }
            problems      = @()
        }
        Get-DoctorSandboxDetail $support2 | Should -Be 'build 26300; cursor 2026.11.13-eacade1; uv 1.52.1; pattern 1; letters Z,Y,X (Z=ours, Y=ours, X=?)'

        $support3 = @{
            ok            = $false
            build         = 26300
            cursorVersion = $null
            uv            = $null
            patternCount  = $null
            letters       = $emptyLetters
            problems      = @('a', 'b')
        }
        (Get-DoctorSandboxDetail $support3).StartsWith('problems: a | b; build 26300') | Should -BeTrue

        $longProblem = 'x' * 400
        $support4 = @{
            ok            = $false
            build         = 26300
            cursorVersion = $null
            uv            = $null
            patternCount  = $null
            letters       = $emptyLetters
            problems      = @($longProblem)
        }
        (Get-DoctorSandboxDetail $support4).Length | Should -Be 300
    }

    It 'reports prerequisites' -Tag 'Slow' {
        $sandboxRoot = Join-Path $TestDrive ("sandbox-{0}" -f [guid]::NewGuid())
        $cursorRoot = Join-Path $TestDrive ("cursor-{0}" -f [guid]::NewGuid())
        $logDir = Join-Path $TestDrive ("log-{0}" -f [guid]::NewGuid())
        $prevSandbox = $env:XAGENT_SANDBOX_ROOT
        $prevCursor = $env:XAGENT_CURSOR_ROOT
        $prevLog = $env:XAGENT_LOG_DIR
        try {
            $env:XAGENT_SANDBOX_ROOT = $sandboxRoot
            $env:XAGENT_CURSOR_ROOT = $cursorRoot
            $env:XAGENT_LOG_DIR = $logDir
            $r = Invoke-Feature @('doctor') -WorkingDirectory $TestDrive
        }
        finally {
            if ($null -eq $prevSandbox) { Remove-Item Env:XAGENT_SANDBOX_ROOT -ErrorAction SilentlyContinue } else { $env:XAGENT_SANDBOX_ROOT = $prevSandbox }
            if ($null -eq $prevCursor) { Remove-Item Env:XAGENT_CURSOR_ROOT -ErrorAction SilentlyContinue } else { $env:XAGENT_CURSOR_ROOT = $prevCursor }
            if ($null -eq $prevLog) { Remove-Item Env:XAGENT_LOG_DIR -ErrorAction SilentlyContinue } else { $env:XAGENT_LOG_DIR = $prevLog }
        }
        $r.ExitCode | Should -Be 0
        $r.Json.ok | Should -BeTrue
        @($r.Json.checks).Count | Should -Be 10
        $names = @($r.Json.checks | ForEach-Object { $_.name })
        $names | Should -Be @('powershell', 'git', 'delegate', 'cursor-cli', 'cursor-login', 'models', 'pester', 'python', 'log-dir', 'sandbox')
        # Checks that hold on any machine able to run this suite (PowerShell 7.4+, git, the repo's own skills, Pester).
        foreach ($n in @('powershell', 'git', 'delegate', 'pester')) {
            ($r.Json.checks | Where-Object { $_.name -eq $n }).ok | Should -BeTrue -Because "$n check should pass here"
        }
        foreach ($c in $r.Json.checks) {
            $c.PSObject.Properties['name'] | Should -Not -BeNullOrEmpty
            $c.PSObject.Properties['ok'] | Should -Not -BeNullOrEmpty
            $c.PSObject.Properties['required'] | Should -Not -BeNullOrEmpty
            $c.PSObject.Properties['detail'] | Should -Not -BeNullOrEmpty
        }
        $requiredOk = @($r.Json.checks | Where-Object { $_.required } | ForEach-Object { [bool]$_.ok })
        $r.Json.ready | Should -Be ($requiredOk -notcontains $false)
        @($r.Json.permissionRules).Count | Should -Be 2
        ($r.Json.permissionRules | Where-Object { $_ -match '/scripts/feature\.ps1 \*\)$' }).Count | Should -Be 1
        ($r.Json.permissionRules | Where-Object { $_ -match '/scripts/delegate\.ps1 \*\)$' }).Count | Should -Be 1
        $r.Raw | Should -Not -Match '@'
        $sandboxCheck = $r.Json.checks | Where-Object { $_.name -eq 'sandbox' } | Select-Object -First 1
        $sandboxCheck.required | Should -BeFalse
        $sandboxCheck.ok | Should -BeFalse
        $sandboxCheck.detail | Should -Not -BeNullOrEmpty
        $build = [Environment]::OSVersion.Version.Build
        if ($build -ge 26300) {
            $expectedSandboxDetail = "build $build; cursor not found; letters not reserved (run delegate.ps1 -SandboxCheck -Reserve with three free letters)"
            $sandboxCheck.detail | Should -Be $expectedSandboxDetail
        } else {
            Set-ItResult -Inconclusive -Because "build $build is below 26300"
        }
    }
}

Describe 'Stop-ProcessTree' {
    BeforeAll {
        . (Get-FeatureFunctionScript -Name @('Stop-ProcessTree'))
        $script:treePids = [System.Collections.Generic.List[int]]::new()
    }

    It 'kills a two-level child process tree' {
        $cimOk = $true
        try { $null = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop } catch { $cimOk = $false }
        if (-not $cimOk) { Set-ItResult -Skipped -Because 'process queries (CIM) are not available here, as inside the sandbox'; return }
        function Test-ProcessAlive {
            param([int]$Id)
            try {
                $null = [Diagnostics.Process]::GetProcessById($Id)
                return $true
            } catch [ArgumentException] {
                return $false
            }
        }
        function Get-DirectChildPids {
            param([int]$ParentId)
            @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ParentId" |
                Where-Object { $_.Name -eq 'pwsh.exe' } |
                ForEach-Object { [int]$_.ProcessId })
        }
        $pwshExe = (Get-Command -Name pwsh).Source
        $grandScript = Join-Path $TestDrive 'sleep-grand.ps1'
        Set-Content -LiteralPath $grandScript -Value 'Start-Sleep 120'
        $leafScript = Join-Path $TestDrive 'sleep-leaf.ps1'
        @"
Start-Process -FilePath '$pwshExe' -ArgumentList '-NoProfile','-File','$grandScript' -WindowStyle Hidden
Start-Sleep 120
"@ | Set-Content -LiteralPath $leafScript
        $childScript = Join-Path $TestDrive 'sleep-child.ps1'
        @"
Start-Process -FilePath '$pwshExe' -ArgumentList '-NoProfile','-File','$leafScript' -WindowStyle Hidden
Start-Sleep 120
"@ | Set-Content -LiteralPath $childScript
        $outer = Start-Process -FilePath $pwshExe -ArgumentList @('-NoProfile', '-File', $childScript) -WindowStyle Hidden -PassThru
        $script:treePids.Add($outer.Id) | Out-Null

        $childId = $null
        $childDeadline = [datetime]::UtcNow.AddSeconds(10)
        while ([datetime]::UtcNow -lt $childDeadline) {
            $childCandidates = @(Get-DirectChildPids -ParentId $outer.Id)
            if ($childCandidates.Count -gt 0) {
                $childId = $childCandidates[0]
                break
            }
            Start-Sleep -Milliseconds 200
        }
        $childId | Should -Not -BeNullOrEmpty
        $script:treePids.Add($childId) | Out-Null

        $grandchildId = $null
        $grandchildDeadline = [datetime]::UtcNow.AddSeconds(10)
        while ([datetime]::UtcNow -lt $grandchildDeadline) {
            $grandchildren = @(Get-DirectChildPids -ParentId $childId)
            if ($grandchildren.Count -gt 0) {
                $grandchildId = $grandchildren[0]
                break
            }
            Start-Sleep -Milliseconds 200
        }
        $grandchildId | Should -Not -BeNullOrEmpty
        $script:treePids.Add($grandchildId) | Out-Null

        { Stop-ProcessTree -ProcessId $outer.Id } | Should -Not -Throw

        $gone = $false
        $waitUntil = [datetime]::UtcNow.AddSeconds(15)
        while ([datetime]::UtcNow -lt $waitUntil) {
            if (-not (Test-ProcessAlive $outer.Id) -and -not (Test-ProcessAlive $childId) -and -not (Test-ProcessAlive $grandchildId)) {
                $gone = $true
                break
            }
            Start-Sleep -Milliseconds 200
        }
        $gone | Should -BeTrue
    }

    It 'Stop-ProcessTree -ProcessId 999999 does not throw and emits nothing' {
        $out = Stop-ProcessTree -ProcessId 999999 6>&1
        $out | Should -BeNullOrEmpty
    }

    It 'does not throw when the process has already exited' {
        $p = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-Command', 'exit 0') -WindowStyle Hidden -PassThru
        $null = $p.WaitForExit(5000)
        { Stop-ProcessTree -ProcessId $p.Id } | Should -Not -Throw
    }

    AfterAll {
        foreach ($id in $script:treePids) {
            try {
                [Diagnostics.Process]::GetProcessById($id).Kill($true)
            } catch {
            }
        }
    }
}

Describe 'scripts/test.ps1' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:testRunner = Join-Path $script:repoRoot 'scripts/test.ps1'
        $script:fixtureDir = Join-Path $TestDrive 'test-runner-fixture'
        New-Item -ItemType Directory -Path $script:fixtureDir -Force | Out-Null
        @"
Describe 'fixture' {
    It 'passes' { 1 | Should -Be 1 }
    It 'fails' { 1 | Should -Be 2 }
    It 'slow' -Tag 'Slow' { Set-Content (Join-Path `$PSScriptRoot 'slow-ran.txt') x }
}
"@ | Set-Content -LiteralPath (Join-Path $script:fixtureDir 'fixture.Tests.ps1') -Encoding utf8

        function script:Invoke-TestRunner {
            param([string[]]$ExtraArgs)
            $stdoutF = [IO.Path]::GetTempFileName()
            $stderrF = [IO.Path]::GetTempFileName()
            try {
                $argList = @('-NoProfile', '-File', $script:testRunner) + $ExtraArgs
                $p = Start-Process -FilePath 'pwsh' -ArgumentList $argList -Wait -PassThru -NoNewWindow `
                    -RedirectStandardOutput $stdoutF -RedirectStandardError $stderrF
                $out = ''
                if (Test-Path -LiteralPath $stdoutF) { $out += [IO.File]::ReadAllText($stdoutF) }
                if (Test-Path -LiteralPath $stderrF) { $out += [IO.File]::ReadAllText($stderrF) }
                return @{ ExitCode = $p.ExitCode; Output = $out }
            } finally {
                foreach ($f in @($stdoutF, $stderrF)) {
                    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
                }
            }
        }
    }

    It 'with -Fast excludes Slow tests and exits 1 when a test fails' {
        $slowFile = Join-Path $script:fixtureDir 'slow-ran.txt'
        if (Test-Path -LiteralPath $slowFile) { Remove-Item -LiteralPath $slowFile -Force }
        $r = Invoke-TestRunner -ExtraArgs @('-Fast', '-Path', $script:fixtureDir)
        $r.ExitCode | Should -Be 1
        Test-Path -LiteralPath $slowFile | Should -BeFalse
    }

    It 'without -Fast runs Slow tests and exits 1 when a test fails' {
        $slowFile = Join-Path $script:fixtureDir 'slow-ran.txt'
        if (Test-Path -LiteralPath $slowFile) { Remove-Item -LiteralPath $slowFile -Force }
        $r = Invoke-TestRunner -ExtraArgs @('-Path', $script:fixtureDir)
        $r.ExitCode | Should -Be 1
        Test-Path -LiteralPath $slowFile | Should -BeTrue
        Remove-Item -LiteralPath $slowFile -Force -ErrorAction SilentlyContinue
    }

    It 'with no existing test folders prints no test folders and exits 0' {
        $missing = Join-Path $TestDrive 'empty-test-folder'
        $r = Invoke-TestRunner -ExtraArgs @('-Fast', '-Path', $missing)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'no test folders'
    }
}
