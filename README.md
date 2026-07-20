# overseer

[![validate](https://github.com/saigonbaddielover/sgbl-overseer/actions/workflows/validate.yml/badge.svg)](https://github.com/saigonbaddielover/sgbl-overseer/actions/workflows/validate.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**One agent that oversees others.** Drive and read other agent sessions — and plain shells — running
in **tmux panes**, turn-based, from outside them. Packaged as a
[Claude Code plugin](https://code.claude.com/docs/en/plugins).

The overseer opens (or attaches) a tmux pane, launches an agent harness in its shell, then reads and
drives that sub-agent turn-based — while also being able to run shell commands directly. Today it
speaks **Claude Code** and **Codex** (plus any shell); `read`/`chat`/`send`/`wait`/`list` auto-detect
which harness a pane runs. It's built so more harnesses can be added behind the same commands.

A running agent TUI has no API — its only input channel is the keyboard. `overseer` wraps a
deterministic, self-verifying `tmux send-keys` / `capture-pane` procedure (plus transcript reading) so
an agent can read and drive another session the user is watching. Because tmux is client/server, it
works the same whether the pane is local or displayed over VSCode Remote-SSH — the driving happens
server-side.

> [!WARNING]
> **This executes actions in other sessions.** Target Claude sessions usually run with
> `--dangerously-skip-permissions`, so anything sent auto-runs with no confirmation gate, and `sh`
> runs a command in the user's shell the instant it's called. Treat every send as running a command on
> a machine you don't fully control. The skill's own rules say: never send unless explicitly asked.

## Requirements

- **Linux** — agent discovery reads `/proc` (macOS/Windows not supported yet; the `/proc` access sits
  behind a small OS seam and a macOS `ps`/`lsof` backend is fully specced in
  [docs/PORTING.md](docs/PORTING.md), unbuilt).
- **tmux** — the target must run inside tmux (a plain PTY can't be driven; the kernel blocks keystroke
  injection and the screen buffer lives client-side).
- **jq** — for transcript reading.
- **bash ≥ 4.1** — the script uses named file descriptors and associative arrays; stock macOS bash 3.2
  is too old (install a newer bash and run overseer under it).
- **Claude Code** — this is a plugin for it.
- **Codex** *(optional)* — to drive Codex panes as well; Claude-only setups need nothing extra.

## Install

From inside Claude Code:

```
/plugin marketplace add saigonbaddielover/sgbl-overseer
/plugin install overseer@sgbl
```

That installs the skill, the `overseer` script, and the turn-done hook together (make sure the
requirements above are present). Then just ask Claude things like *"read the latest from the claude in
my other tmux pane"* or *"reply to it with X"* — the skill triggers on its own.

## Updating

```
/plugin marketplace update sgbl   # re-fetch the marketplace from GitHub
/plugin update overseer           # pull the new version into the plugin cache
/reload-plugins                   # activate it in the current session — no restart
```

## Commands

All work goes through one script; the agent calls it as
`bash "${CLAUDE_PLUGIN_ROOT}/skills/overseer/scripts/overseer" <command> [args]`.
`<target>` is a tmux pane id (`%3`) or a session/window name (its active pane).

| Command | Effect |
|---|---|
| `list [--all]` | List agent panes + their **HARNESS** (claude/codex). `--all`: every pane + its foreground command. |
| `read <target>` | Print the last user prompt + last assistant reply from the agent's transcript (Claude or Codex, auto-detected). |
| `peek [raw\|-e] <target> [lines]` | Dump the pane's current screen. `raw` (also `-e`/`--raw`) keeps ANSI colors (see the active tab/selection) and prints the whole screen; plain mode drops blank lines and honours `[lines]`. |
| `chat [--yes] [--force] <target> <msg\|-> [timeout]` | **Agent (Claude/Codex).** Send, wait for the turn to finish, print the reply. If the agent stops at a prompt, returns its question + how to answer instead. |
| `send [--yes] [--force] <target> <msg\|->` | **Agent (Claude/Codex).** Place + submit, confirm the turn started (so a following `wait` doesn't race), don't wait for the reply. |
| `wait <target> [timeout]` | **Agent (Claude/Codex).** Block until the current turn finishes — or return early if the agent stops at a prompt awaiting input. |
| `fleet [status\|read\|wait\|send\|chat] [args]` | **Every agent pane at once** (no subcommand = `status`). `status` = one line each (harness + `idle`/`busy`/`awaiting`, plus `idle(0-turn)` for a started-but-unused agent and `(not an agent)` for a pane that stopped being one); `read`; `wait [timeout]`; `send`/`chat [--yes] [--force] <msg>` **broadcast** the same message to all agent panes. A thin fan-out over the per-pane commands — each pane keeps its own guards, and one failing pane never aborts the batch. |
| `quit <target>` | **Agent (Claude/Codex).** Exit the TUI (Claude: two Ctrl-C; Codex: one), revealing the shell, keeping tmux/pane alive. |
| `slash <target> </cmd>` | **Agent (Claude/Codex).** Run a slash command (`/model`, `/status`, ...; Claude also `/resume`, `/clear`) that `send`/`chat` can't. The leading `/` is optional — `slash <target> resume` works too. |
| `menu <target> <item> [nav-key]` | **Any pane.** Navigate a tab bar / list until `<item>` is highlighted (verify-driven). Default nav key `Right` suits a Claude tab bar; Codex popups are vertical — pass `Down`. |
| `sh <target> <command> [timeout]` | **Shell.** Run one command line, wait, print output + exit code. |
| `keys <target> <key>...` | Send raw tmux keys (`Enter`, `Escape`, `Up`, `C-c`, ...). Any pane. |
| `doctor [--live]` | Preflight: check Linux/`/proc`, `tmux`, `jq`, `codex`, and that Claude/Codex session state is where discovery expects it. `--live` (also plain `live`) additionally drives a throwaway pane through a `sh` round-trip to verify the send/capture path end to end; a failing `--live` check makes `doctor` exit non-zero. |
| `deploy <host>` | **Remote (SSH).** Copy overseer's `scripts/` to `~/.overseer` on a remote ssh host (via `ssh`+`tar`) so `on` can run there. `<host>` is any ssh target — a `user@host`, a `~/.ssh/config` alias, or a Tailscale MagicDNS name. Run once per host (re-run to update). |
| `on <host> <command> [args]` | **Remote (SSH).** Run any overseer command on a remote host over ssh and stream the result back — the *whole* program runs remote-side, where its tmux/`/proc`/transcript reads are all co-located, so discovery and completion detection work unchanged. Blocking `chat`/`wait`/`sh` hold one ssh connection while they poll remote-side; one-shots reuse a multiplexed master (`ControlPersist`). Pass `--yes` for remote auto-submit (the confirm gate has no tty over ssh). e.g. `on sandbox chat %0 'hi'`, `on sandbox doctor`. |

`--yes` auto-submits (skips the confirm gate); `--force` skips the mid-turn guard. Pass `-` as the
message to read a long, multi-line prompt from stdin.

Two environment variables tune the defaults (both validated at startup, so a bad value fails loudly):
`OVERSEER_TIMEOUT` (default `600`) is the fallback `[timeout]` seconds for `chat`/`wait`/`sh`, and
`OVERSEER_POLL_INTERVAL` (default `0.25`) is the poll cadence in seconds. Two more point overseer at
non-default state directories: `CLAUDE_HOME` (default `~/.claude`) and `CODEX_HOME` (default `~/.codex`),
used to find session files, transcripts and the hook markers.

## Remote (SSH / Tailscale)

To drive a pane on another Linux box — e.g. across a Tailscale tailnet — run the whole overseer program
on that host over ssh, so its tmux/`/proc`/transcript reads stay co-located and every command behaves as
it does locally. Deploy once, then prefix any command with `on <host>`:

```
overseer deploy sandbox                  # copy scripts to sandbox:~/.overseer (ssh + tar)
overseer on sandbox doctor               # remote preflight: tmux + a running agent + jq + ssh key
overseer on sandbox chat --yes %0 'hi'   # drive the remote agent; the reply streams back
```

`<host>` is any ssh target (a `user@host`, a `~/.ssh/config` alias, or a Tailscale MagicDNS name);
credentials are ssh's own — no daemon, DB, or token store. overseer adds `ControlMaster`+`ControlPersist`
so bursts of one-shot commands reuse one connection. A blocking `chat`/`wait`/`sh` polls remote-side and
ssh just holds the pipe, so no separate event channel is needed. Pass `--yes` for a remote `chat`/`send`:
without a tty the confirm gate can't prompt, so it fails closed. Overrides: `OVERSEER_REMOTE_BIN`
(default `~/.overseer/scripts/overseer`), `OVERSEER_SSH`, `OVERSEER_SSH_OPTS`. Native Windows is out of
scope (no `/proc`, no native tmux) — run the agent inside WSL2 and target that as ordinary Linux.

## How it works

- **Delivery** is one atomic **bracketed paste**, verified before submit — uniform for one line, many
  lines, or a line wider than the pane, and a ghost autocomplete can never interleave. A Claude message
  whose first char is `/ ! # @` gets one leading space (Claude trims it back off) so it stays literal;
  for Codex a message starting with `!` is **refused** — Codex runs `!…` as a shell command by design,
  so use `sh <target> '<cmd>'` (or reword) — and an `@`-mention token can pop its file picker (`peek` +
  `keys` to recover).
- **Turn completion** (`chat`/`wait`) comes from the transcript, never the on-screen spinner (a
  finished turn leaves a stale spinner line): for Claude, an assistant message whose `stop_reason`
  isn't `tool_use`; for Codex, a `task_complete` event in the rollout jsonl.
- **Blocked on a prompt** is detected from the screen: if the agent stops at a permission / plan /
  select prompt (a cursor `❯`/`›` on a line of **two or more** numbered options), `chat`/`wait` return
  its question + options rather than hanging to timeout — you answer with `keys`/`menu` (pick) or `send`
  (free-text). The detector first cancels tmux copy-mode, so a pane you scrolled up still reports its
  live state. A single-option or unnumbered y/n prompt is **not** matched — see the limits below.
- **Agent exits mid-turn** (a crash, a `quit`, or the pane being killed): `chat`/`wait` notice the pane
  is no longer running an agent and fail fast with a clear message, instead of waiting out the whole
  timeout for a reply that will never come. (A hung-but-alive turn is still bounded by the timeout.)
- **Concurrent invocations are serialized per pane.** Every command that types into a pane
  (`send`/`chat`/`sh`/`quit`/`slash`/`menu`) takes a `flock` on that pane first, so two overseer runs
  can't interleave keystrokes into the same box; the lock is released before the reply wait, so a long
  `chat` doesn't block a `read`. Where `flock` is missing — or the lock is still contended after 30s —
  it proceeds unlocked rather than failing.
- **Harness detection** is by pane process: a Claude pane owns `~/.claude/sessions/<pid>.json`; a Codex
  pane has a descendant process named `codex` (so a 0-turn Codex is detected before it opens a rollout).
  Codex's transcript is the `~/.codex/sessions/**/rollout-*.jsonl` the process holds open, read straight
  off `/proc/<pid>/fd`. Note `list` and `fleet` additionally pre-filter panes on their foreground command
  (`claude`/`node`) for speed, so an agent launched under some other wrapper can be missing from those
  listings while still being fully drivable by its `%N`.
- **`sh` completion** is a pair of unique sentinel lines bracketing the command — prompt-agnostic, no
  `PS1` assumption, and the leading sentinel keeps the shell's own echo of the command out of the
  output. Pagers are neutralized and stdin is `/dev/null`, so `git log`/`man`/`cat` won't hang. If the
  output was long enough that the *opening* sentinel scrolled out of the pane's history, `sh` says so
  and prints the exit code without the (unreconstructable) output — re-run redirecting to a file.

### Event mode (bundled)

The plugin ships three hooks (one shared script, `hooks/turn-done.sh`) so overseer wakes on events
instead of polling: `Stop` touches `~/.claude/turn-done/<session_id>` (turn ended → `chat`/`wait` wake
in ~0.25s not ~2s), `UserPromptSubmit` touches `turn-started/<session_id>` (so a `send` confirms the
turn started with no sub-second race), and `Notification` touches `awaiting/<session_id>` (so `chat`/`wait`
surface a permission/menu prompt the moment it appears). They are wired **automatically** on install — no
`settings.json` editing. Every signal is only an accelerator: the transcript stays the source of truth
(an answer is never read half-written) and the on-screen prompt stays the arbiter for awaiting, so a
session the hooks do not cover — or a Codex pane, which has none — just falls back to polling, never
worse. The fast path assumes the driven Claude session shares overseer's `~/.claude` (`CLAUDE_HOME`);
one running as another user, under a custom `CLAUDE_HOME`, or started before the plugin was installed
simply polls (~2s slower), never blocked.

## Caveats

- **Linux only** (`/proc`).
- **Depends on each agent's internal on-disk layout** — Claude (`~/.claude/sessions/*.json`,
  `~/.claude/projects/*/*.jsonl`) and Codex (`~/.codex/sessions/**/rollout-*.jsonl`) — undocumented and
  may change between releases. If a release breaks discovery, open an issue.
- The target program must run **inside tmux**.
- **Awaiting-input detection covers numbered menus** — a cursor (`❯`/`›`) on **two or more** numbered
  options, which is how Claude and Codex render permission/approval and most select prompts. Two shapes are
  therefore not auto-detected. A prompt with a *single* numbered option, or a bare y/n prompt with no
  numbering at all, falls below the two-option floor that keeps the detector off ordinary prose. And a
  *searchable* picker that drops the numbers (e.g. a type-to-filter list, or Codex's `@`-mention list) is
  **intentionally** excluded: those are input-box UI you open by typing (`@`, a slash command), not a state a
  turn ends in, and their chrome (a leading `>`/`›`, an "esc to cancel" footer) overlaps a normal reply's
  markdown, so auto-detecting them would risk false-positives on real answers. In both cases `chat`/`wait`
  run to timeout instead of returning early — `peek` the pane and drive it with `keys`.
- **`overseer doctor` self-checks** the awaiting detector against a sample menu (catches a broken UTF-8
  locale); **`overseer doctor --live`** additionally spins up a throwaway pane and runs a `sh` round-trip
  through it, verifying the send-keys/capture-pane path end to end.

## Compatibility

Last verified live against **Claude Code 2.1.215** and **Codex 0.144.6**. Because overseer reads each
agent's internal on-disk layout (above), an upstream update *could* change that layout and break
discovery. Rather than pin exact versions, `overseer doctor` prints the running versions and then
*probes the contract directly*: it runs overseer's own transcript readers against the newest on-disk
session and warns only when a session that has completed turns can't be read — a real schema shift, not
a version-number bump. Run it after an update, and if it warns, open an issue with its output. There is
no plugin manifest field to pin an agent version, so compatibility is tracked here + in `doctor`, not
enforced — the plugin never hard-blocks on version.

## Troubleshooting

Run the preflight first:

```
overseer doctor        # or: bash "$CLAUDE_PLUGIN_ROOT/skills/overseer/scripts/overseer" doctor
```

- **"no claude pane for target"** → the pane isn't a Claude session, or you targeted the wrong one.
  `overseer list --all` shows every pane and its command; target a specific pane by its `%N`.
- **`doctor` warns about `~/.claude/sessions/*.json`** → either no Claude session is running, or a
  Claude Code update changed its on-disk layout (which breaks discovery). Open an issue with the
  `doctor` output and your `claude --version`.
- **Nothing gets driven** → the target must run **inside tmux** (a plain terminal can't be driven), and
  you must run overseer from **outside** that pane's tmux client.

## Uninstall

```
/plugin uninstall overseer@sgbl
```

## Development

Clone and add as a **local marketplace**:

```
git clone https://github.com/saigonbaddielover/sgbl-overseer
/plugin marketplace add ./sgbl-overseer
/plugin install overseer@sgbl
```

Validate locally (CI can't run `claude plugin validate` — the CLI isn't on the runner):

```
claude plugin validate --strict ./overseer
bash tests/run.sh
```

Releasing is automatic: bump the version in **both** manifests, land the PR, and the `autotag` workflow
tags `overseer--v<version>` on `main` and publishes the GitHub Release. CI fails a version bump that
arrives without a matching `CHANGELOG.md` heading.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the branch → PR → merge flow (`main` is protected). Design
notes: [why overseer stays one bash program](docs/DECISIONS.md) · [porting beyond Linux](docs/PORTING.md).

### Useful Claude Code commands

- `/reload-plugins` — apply an overseer update or a local `hooks/`/skill edit in the current session, no restart.
- `/reload-skills` — pick up a `SKILL.md` text edit on disk.
- `/hooks` — confirm the bundled `Stop` hook (`turn-done.sh`) is wired.
- `/plugin` — enable / disable / inspect / update overseer interactively.
- `/release-notes` — see what changed when Claude Code itself updates (the upstream this reads).

## License

[MIT](LICENSE) © saigonbaddielover
