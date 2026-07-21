param(
  [string]$Pipe = 'overseer-broker',
  [string]$Which = 'pwsh',
  [string]$WorkDir = ''
)
$ErrorActionPreference = 'Stop'

switch ($Which) {
  'pwsh'   { $child = 'pwsh.exe'; $cargs = '-NoLogo'; $kind = 'shell' }
  'claude' { $child = 'pwsh.exe'; $cargs = '-NoLogo -Command claude'; $kind = 'claude' }
  'codex'  { $child = 'pwsh.exe'; $cargs = '-NoLogo -Command codex'; $kind = 'codex' }
  default  { "ERR unknown child '$Which' (use pwsh|claude|codex)"; exit 2 }
}

$brk = Join-Path $env:USERPROFILE 'overseer-win-broker.ps1'
if (-not (Test-Path -LiteralPath $brk)) { "ERR broker payload not found at $brk"; exit 2 }
$cu = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not $cu) { 'ERR no interactive console user (screen locked or logged off)'; exit 2 }

$all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, ParentProcessId, Name, CommandLine)
$pipePat = '-Pipe\s+' + [regex]::Escape($Pipe) + '(\s|$)'
$stale = @($all | Where-Object { $_.Name -eq 'pwsh.exe' -and $_.CommandLine -match 'overseer-win-broker' -and $_.CommandLine -match $pipePat })
foreach ($b in $stale) {
  $tree = New-Object System.Collections.Generic.List[int]
  $q = New-Object System.Collections.Generic.Queue[int]
  $q.Enqueue([int]$b.ProcessId)
  while ($q.Count -gt 0) {
    $p = $q.Dequeue()
    $tree.Add($p)
    foreach ($c in ($all | Where-Object { [int]$_.ParentProcessId -eq $p })) { $q.Enqueue([int]$c.ProcessId) }
  }
  $tree.Reverse()
  foreach ($p in $tree) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
}

$argline = "-NoProfile -ExecutionPolicy Bypass -File `"$brk`" -Pipe $Pipe -Child `"$child`" -ChildArgs `"$cargs`" -Kind $kind -WorkDir `"$WorkDir`""
$act = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument $argline
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
$prin = New-ScheduledTaskPrincipal -UserId $cu -LogonType Interactive -RunLevel Limited
$task = $Pipe
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
