# overseer

**One agent that oversees others.** Drive and read other agent sessions — and plain shells — running
in **tmux panes**, turn-based, from outside them. Packaged as a
[Claude Code plugin](https://code.claude.com/docs/en/plugins).

The overseer opens (or attaches) a tmux pane, launches an agent harness in its shell, then reads and
drives that sub-agent turn-based — while also being able to run shell commands directly. Today it
speaks **Claude Code** (plus any shell); it's built so other harnesses can be added behind the same
commands.

A running Claude Code TUI has no API — its only input channel is the keyboard. `overseer` wraps a
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

## Install

From inside Claude Code:

```
/plugin marketplace add saigonbaddielover/sgbl-overseer
/plugin install overseer@sgbl
```

That installs the skill, the `overseer` script, and the turn-done hook together (make sure the
requirements above are present). Then just ask Claude things like *"read the latest from the claude in
my other tmux pane"* or *"reply to it with X"* — the skill triggers on its own.

## Commands

All work goes through one script; the agent calls it as
`bash "${CLAUDE_PLUGIN_ROOT}/skills/overseer/scripts/overseer" <command> [args]`.
`<target>` is a tmux pane id (`%3`) or a session/window name (its active pane).

| Command | Effect |
|---|---|
| `list [--all]` | List panes running a claude agent. `--all`: every pane + its foreground command. |
| `read <target>` | Print the last user prompt + last assistant reply from a claude session's transcript. |
| `peek [raw] <target> [lines]` | Dump the pane's current screen. `raw` keeps ANSI colors (see the active tab/selection). |
| `chat [--yes\|--force] <target> <msg\|-> [timeout]` | **Claude.** Send, wait for the turn to finish, print the reply. |
| `send [--yes\|--force] <target> <msg\|->` | **Claude.** Place + submit the message, don't wait. |
| `wait <target> [timeout]` | **Claude.** Block until the current turn finishes. |
| `quit <target>` | **Claude.** Exit the TUI (two Ctrl-C), revealing the shell, keeping tmux/pane alive. |
| `slash <target> </cmd>` | **Claude.** Run a slash command (`/resume`, `/model`, ...) that `send`/`chat` can't. |
| `menu <target> <item> [nav-key]` | **Claude.** Navigate a tab bar / list until `<item>` is highlighted (verify-driven). |
| `sh <target> <command> [timeout]` | **Shell.** Run one command line, wait, print output + exit code. |
| `keys <target> <key>...` | Send raw tmux keys (`Enter`, `Escape`, `Up`, `C-c`, ...). Any pane. |

`--yes` auto-submits (skips the confirm gate); `--force` skips the mid-turn guard. Pass `-` as the
message to read a long, multi-line prompt from stdin.

## How it works

- **Delivery** is one atomic **bracketed paste**, verified before submit — uniform for one line, many
  lines, or a line wider than the pane, and a ghost autocomplete can never interleave.
- **Turn completion** (`chat`/`wait`) is an assistant transcript message whose `stop_reason` isn't
  `tool_use` — never the on-screen spinner (a finished turn leaves a stale spinner line).
- **`sh` completion** is a unique sentinel line appended after the command — prompt-agnostic, no `PS1`
  assumption. Pagers are neutralized and stdin is `/dev/null`, so `git log`/`man`/`cat` won't hang.

### Event mode (bundled)

The plugin ships a `Stop` hook (`hooks/turn-done.sh`) that touches `~/.claude/turn-done/<session_id>`
so `chat`/`wait` wake the instant a turn ends instead of polling (~2s). It is wired **automatically**
on install — no `settings.json` editing. The transcript stays the source of truth for the reply, so an
answer is never read half-written; without the hook it simply falls back to polling.

## Caveats

- **Linux only** (`/proc`).
- **Depends on Claude Code's internal on-disk layout** (`~/.claude/sessions/*.json`,
  `~/.claude/projects/*/*.jsonl`) — undocumented and may change between Claude Code releases. If a
  release breaks discovery, open an issue.
- The target program must run **inside tmux**.

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

Validate and cut a release tag:

```
claude plugin validate --strict ./overseer
claude plugin tag ./overseer        # creates overseer--v<version>
```

## License

[MIT](LICENSE) © saigonbaddielover
