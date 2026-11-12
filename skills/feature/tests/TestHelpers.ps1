[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

function New-TestRepo {
    $dir = Join-Path $TestDrive ("repo-{0}" -f [guid]::NewGuid())
    New-Item -ItemType Directory -Path $dir | Out-Null
    & git -C $dir init -b main 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
    & git -C $dir config user.name test
    & git -C $dir config user.email test@example.invalid
    & git -C $dir config commit.gpgsign false
    & git -C $dir config core.autocrlf false
    Set-Content -LiteralPath (Join-Path $dir 'README.md') -Value 'test' -NoNewline
    & git -C $dir add README.md 2>&1 | Out-Null
    & git -C $dir commit -m 'init' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
    return $dir
}

function Invoke-Feature {
    param(
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$ScriptPath = (Join-Path $PSScriptRoot '../scripts/feature.ps1')
    )
    $pushed = $false
    try {
        if ($WorkingDirectory) {
            Push-Location -LiteralPath $WorkingDirectory
            $pushed = $true
        }
        $stderrFile = New-TemporaryFile
        try {
            $stdout = & pwsh -NoProfile -File $ScriptPath @Arguments 2> $stderrFile.FullName
            $exitCode = $LASTEXITCODE
            $stderr = (@(Get-Content -LiteralPath $stderrFile.FullName) -join "`n").TrimEnd()   # -join: an empty file still gives ''
        } finally {
            Remove-Item -LiteralPath $stderrFile.FullName -Force -ErrorAction SilentlyContinue
        }
        $raw = if ($null -eq $stdout) { '' } else { ($stdout | Out-String).TrimEnd() }
        $json = $null
        if ($raw) {
            try { $json = $raw | ConvertFrom-Json } catch { }
        }
        [pscustomobject]@{
            ExitCode = $exitCode
            Json     = $json
            Raw      = $raw
            Stderr   = $stderr
        }
    } finally {
        if ($pushed) { Pop-Location }
    }
}

function Invoke-FeatureInProcess {
    param(
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$ScriptPath = (Join-Path $PSScriptRoot '../scripts/feature.ps1')
    )
    if (-not $Arguments -or $Arguments.Count -eq 0 -or ($Arguments.Count % 2 -eq 0)) {
        throw 'Invoke-FeatureInProcess: bad arguments'
    }
    $h = @{ Subcommand = $Arguments[0] }
    for ($i = 1; $i -lt $Arguments.Count; $i += 2) {
        $h[$Arguments[$i].TrimStart('-')] = $Arguments[$i + 1]
    }
    $global:LASTEXITCODE = 0
    $pushed = $false
    try {
        Push-Location -LiteralPath $WorkingDirectory
        $pushed = $true
        $out = & $ScriptPath @h
        $code = $LASTEXITCODE
    } finally {
        if ($pushed) { Pop-Location }
    }
    $raw = (@($out) -join "`n").TrimEnd()
    $json = $null
    if ($raw) {
        try { $json = $raw | ConvertFrom-Json } catch { }
    }
    [pscustomobject]@{
        ExitCode = $code
        Json     = $json
        Raw      = $raw
        Stderr   = ''
    }
}

function Get-FeatureFunctionScript {
    param([string[]]$Name)
    $path = Join-Path $PSScriptRoot '../scripts/feature.ps1'
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    $defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $Name) {
        $found = $defs | Where-Object { $_.Name -ceq $n } | Select-Object -First 1
        if (-not $found) { throw "function not found: $n" }
        $parts.Add($found.Extent.Text)
    }
    return [scriptblock]::Create(($parts -join "`n`n"))
}

function Get-SampleSchemaName {
    param([string]$FileName)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $dash = $base.IndexOf('-')
    if ($dash -gt 0) { return $base.Substring(0, $dash) }
    return $base
}

function Test-Schema {
    param(
        [string]$Json,
        [string]$SchemaName
    )
    $schemaFile = Join-Path $PSScriptRoot "../schemas/$SchemaName.schema.json"
    Test-Json -Json $Json -SchemaFile $schemaFile -ErrorAction SilentlyContinue
}

function Assert-FeatureOk {
    param($Result)
    if ($Result.ExitCode -ne 0 -or -not $Result.Json -or -not $Result.Json.ok) {
        $err = if ($Result.Json) { $Result.Json.error } else { $Result.Raw }
        throw "feature command failed: $err"
    }
    return $Result.Json
}

function New-FeatureAtStage {
    param(
        [string]$Repo,
        [string]$Name,
        [string]$Stage
    )
    $common = @{ '-Repo' = $Repo; '-WorkingDirectory' = $Repo; '-Name' = $Name }
    Assert-FeatureOk (Invoke-FeatureInProcess @('new', '-Name', $Name, '-Repo', $Repo) -WorkingDirectory $Repo)
    if ($Stage -eq 'design') { return }
    if (@('design-review', 'plan', 'build', 'signoff') -contains $Stage) {
        Assert-FeatureOk (Invoke-FeatureInProcess @('stage', '-To', 'design-review', '-Repo', $Repo, '-Name', $Name) -WorkingDirectory $Repo)
    }
    if (@('plan', 'build', 'signoff') -contains $Stage) {
        $designPath = Join-Path $Repo "docs/designs/$Name.md"
        New-Item -ItemType Directory -Force (Split-Path $designPath) | Out-Null
        Set-Content -LiteralPath $designPath -Value '# design' -NoNewline
        Assert-FeatureOk (Invoke-FeatureInProcess @('commit-design', '-Section', 'intro', '-Repo', $Repo, '-Name', $Name) -WorkingDirectory $Repo)
        Assert-FeatureOk (Invoke-FeatureInProcess @('gate', '-Gate', 'design-locked', '-Quote', 'lock it', '-Repo', $Repo, '-Name', $Name) -WorkingDirectory $Repo)
        Assert-FeatureOk (Invoke-FeatureInProcess @('stage', '-To', 'plan', '-Repo', $Repo, '-Name', $Name) -WorkingDirectory $Repo)
    }
    if (@('build', 'signoff') -contains $Stage) {
        Assert-FeatureOk (Invoke-FeatureInProcess @('gate', '-Gate', 'plan-approved', '-Quote', 'approve', '-Repo', $Repo, '-Name', $Name) -WorkingDirectory $Repo)
        Assert-FeatureOk (Invoke-FeatureInProcess @('stage', '-To', 'build', '-Repo', $Repo, '-Name', $Name) -WorkingDirectory $Repo)
    }
    if ($Stage -eq 'signoff') {
        Assert-FeatureOk (Invoke-FeatureInProcess @('stage', '-To', 'signoff', '-Repo', $Repo, '-Name', $Name) -WorkingDirectory $Repo)
    }
}

function New-PlanFile {
    param(
        [string]$Path,
        [hashtable]$Plan
    )
    $json = $Plan | ConvertTo-Json -Depth 12
    $json = $json -replace "`r`n", "`n" -replace "`r", "`n"
    if (-not $json.EndsWith("`n")) { $json += "`n" }
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Set-TaskState {
    param(
        [string]$Repo,
        [string]$Name,
        [hashtable]$States
    )
    $dir = Join-Path $Repo ".xagent/features/$Name"
    New-Item -ItemType Directory -Force $dir | Out-Null
    $tasks = [ordered]@{}
    foreach ($id in $States.Keys) {
        $tasks[$id] = [ordered]@{ status = [string]$States[$id]; failures = 0 }
    }
    $body = [ordered]@{
        name          = $Name
        lastReconcile = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        tasks         = $tasks
    }
    $json = $body | ConvertTo-Json -Depth 10
    $json = $json -replace "`r`n", "`n" -replace "`r", "`n"
    if (-not $json.EndsWith("`n")) { $json += "`n" }
    [IO.File]::WriteAllText((Join-Path $dir 'state.json'), $json, [Text.UTF8Encoding]::new($false))
}

function Get-StandardTwoPhasePlan {
    return @{
        summary = 'Test plan summary'
        phases  = @(
            @{
                n         = 1
                rationale = 'Phase one rationale'
                test      = 'pwsh -NoProfile -c "exit 0"'
                tasks     = @(
                    @{
                        id        = 't1'
                        title     = 'Task one'
                        dependsOn = @()
                        files     = @('src/a.ts')
                        test      = 'npm test'
                        profile   = 'code'
                        brief     = 'Do task one.'
                    },
                    @{
                        id        = 't2'
                        title     = 'Task two'
                        dependsOn = @('t1')
                        files     = @('src/b.ts')
                        test      = 'npm test'
                        profile   = 'code-hard'
                        brief     = 'Do task two.'
                    }
                )
            },
            @{
                n         = 2
                rationale = 'Phase two rationale'
                test      = 'pwsh -NoProfile -c "exit 0"'
                tasks     = @(
                    @{
                        id        = 't3'
                        title     = 'Task three'
                        dependsOn = @('t2')
                        files     = @('docs/readme.md')
                        test      = 'npm test'
                        profile   = 'code'
                        brief     = 'Do task three.'
                    }
                )
            }
        )
    }
}

function Import-TestPlan {
    param(
        [string]$Repo,
        [string]$Name,
        [hashtable]$Plan
    )
    New-FeatureAtStage -Repo $Repo -Name $Name -Stage 'plan'
    $planPath = Join-Path $TestDrive ("plan-$Name-{0}.json" -f [guid]::NewGuid())
    New-PlanFile -Path $planPath -Plan $Plan
    $r = Invoke-FeatureInProcess @('plan', '-PlanFile', $planPath, '-Repo', $Repo, '-Name', $Name) -WorkingDirectory $Repo
    Assert-FeatureOk $r
    return $r
}

function Write-FeatureJsonFileLocal {
    param([string]$Path, [object]$Feature)
    if ($Feature.gates -and $Feature.gates.PSObject.Properties) {
        foreach ($prop in $Feature.gates.PSObject.Properties) {
            $atP = $prop.Value.PSObject.Properties['at']
            if ($null -eq $atP) { continue }
            $atP.Value = ([datetime]$atP.Value).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
    }
    $json = $Feature | ConvertTo-Json -Depth 12
    $json = $json -replace '(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\.\d+Z', '$1Z'
    $json = $json -replace "`r`n", "`n" -replace "`r", "`n"
    if (-not $json.EndsWith("`n")) { $json += "`n" }
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function New-OneTaskPlan {
    param(
        [string]$TaskId = 't1',
        [string[]]$Files = @('src/a.ts'),
        [string]$Test = 'pwsh -NoProfile -c "exit 0"'
    )
    return @{
        summary = 'one task plan'
        phases  = @(
            @{
                n         = 1
                rationale = 'R'
                test      = 'pwsh -NoProfile -c "exit 0"'
                tasks     = @(
                    @{
                        id        = $TaskId
                        title     = 'Task'
                        dependsOn = @()
                        files     = $Files
                        test      = $Test
                        profile   = 'code'
                        brief     = 'Brief'
                    }
                )
            }
        )
    }
}

function New-TaskWorktree {
    param(
        [string]$Repo,
        [string]$Name,
        [string]$TaskId = 't1',
        [string[]]$Files = @('src/a.ts'),
        [string]$Test = 'pwsh -NoProfile -c "exit 0"',
        [switch]$NoRecord,
        [switch]$SkipPlanImport
    )
    if (-not $SkipPlanImport) {
        Import-TestPlan -Repo $Repo -Name $Name -Plan (New-OneTaskPlan -TaskId $TaskId -Files $Files -Test $Test) | Out-Null
    }
    $featJson = (& git -C $Repo show "HEAD:docs/features/$Name/feature.json") -join "`n" | ConvertFrom-Json
    $delegateId = $null
    foreach ($ph in @($featJson.phases)) {
        foreach ($t in @($ph.tasks)) {
            if ([string]$t.id -ceq $TaskId) {
                $delegateId = [string]$t.delegateTaskId
                break
            }
        }
    }
    if (-not $delegateId) { throw 'delegateTaskId not found' }
    $base = @(& git -C $Repo rev-parse "feature/$Name")[0]
    $driveRoot = [IO.Path]::GetFullPath(([string]$TestDrive).Trim())
    $wtRootPath = Join-Path $driveRoot ('wt-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $wtRootPath = [IO.Path]::GetFullPath($wtRootPath).Trim()
    if (-not $wtRootPath) { throw 'empty worktree path' }
    & git -C $Repo worktree add -b "xagent/$delegateId" $wtRootPath "feature/$Name" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'worktree add failed' }
    if (-not $NoRecord) {
        Assert-FeatureOk (Invoke-FeatureInProcess @(
                'task', '-Repo', $Repo, '-Name', $Name, '-Task', $TaskId,
                '-Worktree', $wtRootPath, '-BaseSha', $base
            ) -WorkingDirectory $Repo)
    }
    return [pscustomobject]@{
        Dir            = [string]$wtRootPath
        AgentBranch    = [string]"xagent/$delegateId"
        BaseSha        = [string]$base
        TaskId         = [string]$TaskId
        DelegateTaskId = [string]$delegateId
    }
}

function Get-TaskWorktreeRoot {
    param($Ctx)
    return ([string]$Ctx.Dir).Trim()
}

function Remove-TaskWorktree {
    param(
        [string]$Repo,
        [string]$WtRoot
    )
    & git -C $Repo worktree remove --force $WtRoot 2>&1 | Out-Null
    & git -C $Repo worktree prune 2>&1 | Out-Null
}

function New-OverlapTestPlan {
    param(
        [string]$FileA,
        [string]$FileB,
        [string]$IdA = 'ta',
        [string]$IdB = 'tb'
    )
    return @{
        summary = 'overlap test'
        phases  = @(
            @{
                n         = 1
                rationale = 'r'
                test      = 'pwsh -NoProfile -c "exit 0"'
                tasks     = @(
                    @{
                        id        = $IdA
                        title     = 'A'
                        dependsOn = @()
                        files     = @($FileA)
                        test      = 'pwsh -NoProfile -c "exit 0"'
                        profile   = 'code'
                        brief     = 'a'
                    },
                    @{
                        id        = $IdB
                        title     = 'B'
                        dependsOn = @()
                        files     = @($FileB)
                        test      = 'pwsh -NoProfile -c "exit 0"'
                        profile   = 'code'
                        brief     = 'b'
                    }
                )
            }
        )
    }
}
