# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and versions follow [SemVer](https://semver.org/).

## [Unreleased]

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
