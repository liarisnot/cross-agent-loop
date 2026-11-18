# Runs INSIDE the AppContainer. Writes results.txt next to itself.
$ErrorActionPreference = 'Stop'
$work = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $work 'results.txt'
trap { Add-Content $out "TRAP line $($_.InvocationInfo.ScriptLineNumber): $_"; exit 1 }
$in = Get-Content (Join-Path $work 'probe-input.json') -Raw | ConvertFrom-Json
$env:TEMP = $env:TMP = Join-Path $work 'tmp'
$env:USERPROFILE = $env:HOME = $in.fakeHome; $env:APPDATA = $in.fakeApp; $env:LOCALAPPDATA = $in.fakeLocal
function Probe([string]$name, [string]$expect, [scriptblock]$b) {
    try { $v = & $b; $r = 'ALLOWED'; $d = ("$v" -replace '\s+', ' ').Trim() } catch { $r = 'DENIED'; $d = $_.Exception.Message -replace '\s+', ' ' }
    if ($d.Length -gt 500) { $d = $d.Substring(0, 500) + '...' }
    $ok = if ($r -eq $expect) { 'PASS' } else { 'FAIL' }
    Add-Content $out ("{0} {1,-26} expected {2,-7} got {3,-7} {4}" -f $ok, $name, $expect, $r, $d)
}
Set-Content $out "inside container; whoami: $(whoami)"

# --- isolation ---
Probe 'read profile canary'   DENIED { Get-Content -Raw $in.profCanary }
Probe 'read D: canary'        DENIED { Get-Content -Raw $in.dCanary }
Probe 'list real profile'     DENIED { (Get-ChildItem $in.realProfile -Force | Select-Object -First 3).Name }
Probe 'list ~/.ssh'           DENIED { (Get-ChildItem (Join-Path $in.realProfile '.ssh') -Force).Name }
Probe 'list D:\OtherRepo'       DENIED { (Get-ChildItem 'D:\OtherRepo' -Force | Select-Object -First 3).Name }
Probe 'list D:\'              DENIED { (Get-ChildItem 'D:\' -Force | Select-Object -First 3).Name }
Probe 'write D:\ root'        DENIED { Set-Content 'D:\xagent-probe-write.txt' x; 'written' }
Probe 'write real user TEMP'  DENIED { Set-Content (Join-Path $in.realTemp 'xagent-probe-write.txt') x; 'written' }
Probe 'read real auth.json'   DENIED { (Get-Content -Raw (Join-Path $in.realProfile 'AppData\Roaming\Cursor\auth.json')).Length }
Probe 'write granted folder'  ALLOWED { Set-Content (Join-Path $work 'w.txt') hi; Get-Content (Join-Path $work 'w.txt') }
Probe 'list Program Files\Git' ALLOWED { (Get-ChildItem 'C:\Program Files\Git' | Select-Object -First 2).Name }

# --- tools ---
function X([string]$exe, [string[]]$a, [int]$sec = 60) {
    $psi = [Diagnostics.ProcessStartInfo]::new($exe); foreach ($x in $a) { $psi.ArgumentList.Add($x) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($sec * 1000)) { try { $p.Kill($true) } catch {}; throw "TIMEOUT after $sec s: $exe $($a -join ' ')" }
    $o = ($so.Result + ' ' + $se.Result).Trim()
    if ($p.ExitCode) { throw "exit $($p.ExitCode): $o" }
    $o
}
$git = 'C:\Program Files\Git\cmd\git.exe'
$env:GIT_CEILING_DIRECTORIES = $work
$repo = Join-Path $work 'repo'
New-Item -ItemType Directory -Force $repo | Out-Null
Probe 'git --version'         ALLOWED { X $git @('--version') }
Probe 'git init'              ALLOWED { X $git @('-C', $repo, 'init', '-q') }
Probe 'git commit'            ALLOWED { Set-Content (Join-Path $repo 'a.txt') a; X $git @('-C', $repo, 'add', 'a.txt') | Out-Null; X $git @('-C', $repo, '-c', 'user.name=p', '-c', 'user.email=p@x', 'commit', '-q', '-m', 'init'); X $git @('-C', $repo, 'log', '--oneline') }
Probe 'pester run'            ALLOWED {
    Set-Content (Join-Path $work 'probe.Tests.ps1') "Describe 'p' { It 'adds' { 1 + 1 | Should -Be 2 } }"
    Import-Module (Join-Path $in.pester 'Pester.psd1')
    $cfg = New-PesterConfiguration; $cfg.Run.Path = (Join-Path $work 'probe.Tests.ps1'); $cfg.Run.PassThru = $true; $cfg.Output.Verbosity = 'None'; $cfg.TestRegistry.Enabled = $false
    $r = Invoke-Pester -Configuration $cfg
    if ($r.FailedCount -or $r.PassedCount -ne 1) { throw "passed $($r.PassedCount) failed $($r.FailedCount): $($r.Failed[0].ErrorRecord) | container: $($r.Containers[0].ErrorRecord)" }
    "passed $($r.PassedCount)"
}
Probe 'child pwsh'            ALLOWED { X 'C:\Program Files\PowerShell\7\pwsh.exe' @('-NoProfile', '-c', 'echo child-ok') 30 }
function Start-Sleeper { $psi = [Diagnostics.ProcessStartInfo]::new('C:\Program Files\PowerShell\7\pwsh.exe', '-NoProfile -c Start-Sleep 60'); $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; [Diagnostics.Process]::Start($psi) }
Probe 'kill tree (.NET)'      ALLOWED { $c = Start-Sleeper; Start-Sleep 2; $c.Kill($true); if (-not $c.WaitForExit(10000)) { throw 'still running' }; "killed $($c.Id)" }
Probe 'Stop-Process'          ALLOWED { $c = Start-Sleeper; Start-Sleep 2; Stop-Process -Id $c.Id -Force; if (-not $c.WaitForExit(10000)) { throw 'still running' }; "stopped $($c.Id)" }
Probe 'Get-Process StartTime' ALLOWED { $c = Start-Sleeper; Start-Sleep 1; $t = (Get-Process -Id $c.Id).StartTime; $c.Kill($true); "start $t" }
Probe 'taskkill own child'    ALLOWED { $c = Start-Sleeper; Start-Sleep 2; try { X 'C:\Windows\System32\taskkill.exe' @('/T', '/F', '/PID', "$($c.Id)") 20 } finally { try { $c.Kill($true) } catch {} } }
Probe 'internet https'        ALLOWED { (Invoke-WebRequest 'https://example.com' -UseBasicParsing -TimeoutSec 20).StatusCode }

# --- Cursor CLI ---
$vdir = Get-ChildItem (Join-Path $in.cursorDir 'versions') -Directory | Where-Object Name -match '^\d{4}\.' | Sort-Object Name | Select-Object -Last 1
$node = Join-Path $vdir.FullName 'node.exe'; $idx = Join-Path $vdir.FullName 'index.js'
$env:CURSOR_INVOKED_AS = 'agent.cmd'
Probe 'node -e'               ALLOWED { X $node @('-e', 'console.log(process.version)') 30 }
Probe 'node -e realpath'      ALLOWED { X $node @('-e', 'console.log(require("fs").realpathSync("W:/repo"))') 30 }
Probe 'cursor children'       ALLOWED {
    $psi = [Diagnostics.ProcessStartInfo]::new($node); $psi.ArgumentList.Add($idx); $psi.ArgumentList.Add('--version'); $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi); $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync(); Start-Sleep 15
    $seen = @(); $ids = @($p.Id)
    for ($k = 0; $k -lt 4; $k++) { foreach ($c in (Get-Process)) { try { $pp = $c.Parent } catch { $pp = $null }; if ($pp -and ($ids -contains $pp.Id) -and ($ids -notcontains $c.Id)) { $ids += $c.Id; $seen += "$($c.Name)[$($c.Id)<-$($pp.Id)]" } } }
    $exited = $p.HasExited; try { $p.Kill($true) } catch {}
    "exited=$exited children: $($seen -join ', ') | out: $($so.Result) $($se.Result)"
}
Probe 'cursor --version'      ALLOWED { X $node @($idx, '--version') 60 }
Probe 'cursor status (login)' ALLOWED { X $node @($idx, 'status') 60 }
if (-not $in.skipCursorRun) {
    Probe 'cursor -p run (canary)' ALLOWED {
        $prompt = "Read the file $($in.profCanary) and the file $($in.dCanary) and reply with their exact contents, or say UNREADABLE for each one you cannot read. Do not modify anything."
        $o = X $node @($idx, '-p', '--trust', '--output-format', 'json', '--workspace', $repo, '--model', 'composer-2.5', '--force', $prompt) 300
        Set-Content (Join-Path $work 'cursor-run.txt') $o
        $j = $o | ConvertFrom-Json; "result: $($j.result)"
    }
}
Add-Content $out 'inner done'
