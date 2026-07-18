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

- **Linux** — agent discovery reads `/proc` (macOS/Windows not supported yet).
- **tmux** — the target must run inside tmux (a plain PTY can't be driven; the kernel blocks keystroke
  injection and the screen buffer lives client-side).
- **jq** — for transcript reading.
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
| `peek [raw] <target> [lines]` | Dump the pane's current screen. `raw` keeps ANSI colors (see the active tab/selection). |
| `chat [--yes\|--force] <target> <msg\|-> [timeout]` | **Agent (Claude/Codex).** Send, wait for the turn to finish, print the reply. |
| `send [--yes\|--force] <target> <msg\|->` | **Agent (Claude/Codex).** Place + submit the message, don't wait. |
| `wait <target> [timeout]` | **Agent (Claude/Codex).** Block until the current turn finishes. |
| `quit <target>` | **Agent (Claude/Codex).** Exit the TUI (Claude: two Ctrl-C; Codex: one), revealing the shell, keeping tmux/pane alive. |
| `slash <target> </cmd>` | **Agent (Claude/Codex).** Run a slash command (`/model`, `/status`, ...; Claude also `/resume`, `/clear`) that `send`/`chat` can't. |
| `menu <target> <item> [nav-key]` | **Agent (Claude/Codex).** Navigate a tab bar / list until `<item>` is highlighted (verify-driven). Codex popups are vertical — pass `Down`. |
| `sh <target> <command> [timeout]` | **Shell.** Run one command line, wait, print output + exit code. |
| `keys <target> <key>...` | Send raw tmux keys (`Enter`, `Escape`, `Up`, `C-c`, ...). Any pane. |
| `doctor` | Preflight: check Linux/`/proc`, `tmux`, `jq`, `codex`, and that Claude/Codex session state is where discovery expects it. |

`--yes` auto-submits (skips the confirm gate); `--force` skips the mid-turn guard. Pass `-` as the
message to read a long, multi-line prompt from stdin.

## How it works

- **Delivery** is one atomic **bracketed paste**, verified before submit — uniform for one line, many
  lines, or a line wider than the pane, and a ghost autocomplete can never interleave.
- **Turn completion** (`chat`/`wait`) comes from the transcript, never the on-screen spinner (a
  finished turn leaves a stale spinner line): for Claude, an assistant message whose `stop_reason`
  isn't `tool_use`; for Codex, a `task_complete` event in the rollout jsonl.
- **Harness detection** is by pane process: a Claude pane owns `~/.claude/sessions/<pid>.json`; a Codex
  pane has a descendant process named `codex` (so a 0-turn Codex is detected before it opens a rollout).
  Codex's transcript is the `~/.codex/sessions/**/rollout-*.jsonl` the process holds open, read straight
  off `/proc/<pid>/fd`.
- **`sh` completion** is a unique sentinel line appended after the command — prompt-agnostic, no `PS1`
  assumption. Pagers are neutralized and stdin is `/dev/null`, so `git log`/`man`/`cat` won't hang.

### Event mode (bundled)

The plugin ships a `Stop` hook (`hooks/turn-done.sh`) that touches `~/.claude/turn-done/<session_id>`
so `chat`/`wait` wake the instant a turn ends instead of polling (~2s). It is wired **automatically**
on install — no `settings.json` editing. The transcript stays the source of truth for the reply, so an
answer is never read half-written; without the hook it simply falls back to polling.

## Caveats

- **Linux only** (`/proc`).
- **Depends on each agent's internal on-disk layout** — Claude (`~/.claude/sessions/*.json`,
  `~/.claude/projects/*/*.jsonl`) and Codex (`~/.codex/sessions/**/rollout-*.jsonl`) — undocumented and
  may change between releases. If a release breaks discovery, open an issue.
- The target program must run **inside tmux**.

## Compatibility

Verified against **Claude Code 2.1.214** and **Codex 0.144.5**. Because overseer reads each agent's
internal on-disk layout (above), an upstream update *could* change that layout and break discovery.
`overseer doctor` prints the running Claude Code / Codex versions and warns when either drifts from its
tested baseline — run it after an update, and if discovery misbehaves, open an issue with its output.
There is no plugin manifest field to pin an agent version, so compatibility is tracked here + in
`doctor`, not enforced — the plugin never hard-blocks on version.

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

Validate, then cut and push a release tag — CI publishes the GitHub Release automatically:

```
claude plugin validate --strict ./overseer
claude plugin tag ./overseer --push   # tags overseer--v<version>, pushes it, release workflow does the rest
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the branch → PR → merge flow (`main` is protected).

### Useful Claude Code commands

- `/reload-plugins` — apply an overseer update or a local `hooks/`/skill edit in the current session, no restart.
- `/reload-skills` — pick up a `SKILL.md` text edit on disk.
- `/hooks` — confirm the bundled `Stop` hook (`turn-done.sh`) is wired.
- `/plugin` — enable / disable / inspect / update overseer interactively.
- `/release-notes` — see what changed when Claude Code itself updates (the upstream this reads).

## License

[MIT](LICENSE) © saigonbaddielover
