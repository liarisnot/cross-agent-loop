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
