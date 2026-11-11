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
