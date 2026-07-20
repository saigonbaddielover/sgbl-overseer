# Porting overseer beyond Linux

overseer is **Linux-only at runtime today.** Discovery reads `/proc`, and a few helpers use GNU
coreutils flags. This document is the exact specification for a macOS (or other Unix) backend, so a
port is a well-scoped, testable task rather than a rewrite. Nothing here is wired up — a contributor
on a Mac implements and *live-verifies* it (the project's core rule: verification is live).

## The OS seam

All `/proc` access is funnelled through **four functions** in
`overseer/skills/overseer/scripts/lib/discovery.sh`. They dispatch on `$OVERSEER_OS` (set once from
`uname -s`, overridable via the `OVERSEER_OS` env var for testing). Only the `Linux` branch exists; every
other platform returns non-zero, so discovery reports "no agent pane" instead of reading a `/proc` that
isn't there.

| Seam function | Contract | Linux (implemented) | macOS (to implement) |
|---|---|---|---|
| `_p_children <pid>` | child PIDs of `<pid>`, whitespace-separated | `cat /proc/<pid>/task/*/children` | `pgrep -P <pid>` — or `ps -o pid= -g $(ps -o pgid= -p <pid>)` if you need the process group |
| `_p_comm <pid>` | the process's command name (`comm`), one line | `cat /proc/<pid>/comm` | `ps -o comm= -p <pid>` then `basename` (macOS `comm` is a full path; strip the dir, and note it is truncated to ~16 chars just like Linux `comm`) |
| `_p_cwd <pid>` | the process's cwd, one line; non-zero if unavailable | `readlink /proc/<pid>/cwd` | `lsof -a -p <pid> -d cwd -Fn` then take the `n`-prefixed line (needs no root for your own procs) |
| `_p_fds <pid>` | every open file's path, one per line | `for fd in /proc/<pid>/fd/*; do readlink "$fd"; done` | `lsof -p <pid> -Fn` and emit each `n`-prefixed path (used to find the Codex rollout the process holds open) |

Implement these four and the entire discovery layer (`_agent_pid`, `_descendants`, `_codex_rollout`,
`_codex_pid`, `_panes`, `_target_ctx`) works unchanged — it never touches `/proc` directly.

### Detection logic that stays the same

The on-disk layouts are **not** OS-specific and need no porting: a Claude pane still owns
`~/.claude/sessions/<pid>.json`; a Codex pane still has a descendant process named `codex` holding a
`~/.codex/sessions/**/rollout-*.jsonl` open. Only the *mechanism* for reading pids/comm/cwd/fds changes.

## Other portability gaps (fix alongside the seam)

The seam covers `/proc`, but a working macOS build must also address these GNU/Linux-isms. Grep the tree
for each before claiming support:

1. **`stat -c` is GNU-only** (`transcript.sh`: `_file_sig`, `_marker_since`, `_fsize`). BSD/macOS `stat`
   uses `-f`: `%Y`→`%m`, `%s`→`%z`. e.g. `stat -f '%m:%z'`, `stat -f %m`, `stat -f %z`. Detect once and
   branch, or prefer `stat` GNU-flags with a BSD fallback.
2. **`date +%s%N` has no nanoseconds on BSD** (`commands.sh`: the `sh` sentinel token). macOS `date`
   drops `%N`. Use `$RANDOM$RANDOM` or `$$` + a counter for the sentinel's uniqueness instead of
   nanoseconds.
3. **`flock` is not present on stock macOS** (`tui.sh`: `_lock_pane`). This already degrades gracefully
   (`command -v flock` guards it), so per-pane locking is simply skipped — acceptable, or supply a
   `flock` shim / use `mkdir`-based locking if you want the guarantee back.
4. **Stock macOS ships bash 3.2**, which lacks features overseer uses: associative arrays
   (`local -A seen`, `commands.sh: cmd_menu`) and named-fd redirection (`exec {fd}>…`, `tui.sh:
   _lock_pane`, bash ≥4.1). Require bash ≥4 (Homebrew `bash`) via the shebang/env, or refactor those two
   spots. This is the biggest single blocker and must be decided first.
5. **`readlink` semantics differ** — only relevant if you reintroduce raw `readlink`; the seam confines
   it, so prefer `lsof` on macOS as above.

## How to test a port

```
# exercise the non-Linux path on any box (no Mac required) — every seam call fails, discovery finds nothing:
OVERSEER_OS=Darwin overseer list          # header only, no panes
OVERSEER_OS=Darwin overseer doctor        # [FAIL] not Linux (Darwin) … see docs/PORTING.md

# on a real Mac, after implementing the four seam functions + the fixes above:
overseer doctor                           # should pass the OS check
overseer list --all                       # your tmux panes + commands
# then drive a real Claude/Codex pane and confirm read/chat/send/wait, exactly as on Linux.
```

Land a port the same way as any change: branch → PR → green CI → merge, with a note in the PR describing
the **live** verification you ran on the target OS.
