# Loopback-exemption probe: can an AppContainer reach a server on the host's localhost?
# Steps: setup (profile + host server), test (run container client), cleanup.
param([ValidateSet('setup', 'test', 'cleanup')] [string]$Step)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$work = 'D:\xagent-lb-probe'; $name = 'xagent.lbprobe'; $port = 47614
. (Join-Path $here 'ac-native.ps1')   # defines [AC]
$sid = [AC]::GetSid($name)

switch ($Step) {
    'setup' {
        New-Item -ItemType Directory -Force $work | Out-Null
        icacls $work /grant "*${sid}:(OI)(CI)F" /T /Q | Out-Null
        $v = Get-ChildItem "$env:LOCALAPPDATA\cursor-agent\versions" -Directory | Where-Object Name -match '^\d{4}\.' | Sort-Object Name | Select-Object -Last 1
        $js = Join-Path $work 'server.js'
        Set-Content $js "require('http').createServer((q,r)=>r.end('host-service-ok')).listen($port,'127.0.0.1',()=>console.log('listening'))"
        $p = Start-Process "$($v.FullName)\node.exe" -ArgumentList "`"$js`"" -WindowStyle Hidden -PassThru
        Set-Content (Join-Path $work 'server.pid') $p.Id
        Start-Sleep 1
        "host check: $((Invoke-WebRequest "http://127.0.0.1:$port/" -UseBasicParsing -TimeoutSec 5).Content)"
        "container sid: $sid"
    }
    'test' {
        $inner = Join-Path $work 'inner.ps1'
        Set-Content $inner @"
`$out = '$work\result.txt'
foreach (`$u in 'http://127.0.0.1:$port/', 'http://localhost:$port/') {
  try { `$c = (Invoke-WebRequest `$u -UseBasicParsing -TimeoutSec 8).Content; Add-Content `$out "REACHED `$u -> `$c" }
  catch { Add-Content `$out "BLOCKED `$u -> `$(`$_.Exception.Message)" }
}
"@
        Remove-Item (Join-Path $work 'result.txt') -ErrorAction SilentlyContinue
        $code = [AC]::Run($sid, @('S-1-15-3-1'), "`"C:\Program Files\PowerShell\7\pwsh.exe`" -NoProfile -ExecutionPolicy Bypass -File $inner", $work, 60000)
        "inner exit: $code"
        Get-Content (Join-Path $work 'result.txt')
        "exemptions listing this sid: $(@(CheckNetIsolation.exe LoopbackExempt -s | Select-String -SimpleMatch $sid).Count)"
    }
    'cleanup' {
        $pidFile = Join-Path $work 'server.pid'
        if (Test-Path $pidFile) { Stop-Process -Id ([int](Get-Content $pidFile)) -Force -ErrorAction SilentlyContinue }
        icacls $work /remove "*$sid" /T /Q 2>$null | Out-Null
        [AC]::DeleteAppContainerProfile($name) | Out-Null
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
        "cleanup done; folder exists: $(Test-Path $work)"
    }
}
