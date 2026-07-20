# Decision records

## ADR-0001 — Stay a single bash program; do not rewrite in a compiled/scripting language

**Status:** Accepted (2026-07-20). Revisit on the triggers below.

### Context

overseer is one bash program (`scripts/overseer` + four sourced `lib/*.sh`, ~600 lines total) that
drives and reads another live agent in a tmux pane. During the optimization audit the question was
raised directly: is bash the right implementation, or should this be rewritten in Rust / Go / Python?

What the tool actually does: shell out to `tmux` (`send-keys`, `capture-pane`, `display-message`,
`load-buffer`/`paste-buffer`), read a few JSON transcripts with `jq`, read `/proc`, and poll with
`sleep`. It is **I/O orchestration of external processes**, not computation. There is no hot loop, no
data structure heavier than a list of panes, no algorithm more complex than "poll a file until a marker
appears."

### Options considered

1. **Keep bash (chosen).** Zero build, single file the user already trusts, `tmux`/`jq`/`/proc` are all
   shell-native. Distribution is "copy the script"; the Claude Code plugin ships it verbatim.
2. **Rewrite in Rust or Go.** Buys static typing, real error handling, and a single binary. But every
   operation is still `Command::new("tmux")…` — the binary would be a thin shell-out wrapper around the
   exact same commands, trading the shell's native ergonomics for subprocess plumbing. Adds a
   compile/CI/release toolchain and per-platform binaries to a plugin that today needs none.
3. **Rewrite in Python.** Better string handling and `subprocess`, still interpreted. Adds an interpreter
   dependency and a packaging story (venv/pip) heavier than the current `jq`-only requirement, for a
   program whose logic is 90% invoking `tmux`.

### Decision

Keep the single bash program. The cost/benefit does not favor a rewrite:

- **The work is shelling out.** The dominant operations are tmux commands and `jq` reads; a rewrite
  reimplements the orchestration in another language while still driving tmux as a subprocess. The core
  contracts (transcript JSON shape, screen rendering) live *outside* the language choice.
- **Distribution is simpler as source.** A Claude Code plugin ships files; a script needs no build, no
  release binaries, no per-arch artifacts. `doctor` is the only preflight.
- **The audit closed the real gaps in bash.** Turn detection, event-mode wakes, streaming readers,
  incremental byte-offset scans, the paste/verify/submit path, per-pane locking, and a portability seam
  were all achievable and *live-verified* in bash. The problems were correctness and TUI edge cases, not
  language limits.
- **Testability is adequate.** The pure parsers (turn/busy/reply/prompt/awaiting/shell) are factored out
  and covered by fixture tests in CI; the rest is inherently live-verified against a real tmux pane, which
  a rewrite would not change.
- **`set -euo` discipline + shellcheck + `-x` cross-file linting** catch the classic shell footguns, and
  the code stays within a strict style (self-documenting, no prose comments, size limits).

### Consequences

- Portability is manual: Linux-isms (`/proc`, GNU `stat`/`date`) must be bridged by hand. Mitigated by
  the OS seam and [PORTING.md](PORTING.md), which turn "port it" into a bounded task.
- No compile-time type checking; correctness rests on shellcheck + fixture tests + live verification.
- Large refactors are riskier in shell than in a typed language — accepted, given the small size and the
  test/lint safety net.

### Revisit this decision if

- **Windows support** is wanted (no POSIX shell, no `/proc`, no tmux) — that is a different tool, and a
  rewrite would be the honest path.
- The tool grows **persistent state or a real API** (a daemon, concurrent multi-pane scheduling, a
  network protocol) — orchestration logic heavy enough that a typed language's error handling and data
  structures start to earn their keep.
- A **third+ harness** and the branching it brings make the `_h_*` dispatch seams unwieldy in shell.
- Startup/parse latency ever becomes user-visible (it is not today: each command is a handful of tmux
  calls plus one `jq` pass).

Until one of those holds, the simplest thing that fully works is the single bash program.
