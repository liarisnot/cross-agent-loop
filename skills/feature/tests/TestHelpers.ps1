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
    Assert-FeatureOk (Invoke-Feature @('new', '-Name', $Name, '-Repo', $Repo) -WorkingDirectory $Repo)
    if ($Stage -eq 'design') { return }
    if (@('design-review', 'plan', 'build', 'signoff') -contains $Stage) {
        Assert-FeatureOk (Invoke-Feature @('stage', '-To', 'design-review', '-Repo', $Repo, '-Name', $Name) -WorkingDirectory $Repo)
    }
    if (@('plan', 'build', 'signoff') -contains $Stage) {
        $designPath = Join-Path $Repo "docs/designs/$Name.md"
        New-Item -ItemType Directory -Force (Split-Path $designPath) | Out-Null
        Set-Content -LiteralPath $designPath -Value '# design' -NoNewline
        Assert-FeatureOk (Invoke-Feature @('commit-design', '-Section', 'intro', '-Repo', $Repo, '-Name', $Name) -WorkingDirectory $Repo)
        Assert-FeatureOk (Invoke-Feature @('gate', '-Gate', 'design-locked', '-Quote', 'lock it', '-Repo', $Repo, '-Name', $Name) -WorkingDirectory $Repo)
        Assert-FeatureOk (Invoke-Feature @('stage', '-To', 'plan', '-Repo', $Repo, '-Name', $Name) -WorkingDirectory $Repo)
    }
    if (@('build', 'signoff') -contains $Stage) {
        Assert-FeatureOk (Invoke-Feature @('gate', '-Gate', 'plan-approved', '-Quote', 'approve', '-Repo', $Repo, '-Name', $Name) -WorkingDirectory $Repo)
        Assert-FeatureOk (Invoke-Feature @('stage', '-To', 'build', '-Repo', $Repo, '-Name', $Name) -WorkingDirectory $Repo)
    }
    if ($Stage -eq 'signoff') {
        Assert-FeatureOk (Invoke-Feature @('stage', '-To', 'signoff', '-Repo', $Repo, '-Name', $Name) -WorkingDirectory $Repo)
    }
}
