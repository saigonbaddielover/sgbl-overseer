param(
  [string]$Child = 'pwsh.exe',
  [string]$ChildArgs = '-NoProfile -NoLogo',
  [string]$Pipe = 'overseer-broker',
  [string]$Kind = 'shell',
  [string]$WorkDir = ''
)
$ErrorActionPreference = 'Stop'
$logf = Join-Path $env:TEMP "overseer-broker-$Pipe.log"
function Log($m) { try { Add-Content -LiteralPath $logf -Value ((Get-Date).ToString('HH:mm:ss.fff') + ' ' + $m) } catch {} }
Set-Content -LiteralPath $logf -Value ((Get-Date).ToString('HH:mm:ss.fff') + " START pipe=$Pipe kind=$Kind") -Encoding UTF8

function Resolve-StartDir {
  $p = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
  if (Test-Path -LiteralPath $p) {
    try {
      $j = Get-Content -Raw -LiteralPath $p | ConvertFrom-Json
      $prof = $j.profiles.list | Where-Object { $_.guid -eq $j.defaultProfile } | Select-Object -First 1
      $sd = $prof.startingDirectory
      if (-not $sd) { $sd = $j.profiles.defaults.startingDirectory }
      if ($sd) { return [Environment]::ExpandEnvironmentVariables($sd) }
    } catch {}
  }
  return $env:USERPROFILE
}

function Get-DescendantPids($root) {
  $out = New-Object System.Collections.Generic.List[int]
  if (-not $root) { return $out }
  $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, ParentProcessId)
  $q = New-Object System.Collections.Generic.Queue[int]
  $out.Add([int]$root); $q.Enqueue([int]$root)
  while ($q.Count -gt 0) {
    $p = $q.Dequeue()
    foreach ($c in ($all | Where-Object { [int]$_.ParentProcessId -eq $p })) {
      $cp = [int]$c.ProcessId
      if (-not $out.Contains($cp)) { $out.Add($cp); $q.Enqueue($cp) }
    }
  }
  return $out
}

function Resolve-Transcript {
  if ($script:txCache -and (Test-Path -LiteralPath $script:txCache)) { return ($script:txCache -replace '\\', '/') }
  $found = ''
  try {
    if ($Kind -eq 'codex') {
      $d = Join-Path $env:USERPROFILE '.codex\sessions'
      $f = Get-ChildItem -Path $d -Recurse -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $script:childStart } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
      if ($f) { $found = $f.FullName }
    } elseif ($Kind -eq 'claude') {
      $ch = if ($env:CLAUDE_HOME) { $env:CLAUDE_HOME } else { Join-Path $env:USERPROFILE '.claude' }
      $sid = ''
      foreach ($p in (Get-DescendantPids $script:childPid)) {
        $sf = Join-Path $ch "sessions\$p.json"
        if (Test-Path -LiteralPath $sf) {
          try { $sid = (Get-Content -Raw -LiteralPath $sf | ConvertFrom-Json).sessionId } catch {}
          if ($sid) { break }
        }
      }
      $pd = Join-Path $ch 'projects'
      if ($sid) {
        $f = Get-ChildItem -Path $pd -Recurse -Filter "$sid*.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { $found = $f.FullName }
      }
      if (-not $found) {
        $f = Get-ChildItem -Path $pd -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue |
          Where-Object { $_.LastWriteTime -ge $script:childStart } |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($f) { $found = $f.FullName }
      }
    }
  } catch {}
  if ($found) { $script:txCache = $found; return ($found -replace '\\', '/') }
  return ''
}

$src = @'
using System;
using System.Text;
using System.Threading;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class ConIO {
    [StructLayout(LayoutKind.Sequential)]
    public struct COORD { public short X; public short Y; public COORD(short x, short y){X=x;Y=y;} }
    [StructLayout(LayoutKind.Sequential)]
    public struct SMALL_RECT { public short Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct CONSOLE_SCREEN_BUFFER_INFO {
        public COORD dwSize; public COORD dwCursorPosition; public ushort wAttributes;
        public SMALL_RECT srWindow; public COORD dwMaximumWindowSize;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEY_EVENT_RECORD {
        public int bKeyDown; public ushort wRepeatCount; public ushort wVirtualKeyCode;
        public ushort wVirtualScanCode; public ushort UnicodeChar; public uint dwControlKeyState;
    }
    [StructLayout(LayoutKind.Explicit)]
    public struct INPUT_RECORD {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
    }
    const int STD_INPUT_HANDLE = -10;
    const int STD_OUTPUT_HANDLE = -11;
    const ushort KEY_EVENT = 1;

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool WriteConsoleInput(IntPtr h, INPUT_RECORD[] b, uint len, out uint written);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool ReadConsoleOutputCharacter(IntPtr h, StringBuilder b, uint len, COORD c, out uint read);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CONSOLE_SCREEN_BUFFER_INFO i);

    static INPUT_RECORD Rec(ushort vk, char c, uint ctrl, bool down) {
        var k = new KEY_EVENT_RECORD();
        k.bKeyDown = down ? 1 : 0; k.wRepeatCount = 1; k.wVirtualKeyCode = vk;
        k.wVirtualScanCode = 0; k.UnicodeChar = (ushort)c; k.dwControlKeyState = ctrl;
        var r = new INPUT_RECORD(); r.EventType = KEY_EVENT; r.KeyEvent = k; return r;
    }
    static uint Emit(List<INPUT_RECORD> recs) {
        IntPtr h = GetStdHandle(STD_INPUT_HANDLE);
        if (recs.Count == 0) return 0;
        uint total = 0;
        const int CHUNK = 256;
        for (int off = 0; off < recs.Count; off += CHUNK) {
            int n = Math.Min(CHUNK, recs.Count - off);
            var arr = recs.GetRange(off, n).ToArray();
            uint w;
            WriteConsoleInput(h, arr, (uint)arr.Length, out w);
            total += w;
            if (off + n < recs.Count) Thread.Sleep(4);
        }
        return total;
    }
    public static uint TypeText(string s) {
        var recs = new List<INPUT_RECORD>();
        foreach (char c in s) {
            ushort vk = (c == '\r' || c == '\n') ? (ushort)0x0D : (ushort)0;
            char uc = (c == '\n') ? '\r' : c;
            recs.Add(Rec(vk, uc, 0, true)); recs.Add(Rec(vk, uc, 0, false));
        }
        return Emit(recs);
    }
    public static uint Paste(string s) {
        string body = s.Replace("\r\n", "\n").Replace("\r", "\n");
        var recs = new List<INPUT_RECORD>();
        for (int k = 0; k < 8; k++) {
            recs.Add(Rec(0x55, (char)0x15, 0x0008, true)); recs.Add(Rec(0x55, (char)0x15, 0x0008, false));
        }
        foreach (char c in body) {
            if (c == '\n') {
                recs.Add(Rec(0x4A, '\n', 0x0008, true)); recs.Add(Rec(0x4A, '\n', 0x0008, false));
            } else {
                recs.Add(Rec(0, c, 0, true)); recs.Add(Rec(0, c, 0, false));
            }
        }
        return Emit(recs);
    }
    public static uint SendKey(ushort vk, char uc, uint ctrl) {
        IntPtr h = GetStdHandle(STD_INPUT_HANDLE);
        var arr = new INPUT_RECORD[] { Rec(vk, uc, ctrl, true), Rec(vk, uc, ctrl, false) };
        uint w; WriteConsoleInput(h, arr, 2, out w); return w;
    }
    public static string Snapshot() {
        IntPtr h = GetStdHandle(STD_OUTPUT_HANDLE);
        CONSOLE_SCREEN_BUFFER_INFO i;
        if (!GetConsoleScreenBufferInfo(h, out i)) return "";
        int left = i.srWindow.Left, top = i.srWindow.Top, right = i.srWindow.Right, bottom = i.srWindow.Bottom;
        int width = right - left + 1;
        var sb = new StringBuilder();
        for (int y = top; y <= bottom; y++) {
            var line = new StringBuilder(width);
            uint read;
            ReadConsoleOutputCharacter(h, line, (uint)width, new COORD((short)left, (short)y), out read);
            sb.AppendLine(line.ToString(0, (int)read).TrimEnd());
        }
        return sb.ToString();
    }
}
'@
Add-Type -TypeDefinition $src -Language CSharp

$keymap = @{
  'Enter' = @(0x0D, "`r", 0); 'Escape' = @(0x1B, [char]0x1B, 0); 'Tab' = @(0x09, "`t", 0)
  'Backspace' = @(0x08, [char]0x08, 0); 'Space' = @(0x20, ' ', 0); 'Delete' = @(0x2E, [char]0, 0)
  'Up' = @(0x26, [char]0, 0); 'Down' = @(0x28, [char]0, 0); 'Left' = @(0x25, [char]0, 0); 'Right' = @(0x27, [char]0, 0)
  'Home' = @(0x24, [char]0, 0); 'End' = @(0x23, [char]0, 0); 'PageUp' = @(0x21, [char]0, 0); 'PageDown' = @(0x22, [char]0, 0)
}
function Send-Named($name) {
  if ($name -match '^[Cc]-([a-zA-Z])$') {
    $ch = $Matches[1].ToUpper()[0]
    return [ConIO]::SendKey([ushort][int]$ch, [char]([int]$ch - 64), 0x0008)
  }
  if ($keymap.ContainsKey($name)) {
    $m = $keymap[$name]
    return [ConIO]::SendKey([ushort]$m[0], [char]$m[1], [uint32]$m[2])
  }
  return -1
}

$myPid = $PID
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $Child
$psi.Arguments = $ChildArgs
$psi.UseShellExecute = $false
$wd = if ($WorkDir) { $WorkDir } else { Resolve-StartDir }
if (-not (Test-Path -LiteralPath $wd)) { $wd = $env:USERPROFILE }
$psi.WorkingDirectory = $wd
$script:txCache = ''
$script:agentPid = 0
$script:agentSeen = $false
$script:childStart = (Get-Date).AddSeconds(-5)
$null = [System.Diagnostics.Process]::Start($psi)
Start-Sleep -Milliseconds 1200
$childPid = (Get-CimInstance Win32_Process -Filter "ParentProcessId=$myPid" | Select-Object -First 1).ProcessId
$script:childPid = $childPid
Log "child exe=$Child kind=$Kind workdir=$wd childPid=$childPid"
function Get-AgentPid {
  if ($Kind -eq 'shell') { return 0 }
  if ($script:agentPid -and (Get-Process -Id $script:agentPid -ErrorAction SilentlyContinue)) { return $script:agentPid }
  $script:agentPid = 0
  foreach ($p in (Get-DescendantPids $script:childPid)) {
    if ($p -eq $script:childPid) { continue }
    $pr = Get-Process -Id $p -ErrorAction SilentlyContinue
    if ($pr -and $pr.ProcessName -match '^(claude|codex|node)$') { $script:agentPid = $p; $script:agentSeen = $true; break }
  }
  return $script:agentPid
}
function ChildAlive {
  if (-not $childPid) { return $true }
  if ($Kind -ne 'shell') {
    if (Get-AgentPid) { return $true }
    if ($script:agentSeen) { return $false }
  }
  $null -ne (Get-Process -Id $childPid -ErrorAction SilentlyContinue)
}

$done = $false
while (-not $done) {
  if (-not (ChildAlive)) { Log 'child exited'; break }
  $srv = New-Object System.IO.Pipes.NamedPipeServerStream($Pipe, [System.IO.Pipes.PipeDirection]::InOut)
  $srv.WaitForConnection()
  $r = New-Object System.IO.StreamReader($srv)
  $w = New-Object System.IO.StreamWriter($srv); $w.AutoFlush = $true
  try {
    $client = $true
    while ($client -and $srv.IsConnected) {
      $line = $r.ReadLine()
      if ($null -eq $line) { break }
      $sp = $line.IndexOf(' ')
      if ($sp -lt 0) { $verb = $line; $arg = '' } else { $verb = $line.Substring(0, $sp); $arg = $line.Substring($sp + 1) }
      if ($verb -eq 'TYPE') {
        try { $n = [ConIO]::TypeText([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($arg))); $w.WriteLine("OK $n") }
        catch { $w.WriteLine("ERR type $($_.Exception.Message)") }
      } elseif ($verb -eq 'PASTE') {
        try { $n = [ConIO]::Paste([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($arg))); $w.WriteLine("OK $n") }
        catch { $w.WriteLine("ERR paste $($_.Exception.Message)") }
      } elseif ($verb -eq 'KEY') {
        $n = Send-Named $arg
        if ($n -ge 0) { $w.WriteLine("OK $n") } else { $w.WriteLine("ERR unknown key $arg") }
      } elseif ($verb -eq 'SNAP') {
        $w.WriteLine('<<<SNAP'); $w.Write([ConIO]::Snapshot()); $w.WriteLine('>>>SNAP')
      } elseif ($verb -eq 'INFO') {
        $w.WriteLine("kind=$Kind workdir=$wd childPid=$childPid alive=$(ChildAlive) transcript=$(Resolve-Transcript)")
      } elseif ($verb -eq 'STAT') {
        $tx = Resolve-Transcript
        $sz = -1; $mt = 0
        if ($tx) {
          try {
            $fi = Get-Item -LiteralPath ($tx -replace '/', '\') -ErrorAction SilentlyContinue
            if ($fi) { $sz = $fi.Length; $mt = ([DateTimeOffset]$fi.LastWriteTimeUtc).ToUnixTimeSeconds() }
          } catch {}
        }
        $w.WriteLine("kind=$Kind alive=$(ChildAlive) size=$sz mtime=$mt transcript=$tx")
      } elseif ($verb -eq 'PING') {
        $w.WriteLine("PONG alive=$(ChildAlive)")
      } elseif ($verb -eq 'BYE') {
        $client = $false
      } elseif ($verb -eq 'QUIT') {
        $client = $false; $done = $true
      } else {
        $w.WriteLine("ERR unknown $verb")
      }
    }
  } catch {
    Log "loop ERR $($_.Exception.Message)"
  } finally {
    try { $srv.Dispose() } catch {}
  }
}
Log 'broker exiting'
try { if ($childPid) { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue } } catch {}
