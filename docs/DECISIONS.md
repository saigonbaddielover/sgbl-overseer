# Decision records

## ADR-0001 — Stay a single bash program; do not rewrite in a compiled/scripting language

**Status:** Accepted (2026-07-20). Revisit on the triggers below.

### Context

overseer is one bash program (`scripts/overseer` + the sourced `lib/*.sh`) that
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

- ~~**Windows support** is wanted (no POSIX shell, no `/proc`, no tmux) — that is a different tool, and a
  rewrite would be the honest path.~~ **This trigger fired in v0.8.0 and did not require a rewrite.**
  Windows is driven as a *remote* target over plain SSH: a PowerShell broker runs on the Windows console
  and speaks a line protocol, while every decision (turn detection, awaiting detection, delivery
  guards) stays in the same bash + jq seam. See [WINDOWS.md](WINDOWS.md). The lesson generalises —
  a non-POSIX target needs a small native agent, not a new language for overseer itself.
- The tool grows **persistent state or a real API** (a daemon, concurrent multi-pane scheduling, a
  network protocol) — orchestration logic heavy enough that a typed language's error handling and data
  structures start to earn their keep.
- A **third+ harness** and the branching it brings make the `_h_*` dispatch seams unwieldy in shell.
- Startup/parse latency ever becomes user-visible (it is not today: each command is a handful of tmux
  calls plus one `jq` pass).

Until one of those holds, the simplest thing that fully works is the single bash program.

## ADR-0002 — Ship as a Claude Code **Skill + hooks** inside a plugin; not an MCP server, not a subagent

**Status:** Accepted (2026-07-21).

### Context

overseer is packaged as a single-skill plugin: `SKILL.md` (procedure + command table), the bash program
under `skills/overseer/scripts/`, and three session hooks. The question raised: is a skill the right
Claude Code extension surface, or should this be "upgraded" to an MCP server or a dedicated subagent?

The product here is not only the executable — the script runs fine from a terminal with no Claude at
all. The product is the **procedure knowledge**: which commands mutate state, that a running Codex turn
is interrupted with `Escape` and never `Ctrl-C`, that `menu` needs `Down` for a vertical popup, that
`winsh` aimed at an agent broker would type the command into a chat box. That knowledge has to reach
the model at the moment it drives a pane, and nowhere else.

### Options considered

1. **Skill + hooks (chosen).** `SKILL.md` is read only when the task is relevant, so the ~25-command
   surface costs nothing on unrelated turns. The hooks are pure accelerators — three per-session mtime
   markers; a session without them falls back to polling, so nothing breaks when they are absent.
2. **MCP server.** Tool schemas are context-resident on *every* request, so 25 commands would be paid
   for continuously whether or not any pane is being driven. It also implies a long-lived server, while
   every overseer command is one-shot and stateless — state lives in tmux, `/proc` and the transcripts,
   which is precisely why the tool needs no store of its own. Rejected.
3. **Dedicated subagent.** A subagent is an isolated context, not a capability: it would still shell out
   to this same script, while paying a fresh context each spawn. Worth revisiting only if `fleet` across
   many hosts floods the main context — as a thin layer *over* the skill, never a replacement for it.
4. **Slash commands.** Complementary, not an alternative: cheap to add for muscle memory, but they
   deliver no procedure knowledge to the model.

### Consequences

- `SKILL.md` is loaded whole on activation, so its size is a running cost — tens of KB, and it has only
  grown (check with `wc -c` rather than trusting a number written here). When it grows past comfortable,
  split the per-harness quirk tables into a reference file the skill points at, rather than letting the
  entry document sprawl.
- Distribution rides the plugin marketplace: version bumps must stay in lockstep across
  `plugin.json` and `marketplace.json`, which CI enforces.

### Revisit this decision if

- Another tool (not Claude Code) needs to call overseer programmatically — an MCP surface would then buy
  interoperability the skill cannot.
- The tool grows genuinely long-lived state that must outlive a single command.
