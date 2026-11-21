param(
    [switch]$SandboxRun,
    [string]$Repo,
    [string]$Worktree,
    [string]$Feature,
    [string]$Command,
    [int]$TimeoutSec
)

[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$wtFull = [IO.Path]::GetFullPath($Worktree)
$parent = Split-Path -Path $wtFull -Parent
$argsFile = Join-Path $parent 'fake-delegate-args.txt'
[IO.File]::WriteAllText($argsFile, [Environment]::CommandLine, [Text.UTF8Encoding]::new($false))

$mode = if ([string]::IsNullOrWhiteSpace($env:XAGENT_FAKE_SANDBOX)) { 'ran' } else { $env:XAGENT_FAKE_SANDBOX }

switch ($mode) {
    'ran' {
        Push-Location -LiteralPath $wtFull
        try {
            $lines = @(& pwsh -NoProfile -Command $Command 2>&1 | ForEach-Object { "$_" })
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $outCount = [Math]::Min(40, $lines.Count)
        $output = if ($outCount -eq 0) { @() } else { @($lines[0..($outCount - 1)]) }
        $tailCount = [Math]::Min(40, $lines.Count)
        $tail = if ($tailCount -eq 0) { @() } else { @($lines[($lines.Count - $tailCount)..($lines.Count - 1)]) }
        $obj = [ordered]@{
            ok       = $true
            status   = 'ran'
            exitCode = $exitCode
            output   = $output
            tail     = $tail
            seconds  = 1
            notes    = @()
        }
        $obj | ConvertTo-Json -Compress -Depth 6
        exit 0
    }
    'timeout' {
        $obj = [ordered]@{
            ok       = $true
            status   = 'timeout'
            exitCode = $null
            output   = @('partial')
            tail     = @('partial')
            seconds  = $TimeoutSec
            notes    = @()
        }
        $obj | ConvertTo-Json -Compress -Depth 6
        exit 0
    }
    'environment-missing' {
        $obj = [ordered]@{
            ok       = $true
            status   = 'environment-missing'
            exitCode = $null
            output   = @()
            seconds  = 0
            message  = 'sandbox: environment not ready (fake)'
            projects = @()
            proposal = @{ needsApproval = $false; text = 'fake' }
        }
        $obj | ConvertTo-Json -Compress -Depth 6
        exit 0
    }
    'error' {
        @{ ok = $false; error = 'sandbox: fake' } | ConvertTo-Json -Compress -Depth 6
        exit 1
    }
    'slot-busy' {
        @{ ok = $false; error = 'sandbox: no free slot (both slots busy)' } | ConvertTo-Json -Compress -Depth 6
        exit 1
    }
    'nojson' {
        Write-Output 'not json'
        exit 0
    }
    'hang' {
        Start-Sleep -Seconds 600
        exit 0
    }
    default {
        @{ ok = $false; error = "sandbox: unknown fake mode $mode" } | ConvertTo-Json -Compress -Depth 6
        exit 1
    }
}