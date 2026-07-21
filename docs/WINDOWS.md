# Driving a remote Windows host

overseer runs on Linux only. Windows is reached as a **remote target over plain SSH** — no WSL, no
agent installed on the Windows box beyond three PowerShell files copied to `%USERPROFILE%` on demand.

This document records *why* the Windows path looks the way it does. The scripts carry no prose
comments by project rule, and every fact below cost a live debugging round to establish — several of
them are invisible in any API documentation and only surfaced by reading back what the driven agent
actually recorded.

## The shape

```
Linux                         │ Windows host
overseer winchat host/name ── ssh ──▶ win-client.ps1  (Session 0, one-shot per turn)
                                          │ named pipe \\.\pipe\overseer-broker[-name]
                                          ▼
                                      win-broker.ps1  (Session 1, VISIBLE on the desktop)
                                          │ shares its console with
                                          ▼
                                      pwsh / claude / codex
```

The broker is the Windows analogue of a tmux pane: it owns a console, a child TUI shares that console,
and the pipe protocol exposes the same two primitives tmux gives us on Linux.

| tmux (Linux) | broker verb (Windows) | Win32 call |
|---|---|---|
| `send-keys` | `TYPE` / `PASTE` / `KEY` | `WriteConsoleInput` |
| `capture-pane` | `SNAP` | `ReadConsoleOutputCharacter` |
| — | `STAT` / `INFO` | transcript path, size, mtime, liveness |

`ReadConsoleOutputCharacter` returns the **already-rendered character grid**, so `winpeek` and the
awaiting-prompt detector work with no VT emulator on either side. That is the reason this approach was
chosen over a ConPTY relay.

**Turn detection never moved.** The Windows agent writes the same transcript JSON as on Linux, so
`STAT` reports its path/size/mtime, the file is fetched only when that signature changes, and the
existing `_h_turn_count` / `_h_is_busy` / `_h_last_reply` bash+jq readers decide when the turn ended.
One harness seam, no PowerShell turn logic to keep in sync.

## Session 0 vs Session 1

SSH lands in **Session 0**, which is a service session with no visible desktop. The logged-on user's
desktop is **Session 1**. A process started directly from SSH runs invisibly and cannot share a console
with anything the user can see.

The bridge is a Task Scheduler task registered with an **Interactive** principal for the console user,
started, then immediately unregistered — the launched process keeps running:

```powershell
New-ScheduledTaskPrincipal -UserId $consoleUser -LogonType Interactive
New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                             -ExecutionTimeLimit ([TimeSpan]::Zero)
```

Both settings flags are load-bearing:

- **On battery**, a default task silently sits at `Status: Queued` with `Last Result: 0` and spawns
  nothing. There is no error anywhere — this cost several debugging rounds. Check power state with
  `(Get-CimInstance Win32_Battery).BatteryStatus` (1 = battery, 2 = AC).
- Without `ExecutionTimeLimit 0`, the task manager eventually kills a long-lived broker.

Cross-session consequences worth knowing:

- A **named pipe is machine-wide**, which is why a Session-0 client can talk to a Session-1 server
  (verified `client_sid=0 ↔ server_sid=1`). This is the only part of the design that crosses the
  boundary, and it does so by construction rather than by privilege.
- `MainWindowHandle` is **0 for every process** when queried from Session 0, so window-handle detection
  is useless cross-session. `winshow` reports success by observing a new process in the console session
  instead.
- `wt.exe` is an app-execution-alias stub; launching it directly exits without activating anything.
  Packaged apps must be started by AUMID via
  `explorer.exe shell:AppsFolder\Microsoft.WindowsTerminal_8wekyb3d8bbwe!App`.

## Console input: what `WriteConsoleInput` will and will not deliver

These were established by driving a real agent and then reading back its transcript — the screen alone
is not evidence, because a mangled prompt can still *look* plausible in the grid.

- **A raw `ESC` byte is never delivered to the child.** Bracketed paste (`ESC[200~` … `ESC[201~`) is
  therefore impossible: the agent receives the literal text `[200~`. v0.9.0 shipped with exactly this
  bug and passed CI — only `winread` exposed it.
- **A `\r`/`\n` char event with `wVirtualKeyCode = 0` is swallowed.** Newlines vanish and every line of
  a multi-line prompt runs together into one.
- **`Ctrl+J` (`vk=0x4A, uc=0x0A, ctrl=0x0008`) is what actually inserts a composer line break** — in
  both Claude Code and Codex. This is the mechanism `PASTE` uses for every newline.
- **The input box must be cleared first** (`Ctrl+U`, `vk=0x55, uc=0x15, ctrl=0x0008`), or leftover text
  is prepended to the prompt and the agent answers a question nobody asked.
- Large bursts must be **chunked** (256 records with a short pause between) or records are dropped.

## Rendering and parsing quirks

- On a Windows console, **Claude Code draws the selection cursor as ASCII `>`**, not `❯`. A screen
  parser keyed only on `❯`/`›` silently never matches, so an interactive prompt is invisible and the
  caller hangs to timeout. `_awaiting_text` accepts all three; `tests/fixtures/awaiting-windows-console.txt`
  is a real capture guarding this.
- `Split-Path -Leaf` returns **empty** for `\\.\pipe\<name>` — PowerShell treats it as a UNC root. Pipe
  enumeration cuts the string manually.
- `[System.Diagnostics.Process]::Start($psi)` can return a *String* in this context; get the child PID
  from `Win32_Process` by `ParentProcessId` instead of trusting the return value.
- Pipe I/O must be **synchronous** `ReadLine`/`WriteLine` with default options. Adding
  `PipeOptions.Asynchronous` + `ReadLineAsync` deadlocks both ends.
- Box-drawing characters mangle over SSH → bash unless UTF-8 is forced on both ends.

## Host environment

The child is launched through a **profile-loading** `pwsh` (`pwsh -NoLogo -Command claude`), never
`-NoProfile`. A user's API configuration commonly lives in the PowerShell profile rather than in
environment variables or any settings file; launching without the profile makes the agent fall back to
its default auth and reply `Not logged in`. If an agent authenticates in the user's own terminal but
not under the broker, the profile is the first thing to check.

## Concurrency

Multiple brokers coexist on one host, addressed as `<host>/<name>` (pipe `overseer-broker-<name>`; the
bare `<host>` form is the default pipe). `winlist` enumerates them. Every box-mutating command takes a
per-broker `flock` on the Linux side so two overseer invocations cannot interleave keystrokes into the
same console.

## Verification rule

CI and shellcheck cannot see any of the above — the v0.9.0 regression proves it. Anything touching
delivery, key encoding, or transcript resolution must be verified by driving a real Windows host **and
reading back what the agent recorded** with `winread`, not by looking at the screen.
