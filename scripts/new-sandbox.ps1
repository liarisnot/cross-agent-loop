#Requires -Version 7.0
$ErrorActionPreference = 'Stop'

$fixture = Join-Path $PSScriptRoot '../skills/feature/tests/fixtures/sandbox'
$fixture = [System.IO.Path]::GetFullPath($fixture)

if (-not (Test-Path -LiteralPath $fixture -PathType Container)) {
    [Console]::Error.WriteLine("fixture folder missing: $fixture")
    exit 1
}

$hex = -join ((1..8) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
$dest = Join-Path ([IO.Path]::GetTempPath()) "feature-sandbox-$hex"

try {
    Copy-Item -LiteralPath $fixture -Destination $dest -Recurse -Force

    & git -C $dest init -b main *> $null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine('git init failed')
        exit 1
    }

    $email = (& git config --global --get user.email 2>$null)
    if (-not $email) {
        & git -C $dest config user.name 'sandbox' *> $null
        if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine('git config user.name failed'); exit 1 }
        & git -C $dest config user.email 'sandbox@example.test' *> $null
        if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine('git config user.email failed'); exit 1 }
    }

    & git -C $dest add -A *> $null
    if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine('git add failed'); exit 1 }
    & git -C $dest -c core.safecrlf=false commit -m 'init' *> $null
    if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine('git commit failed'); exit 1 }

    Write-Output $dest
    exit 0
}
catch {
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
    }
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
