param(
  [string]$Pipe = 'overseer-broker',
  [string]$Which = 'pwsh',
  [string]$WorkDir = ''
)
$ErrorActionPreference = 'Stop'

switch ($Which) {
  'pwsh'   { $child = 'pwsh.exe'; $cargs = '-NoProfile -NoLogo'; $kind = 'shell' }
  'claude' { $g = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1; $child = if ($g) { $g.Source } else { 'claude' }; $cargs = ''; $kind = 'claude' }
  'codex'  { $child = 'pwsh.exe'; $cargs = '-NoLogo -NoProfile -Command codex'; $kind = 'codex' }
  default  { "ERR unknown child '$Which' (use pwsh|claude|codex)"; exit 2 }
}

$brk = Join-Path $env:USERPROFILE 'overseer-win-broker.ps1'
if (-not (Test-Path -LiteralPath $brk)) { "ERR broker payload not found at $brk"; exit 2 }
$cu = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not $cu) { 'ERR no interactive console user (screen locked or logged off)'; exit 2 }

Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'overseer-win-broker' } | ForEach-Object {
  Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $_.ProcessId) | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}

$argline = "-NoProfile -ExecutionPolicy Bypass -File `"$brk`" -Pipe $Pipe -Child `"$child`" -ChildArgs `"$cargs`" -Kind $kind -WorkDir `"$WorkDir`""
$act = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument $argline
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
$prin = New-ScheduledTaskPrincipal -UserId $cu -LogonType Interactive -RunLevel Limited
$task = 'overseer-broker'
try {
  Register-ScheduledTask -TaskName $task -Action $act -Settings $set -Principal $prin -Force | Out-Null
  Start-ScheduledTask -TaskName $task
} finally {
  Start-Sleep -Milliseconds 1500
  Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
}

$ok = $false
for ($t = 0; $t -lt 40; $t++) {
  Start-Sleep -Milliseconds 500
  try { if ([System.IO.Directory]::GetFileSystemEntries('\\.\pipe\') -match ('\\' + $Pipe + '$')) { $ok = $true; break } } catch {}
}
if ($ok) { "OK broker ready pipe=$Pipe child=$Which kind=$kind" } else { 'ERR broker pipe not up after 20s' }
