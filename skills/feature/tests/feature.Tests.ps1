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
    It 'blocks when lock matches running pid and start time' {
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

    It 'overlap: folder vs file under it' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'ov2' -Plan (New-OverlapTestPlan -FileA 'src/' -FileB 'src/x/y.ts') | Out-Null
        Set-TaskState -Repo $repo -Name 'ov2' -States @{ ta = 'running' }
        $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'ov2') -WorkingDirectory $repo
        $r.Json.tasks | Should -Be @()
    }

    It 'overlap: ** overlaps anything' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'ov3' -Plan (New-OverlapTestPlan -FileA '**' -FileB 'anywhere/foo.ts') | Out-Null
        Set-TaskState -Repo $repo -Name 'ov3' -States @{ ta = 'running' }
        $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'ov3') -WorkingDirectory $repo
        $r.Json.tasks | Should -Be @()
    }

    It 'overlap: *.md overlaps anything' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'ov4' -Plan (New-OverlapTestPlan -FileA '*.md' -FileB 'z.ts') | Out-Null
        Set-TaskState -Repo $repo -Name 'ov4' -States @{ ta = 'running' }
        $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'ov4') -WorkingDirectory $repo
        $r.Json.tasks | Should -Be @()
    }

    It 'overlap: src/test*.ts vs src/testing.ts' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'ov5' -Plan (New-OverlapTestPlan -FileA 'src/test*.ts' -FileB 'src/testing.ts') | Out-Null
        Set-TaskState -Repo $repo -Name 'ov5' -States @{ ta = 'running' }
        $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'ov5') -WorkingDirectory $repo
        $r.Json.tasks | Should -Be @()
    }

    It 'overlap: src/a/* vs src/b/x.ts does not overlap' {
        $repo = New-TestRepo
        Import-TestPlan -Repo $repo -Name 'ov6' -Plan (New-OverlapTestPlan -FileA 'src/a/*' -FileB 'src/b/x.ts') | Out-Null
        Set-TaskState -Repo $repo -Name 'ov6' -States @{ ta = 'running' }
        $r = Invoke-Feature @('schedule', '-Repo', $repo, '-Name', 'ov6') -WorkingDirectory $repo
        $r.Json.tasks.id | Should -Be @('tb')
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

    It 'cap blocks tasks when two live runs exist for feature' {
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

    It 'live run count ignores pid files for another feature' {
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

    It 'mismatched start time is not live' {
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

    It 'returns one task when one live run and two ready tasks' {
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
}
