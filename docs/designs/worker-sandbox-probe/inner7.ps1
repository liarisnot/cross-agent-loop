# Runs INSIDE the AppContainer: loopback inside the same container, and node realpath under a D:\ folder.
$ErrorActionPreference = 'Stop'
$work = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $work 'results.txt'
trap { Add-Content $out "TRAP line $($_.InvocationInfo.ScriptLineNumber): $_"; exit 1 }
$in = Get-Content (Join-Path $work 'probe-input.json') -Raw | ConvertFrom-Json
$env:TEMP = $env:TMP = Join-Path $work 'tmp'
Set-Content $out 'inside container'
function Probe($name, [scriptblock]$b) { try { $v = & $b; Add-Content $out "OK   $name : $v" } catch { Add-Content $out "FAIL $name : $($_.Exception.Message)" } }
Probe 'loopback same process' {
    $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start(); $port = $l.LocalEndpoint.Port
    $c = [Net.Sockets.TcpClient]::new(); $t = $c.ConnectAsync('127.0.0.1', $port)
    if (-not $t.Wait(5000)) { throw "connect timeout on $port" }
    $s = $l.AcceptTcpClient(); $s.Close(); $c.Close(); $l.Stop(); "connected on $port"
}
Probe 'loopback child server' {
    $node = Get-ChildItem 'W:\nodelocal\node.exe'
    $srv = [Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]@{ FileName = $node.FullName; Arguments = '-e "require(''http'').createServer((q,r)=>r.end(''hi'')).listen(47613,''127.0.0.1'')"'; UseShellExecute = $false; CreateNoWindow = $true })
    Start-Sleep 2
    try { (Invoke-WebRequest 'http://127.0.0.1:47613/' -UseBasicParsing -TimeoutSec 5).Content } finally { $srv.Kill($true) }
}
Probe 'node realpathSync D:\ path' {
    $o = & 'W:\nodelocal\node.exe' -e "console.log(require('fs').realpathSync('D:/xagent-ac-probe/tmp'))" 2>&1; if ($LASTEXITCODE) { throw ($o -join ' ') }; $o
}
Probe 'node require D:\ file' {
    Set-Content (Join-Path $work 'm.js') 'module.exports = 42'
    $o = & 'W:\nodelocal\node.exe' -e "console.log(require('D:/xagent-ac-probe/m.js'))" 2>&1; if ($LASTEXITCODE) { throw ($o -join ' ') }; $o
}
Add-Content $out 'inner done'
