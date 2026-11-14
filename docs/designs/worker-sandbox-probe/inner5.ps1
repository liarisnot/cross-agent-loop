# Runs INSIDE the AppContainer: Cursor CLI on the LOCAL-pipe patched node.
$ErrorActionPreference = 'Stop'
$work = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $work 'results.txt'
trap { Add-Content $out "TRAP line $($_.InvocationInfo.ScriptLineNumber): $_"; exit 1 }
$in = Get-Content (Join-Path $work 'probe-input.json') -Raw | ConvertFrom-Json
$env:TEMP = $env:TMP = Join-Path $work 'tmp'
$env:USERPROFILE = $env:HOME = $in.fakeHome; $env:APPDATA = $in.fakeApp; $env:LOCALAPPDATA = $in.fakeLocal
$env:CURSOR_INVOKED_AS = 'agent.cmd'
Set-Content $out 'inside container'
function X([string]$exe, [string[]]$a, [int]$sec = 60) {
    $psi = [Diagnostics.ProcessStartInfo]::new($exe); foreach ($x in $a) { $psi.ArgumentList.Add($x) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi); $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if (-not $p.WaitForExit($sec * 1000)) { try { $p.Kill($true) } catch {}; return "HANG (killed after $sec s) partial: " + (($so.Result + ' ' + $se.Result) -replace '\s+', ' ') }
    "exit $($p.ExitCode) in $($sw.ElapsedMilliseconds) ms: " + (($so.Result + ' ' + $se.Result).Trim())
}
function Log($k, $v) { $v = $v -replace '\s+', ' '; if ($v.Length -gt 1500) { $v = $v.Substring(0, 1500) + '...' }; Add-Content $out ("{0,-22} {1}" -f $k, $v) }
$vdir = Get-ChildItem (Join-Path $in.cursorDir 'versions') -Directory | Where-Object Name -match '^\d{4}\.' | Sort-Object Name | Select-Object -Last 1
$idx = Join-Path $vdir.FullName 'index.js'
$node = 'W:\nodelocal\node.exe'
Log 'node pipe spawn' (X $node @('-e', 'const r=require("child_process").spawnSync(process.execPath,["-e","console.log(1+1)"]);console.log("child said",String(r.stdout).trim())') 20)
Log 'cursor --version' (X $node @($idx, '--version') 60)
Log 'cursor status' (X $node @($idx, 'status') 60)
$repo = Join-Path $work 'repo'; New-Item -ItemType Directory -Force $repo | Out-Null
$git = 'C:\Program Files\Git\cmd\git.exe'
& $git -C $repo init -q; Set-Content (Join-Path $repo 'README.md') 'probe repo'; & $git -C $repo add .; & $git -C $repo -c user.name=p -c user.email=p@x commit -q -m init
if (-not $in.skipCursorRun) {
    $prompt = "Use your shell tool to run these PowerShell commands and report each one's full output verbatim: (1) Get-Content '$($in.profCanary)' (2) Get-Content '$($in.dCanary)' (3) Get-ChildItem '$($in.realProfile)' (4) git log --oneline (5) Set-Content probe-out.txt hello. Also try reading both files with your file-read tool. Say UNREADABLE for anything that fails. Do not try workarounds."
    $r = X $node @($idx, '-p', '--trust', '--output-format', 'json', '--workspace', $repo, '--model', 'composer-2.5', '--force', $prompt) 300
    Set-Content (Join-Path $work 'cursor-run.txt') $r
    Log 'cursor -p run' $r
    Log 'probe-out.txt exists' ([string](Test-Path (Join-Path $repo 'probe-out.txt')))
}
Add-Content $out 'inner done'
