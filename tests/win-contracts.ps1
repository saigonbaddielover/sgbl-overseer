$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$scripts = Join-Path (Split-Path -Parent $here) 'overseer/skills/overseer/scripts'
$fail = 0
function Check($name, $expected, $actual) {
  if ($expected -eq $actual) { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n         expected: [$expected]`n         actual:   [$actual]"; $script:fail++ }
}

$broker = Get-Content -Raw (Join-Path $scripts 'win-broker.ps1')
$client = Get-Content -Raw (Join-Path $scripts 'win-client.ps1')
$launch = Get-Content -Raw (Join-Path $scripts 'win-launch.ps1')

Check 'broker requires an AUTH handshake' $true ($broker -match '\$auth -ne "AUTH \$Token"')
Check 'broker builds an explicit pipe ACL' $true ($broker -match 'PipeAccessRule')
Check 'broker pipe ctor works on PowerShell 5 and 7' $true (($broker -match 'NamedPipeServerStreamAcl') -and ($broker -match 'New-Object -TypeName System\.IO\.Pipes\.NamedPipeServerStream -ArgumentList'))
Check 'broker kills the whole child tree' $true ($broker -match 'Stop-Descendants \$childPid')
Check 'broker claims a codex rollout exclusively' $true ($broker -match 'Get-ClaimedTranscripts')
Check 'broker has no newest-mtime claude fallback' $false ($broker -match "Filter '\*\.jsonl'")
Check 'broker exposes scrollback for winsh' $true ($broker -match "verb -eq 'SNAPALL'")
Check 'broker exposes a clear verb' $true ($broker -match "verb -eq 'CLEAR'")

Check 'client authenticates before any verb' $true ($client -match 'AUTH \$\(\$config\.Token\)')
Check 'client fails nonzero on error' $true ($client -match 'exit 3')
Check 'client rejects a malformed frame' $true ($client -match 'malformed snapshot frame')
Check 'client reads brokers from ProgramData' $true ($client -match 'overseer.brokers')
Check 'client validates the broker name' $true ($client -match 'overseer-broker\(\?:-\[0-9A-Za-z_-\]\+\)\?\$')
Check 'client reads scrollback for sh' $true ($client -match "WriteLine\('SNAPALL'\)")

Check 'launcher takes workdir as base64 data' $true ($launch -match '\$WorkDirB64')
Check 'launcher never interpolates workdir into a command' $false ($launch -match '-WorkDir "\$')
Check 'launcher mints a random pipe name' $true ($launch -match "Guid\]::NewGuid")
Check 'launcher mints a capability token' $true ($launch -match 'RandomNumberGenerator')
Check 'launcher restricts the descriptor ACL' $true ($launch -match 'Set-ConfigAcl')
Check 'launcher exits nonzero when the pipe never appears' $true ($launch -match "'ERR broker pipe not up after 20s'; exit 3")
Check 'launcher schedules a pwsh host' $true ($launch -match "New-ScheduledTaskAction -Execute 'pwsh\.exe'")
Check 'broker logs terminating errors' $true ($broker -match 'trap \{ Log "FATAL')

Check 'no payload assigns the read-only $pid automatic' $false (($broker + $client + $launch) -match '(foreach|for)\s*\(\s*\$pid\b')

if ($fail -eq 0) { Write-Host 'PASS: windows payload contracts'; exit 0 }
Write-Host "FAIL: $fail contract check(s) failed"; exit 1
