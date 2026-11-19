Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:FAKE_UV_LOG) {
    Add-Content -LiteralPath $env:FAKE_UV_LOG -Value ($args -join ' ') -Encoding utf8
}

$fail = $env:FAKE_UV_FAIL
if ($fail -and $args.Count -gt 0 -and $args[0] -eq $fail) {
    [Console]::Error.WriteLine('fake failure')
    exit 1
}

if ($args.Count -ge 1 -and $args[0] -eq '--version') {
    Write-Output 'uv 0.0.0-fake'
    exit 0
}

if ($args.Count -ge 3 -and $args[0] -eq 'python' -and $args[1] -eq 'install') {
    $req = $args[2]
    $dir = Join-Path $env:UV_PYTHON_INSTALL_DIR "cpython-$req-fake"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $py = Join-Path $dir 'python.cmd'
    if ($req -match '^\d+\.\d+$') {
        Set-Content -LiteralPath $py -Value "@echo $($req).99" -Encoding ascii
    } else {
        Set-Content -LiteralPath $py -Value "@echo $req" -Encoding ascii
    }
    exit 0
}

if ($args.Count -ge 4 -and $args[0] -eq 'python' -and $args[1] -eq 'find' -and $args[2] -eq '--managed-python') {
    $req = $args[3]
    $py = Join-Path $env:UV_PYTHON_INSTALL_DIR "cpython-$req-fake\python.cmd"
    Write-Output $py
    exit 0
}

if ($args.Count -ge 1 -and $args[0] -eq 'sync') {
    $root = $env:UV_PROJECT_ENVIRONMENT
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'Scripts') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'Lib\site-packages') | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $root 'Scripts\python.exe') | Out-Null
    exit 0
}

if ($args.Count -ge 2 -and $args[0] -eq 'venv') {
    $root = $args[1]
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'Scripts') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'Lib\site-packages') | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $root 'Scripts\python.exe') | Out-Null
    exit 0
}

if ($args.Count -ge 1 -and $args[0] -eq 'lock') {
    Set-Content -LiteralPath 'uv.lock' -Value 'version = 1' -Encoding utf8
    exit 0
}

if ($args.Count -ge 2 -and $args[0] -eq 'pip' -and $args[1] -eq 'install') {
    exit 0
}

exit 0
