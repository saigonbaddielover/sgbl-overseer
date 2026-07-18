---
name: overseer
description: Read or drive ANOTHER live process in a tmux pane from outside it — a running Claude Code session or a plain shell. Use when the user wants to see the latest conversation of a claude in a tmux pane they are watching, send a message / reply on their behalf to it, run a command turn-based in a shell pane they are watching, or list which tmux panes are running what. Works on any pane the user watches, including tmux attached from a VSCode Remote-SSH terminal (tmux is server-side, so display location is irrelevant). Linux + tmux only; a plain non-tmux terminal cannot be driven.
---

# overseer — read and drive a live tmux pane (Claude Code, or a plain shell)

A running Claude Code TUI cannot be talked to programmatically — the only input channel
is the keyboard. This skill wraps a deterministic, self-verifying `tmux send-keys` /
`capture-pane` procedure plus transcript reading, so you can read and drive another
claude session — or run commands turn-based in a plain shell — that the user is watching
in a tmux pane. It works the same whether the pane is on this box or displayed on the
user's machine over VSCode Remote-SSH, because tmux is server-side here.

All work goes through one bundled script:

```
bash "${CLAUDE_PLUGIN_ROOT}/skills/overseer/scripts/overseer" <command> [args]
```

`<target>` is either a tmux pane id (`%3`) or a session/window name (**its active pane** — so every
command acts on the same one pane; in a split window, target a background claude pane by its `%N`).
`<message>` may be a literal string or `-`, which reads the whole message (a long, multi-line prompt)
from stdin.

| Command | Effect | Safe? |
|---|---|---|
| `list [--all]` | List tmux panes running a claude agent (session, pane, pids, cwd). `--all` lists **every** tmux pane and its foreground command — use it to find shell panes to target. | read-only |
| `read <target>` | Print the last user prompt + last assistant reply from a claude session's transcript (`~/.claude/projects/<enc-cwd>/<sid>.jsonl`), resolved via the pane pid. | read-only |
| `peek [raw] <target> [lines]` | Dump the pane's current screen. Default: the **whole** visible screen (a feature panel like `/status` fills it). `raw` keeps ANSI colors so the **active tab / selected row** — a reverse-video or background highlight, invisible in plain text — is readable. A trailing number caps plain output to the last N lines. Any pane. | read-only |
| `chat [--yes\|--force] <target> <message\|-> [timeout]` | **Claude pane.** Send the message, **wait for the turn to finish**, then print the reply. The human round-trip. `--force` skips the mid-turn guard. | **SIDE EFFECT** |
| `send [--yes\|--force] <target> <message\|->` | **Claude pane.** Place + submit the message, do **not** wait (fire-and-forget). `--force` skips the mid-turn guard. | **SIDE EFFECT** |
| `wait <target> [timeout]` | **Claude pane.** Block until the target's current turn finishes. | read-only |
| `quit <target>` | **Claude pane.** Exit the Claude TUI (two Ctrl-C) to reveal the shell underneath, **keeping tmux and the pane alive**; confirms the pane left claude. | **SIDE EFFECT** |
| `slash <target> </cmd>` | **Claude pane.** Run a Claude slash command (`/resume`, `/clear`, `/model`, ...) — which `send`/`chat` can't, since they keep a leading `/` literal. A command that opens a menu is then navigated with `menu`/`keys`. | **SIDE EFFECT** |
| `menu <target> <item> [nav-key]` | **Claude pane.** Drive a tab bar / highlighted list until `<item>` is the active one, verify-driven (one key → re-read highlight → repeat; never counts keys). Default key `Right` (a tab bar); pass `Down` for a vertical list. Does not select — follow with `keys <t> Enter`. | **SIDE EFFECT** |
| `sh <target> <command> [timeout]` | **Shell pane.** Run one command line, **wait for it to finish**, print its output + exit code. Pagers are neutralized (`git log`/`man`/`less` won't seize the pane) and stdin is `/dev/null` (a command that reads stdin won't hang); on timeout it Ctrl-C's the pane so it isn't left stuck. `cd`/`export` still persist. Refuses if the pane is not an idle shell. | **SIDE EFFECT** |
| `keys <target> <key>...` | Send raw tmux keys (`Enter`, `Escape`, `y`, `Up`, `C-c`, ...) to answer a prompt/menu or interrupt. Any pane. | **SIDE EFFECT** |

`chat`/`send`/`wait` are for a Claude Code TUI (they read its transcript to know a turn ended). `sh`
is for a plain shell (it appends a unique sentinel line and waits for it — prompt-agnostic). `read`
is claude-only; `peek`, `keys`, `list --all`, and `sh` work on any pane.

Every message is placed by **bracketed paste** — atomic (tmux sends the exact bytes at once), so it
handles one line, many lines, and lines wider than the pane uniformly, and a ghost suggestion can
never interleave. It is verified before submit: an exact match when it fits on one row, else a
`[Pasted text #N +M lines]` chip whose line count must match, else non-empty content (a long line
that wrapped). Pipe long prompts in:

```
bash "${CLAUDE_PLUGIN_ROOT}/skills/overseer/scripts/overseer" chat --yes <target> - <<'EOF'
first paragraph of a long prompt...

more lines...
EOF
```

## When to use which

- "What is that claude working on / show its latest chat" → `read` (transcript is clean;
  prefer it over `peek`, which is a noisy TUI screenshot).
- "Which sessions/panes are running" → `list` (claude panes) or `list --all` (every pane).
- "Ask it X and tell me what it says" → `chat` (sends, waits, returns the answer).
- "Reply to it / send it X on my behalf" → `chat` (or `send` if you do not need the reply),
  under the rules below.
- "Run this in the terminal I'm watching" (a plain shell pane) → `sh` (runs it, waits, returns
  output + exit code — so the user sees it happen live and you get the result).
- "Quit that claude but keep the terminal" → `quit` (the two Ctrl-C taps must be close together, so
  it does them itself; sending them across separate calls arrives too late). After it, the pane is a
  plain shell you drive with `sh`.
- "Run /resume /clear /model ... in that claude" → `slash` (not `send`/`chat` — they keep `/` literal).
  Then read the menu with `peek` and drive it with `keys` (Up/Down, Enter to pick, Esc to cancel).
- It is showing a y/n prompt or a menu, or needs interrupting → `keys`.

## Scope: tmux panes only

This drives panes running under **tmux** (tmux is client/server, so a pane attached from a VSCode
Remote-SSH terminal is driven server-side and the user still sees it live). A **plain, non-tmux
terminal cannot be driven**: the kernel blocks keystroke injection into a bare PTY
(`dev.tty.legacy_tiocsti=0`) and its screen buffer lives in the client (e.g. xterm.js on the user's
machine), not here. To make such a terminal drivable, run it inside tmux.

## How completion is detected

`chat`/`wait` know a turn ended by watching for an assistant message whose `stop_reason` is not
`tool_use` in the transcript (a turn = zero or more tool_use messages then one terminal message).
If **event mode** is installed (see below) a `Stop` hook also fires the moment a turn ends, so the
wait wakes immediately instead of at the next poll; the transcript is still the source of truth for
the reply, so the answer is never read half-written. Without the hook it falls back to polling.
Do **not** use the on-screen spinner to judge done — a finished turn leaves a stale
`Brewed/Churned for Ns` line on screen.

`sh` is different: it appends `; printf '\n<token>:<exit>\n'` to the command and waits for that
unique sentinel line to appear (then reads the output between the command echo and the sentinel).
This is prompt-agnostic — it does not depend on knowing the shell's `PS1`.

## Navigating a Claude feature screen (`/status`, `/resume`, `/model`, ...)

Many slash commands open a **tabbed and/or scrollable** panel, not a single static view. Read the
WHOLE thing, do not stop at the first screen. The reliable loop:

1. Open it with `slash <t> /status`, then `peek <t>` — default `peek` shows the **full** screen, so a
   tall panel is not truncated.
2. To see **which tab or row is active**, use `peek raw <t>`. The active item is a reverse-video
   (`ESC[7m`) or background-color (`ESC[48;5;Nm`) highlight — **plain `peek` cannot show it**, so
   navigating by plain text alone is flying blind.
3. **To reach a named tab/row, use `menu <t> <item>`** — it does the reliable thing for you: press
   one key, re-read the highlight, repeat until `<item>` is active (default key `Right`; pass `Down`
   for a vertical list). It stops itself once the view cycles back to a screen already seen, so a
   wrong or absent name fails fast instead of looping, and the item name is matched literally (regex
   metacharacters like `()` are safe). It does **not** select — follow with `keys <t> Enter` to pick. Do this
   **instead of counting keystrokes**, which is unreliable: a keypress can register as two, and a tab
   bar **wraps around**, so an off-by-one is silent. (If you must navigate by hand, follow the same
   loop: one key → `peek raw` → check the highlight → repeat.)
4. Keys: tabs switch with `Left`/`Right` (or `Tab`); lists move with `Up`/`Down`; `Enter`/`Space`
   selects or toggles; `Esc` closes. A long list shows `↓ N more below` / `↑ N above` — scroll with
   `Down` and re-`peek` until the indicator is gone. Then close with `keys <t> Escape`.
5. Not every word in a header bar is a navigable tab — e.g. `/status` prints "Settings" as the panel
   **title**; only Status / Config / Usage / Stats take the highlight and cycle. `peek raw` tells you
   which ones actually get selected.

## Safety rules for `send`/`sh` (READ BEFORE SENDING)

1. **The target almost always runs with bypass permissions on** (`--dangerously-skip-permissions`).
   Anything you submit auto-executes in that agent with no confirmation gate. Treat `send`
   as running a command on a machine you do not control.
2. **Never `send` unless the user explicitly asked you to send that specific message.** Reading
   is fine to do proactively; sending is not.
3. **Do not pass `--yes`** unless the user explicitly authorized auto-submit. Without `--yes` the
   script types the message, verifies the input box contains exactly it, then waits for a
   keypress — relay the verified text to the user and get their confirmation before continuing.
4. Any length is fine (see the intro): everything is placed by bracketed paste and verified before
   submit. A first line starting with `/ ! # @` would open the TUI's command/bash/memory/file mode,
   so the script prepends one space to dodge that — Claude Code trims it back off, so the message
   still arrives literally.
5. **`sh` auto-executes the command in the user's shell** the instant it is called (there is no
   confirm gate). Only use it when the user asked you to run that command in the terminal they are
   watching. It refuses any pane that is not an idle shell (so it never types into a running program
   or a claude TUI), and runs **one command line** — chain with `;` or `&&`.
6. **`send`/`chat` refuse a session that is mid-turn** (its last transcript entry is a `tool_use`) to
   avoid typing into a busy agent. If you get "session looks mid-turn", either `wait <t>` for it to
   finish, or interrupt it with `keys <t> Escape`, then retry. If it is **actually idle** — a turn was
   aborted while a tool was running, leaving `tool_use` as the last entry (a false-busy deadlock) —
   rerun with `--force` to bypass the guard.

## Gotchas the script already handles (do not re-derive)

- **Never trust the spinner** to tell busy from idle. A finished turn leaves a stale
  `Brewed for Ns · N shells still running` line on screen. The reliable idle signal is a
  **dim ghost suggestion** in the input box — Claude Code only shows it while awaiting input.
- **Ghost suggestion vs. real typed text**: the ghost is rendered dim (`ESC[2m`). `capture-pane -e`
  keeps the color; the script uses it to tell an empty box (only ghost) from real content, so a
  suggestion can never be mistaken for, or mixed into, your message.
- **A non-breaking space (U+00A0) sits between `❯` and the text** — normalized before comparing.
- **The TUI renders with lag**: wait for a *specific condition* (the text appearing), never for
  "the screen stopped changing" — two identical captures usually mean "still stale", not "done".
- **The user scrolling the pane up** (tmux copy-mode) would otherwise freeze capture on the scrolled
  view and swallow keys — the script cancels copy-mode before any read/write, so driving works even
  while they scroll to read.
- **Control bytes in a message** (a raw ESC, or an embedded `\e[201~` paste-end marker) are stripped
  before the bracketed paste, so pasted content can't terminate the paste early and inject keystrokes.
- **The input line is read at the cursor row** (`#{cursor_y}`), not "the last `❯` on screen", so a
  menu/autocomplete that draws its own `❯` below the box can't be mistaken for the prompt.
- **A brand-new session with 0 turns has no transcript yet** — `chat`/`read`/`wait` can't resolve it;
  send its first message with `send` (needs no transcript), and after one turn the rest work.

## Event mode (turn-done hook — bundled, faster `chat`/`wait`)

By default `chat`/`wait` poll the transcript (correct, ~2s worst-case latency). To wake the instant a
turn ends, the plugin ships a `Stop` hook (`hooks/hooks.json` → `${CLAUDE_PLUGIN_ROOT}/hooks/turn-done.sh`)
that touches `~/.claude/turn-done/<session_id>`. **It is wired automatically when the plugin is
installed** — no `settings.json` editing. A user-scope install covers every session; there is no
project-scope walk-up caveat (that only bites a hook placed in a single project's `.claude/settings.json`
by hand, which does not apply here).

The waiter reads `~/.claude/turn-done/<session_id>`'s mtime as the last turn-end time (the file is
reused per session — no unbounded growth), but the transcript is still the source of truth for the
reply, so an answer is never read half-written. A session the hook does not cover just falls back to
polling — nothing breaks.

## Requirements

- Linux (uses `/proc` to map pane pid → agent pid → sessionId) and `tmux`; `jq` for `read`/`chat`.
- Run from **outside** the target session's tmux client (this is normal — you drive it from a
  separate shell).

## Install

Distributed as a Claude Code plugin. From inside Claude Code:

```
/plugin marketplace add saigonbaddielover/sgbl-overseer
/plugin install overseer@sgbl
```

This installs the skill, the `overseer` script, and the turn-done hook together (the hook is wired
automatically — see Event mode). Requirements and safety notes are in the repo `README.md`.
