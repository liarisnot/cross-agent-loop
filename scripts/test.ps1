#Requires -Version 7.0
param([switch]$Fast)

$ErrorActionPreference = 'Stop'

Import-Module Pester -MinimumVersion 5.5

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$candidates = @(
    (Join-Path $repoRoot 'skills/feature/tests')
    (Join-Path $repoRoot 'skills/delegate/tests')
)
$paths = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container })

if ($paths.Count -eq 0) {
    Write-Output 'no test folders'
    exit 0
}

$config = New-PesterConfiguration
$config.Run.Path = $paths
$config.Run.PassThru = $true
$config.TestRegistry.Enabled = $false

$excludeTags = @('Live')
if ($Fast) {
    $excludeTags += 'Slow'
}
$config.Filter.ExcludeTag = $excludeTags

$config.Output.Verbosity = 'Normal'

$result = Invoke-Pester -Configuration $config
exit [int]([Math]::Min($result.FailedCount, 250))