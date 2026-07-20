# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and versions follow [SemVer](https://semver.org/).

## [Unreleased]

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
