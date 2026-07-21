# Driving a remote Windows host

overseer runs on Linux only. Windows is reached as a **remote target over plain SSH** — no WSL, no
agent installed on the Windows box beyond three PowerShell files staged under `%ProgramData%\overseer`
on demand.

This document records *why* the Windows path looks the way it does. The scripts carry no prose
comments by project rule, and every fact below cost a live debugging round to establish — several of
them are invisible in any API documentation and only surfaced by reading back what the driven agent
actually recorded.

## Prerequisites

On the **Linux controller**: `ssh` and `scp` on `PATH` (plus overseer's usual `jq`/`bash ≥ 4.1`).
Overrides: `OVERSEER_SSH`, `OVERSEER_SSH_OPTS`, `OVERSEER_SCP`.

On the **Windows target**:

| | |
|---|---|
| OpenSSH server | running and reachable; key-based auth recommended |
| SSH identity | must be an **administrator** — registering the interactive scheduled task requires it |
| PowerShell 7 (`pwsh.exe`) | on `PATH`; the broker is hosted by `pwsh`, not `powershell.exe` |
| A logged-in console user | somebody must be signed in at the physical/RDP console (Session 1). Locked is fine, logged off is not — `winshow`/`winbroker` fail with a clear error |
| The agent itself | `claude` / `codex` installed **for the console user**, authenticated in *their* PowerShell profile (see [Host environment](#host-environment)) |

The SSH admin and the console user may be different accounts; that is the topology `%ProgramData%`
staging exists to serve.

## Security model

- **Everything runs as the console user, on their visible desktop.** `winbroker`, `winkeys`, `winsh`,
  `winchat` and `winstop` execute real commands on somebody's live machine, with their credentials, in
  a window they are looking at. Treat every one of them the way you would treat `sh` on the user's own
  box: never run one unless the user explicitly asked for it.
- **The trust boundary is the named pipe.** The pipe name is a random GUID and the broker requires an
  `AUTH <token>` handshake (256 random bits) before any verb. Both live in a per-broker JSON descriptor
  at `%ProgramData%\overseer\brokers\<broker>.json`, ACL'd to Administrators, SYSTEM and the console
  user only. A local process that cannot read that file cannot drive the broker.
- **Anyone who *can* read the descriptor gets full control** of the hosted agent — that is by design
  (it is the same set of principals who could already attach to the console). The pipe is not a
  security boundary against a local administrator.
- **The token never crosses the wire in the clear beyond ssh**, is never logged by the broker, and is
  never printed by any overseer command.
- `winstop` removes the descriptor and kills the child's whole descendant tree leaf-first, so a stopped
  broker leaves no live orphan and no reusable credential behind.

## The shape

```
Linux                         │ Windows host
overseer winchat host/name ── ssh ──▶ win-client.ps1  (Session 0, one-shot per turn)
                                          │ reads %ProgramData%\overseer\brokers\<broker>.json
                                          │ named pipe \\.\pipe\overseer-<guid>, after AUTH <token>
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
| `capture-pane` | `SNAP` / `SNAPALL` | `ReadConsoleOutputCharacter` |
| `send-keys C-u` | `CLEAR` | `WriteConsoleInput`, verified against the grid |
| — | `STAT` / `INFO` | transcript path, size, mtime, liveness |

`SNAP` reads the visible window; `SNAPALL` reads the whole screen buffer, which the broker grows to
9999 rows at startup. Without that, the buffer is only as tall as the window and `winsh` output longer
than a screenful **destroys** its opening sentinel rather than scrolling it — reported as a false
timeout.

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
  caller hangs to timeout. `_awaiting_text` therefore takes the accepted glyph set as an argument:
  `_win_awaiting` passes `❯›>`, and the Linux `_awaiting` keeps the strict `❯›`. Sharing one loose set
  was a bug — on Linux a reply containing a markdown blockquote of a numbered list (`> 1. …`) read as a
  menu and ended the wait early. Both paths additionally require that **not every** numbered line
  carries the glyph, since a real menu marks only the selected row.
  `tests/fixtures/awaiting-windows-console.txt` is a real capture guarding the positive case;
  `awaiting-none-markdown-quote.txt` and `awaiting-none-numbered-list.txt` guard the negatives.
- `Split-Path -Leaf` returns **empty** for `\\.\pipe\<name>` — PowerShell treats it as a UNC root.
- `[System.Diagnostics.Process]::Start($psi)` can return a *String* in this context, and the child's
  "first descendant" may be `conhost`, not the agent. `Start-Process -PassThru` gives the exact pid.
- **`$pid` is a read-only automatic variable** — assigning it (e.g. as a loop variable) is a runtime
  error the parser will not catch. `tests/win-contracts.ps1` asserts no payload does.
- A `List[int]` returned from a PowerShell function is **unrolled to `Object[]`**, which has no
  `.Reverse()`. `winstop` iterates by descending index instead; killing parent-first took the broker
  down before it reached the agent, orphaning it.
- PowerShell 7 lacks the 8-argument `NamedPipeServerStream` constructor. Use
  `NamedPipeServerStreamAcl::Create` when the type exists and fall back to the constructor otherwise.
- `GetFinalPathNameByHandle` **blocks forever** on a pipe handle. Any handle sweep must filter on
  `GetFileType == FileTypeDisk` first — which is why transcript ownership is now claimed through the
  descriptor rather than discovered by sweeping handles.
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

Multiple brokers coexist on one host, addressed as `<host>/<name>` (descriptor
`overseer-broker-<name>.json`; the bare `<host>` form is `overseer-broker.json`). `winlist` enumerates
**descriptors**, not `\\.\pipe\` entries — the pipe names are random. Every box-mutating command takes
a per-broker `flock` on the Linux side, acquired *before* it reads `STAT`, so two overseer invocations
cannot interleave keystrokes into the same console or act on a stale busy-check.

Two brokers of the same kind would otherwise fight over the same transcript, so each **claims** one:
Claude resolves its session id from a descendant-owned `sessions\<pid>.json` (no newest-file fallback),
and Codex records the `rollout-*.jsonl` it took in its descriptor so a sibling broker skips it. This is
why the descriptor ACL grants the console user **`Modify`** and not `ReadAndExecute` — with read-only
rights neither broker can record its claim and both attach to the same rollout.

## Verification rule

CI covers the Windows payloads two ways: a `windows-latest` job parses every `win-*.ps1` with
`System.Management.Automation.Language.Parser` (it caught two real defects on its first run that every
prior check had passed), and `tests/win-contracts.ps1` asserts the invariants above — the AUTH
handshake, the pipe constructor fallback, exclusive rollout claiming, no workdir interpolation, no
assignment to `$pid`.

That is still not enough. Anything touching delivery, key encoding, or transcript resolution must also
be verified by driving a real Windows host **and reading back what the agent recorded** with `winread`,
not by looking at the screen — the v0.9.0 regression rendered plausibly and was wrong.
