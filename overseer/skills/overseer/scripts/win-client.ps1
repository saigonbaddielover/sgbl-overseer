param(
  [Parameter(Mandatory = $true)][string]$Op,
  [string]$Pipe = 'overseer-broker',
  [string]$B64 = '',
  [string]$Name = '',
  [string]$T1 = '',
  [string]$T2 = '',
  [int]$TimeoutSec = 30
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Connect-Pipe($name) {
  for ($i = 0; $i -lt 8; $i++) {
    $c = New-Object System.IO.Pipes.NamedPipeClientStream('.', $name, [System.IO.Pipes.PipeDirection]::InOut)
    try { $c.Connect(3000); return $c } catch { try { $c.Dispose() } catch {}; Start-Sleep -Milliseconds 700 }
  }
  return $null
}
function Read-Frame($reader) {
  $head = $reader.ReadLine()
  $lines = New-Object System.Collections.Generic.List[string]
  if ($head -ne '<<<SNAP') { return $lines }
  while ($true) { $x = $reader.ReadLine(); if ($null -eq $x -or $x -eq '>>>SNAP') { break }; $lines.Add($x) }
  return $lines
}

$cli = Connect-Pipe $Pipe
if (-not $cli) { 'ERR connect failed'; exit 3 }
$r = New-Object System.IO.StreamReader($cli)
$w = New-Object System.IO.StreamWriter($cli); $w.AutoFlush = $true

switch ($Op) {
  'info' {
    $w.WriteLine('INFO'); $r.ReadLine()
  }
  'snap' {
    $w.WriteLine('SNAP'); (Read-Frame $r) | ForEach-Object { $_ }
  }
  'type' {
    $w.WriteLine("TYPE $B64"); $r.ReadLine()
  }
  'key' {
    $w.WriteLine("KEY $Name"); $r.ReadLine()
  }
  'quit' {
    $w.WriteLine('QUIT'); 'OK quit'
  }
  'sh' {
    $w.WriteLine("TYPE $B64"); $null = $r.ReadLine()
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $found = $false
    $lastGrid = @()
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Milliseconds 400
      $w.WriteLine('SNAP')
      $lines = Read-Frame $r
      if ($lines.Count -eq 0) { continue }
      $lastGrid = $lines
      $i2 = -1
      for ($k = 0; $k -lt $lines.Count; $k++) { if ($lines[$k].Trim().StartsWith($T2 + ':')) { $i2 = $k } }
      if ($i2 -ge 0) {
        $i1 = -1
        for ($k = $i2 - 1; $k -ge 0; $k--) { if ($lines[$k].Trim() -eq $T1) { $i1 = $k; break } }
        if ($i1 -ge 0) {
          $rc = $lines[$i2].Trim().Substring($T2.Length + 1)
          '<<<OUT'
          for ($k = $i1 + 1; $k -lt $i2; $k++) { $lines[$k].TrimEnd() }
          '>>>OUT'
          "EXIT $rc"
          $found = $true
          break
        }
      }
    }
    if (-not $found) { 'ERR sh timeout'; $lastGrid | Where-Object { $_.Trim() -ne '' } | ForEach-Object { '| ' + $_ } }
  }
  default { "ERR unknown op $Op" }
}
try { $w.WriteLine('BYE') } catch {}
try { $cli.Dispose() } catch {}
