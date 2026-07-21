# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and versions follow [SemVer](https://semver.org/).

## [Unreleased]

## [0.13.1] - 2026-07-21

### Documentation
- **Corrected two false claims in `README.md`.** The intro said overseer *"opens (or attaches) a tmux
  pane, launches an agent harness in its shell"* — it does neither: on Linux it only discovers and
  drives a pane somebody else already started (the sole `tmux new-session` in the tree is `doctor
  --live`'s throwaway self-test), and `winbroker` is the one command that starts a child, because a
  Windows host has no pane to find. The troubleshooting section also quoted an error string,
  `"no claude pane for target"`, that no longer exists — it became
  `"no agent pane (claude/codex) for target"` when Codex support landed.
- **`SKILL.md` no longer claims `CLAUDE_HOME`/`CODEX_HOME` are validated at startup.** Only
  `OVERSEER_TIMEOUT` and `OVERSEER_POLL_INTERVAL` are; the home paths are plain `${VAR:-default}`
  substitutions.
- **`OVERSEER_REMOTE_DIR` is documented** in README and `SKILL.md`, with the constraint that it and
  `OVERSEER_REMOTE_BIN` must be changed together — `deploy` writes to one and `on` executes the other,
  so setting just one silently breaks every remote command.
- **`CONTRIBUTING.md` describes CI job-by-job in a table.** The prose omitted the `windows flow tests`
  step entirely and said the Windows job runs `tests/win-payloads.sh`, when it runs `win-parse.ps1` and
  `win-contracts.ps1` natively.
- **Brittle counts removed rather than corrected** — `tests/win-flow.sh`'s assertion count, an older
  entry's `win-contracts.ps1` count, and `docs/DECISIONS.md`'s `SKILL.md` size. All three had already
  rotted, the same way a line count in the 0.10.1 notes did; the numbers carried no information a
  reader could act on.
- **GitHub repository metadata refreshed** (About, topics) plus the manifest keywords, which still
  described a Claude-only, tmux-only tool.
- **`docs/WINDOWS.md`** records that Claude's console composer gutter is `>` + U+00A0 while Codex's is
  `›` + a plain space — verified live by dumping the raw grid bytes of both. That difference is why the
  U+00A0 delivery bug hit Claude only.

### Added
- **`tests/win-parse.ps1`** — the payload parse check, lifted out of the workflow's inline script so
  CI and a local run execute the same file. It is also stricter than the inline version it replaces:
  it resolves paths from `$PSScriptRoot` instead of the working directory, and it **fails when the
  glob matches nothing** (the inline loop would have reported success if the payloads were ever moved
  or renamed).
- **`tests/win-payloads.sh`** — runs `win-parse.ps1` and `win-contracts.ps1` locally in one command.
  PowerShell runs on Linux, so the Windows payloads are checkable **before** pushing rather than only
  by the `windows-latest` job; `OVERSEER_PWSH` points it at a non-`PATH` install. Exit 1 = a payload
  failed, 2 = no PowerShell found. It is a convenience only — the `windows-latest` job remains the
  gate, and still runs both `.ps1` files natively under `pwsh`. Verified it fails (rc=1) on a
  deliberately broken payload; the last two red CI runs were PowerShell-only defects it catches.

## [0.13.0] - 2026-07-21

### Fixed
- **A single-line `winchat` could never verify its prompt against Claude Code on a Windows console.**
  Claude renders the composer gutter as `>` followed by **U+00A0 NO-BREAK SPACE**, which POSIX
  `[[:space:]]` does not match, so the captured text kept a leading NBSP, the equality check against
  the sent message always failed, and `winchat` aborted with "could not place/verify the prompt" after
  clearing the box. A *multi-line* prompt was unaffected because it verifies through the paste chip
  instead — which is why the bug survived every earlier live test. `_win_snap` now normalizes U+00A0 to
  a plain space as it reads the grid, so delivery verification, the awaiting-prompt detector and
  `winpeek` all see the same text a human does. Found and fixed live; the reply now round-trips.
- **`winstop` can now clean up after a broker that already died.** Stopping went through the pipe, so a
  broker whose console had closed (its child exited) left its descriptor behind: `winstop` reported
  `ERR connect failed`, `winlist` showed `state=offline` forever, and only a manual delete cleared it.
  `quit` now removes the descriptor whether or not the pipe answers, and says which happened.
- **`winstop` exits non-zero when the broker refuses or is missing**, instead of swallowing the `ERR`
  line and reporting success.

### Added
- **`OVERSEER_WIN_CLAUDE` / `OVERSEER_WIN_CODEX`** (defaults `claude` / `codex`) name the command
  `winbroker` launches on a Windows host. The agent's command name is host-specific — a machine whose
  users go through a wrapper (`claudeep`) previously got a broker running the wrong binary, which
  starts, paints, and answers every prompt with `Not logged in`. The value must be a bare command name,
  travels base64-encoded, and is decoded into a parameter rather than interpolated, like `workdir`. The
  broker's `kind` stays `claude`/`codex`, so transcript reading and turn detection are untouched.
- **`tests/win-flow.sh`** — mocks the two remote chokepoints (`_win_client`,
  `_win_fetch`) and run the real `win*` bash orchestration against a recorded call log: the scp-failure
  and mid-turn guards fail closed and never submit, `--force` bypasses each, a `pwsh`/dead-child/Codex-`!`
  target is refused before anything is pasted, a failed submit or unverified delivery clears the box
  after pasting, `mtime:size` gating refetches on an mtime-only change but not on an unchanged
  signature, a child that exits mid-turn fails fast with rc=3, and broker-target parsing rejects
  traversal. Runs in CI with no ssh and no host.

## [0.12.1] - 2026-07-21

### Fixed
- **A markdown blockquote of a numbered list no longer reads as an interactive menu.** v0.10.1 added the
  ASCII `>` cursor for Claude Code on a Windows console to the *shared* `_awaiting_text` parser, so on
  **Linux** an ordinary reply containing

  ```
  > 1. read the file
  > 2. patch it
  ```

  matched the awaiting-prompt detector: `chat`/`wait` returned "awaiting input" and stopped waiting for
  the real turn, and `fleet status` reported the pane as `awaiting`. Two fixes, both covered by
  fixtures: the accepted glyph set is now a parameter — `_win_awaiting` passes `❯›>`, Linux `_awaiting`
  keeps the strict `❯›` — and both paths now require that **not every** numbered line carries the
  glyph, since a real menu marks only the selected row. That second rule also protects the Windows
  path, where `>` legitimately is a cursor.

## [0.12.0] - 2026-07-21

### Fixed
- **`on <host>` no longer requires the remote login shell to be bash.** Argv was serialized with
  `printf %q`, which emits bash-only `$'…'` for anything with a newline, tab, or quote; a `dash`/`ash`
  login shell passed that through literally and the remote overseer received mangled arguments. It is
  now POSIX single-quote quoting, which every POSIX shell parses identically. `stdin` stays free, so
  `on <host> chat %0 -` still reads the prompt body from the pipe.
- **`doctor`'s contract probe handles session paths containing spaces.** The scan word-split `ls`
  output, so a project directory with a space in its name silently probed a nonexistent file and the
  probe reported a false schema shift.
- **`OVERSEER_POLL_INTERVAL` rejects values that are not a positive number.** `.`, `1..2`, `0`, and
  `0.0` all passed validation; the first two made every `sleep` fail and zero spun the poll loop at
  100% CPU. Covered by fixture tests for both the accepted and the rejected forms.
- **`_win_cp` honours `OVERSEER_SSH`**, passing it to `scp -S` so a custom ssh binary applies to the
  transcript fetch as it already did to every other Windows call.

### Changed
- **Release recovery is no longer manual.** If `autotag` finds the version tag already present it now
  checks whether the matching GitHub Release exists and publishes it if not, instead of standing down
  and leaving a tag with no release. `release.yml` (the human-pushed-tag path) first validates that the
  tag version equals both manifests and has a `## [x.y.z]` CHANGELOG heading, and is idempotent.
- **The support model is stated consistently everywhere** — README, `SKILL.md` frontmatter and scope
  section, both manifest descriptions, and the entry-script header: overseer is a **Linux controller**
  driving **local/remote Linux tmux panes** and **remote native Windows console brokers over SSH**;
  local pane discovery stays Linux + tmux only. The skill previously advertised itself as tmux-only, so
  a request to drive a Windows machine could fail to activate it.
- **The Windows walkthroughs show the whole broker lifecycle** (`winbroker` → `winchat`/`winwait`/
  `winread` or `winsh` → `winstop`) rather than only `winshow`, and describe the turn poll as gated on
  the broker's `mtime:size` signature rather than "when it grew".

### Documentation
- **`docs/WINDOWS.md` is the canonical Windows reference**, now covering the v0.11.0 descriptor/auth
  design, a prerequisites table, a security model section, `SNAPALL` and the screen-buffer growth, the
  descriptor-based transcript claiming (and why its ACL must grant `Modify`), and the PowerShell traps
  found live — read-only `$pid`, `List[int]` unrolling, the missing pipe constructor overload,
  `GetFinalPathNameByHandle` blocking on pipes. README and `SKILL.md` link to it.
- **`SECURITY.md` and the skill's safety rules cover the `win*` commands** — remote execution as the
  console user, visible-desktop side effects, the named-pipe trust boundary, and never relaying a
  broker descriptor.
- **CONTRIBUTING is current**: Claude *and* Codex are documented as supported with the real `_h_*`
  seam described, the Windows parser/contract CI job is listed, the comment policy is stated
  (preserve existing ones, add none), and a conditional Windows live-verification checklist is added —
  mirrored in the PR template. The bug template gained a target dropdown and sanitized Windows fields.
- `tests/run.sh` asserts these doc contracts, so the support-model wording, `mtime:size` wording,
  Windows links and live-test checklist cannot silently disappear.

## [0.11.0] - 2026-07-21

### Security
- **The Windows broker pipe is now unguessable and authenticated.** It was named `overseer-broker[-name]`
  — predictable and machine-wide — and accepted `TYPE`/`PASTE`/`KEY`/`QUIT` from any local caller, so
  anything able to reach it could type into the driven agent. Each launch now mints a random pipe name
  plus a 256-bit capability token, records both in an ACL-protected descriptor under
  `%ProgramData%\overseer\brokers`, applies an explicit `PipeSecurity` allowing only the console user
  and Administrators, and requires an `AUTH` handshake before any verb. Verified live: connecting by the
  old predictable name fails, and a wrong token is refused with `ERR auth`.
- **`workdir` is no longer interpolated into a remote PowerShell command line.** PowerShell expands
  `$(...)` inside double quotes, so a crafted workdir could execute under the SSH identity. It now
  travels base64-encoded and is decoded into a parameter value.
- **Payloads are staged in `%ProgramData%\overseer`, not the SSH user's profile**, so the documented
  setup where the SSH admin differs from the console user actually works instead of silently failing.

### Fixed
- **Two Codex brokers no longer share one transcript.** Resolution picked the newest rollout written
  after the child started and cached it forever, so a second broker could bind to the first one's file
  and report its replies. Each broker now claims a rollout in its own descriptor and skips rollouts
  claimed by siblings. Verified live: two concurrent Codex brokers produced distinct rollouts, and
  `winread` returned `ALPHAWIN` and `BETAWIN` to the right broker.
- **Claude transcript resolution no longer falls back to "newest jsonl on the box"** — it resolves the
  session id from a descendant-owned `sessions/<pid>.json` and reports no transcript until its own file
  exists.
- **`winstop` no longer orphans the agent.** Teardown walked the tree but killed it parent-first (a
  `List[int]` returned from a function is unrolled to `Object[]`, whose missing `.Reverse()` silently
  reordered the kill), so killing the console-sharing shell took the broker down before it reached the
  agent. Kills are now leaf-first by index, retried, and verified. Verified live: `codex=0 brokers=0`.
- **`winsh` no longer times out on output taller than the window.** The console screen buffer is the
  window height by default, so the opening sentinel was destroyed rather than scrolled. The broker now
  enlarges the buffer at startup and serves scrollback via `SNAPALL`. Verified live: all 200 lines of a
  200-line command captured with `exit=0`.
- **Delivery is verified against the composer, not the whole screen.** A 24-character substring probe
  anywhere on screen counted as success; a single-line prompt is now matched for equality on the input
  row, and a multi-line prompt against its paste chip.
- **An aborted `winchat` clears the remote input box** instead of leaving the prompt staged where a
  later `Enter` would submit it.
- **A failed transcript fetch no longer silently bypasses the mid-turn guard** — `winchat` fails closed
  unless `--force` is given.
- **`winsh`/`winchat` check broker kind, liveness and busy state under the per-broker lock**, closing a
  window where a concurrent `winbroker` could swap the child between the check and the keystrokes.
- **The client fails loudly.** Protocol errors, missing descriptors, failed authentication, malformed
  frames and a failed submit now exit non-zero instead of returning success, and `winbroker` fails
  unless the child actually paints.

### Added
- **Windows payloads are covered in CI.** A `windows-latest` job parses every `win-*.ps1` with the
  PowerShell parser and runs `tests/win-contracts.ps1` (assertions over the auth handshake, pipe ACL,
  descriptor handling, argument encoding, teardown order and error exits). The parser check immediately
  caught two real defects — a `$line:` scope-qualified variable and a `.Reverse()` on an unrolled array
  — that had shipped past every existing check.
- `OVERSEER_SCP` overrides the `scp` binary, matching `OVERSEER_SSH`.

### Changed
- The broker records the exact child pid from `Start-Process -PassThru` rather than guessing "first
  child", which is what made the descendant walk unreliable.
- Broker terminating errors are logged; a broker that dies during startup or teardown is no longer
  silent.

## [0.10.1] - 2026-07-21

### Added
- **Windows parsers are now covered by CI.** `tests/run.sh` asserts `_win_split` (bare host, `user@ip`,
  `<host>/<name>`, and the three rejection cases) and `_win_field`/`_win_sig` against real `STAT`/`INFO`
  lines. Until now the whole Windows path had zero automated coverage, even though its parsers are
  exactly the kind that shipped broken in 0.9.0 and passed CI.
- **`docs/WINDOWS.md`** — the mechanism and its constraints in one place: the Session 0 → Session 1
  scheduled-task bridge and its battery/time-limit traps, the tmux↔broker primitive mapping, and the
  console-input facts that no documentation states (a raw `ESC` is never delivered, so bracketed paste
  is impossible; a `\r`/`\n` with `wVirtualKeyCode = 0` is swallowed; `Ctrl+J` is what inserts a
  composer newline; the box must be cleared first). The no-prose-comments rule keeps these out of the
  scripts, and until now they lived only in commit messages.
- **ADR-0002** records why overseer stays a Claude Code *skill + hooks* rather than becoming an MCP
  server or a subagent.

### Changed
- **`lib/windows.sh` split out of `lib/commands.sh`.** `commands.sh` had grown past 650 lines mixing
  four concerns; it now holds only the local/ssh commands, with the `win*` surface in its own lib.
  No behaviour change from the move.
- **The Windows turn poll gates on `mtime:size`, not size alone**, matching `_file_sig` on Linux. The
  broker already reported `mtime` over `STAT` and nothing read it; a same-size rewrite of the transcript
  could previously be missed.
- **ADR-0001's "revisit if Windows support is wanted" trigger is marked as fired and resolved** — it
  predicted a rewrite would be the honest path, and 0.8.0 showed a native broker plus the unchanged bash
  seam was enough. Recording the outcome keeps the decision log from arguing against shipped reality.

### Fixed
- `winbroker` and `winstop` now take the same per-broker lock as `winkeys`/`winsh`/`winchat`, so
  restarting or stopping a broker cannot interleave with an in-flight command on that broker.

## [0.10.0] - 2026-07-21

### Added
- **`winread <host>[/name]`** — the Windows peer of `read`: the last user prompt + last assistant
  reply from the broker's agent, off its transcript, through the same `transcript.sh` readers. Until
  now the only way to see a Windows agent's last exchange was `winpeek`, a noisy TUI screenshot.
- **`winwait <host>[/name] [timeout]`** — the Windows peer of `wait`: block until the current turn
  ends, return the **question** if the agent is stopped at an interactive prompt, print `idle` if it
  was not busy. This is what a `winchat` timeout now points at, so a long turn is resumed instead of
  re-sending the prompt.
- **Several brokers per Windows host.** Every `win*` command takes `<host>[/name]`; the name selects
  the broker's pipe (`overseer-broker-<name>`, default `overseer-broker`), so a Claude and a Codex —
  or two agents on different repos — can run side by side in their own console windows:
  `winbroker win-host/codex2 codex` then `winchat win-host/codex2 '...'`. Starting a broker now only
  replaces the one with the same name (and kills its whole process tree, not just its direct child),
  and its scheduled task is named per broker so two launches cannot collide.
- **`winlist <host>`** — the Windows peer of `list`: every overseer broker on the host with its
  child kind, working directory and whether the child is alive.

### Fixed
- **A multi-line prompt to a Windows agent now arrives verbatim.** 0.9.0 wrapped it in
  bracketed-paste markers, but `WriteConsoleInput` never delivers the `ESC` of those markers — the
  agent recorded the literal `[200~`/`[201~` around the prompt, and the newlines were swallowed
  entirely, so the lines ran together. Newlines are now injected as the composer's own newline key
  (Ctrl+J), which both Claude Code and Codex accept as a line break rather than a submit. Verified by
  reading back what each agent actually recorded.
- **The input box is cleared before the prompt is placed**, as `_paste_verified` has always done on
  Linux. Without it, whatever the box already held was prepended to the prompt and submitted with it
  — observed live as a stray fragment glued to the first line.

### Changed
- `winchat`'s wait, `winwait`'s wait, and their awaiting/liveness handling are one shared helper, so
  the two commands cannot drift.

## [0.9.0] - 2026-07-21

### Added
- **`winchat` now carries the same guards as `chat`.** It previously had none, so driving a Windows
  agent was materially less safe than driving a Linux one:
  - **Refuses a Codex prompt starting with `!`** — Codex runs such a message as a *shell command* by
    its design, so `winchat <host> '!<cmd>'` silently executed on the Windows box. This is the same
    refusal `_deliver` has always applied on Linux.
  - **Prepends a space for Claude's `/ ! # @`**, so a prompt leading with one of those arrives as
    chat instead of opening command/bash/memory/file mode.
  - **Strips C0 control bytes** from the prompt.
  - **Refuses a mid-turn agent** (`_h_is_busy` on the fetched transcript); `--force` bypasses.
  - **`--yes`** — without it, the prompt is placed, verified, and shown for confirmation before it is
    submitted (matching `chat`/`send`).
  - **Returns the question** when the agent stops at an interactive permission/menu prompt, instead
    of hanging to timeout. The broker's `SNAP` is an already-rendered console grid, so the existing
    `_awaiting_text` screen parser reads it unchanged — no second implementation.
  - **Fails fast when the agent exits mid-turn** rather than waiting out the timeout.
  - **Per-host lock** (`_lock_pane`) around delivery in `winchat`/`winkeys`/`winsh`, so two overseer
    invocations can no longer interleave keystrokes into the same broker.
- **Multi-line prompts to a Windows agent** (`winchat <host> -` reads stdin). A new broker `PASTE`
  verb wraps the text in bracketed-paste markers and emits newlines as characters; the old `TYPE`
  path sent a newline as a real `VK_RETURN`, which submitted a multi-line prompt at its first line.
  Delivery is verified on screen before Enter, mirroring `_paste_verified`.
- **`winsh` refuses a broker that is hosting an agent.** It previously typed the command line into
  whatever child was running — including a Claude/Codex chat box, which then submitted it as a
  message.

### Fixed
- **A Windows broker child now runs through the user's PowerShell profile**, so it behaves exactly
  like the user opening their terminal and typing `claude` / `codex` / `pwsh`. The launcher started
  `claude.exe` directly and passed `-NoProfile` to the pwsh wrappers, so any environment the user
  sets in their profile was missing — on the test host that profile dot-sources the file configuring
  a third-party API, so the broker's Claude fell back to "Not logged in · Please run /login" while
  the same command in the user's own terminal worked.
- **An interactive prompt is now detected on a Windows console.** Claude Code draws the selection
  cursor as an ASCII `>` there rather than `❯`, so `_awaiting_text` never matched a Windows grid and
  `winchat` would have waited out its whole timeout at a permission/menu prompt. The cursor class now
  accepts `>` as well, still gated on two or more numbered options. A real Windows-console capture is
  now a fixture (`awaiting-windows-console.txt`) so this cannot regress.
- **`winbroker` waits for the child to actually paint** before returning, not merely for the pipe to
  appear. A `winsh`/`winchat` issued immediately after could otherwise race the child's startup and
  time out looking for its sentinels.
- **`scp` is retried like `ssh`.** Payload upload and transcript fetch had no retry, so a single
  dropped packet on a relayed tailnet link failed the whole command.
- **`winsh` always reports a numeric exit code.** PowerShell only sets `$LASTEXITCODE` for native
  commands, so a cmdlet-only line reported an empty exit; it now falls back to the command's success
  status.

### Changed
- **`winchat`'s wait no longer copies the whole transcript every poll.** A new broker `STAT` verb
  reports `alive`/`size`/`mtime`/`transcript`, and the transcript is refetched only when its size
  changed — the same size-gated poll the Linux reader uses. A long Codex rollout is multiple MB, so
  the old loop re-copied it over the network every 0.5s.
- **The broker resolves the transcript of *its own* child**, not the newest file on the machine:
  Claude via the `sessions/<pid>.json` → `sessionId` chain over the child's descendant pids (the
  Windows twin of `_agent_pid`/`_sid_of`), Codex by restricting rollouts to those written since the
  child started. Another agent running on the same Windows box no longer shadows it.
- Broker input is written in bounded chunks, so a long paste cannot overflow the console input
  buffer.

## [0.8.0] - 2026-07-21

### Added
- **Drive a shell / Claude Code / Codex on a remote Windows host, turn-based, over plain ssh
  (`winbroker` + `winpeek`/`winkeys`/`winsh`/`winchat`/`winstop`).** A plain-SSH Windows host has no
  tmux, and an ssh login lands in the invisible **Session 0**, so the existing `on`/tmux path can't
  reach it. `overseer winbroker <host> [pwsh|claude|codex] [workdir]` launches a small cooperative
  PowerShell **broker** on the host's logged-in **console** (Session 1, via the same interactive
  scheduled-task bridge as `winshow`), hosting the chosen child in a window the user watches. The broker
  is the tmux stand-in: it shares the child's console and exposes a **machine-wide named pipe**
  (reachable from Session 0) whose protocol maps `WriteConsoleInput` → tmux `send-keys` and
  `ReadConsoleOutputCharacter` → `capture-pane`, so the rendered screen grid comes back for free (no VT
  emulator). It opens in the host's Windows Terminal default directory unless `[workdir]` is given.
  - `winpeek <host>` snapshots the broker screen; `winkeys <host> <key|text>…` injects named keys
    (`Enter` `Escape` `Up` `C-c` …) or literal text (a TUI needs a **separate** `Enter` to submit a
    pasted burst); `winsh <host> <command>` runs one command line in a pwsh child with a sentinel and
    returns output + exit code; `winstop <host>` stops the broker.
  - `winchat <host> <prompt>` sends a prompt to a claude/codex child, submits it, and waits for the turn
    by reading the agent's on-disk transcript with the **same `transcript.sh` readers** overseer uses
    locally — run on the rollout/session `.jsonl` fetched back over ssh — so completion detection is one
    seam across Linux and Windows, not a reimplementation. Prints the reply.
  - Payloads: `scripts/win-broker.ps1` (console-API host + pipe server), `scripts/win-client.ps1` (the
    one-shot `info|snap|type|key|sh|quit` client), `scripts/win-launch.ps1` (the Session-1 launcher).
    Requires an **admin** ssh login and PowerShell 7 on the Windows host.

## [0.7.0] - 2026-07-20

### Added
- **Open a GUI on a remote Windows host's visible desktop (`winshow`).** `overseer winshow <host> [app]`
  opens a GUI app — default Windows Terminal, or any Start-menu name / AUMID / full exe path — on the
  **console session** of a remote Windows machine over plain ssh. overseer itself can't run on Windows
  (no `/proc`, no native tmux); it only ssh-executes a small PowerShell launcher. An ssh login on
  Windows lands in the non-interactive **Session 0**, so a naive GUI launch is invisible — `winshow`
  bridges to the logged-in desktop with a throwaway interactive scheduled task (`-LogonType Interactive`
  as the live-resolved console user) and clears two silent traps: a laptop **on battery** (default tasks
  carry `DisallowStartIfOnBatteries`, so they sit `Queued` and never launch) and Windows Terminal's
  **app-execution-alias** stub (launched by AUMID via `explorer.exe shell:AppsFolder\…`, not a direct
  `CreateProcess`). It confirms a new top-level window appeared and errors clearly when nobody is at the
  console. Needs an admin ssh login on the Windows host. This supersedes the earlier "run the agent in
  WSL2" guidance — a Windows machine's desktop is now reachable directly.

## [0.6.0] - 2026-07-20

### Added
- **Drive panes on remote Linux hosts over SSH (`on`, `deploy`).** `overseer on <host> <command> [args]`
  runs any command on a remote ssh host and streams the result back; `overseer deploy <host>` copies the
  scripts to `~/.overseer` there first. The *whole* program executes remote-side, so its tmux / `/proc` /
  transcript reads stay co-located and discovery + completion detection work unchanged — only the
  invocation and result cross the wire. A blocking `chat`/`wait`/`sh` runs its poll loop on the remote
  (reading that host's own transcript and hook markers — no new event channel); one-shots reuse one
  multiplexed connection via `ControlMaster`+`ControlPersist`. `<host>` is any ssh target (`user@host`, a
  `~/.ssh/config` alias, or a Tailscale MagicDNS name); credentials are ssh's own, so overseer keeps no
  daemon, DB, or token store. `overseer on <host> doctor` is the remote preflight. New overrides:
  `OVERSEER_REMOTE_BIN`, `OVERSEER_SSH`, `OVERSEER_SSH_OPTS`. Native Windows stays out of scope (no
  `/proc`, no native tmux); run the agent in WSL2 and target that as ordinary Linux.

## [0.5.17] - 2026-07-20

### Docs
- **Every documented behaviour now matches the code.** A three-axis audit (command surface · documented
  behaviour vs code · release hygiene) found ~20 statements that had drifted as the plugin gained
  commands; all are corrected across the built-in help, `README.md`, `SKILL.md` and `docs/`. The ones
  that actively misled:
  - **`menu` was described three different ways** — the built-in help said "claude only", the docs said
    "Agent (Claude/Codex)", and the code gates on neither: it drives *any* pane off what is highlighted
    on screen. Now stated as "any pane" everywhere, with the `Right`-vs-`Down` nav-key guidance kept.
  - **`doctor` was missing from `SKILL.md` entirely**, so the agent-facing surface listed 12 of 13
    commands.
  - **`--yes` and `--force` were written `[--yes|--force]`** as if mutually exclusive; they are
    independent and combinable, which the code's own usage strings already said. Both `fleet` usage
    strings also disagreed with each other about `--force`.
  - **The awaiting detector needs *two or more* numbered options** — a single-option or unnumbered y/n
    prompt is not matched and `chat`/`wait` run to timeout. Previously only the searchable-picker
    exclusion was documented.
  - **`sh` brackets the command with two sentinels, not one**, and reports (rather than silently drops)
    output whose opening sentinel outran the pane scrollback.
  - **Busy/idle comes from the transcript, not the "dim ghost suggestion"** — the ghost only
    distinguishes an empty input box from a full one. The old wording contradicted this file's own
    completion-detection section.
  - **Copy-mode is cancelled before *writes* and before the awaiting check**, not before "any
    read/write": `peek`/`read` deliberately leave a scrolled pane alone.
  - **Marker pruning runs at most once every 24h**, not "on the next turn".
- Also newly documented: per-pane `flock` serialization (including that it proceeds unlocked when
  contended past 30s), `CODEX_HOME`, the `bash >= 4.1` requirement and the real `jq` scope in
  `SKILL.md`, the `list`/`fleet` foreground-command pre-filter, `fleet`'s `idle(0-turn)` /
  `(not an agent)` states and its bare-`fleet` default, and the `doctor live` / `peek -e|--raw` /
  bare-name `slash` aliases. `docs/PORTING.md` no longer presents the bash-version question as open (it
  is decided and enforced), and `docs/DECISIONS.md` drops a line count that had already rotted.
- **CHANGELOG: 0.5.5, 0.5.6 and 0.5.7 got their own headings.** Their notes had been folded under
  `[0.5.8]`, leaving one version block with `### Changed` three times and no record of what each
  release actually contained.

## [0.5.16] - 2026-07-20

### Fixed
- **`doctor --live` reported `doctor: OK` (exit 0) even when its own self-test printed `[FAIL]`.**
  `_doctor_live` never fed its result back into the `bad` flag, so the one check that exercises the real
  send-keys/capture-pane path could fail while `doctor` still declared the runtime healthy — a false
  green, the worst outcome for a preflight. It now returns non-zero on `[FAIL]` and `doctor` exits 1.
  `[skip]` outcomes (no tmux, no throwaway session) stay non-fatal, as before.
- **`chat`/`wait` read a frozen screen when the pane was scrolled up.** A pane in tmux copy-mode serves
  the *scrolled* view to `capture-pane`, so `_awaiting` could miss a permission/select prompt the agent
  was actually blocked on and hang to timeout instead of returning the question. `_awaiting` now cancels
  copy-mode first (`_wake_pane`), so the awaiting detector always reads the live screen. `fleet status`
  goes through the same detector and therefore also reports live state rather than a frozen one. The
  read-only `peek`/`read` paths are deliberately left alone — they never cancel a scroll you set up.

Both bugs were found by a three-axis audit (command surface, documented behaviour vs code, release
hygiene) rather than by use; the doc drift the same audit turned up is addressed separately.

## [0.5.15] - 2026-07-20

### Changed
- **CI now *runs* the harness-free stress subset, not just lint-checks it.** A new `stress` job installs
  tmux and executes `tests/stress.sh`, which — with no `OVERSEER_STRESS_CODEX_PANE` set — covers
  multi-pane concurrency, per-pane lock serialization, large-rollout (~18 MB) reader perf, and mid-turn
  crash liveness against throwaway shell panes (no Claude/Codex needed). This turns four core properties
  from *manual-only* into *automated regression gates*. Only the Codex `!`-refuse check (needs a real
  Codex pane) stays manual. The reader-perf ceilings are env-tunable (`OVERSEER_STRESS_PERF_LASTREPLY`,
  `OVERSEER_STRESS_PERF_TURNS`) and set generously in CI so a genuine O(n²)-style regression still fails
  while normal runner variance doesn't.

## [0.5.14] - 2026-07-20

### Fixed
- **Error output was being swallowed by every box-mutating command since v0.5.9.** The per-pane lock
  helpers opened their fd with `exec {fd}>"$f" 2>/dev/null` — but `exec` *with no command* applies both
  redirections to the **current shell permanently**, so `2>/dev/null` silenced stderr for the rest of the
  process. Any later `_die`/warning from `chat`/`send`/`sh`/`slash`/`menu`/`keys` printed nothing (a
  command could fail with an empty message). Scoping the redirect to a group (`{ exec {fd}>"$f"; }
  2>/dev/null`) keeps the fd open while restoring stderr. Caught by the new stress harness.
- **Codex now refuses a message starting with `!` instead of running it as a shell command.** Codex
  treats a submitted `!…` as a Shell-mode command (its design) — trimming or space-guarding doesn't stop
  it — so `chat`/`send` on such a message could execute arbitrary shell in the watched session. `_deliver`
  now refuses it with a clear message pointing at `sh <target> '<cmd>'` (or rewording).

### Added
- **`tests/stress.sh`** — a manual (non-CI, tmux-required) verification harness for the live paths the
  fixture tests can't reach: 8-pane concurrent `sh` isolation, 5-way same-pane lock serialization,
  large-rollout (~18 MB) reader perf, mid-turn crash liveness (`rc=3`, not timeout), and — with
  `OVERSEER_STRESS_CODEX_PANE=%N` — the Codex `!`-refuse safety against a real pane. CI lint-checks it
  (`bash -n` + shellcheck); it is run by hand. This capstone run is what surfaced the two fixes above.

## [0.5.13] - 2026-07-20

### Added
- **`overseer doctor --live`** — an opt-in end-to-end self-test. Plain `doctor` stays static (no side
  effects); with `--live` it spins up a *throwaway* tmux session, runs one `sh` round-trip through it
  (send-keys → sentinel → capture-pane), reports ok/FAIL, and tears the session down. This exercises the
  whole shell-driving path — tmux plumbing, the sentinel protocol, `_is_shell`, wake/env-neutralization
  — against a real pane, catching a broken tmux or locale that the static checks can't. Verified live:
  plain `doctor` spawns nothing; `--live` reports ok and leaves no session behind.

### Docs
- **Clarified why searchable pickers aren't auto-detected as "awaiting" — it is intentional, not a gap.**
  Live investigation (Codex's `@`-mention list) confirmed these are input-box UI the user opens by typing
  (`@`, a slash command), never a state a turn ends in, and their on-screen chrome (a leading `>`/`›`, an
  "esc to cancel" footer) overlaps a normal reply's markdown — so auto-detecting them would risk
  false-positives on real answers on the core `chat`/`wait` path. They stay driven by `peek` + `keys`, as
  documented. (No detector change shipped, by design.)

## [0.5.12] - 2026-07-20

### Added
- **`fleet` — one command over every agent pane at once.** A thin fan-out on top of the existing
  per-pane commands (not a scheduler): `fleet status` prints one line per discovered Claude/Codex pane
  (harness + idle/busy/awaiting); `fleet read` and `fleet wait [timeout]` fan those out; `fleet send` /
  `fleet chat [--yes] <msg>` **broadcast** the same message to all agent panes. Each pane is handled in
  its own subshell, so one pane erroring (mid-turn, timed out, exited) never aborts the batch, and every
  pane keeps its own guards (confirm-unless-`--yes`, mid-turn refuse, per-pane lock). Verified live:
  `status`/`read`/`wait` across 4 mixed panes, and `send`/`chat` argument threading (`flags → pane →
  msg`) in isolation without broadcasting to live sessions.

## [0.5.11] - 2026-07-20

### Added
- **`chat`/`wait` fail fast when the agent exits mid-turn.** The wait loop watched only the transcript,
  so if the driven Claude/Codex crashed (or was `quit`) mid-turn it would wait out the entire
  `[timeout]` (default 600s) for a reply that would never come. It now also checks, a few times a
  second's worth of ticks apart, whether the pane has dropped back to a shell (the harness process
  gone); if so it returns immediately with "agent exited mid-turn — peek …". A hung-but-alive turn is
  still bounded by the timeout, as before. Verified live (rc in ~3s on a shell pane vs. the full
  timeout; a real turn on a live agent is unaffected).

### Changed
- **Idle turn-marker files are swept automatically.** The `Stop`/`UserPromptSubmit`/`Notification`
  hooks write one mtime marker per session id; across many sessions over time those accumulated
  forever. The hook now prunes markers untouched for over a week, gated to run at most once a day (via
  a `.overseer-pruned` stamp), so a heavy user's `~/.claude/{turn-done,turn-started,awaiting}/` no
  longer grows without bound. Deleting a stale marker only costs a poll-fallback on that session's next
  turn (the hook recreates it), never a wrong read.

### Fixed
- **A too-old bash now fails loudly at startup.** The script relies on named file descriptors
  (`exec {fd}>…`, bash ≥4.1) and associative arrays (bash ≥4.0); under stock macOS bash 3.2 those are
  parse/runtime errors surfacing cryptically deep in a sourced lib. The entry now checks
  `BASH_VERSINFO` up front and exits with a clear "needs bash >= 4.1" message before sourcing anything.

## [0.5.10] - 2026-07-20

### Changed
- **All `/proc` access now sits behind a four-function OS seam** (`_p_children`, `_p_comm`, `_p_cwd`,
  `_p_fds` in `discovery.sh`), dispatched on `$OVERSEER_OS`. The Linux branch is unchanged (verified
  live: `list`/`read`/discovery identical to before); any other platform returns cleanly so discovery
  reports "no agent pane" instead of reading a `/proc` that isn't there. This turns a future macOS port
  from a rewrite into implementing four functions. `doctor`'s non-Linux message now names the OS and
  points at the porting spec.

### Docs
- **`docs/PORTING.md`** — exact macOS (`ps`/`lsof`) mapping for each seam function, plus the other
  Linux/GNU-isms a port must bridge (`stat -c` vs `-f`, `date +%N`, `flock`, macOS's stock bash 3.2) and
  how to exercise the non-Linux path (`OVERSEER_OS=Darwin`). Runtime stays Linux-only; nothing is
  claimed as supported that hasn't been live-verified.
- **`docs/DECISIONS.md` (ADR-0001)** — records why overseer stays a single bash program rather than a
  Rust/Go/Python rewrite (the work is tmux/`jq`/`/proc` orchestration, not computation; ships as source
  with no build), and the concrete triggers that would reopen the question (Windows support, persistent
  state / a real API, a third harness straining the dispatch seams).

## [0.5.9] - 2026-07-20

### Fixed
- **`clear-box` no longer declares a multi-row input box empty while a row above the cursor still holds
  text.** Emptiness was read from the cursor row only (`_realtext`), so after `C-u` cleared the last
  line — leaving the cursor on a blank row with earlier lines still filled — the box read as empty and a
  stale first line survived into the next paste. It now treats the box as empty only when the cursor row
  is blank **and** still carries the prompt glyph (`❯`/`›`); a blank row without the glyph means content
  remains above, so it keeps clearing. Falls through to the old cursor-row test if the glyph can't be
  seen (broken UTF-8 locale), never stricter than before. Reproduced and verified live on Codex.

### Added
- **Two env tunables, validated at startup:** `OVERSEER_TIMEOUT` (default `600`) sets the fallback
  `[timeout]` for `chat`/`wait`/`sh`; `OVERSEER_POLL_INTERVAL` (default `0.25`s) sets the poll cadence.
  A non-numeric value fails loudly at launch instead of being silently read as `0`. Replaces the
  scattered hard-coded `600`/`0.25` literals with one config layer.
- **Per-pane advisory lock** so two concurrent `overseer` box-mutating commands (`send`/`chat`/`sh`/
  `slash`/`quit`/`menu`) on the *same* pane serialize instead of interleaving keystrokes and corrupting
  each other's input box. Best-effort `flock` (held only for the box-mutation critical section, released
  before the read-only reply wait); if `flock` is absent, the lock dir is unwritable, or the wait times
  out, the command proceeds unlocked — never blocked. Different panes never contend.

### Changed
- **Broadened the "idle shell" allowlist** (`sh`/`quit`) behind one `_is_shell` helper: adds `mksh`,
  `ash`, `tcsh`, `csh`, `nu`, `xonsh`, `elvish` and their login-shell (`-`-prefixed) forms to the
  existing `sh`/`bash`/`zsh`/`fish`/`dash`/`ksh`. `sh` on a non-Bourne interactive shell (and `quit`
  confirming the pane returned to one) no longer wrongly refuses. Covered by new fixture tests.

### Docs
- Spelled out the fast-path's `CLAUDE_HOME` dependency (README + skill): the event hooks accelerate a
  driven Claude session only when it shares overseer's `~/.claude`; a session under another user, a
  custom `CLAUDE_HOME`, or started before the plugin was installed falls back to polling (~2s), never
  blocked.

## [0.5.8] - 2026-07-20

### Fixed
- **`sh` no longer returns silently-empty output when a command outprints the pane scrollback.** If the
  output was long enough that its start (the begin sentinel) scrolled out of tmux history, `sh` now says so
  and suggests re-running with the output redirected to a file, instead of printing just the exit code with
  an empty body that reads like "no output".

### Changed
- **`doctor`'s contract probe targets the newest session that actually has a completed turn** (scanning up
  to the 20 newest), instead of the single newest file. A brand-new 0-turn session no longer masks a real
  schema break in a slightly older session — the probe now always has something meaningful to read when any
  recent session does.
- **`doctor` self-checks the awaiting-input detector** against a built-in sample menu, warning if it fails
  to match — which catches a broken/non-UTF-8 locale where `grep` can't see the `❯`/`›` cursor glyphs (that
  would otherwise make `wait`/`chat` silently miss permission prompts).

### Docs
- README caveat: awaiting-input detection covers numbered menus (`❯`/`›` + numbered options), not
  type-to-filter searchable pickers — `peek` + `keys` those.

## [0.5.7] - 2026-07-20

### Added
- **Parser regression tests** (`tests/run.sh` + `tests/fixtures/`), run in CI. They assert the pure
  transcript/screen parsers against hand-built fixtures — turn counting, busy detection, last
  reply/prompt (incl. multi-line and injected-wrapper exclusion), `sessionId` extraction, incremental
  `_turns_after`, and awaiting-prompt detection for **both** Claude (`❯`) and Codex (`›`) menus plus a
  negative case. This is the drift signal that was missing: an upstream on-disk/TUI change now fails CI
  instead of surfacing at runtime. No live tmux needed.

### Changed
- **`last reply` / `last prompt` readers stream the transcript** (`jq -n 'last(inputs | …)'`) instead of
  slurping the whole file into an array (`jq -s`), so a large session is read in near-constant memory.
  Verified byte-identical to the old readers across 16 real Claude + Codex transcripts and the fixtures.
- **`_awaiting` split into a pure `_awaiting_text`** (screen text in, verdict out) plus a thin
  `capture-pane` wrapper, so the awaiting-prompt logic is unit-testable. No behavior change; confirms the
  existing regex already covers Codex's `›`-cursor numbered menus.

## [0.5.6] - 2026-07-20

### Changed
- **Turn detection in the wait loops now reads only the bytes appended since the send**, not the whole
  transcript. While waiting, overseer re-scanned the entire `.jsonl`/rollout on every change to recount
  turns; it now records the file size at send time and `tail`s from that offset to spot the new terminal
  marker (`stop_reason ≠ tool_use` for Claude, `task_complete` for Codex). Equivalent to the old
  count-vs-baseline while the file only grows; the full-count reader is kept for `doctor`'s display and as
  the fallback. Pairs with the size/mtime gate from 0.5.4, so a `wait` on a multi-megabyte session does
  near-constant work per tick instead of re-parsing megabytes.
- **`/proc` discovery walks every thread's `children`, not just the pane's main thread.** `_agent_pid` /
  `_descendants` read `task/<pid>/children` only; they now read `task/*/children`, so an agent a harness
  spawns from a non-main thread is still discovered. No effect on today's Claude/Codex (both spawn from
  the main thread) — a robustness fix against future layouts.

## [0.5.5] - 2026-07-20

### Added
- **Event-driven turn-start and awaiting-input signals for Claude**, closing the last polling gap. Two
  more Stop-hook-style markers now ride the same bundled hook script: `UserPromptSubmit` touches
  `turn-started/<sid>` and `Notification` touches `awaiting/<sid>`. `send` records the submit time and
  confirms the turn started the instant the marker lands — removing the sub-second race where the
  transcript has no turn-start entry until the first token — and `chat`/`wait` surface an interactive
  prompt as soon as the notification fires. Both are pure accelerators: when the target session does not
  carry the hook (or on Codex, which has none), the readers fall back to the same size/mtime-gated
  transcript poll, so behavior is unchanged, never worse. The reader uses one `_marker_since` helper for
  all three markers, and the hook honors `${CLAUDE_HOME:-$HOME/.claude}`.

## [0.5.4] - 2026-07-20

### Fixed
- **Event-mode wake now survives a custom `CLAUDE_HOME`.** The bundled `Stop` hook wrote the turn-done
  marker to a hardcoded `$HOME/.claude/turn-done/`, while the reader looked under `$CLAUDE_HOME/turn-done/`.
  When `CLAUDE_HOME` was overridden the two diverged, silently disabling the ~0.25s event wake and
  dropping `chat`/`wait` back to ~2s polling. The hook now honors `${CLAUDE_HOME:-$HOME/.claude}`.
- **The Claude turn-done signal id is now read from the transcript's `sessionId`**, not parsed from the
  `.jsonl` filename. `basename` matched the session id only as long as the on-disk filename stayed exactly
  `<sessionId>.jsonl`; deriving it from the canonical field keeps the event wake working if that ever gains
  a suffix.

### Changed
- **Codex busy-check does one streaming `jq` pass instead of three**, and both wait loops re-scan the
  transcript only when its size/mtime actually changed. A Codex `wait` (no Stop hook, so it polls every
  ~0.25s) was re-parsing the whole rollout up to four times per tick; on a multi-megabyte session that is
  now skipped whenever the file is unchanged. No behavior change — turn counts only grow when the file does.

## [0.5.3] - 2026-07-19

### Changed
- Marketplace manifest hygiene: added the `$schema` reference for editor validation and dropped the
  non-standard `displayName` field (absent from the marketplace schema, silently ignored at load).
- `doctor` now **probes the transcript contract** instead of pinning exact CLI versions. It runs
  overseer's own readers against the newest on-disk session and warns only on a real parse failure
  (turns present but the reply is unreadable), so a harmless patch bump is silent while an actual
  layout change is caught — on any version, even one previously "tested". Removed the
  `TESTED_CLAUDE_VERSION` / `TESTED_CODEX_VERSION` baselines and the every-release bump they forced;
  `doctor` still prints the running versions for reference.

### Fixed
- **`send` now confirms the turn actually started before returning**, closing a race where a following
  `wait`/`read` read stale state. `send` submitted and returned in the sub-second window before the
  harness wrote the turn's first transcript marker, so an immediate `wait` reported `idle` and `read`
  showed the previous reply (reproduced on both Claude and Codex). `send` now polls until the turn is
  observable — mid-flight, already advanced, or stopped at an interactive prompt — bounded to 10s.
- **`chat` handles the first message to a 0-turn session** instead of refusing it. A brand-new Claude or
  Codex session has no transcript to baseline against; `chat` now sends, resolves the transcript once the
  turn begins, then waits for the reply — so the first turn no longer requires a separate `send`.

## [0.5.2] - 2026-07-19

Fixes from a full live + static audit of the interaction surface.

### Fixed
- **Interrupting a Codex turn (Escape) no longer wedges the session as permanently "busy".** Codex
  writes a `turn_aborted` event on interrupt but no `task_complete`, so the started>completed count
  stayed unbalanced forever — `wait` then hung to timeout and `send`/`chat` refused every future turn
  (even completed ones) until `--force`. Busy is now `task_started > task_complete + turn_aborted`.
- **`wait`/`chat` no longer mis-report "awaiting input" on a normal reply** that happens to contain a
  line like `▶ 1. …`. `_awaiting` now requires a real prompt cursor (`❯`/`›`) on a numbered row **and**
  at least two numbered options — a menu/permission prompt, not one stray glyph line in the answer.
- **`read`/`chat` no longer show a STALE prompt when your actual message starts with `<`, `{` (Claude)
  or `<`, `#`, `{` (Codex).** The prompt readers filtered those as injected-wrapper lines. They now read
  the harness's real user-input signal instead: Claude's `origin.kind == "human"` records, and Codex's
  `user_message` events — neither of which the AGENTS.md / `<INSTRUCTIONS>` / notification wrappers set.
- **Concurrent `overseer` invocations on different panes no longer clobber each other's paste.** The
  tmux paste buffer was a shared constant; it is now per-process (`overseer_paste_$$`).
- **A non-numeric `timeout` is rejected up front** (`chat/wait/sh … 30s`) instead of being read as 0 —
  which sent the message and then died "timeout", tempting a double-send.
- Claude pane detection now requires the session-owning process to actually be `claude` (guards against a
  stale `sessions/<pid>.json` + PID reuse) and also matches an `exec`-launched claude (pane pid itself).
- `menu` cycle-detection ignores the volatile bottom status lines (token/context counters) so a live
  counter no longer defeats the "screen repeated → stop" check.
- `sh`/`quit` fail with a message instead of a bare `set -e` abort if the pane vanishes mid-lookup.
- Multi-line paste verification accepts either chip convention (`+M` = newline count or line count).

### Known / not fixed (documented)
- Concurrent human-and-agent driving of the same pane has a sub-second window where a turn already in
  flight is not yet visible as "busy"; prefer `read`/`wait` over `chat` on a pane a human is actively
  typing in.
- The leading-`/ ! # @` space-guard can leave one leading space in the delivered message (Claude does not
  always trim it); the message still arrives as text. `menu` on a numbered popup (e.g. Claude `/model`)
  can't bridge the `N.` prefix — use `keys <n>` for numbered prompts.

## [0.5.1] - 2026-07-19

### Fixed
- **Multi-line replies and prompts are no longer truncated to their last line.** `read`/`chat`/`wait`
  read the reply and the echoed prompt whole again. The readers selected the last transcript entry with
  `... | tail -1`, which operates on physical lines, so a reply spanning several lines collapsed to only
  its final line. They now slurp the entries and take the last one intact (Claude and Codex, reply and
  prompt paths). This was the common case — most agent replies are multi-line.
- **`send`/`chat` now confirm the message actually submitted.** After the paste they fired a single
  `Enter`; one arriving mid-paste-render is dropped by the TUI, leaving the message sitting unsent in the
  box — most reliably reproduced on the first (long, wrapping) message to a just-launched agent, where
  `chat` would then wait out its whole timeout for a reply that was never requested. Submission is now
  verify-driven (`_submit`): press `Enter`, confirm the box emptied, retry until it does, matching how
  every other step self-verifies.

### Changed
- `TESTED_CLAUDE_VERSION` bumped to `2.1.215` (re-verified live against it); the 0-turn `chat` error no
  longer hard-codes "claude" for what may be a Codex session.

## [0.5.0] - 2026-07-19

### Added
- **Awaiting-input detection.** `wait` and `chat` now notice when the agent is blocked on an
  interactive prompt — a permission dialog, a plan approval, a select menu — instead of treating it as
  a still-running turn and hanging until timeout. They return immediately with the question, its
  options, and how to answer (`keys`/`menu` to pick, `send` to type free-text, then `read`). Detection
  is on-screen: a cursor (`❯`/`›`/`▶`) on a numbered option row, so it covers both Claude and Codex.
  Answering a prompt can reveal the next one (plan approval → per-edit permission → shell approval);
  each `wait` surfaces the next, so the whole approve-as-you-go loop is drivable from outside.

### Fixed
- `wait`/`chat` no longer abort silently under `set -e` when the wait returns a non-zero status
  (the awaiting/timeout codes are now captured with `|| rc=$?`).

## [0.4.1] - 2026-07-18

### Added
- **`menu` now works on Codex too**, completing harness parity — every command except the
  shell-only `sh` drives both agents. Codex marks its active popup row with a bold cyan pointer
  (`ESC[1m ESC[38;5;6m ›`) rather than Claude's reverse-video, so `_is_active` now also recognizes that
  style. Codex popups (`/model`, `/approvals`, ...) are vertical: pass `Down` as the nav key.

## [0.4.0] - 2026-07-18

### Added
- **Codex parity for `quit` and `slash`.** Both now auto-detect the harness and adapt: `quit` sends the
  right number of Ctrl-C taps (Claude two, Codex one) and confirms the pane returned to a shell; `slash`
  types a slash command into either TUI. Only `menu` stays Claude-only.
- Codex is now detected by a descendant process named `codex` (not by an open rollout fd), so a **0-turn
  Codex** — still at `Context 0%`, before it has opened a rollout file — is discovered by `list`, and
  driven by `send`/`slash`/`quit`. `read`/`chat`/`wait` still need one turn (no transcript before that),
  matching Claude's 0-turn behavior.

### Changed
- Docs (README + skill) note Codex specifics: quitting takes a single Ctrl-C; **interrupt a running
  Codex turn with `Escape`, not Ctrl-C** (Ctrl-C quits Codex when idle); a Codex approval prompt is
  answered with a letter key (`y`/`a`/`d`) via `keys`.

## [0.3.1] - 2026-07-18

### Changed
- Internal: split the `overseer` script into a thin entry point that sources `scripts/lib/`
  (`discovery.sh`, `transcript.sh`, `tui.sh`, `commands.sh`). No behavior change; the largest file
  drops from ~620 to ~270 lines. CI shellchecks the entry with `-x` to follow the sources.

## [0.3.0] - 2026-07-18

### Added
- **Codex support.** `list`, `read`, `chat`, `send`, `wait` now auto-detect whether a pane runs
  Claude Code or Codex and read the right transcript — the same commands drive both. Codex discovery
  reads the rollout jsonl the codex process holds open (`/proc/<pid>/fd` →
  `~/.codex/sessions/**/rollout-*.jsonl`); turn completion is the rollout's `task_complete` event, and
  the reply its `last_agent_message`. `quit`/`slash`/`menu` stay Claude-only for now.
- `list` gained a **HARNESS** column (claude/codex).
- `overseer doctor` also checks the running Codex version + `~/.codex/sessions`, warning when Codex
  drifts from its tested baseline (`0.144.5`).
- `overseer doctor` checks the running Claude Code version and warns when it drifts from the tested
  baseline (`2.1.214`) — surfaces upstream layout-change risk without hard-blocking.
- README: `Updating` (apply with `/reload-plugins`, no restart), `Compatibility`, and a
  `Useful Claude Code commands` list.

### Changed
- Docs: apply overseer updates with `/reload-plugins` instead of restarting Claude Code (it re-wires
  the bundled `Stop` hook and reloads the skill in the current session).

## [0.2.0] - 2026-07-18

### Added
- `overseer doctor` — preflight check (Linux/`/proc`, `tmux`, `jq`, tmux server, and whether Claude
  Code's `~/.claude/sessions/*.json` layout is where discovery expects it). Run it first when a pane
  "can't be found".
- Contributor scaffolding: GitHub Actions validation workflow, issue/PR templates, `CONTRIBUTING.md`,
  `SECURITY.md`, `.gitattributes`.

### Fixed
- Shellcheck-clean: split two `local` + command-substitution assignments (SC2318/SC2155) so a
  just-assigned value and command exit codes are not masked.

## [0.1.0] - 2026-07-18

Initial release as a Claude Code plugin distributed via the `sgbl` marketplace.

### Added
- `overseer` script with 11 commands: `list`, `read`, `peek`, `chat`, `send`, `wait`,
  `quit`, `slash`, `menu`, `sh`, `keys`.
- Bundled Claude Code skill (`skills/overseer/SKILL.md`) so an agent can drive/read another
  session or a shell in a tmux pane.
- Bundled `Stop` hook (`hooks/turn-done.sh`, wired via `hooks/hooks.json`) for event mode — wakes
  `chat`/`wait` the instant a turn ends. Wired automatically on install.
- Plugin manifest (`.claude-plugin/plugin.json`) and single-plugin marketplace
  (`.claude-plugin/marketplace.json`, name `sgbl`).

### Notes
- Linux only (agent discovery reads `/proc`). Requires `tmux` and `jq`.
- Reads Claude Code's on-disk session/transcript layout, which is internal and may change
  between Claude Code releases.
