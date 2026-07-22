---
description: Read or drive ANOTHER live agent process from outside it — a running Claude Code or Codex session, or a plain shell — in a local or remote Linux tmux pane, or in a console window on a remote WINDOWS machine over SSH. Use when the user wants to see the latest conversation of a claude or codex they are watching, send a message / reply on their behalf to it, run a command turn-based in a shell they are watching, list which tmux panes are running what agent, create or tear down a Linux tmux session running a shell/claude/codex (start/stop), or start/drive/stop a claude, codex or pwsh on a Windows PC's visible desktop (win <host> start/chat/sh/read/stop). read/chat/send/wait/list auto-detect the harness (Claude Code or Codex). Overseer itself runs on a Linux controller; its targets are Linux tmux panes (local or over ssh) and remote native Windows console brokers. Local pane discovery is Linux + tmux only; a plain non-tmux Linux terminal cannot be driven.
---

# overseer — read and drive a live tmux pane (Claude Code, Codex, or a plain shell)

A running agent TUI (Claude Code, Codex) cannot be talked to programmatically — the only
input channel is the keyboard. This skill wraps a deterministic, self-verifying
`tmux send-keys` / `capture-pane` procedure plus transcript reading, so you can read and
drive another agent session — or run commands turn-based in a plain shell — that the user
is watching in a tmux pane. It works the same whether the pane is on this box or displayed on
the user's machine over VSCode Remote-SSH, because tmux is server-side here.

**Harnesses.** `list`, `read`, `chat`, `send`, `wait`, `quit`, `slash`, `fleet` **auto-detect** whether a
pane runs Claude Code or Codex and adapt (right transcript, right completion signal, right exit keys), so
you use the same commands for both. `peek`, `keys`, `menu`,
`sh`, `list --all` are harness-agnostic — in particular `menu` drives *any* pane by looking at what is
highlighted on screen, which is why you pass it `Down` for a vertical Codex popup. Codex specifics you may need: **quitting** takes a single
Ctrl-C (the script handles it); to **interrupt a running Codex turn** use `keys <t> Escape` — NOT
Ctrl-C, which would quit Codex when it is idle; a Codex **approval prompt** is answered with a letter
key via `keys` (`y` approve once, `a` approve for session, `d` deny). Support for more harnesses is
added behind these same commands.

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
| `list [--all]` | List tmux panes running an agent + its **HARNESS** (claude or codex): session, pane, pids, cwd. `--all` lists **every** tmux pane and its foreground command — use it to find shell panes to target. | read-only |
| `read <target>` | Print the last user prompt + last assistant reply from an agent's transcript (Claude `~/.claude/projects/.../<sid>.jsonl`, or Codex `~/.codex/sessions/.../rollout-*.jsonl`), auto-detected via the pane pid. | read-only |
| `peek [raw\|-e] <target> [lines]` | Dump the pane's current screen. Plain mode drops blank lines and a trailing number caps it to the last N lines. `raw` (also `-e`/`--raw`) keeps ANSI colors so the **active tab / selected row** — a highlight invisible in plain text — is readable; `raw` always prints the whole screen and ignores `[lines]`. Any pane. | read-only |
| `chat [--yes] [--force] <target> <message\|-> [timeout]` | **Agent pane (Claude or Codex).** Send the message, **wait for the turn to finish**, then print the reply. The human round-trip. If the agent stops at an interactive prompt (permission / plan / select menu) it returns that question + how to answer instead of hanging. `--force` skips the mid-turn guard; the two flags are independent and may be combined. | **SIDE EFFECT** |
| `send [--yes] [--force] <target> <message\|->` | **Agent pane (Claude or Codex).** Place + submit the message, then confirm the turn actually started before returning (so a following `wait`/`read` doesn't race) — but do **not** wait for the reply (use `chat` for that). `--force` skips the mid-turn guard. | **SIDE EFFECT** |
| `wait <target> [timeout]` | **Agent pane (Claude or Codex).** Block until the target's current turn finishes — or return early with the question if the agent stops at an interactive prompt awaiting your input. | read-only |
| `fleet [status\|read\|wait\|send\|chat] [args]` | **Every agent pane at once** (a fan-out over the per-pane commands; each pane is handled in isolation so one failure never aborts the batch). With no subcommand it defaults to `status`, which prints one line per pane — harness + `idle`/`busy`/`awaiting`, plus `idle(0-turn)` for an agent that hasn't taken a turn yet and `(not an agent)` for a pane that stopped being one. `read` and `wait [timeout]` fan those out; `send`/`chat [--yes] [--force] <msg>` **broadcast** the same message to all agent panes, each still subject to its own confirm/mid-turn guard. Use `status` to survey many sessions; broadcast only when the user explicitly asks to message every agent. | status/read/wait read-only · send/chat **SIDE EFFECT** |
| `quit <target>` | **Agent (Claude/Codex).** Exit the TUI to reveal the shell underneath, **keeping tmux and the pane alive** (Claude: two Ctrl-C; Codex: one), then confirms the pane returned to a shell. | **SIDE EFFECT** |
| `start <name> [shell\|claude\|codex] [workdir]` | **Create (Linux tmux).** Open a new **detached** tmux session `<name>` running a shell (default), Claude Code or Codex; for an agent it blocks until the harness has actually come up before returning. The user watches it with `tmux attach -t <name>`; you drive it with `chat`/`send`/`sh`/… Runs identically locally and via `on <host> start …`. Refuses a name outside `[A-Za-z0-9_-]`, one already in use, or a `workdir` that does not exist. | **SIDE EFFECT** (spawns a session) |
| `stop <target>` | **Delete (Linux tmux).** Tear down a `start`ed session (or any tmux target): a `%N` pane → `kill-pane` (that pane); a session name → `kill-session` (the whole session + its child, via SIGHUP). Refuses to kill the session — or, for a `%N` target, the pane — overseer is running in. The Linux peer of `win <host> stop`; use `quit` instead when you only want to leave an agent's TUI but keep the pane. | **SIDE EFFECT** (destroys a session) |
| `slash <target> </cmd>` | **Agent (Claude/Codex).** Run a slash command (`/model`, `/status`, ...; Claude also `/resume`, `/clear`) — which `send`/`chat` can't, since they keep a leading `/` literal. The leading `/` is optional (`slash <t> resume` works). A command that opens a menu is then navigated with `menu`/`keys`. | **SIDE EFFECT** |
| `menu <target> <item> [nav-key]` | **Any pane** (no harness gate — it works off what is highlighted on screen). Drive a tab bar / highlighted list until `<item>` is the active one, verify-driven (one key → re-read highlight → repeat; never counts keys). Default key `Right` (a tab bar); pass `Down` for a vertical list — Codex popups (`/model`, `/approvals`) are vertical, so use `Down`. Does not select — follow with `keys <t> Enter`. | **SIDE EFFECT** |
| `sh <target> <command> [timeout]` | **Shell pane.** Run one command line, **wait for it to finish**, print its output + exit code. Pagers are neutralized (`git log`/`man`/`less` won't seize the pane) and stdin is `/dev/null` (a command that reads stdin won't hang); on timeout it Ctrl-C's the pane so it isn't left stuck. `cd`/`export` still persist. Refuses any pane that is not an idle POSIX-ish shell (`sh`, `bash`, `zsh`, `dash`, `ksh`, `mksh`, `ash`) — its wrapper is POSIX-only, so fish/tcsh/csh/nu/xonsh/elvish are rejected up front rather than hanging to timeout. If the output outran the pane's scrollback, it reports the exit code and says the output can't be captured whole — re-run with `> out.txt 2>&1` and read the file. | **SIDE EFFECT** |
| `keys <target> <key>...` | Send raw tmux keys (`Enter`, `Escape`, `y`, `Up`, `C-c`, ...) to answer a prompt/menu or interrupt. Any pane. | **SIDE EFFECT** |
| `doctor [--live]` | Preflight the runtime: Linux + `/proc`, `tmux`, `jq`, `claude`/`codex` versions, that on-disk session state is where discovery expects it, and a contract probe that runs the real transcript readers against the newest session. `--live` (also plain `live`) additionally drives a **throwaway** pane through an `sh` round-trip. Exits non-zero on a hard requirement (not Linux, no `/proc`/`tmux`/`jq`) or on a broken contract probe or awaiting detector; a missing `claude`/`codex` CLI, no tmux server and no sessions on disk are `[warn]`s that still exit 0. Run it first when a pane "can't be found" or a command behaves oddly. | read-only (`--live` spawns and kills its own tmux session) |
| `hosts [--list] [--tailscale] [--os NAME] [-u USER] [-t secs]` | **Remote (SSH), fleet survey.** One line per host — `HOST ONLINE OS SSH DRIVE`, `HOST` = the effective **`user@host`** — so you see which machines are drivable *and as which user* before an `on`/`win`. Inventory: `$OVERSEER_HOSTS`, else `$XDG_CONFIG_HOME/overseer/hosts`, else non-wildcard `Host` entries in `~/.ssh/config`; or `--tailscale` to enumerate the tailnet (`--os windows`/`linux` filters) for machines not in ssh config. Login user for a bare host comes from `ssh -G` (so a `Host … User fleetuser` block shows through), or is forced with `-u USER` / `$OVERSEER_HOSTS_USER` for a uniform-user fleet. Probes **live and in parallel**: `SSH` = `ok`/`deny`/`unreach`, `OS` = `linux`/`windows`/`macos`, `DRIVE` = `yes` (Linux w/ `tmux`+`jq`), `no:tmux`/`no:jq`, or `win*`. `ONLINE` from `tailscale status` if present. Stateless — no cred/health store (ssh keys stay the credential; reachability recomputed each run, never cached). `--list` = inventory only, no ssh; `-t` = per-host connect timeout (default 6s). | read-only (ssh probe: `uname`, `command -v`) |
| `provision [--dry-run] <host>` | **Remote (SSH).** Install the missing Linux **drive** deps (`tmux`+`jq`) on a reachable host — the fix for a `hosts` `DRIVE=no:tmux`/`no:jq`. Detects the package manager (`apt`/`dnf`/`yum`/`pacman`/`zypper`/`apk`), installs only what's absent (idempotent), needs **root or passwordless `sudo`** (runs non-interactively). `--dry-run` prints the command instead of running it. Linux base deps only — Claude/Codex agents and every Windows prerequisite are set up by hand. | **SIDE EFFECT** (installs packages on the remote) |
| `deploy <host>` | **Remote (SSH).** Copy overseer's `scripts/` to `~/.overseer` on a remote ssh host (via `ssh`+`tar`), so `on <host> …` can run there. `<host>` is any ssh target — `user@host`, a `~/.ssh/config` alias, or a Tailscale MagicDNS name. Run once per host; re-run to update. | **SIDE EFFECT** (writes `~/.overseer` on the remote) |
| `on <host> <command> [args]` | **Remote (SSH).** Run any overseer command on a remote host over ssh — the *whole* program executes remote-side, where its tmux / `/proc` / transcript reads co-locate, so discovery and completion detection work unchanged; only the invocation and the result cross the wire. A blocking `chat`/`wait`/`sh` holds one ssh connection while it polls remote-side (no new event protocol — the remote's own hook markers/transcript are the truth); one-shots reuse a multiplexed master (`ControlMaster`+`ControlPersist`). Pass `--yes` for remote auto-submit — the interactive confirm has no tty over ssh. e.g. `on sandbox chat %0 'hi'`, `on sandbox doctor`. | inherits the wrapped command's safety |
| `win <host>[/name] <verb>` | **Remote (SSH), Windows target.** Drive a remote Windows **console broker** over plain ssh — the `win` prefix is to a Windows host what `on <host>` is to a remote Linux one. `<host>[/name]` picks the broker (`/name` runs several side by side); `<verb>` is one of the shared verbs in the table just below (**same vocabulary as the Linux commands**). A plain-SSH Windows host has no tmux; the broker is the tmux stand-in — a **visible** console child (pwsh/claude/codex) exposing a machine-wide named pipe (reachable from the invisible SSH Session 0) speaking `WriteConsoleInput`/`ReadConsoleOutputCharacter` (= `send-keys`/`capture-pane`). Needs an **admin** ssh login. Full rationale: [docs/WINDOWS.md](../../../docs/WINDOWS.md). | verbs vary (see below) |

`chat`/`send`/`wait`/`read` are for an agent TUI — Claude Code or Codex — and read its transcript to
know a turn ended (auto-detected per pane). `sh` is for a plain shell (it appends a unique sentinel
line and waits for it — prompt-agnostic). `peek`, `keys`, `list --all`, and `sh` work on any pane.

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

### Windows verbs (`win <host>[/name] <verb>`)

The Windows surface reuses the **same verb vocabulary as Linux** behind the `win` prefix (the old fused
names `winbroker`/`winchat`/`winstop`/… were folded into these). Each is the Windows peer of the Linux
command of the same name.

| verb | what it does | Safe? |
|---|---|---|
| **start** `[pwsh\|claude\|codex] [workdir]` | Start/switch a **visible broker** child on the host's console (Session-0→1 bridge). Opens in the host's Windows Terminal default dir unless `[workdir]` given; starts the child **through the user's PowerShell profile** (same env — API config, PATH, aliases). Returns once it has painted; re-run to switch child. Set `OVERSEER_WIN_CLAUDE`/`OVERSEER_WIN_CODEX` if the agent has a different command name (e.g. `OVERSEER_WIN_CLAUDE=claudeep overseer win win-host start claude`); `kind` stays `claude`/`codex`. Needs an **admin** ssh login. | **SIDE EFFECT** (spawns a visible process on the remote desktop) |
| **show** `[app]` | Open a GUI app on the host's **visible console session** (Start-menu name / AUMID / full exe path; default Windows Terminal). Bridges the invisible Session 0 to the logged-in desktop via a throwaway interactive scheduled task; works on battery; errors if nobody is at the console. Windows-only (no Linux peer). e.g. `win admin@win-host show`, `win win-host show 'Notepad'`. | **SIDE EFFECT** (opens a window on the remote desktop) |
| **list** | List the overseer brokers on the host: name, child kind, workdir, alive. Needed once several brokers run side by side (`win <host>/codex2 …`). | read-only |
| **peek** | Snapshot the broker window's screen grid (rendered child text — shell or agent TUI). | read-only |
| **keys** `<key\|text>...` | Inject named keys (`Enter` `Escape` `Up` `Down` `Tab` `Backspace` `C-c` …) or literal text into the broker child. Text is one burst; submit with a **separate** `Enter`. | **SIDE EFFECT** |
| **sh** `<command> [timeout]` | Run one command line in the broker's **pwsh** child, wait via a unique sentinel, print output + exit code. Needs `win <host> start pwsh`; **refuses a broker hosting an agent**. | **SIDE EFFECT** |
| **read** | Last user prompt + last assistant reply from the broker's claude/codex, read from its transcript with the *same* `transcript.sh` readers (fetched over ssh). Prefer over `peek` (a noisy screenshot). | read-only |
| **chat** `[--yes] [--force] <prompt\|-> [timeout]` | Send a prompt to the broker's claude/codex, submit, wait the turn via transcript, print the reply. Needs `win <host> start claude\|codex`. Same guards as Linux `chat`: refuses a **mid-turn** agent (`--force` bypasses), **refuses a Codex `!` message**, prepends a space for Claude's `/ ! # @`, verifies the pasted prompt on screen before submitting, per-host lock, returns the **question** if the agent stops at a prompt, fails fast if it dies mid-turn. Turn completion is signature-gated on the broker's reported `mtime:size`. | **SIDE EFFECT** |
| **send** `[--yes] [--force] <prompt\|->` | Like `chat` but **does not wait for the reply** — place + submit + confirm the turn *started* (so a following `wait` doesn't race), then return. Read later with `read`, or block with `wait`. Same guards as `chat`. | **SIDE EFFECT** |
| **wait** `[timeout]` | Block until the broker's agent finishes its turn, or return the **question** if it stopped at a prompt (`idle` if not busy). Resume with this after a `win <host> chat`/`send` timeout instead of re-sending. | read-only |
| **slash** `</cmd>` | Run a slash command (`/model`, `/status`, …) in the broker's claude/codex — which `chat`/`send` keep literal. Leading `/` optional. A menu it opens is navigated with `menu`/`keys`. | **SIDE EFFECT** |
| **menu** `<item> [nav-key]` | Navigate the child's popup until `<item>` is the highlighted row, then confirm with `keys Enter`. The console grid carries **no colour**, so the highlight is read from the row's cursor glyph (`>`/`❯`/`›`) — works on the vertical popups (`/model`, approvals) that matter on Windows. Default nav key `Down`. | **SIDE EFFECT** |
| **quit** | Gracefully exit the broker's agent TUI with Ctrl-C (twice for Claude) so it can flush on the way out; the broker **closes with it** if the agent was its only child. `stop` is the force-kill alternative. | **SIDE EFFECT** |
| **stop** | Stop the broker and its child on the host. | **SIDE EFFECT** |

## When to use which

- "What is that claude working on / show its latest chat" → `read` (transcript is clean;
  prefer it over `peek`, which is a noisy TUI screenshot).
- "Which sessions/panes are running" → `list` (claude panes) or `list --all` (every pane).
- "How are all my agents doing / act on all of them" → `fleet status` (one line per pane: idle/busy/
  awaiting), `fleet read`/`fleet wait` to fan those out; `fleet send`/`fleet chat` only when the user
  explicitly asks to broadcast the same message to every agent.
- "Ask it X and tell me what it says" → `chat` (sends, waits, returns the answer).
- "Reply to it / send it X on my behalf" → `chat` (or `send` if you do not need the reply),
  under the rules below.
- "Run this in the terminal I'm watching" (a plain shell pane) → `sh` (runs it, waits, returns
  output + exit code — so the user sees it happen live and you get the result).
- "Quit that agent but keep the terminal" → `quit` (works for Claude and Codex; it sends the right
  number of Ctrl-C taps close together itself). After it, the pane is a plain shell you drive with `sh`.
- "Run /model /status ... (Claude also /resume /clear) in that agent" → `slash` (not `send`/`chat` —
  they keep `/` literal). Then read the menu with `peek` and drive it with `keys` (Up/Down, Enter to
  pick, Esc to cancel).
- It is showing a y/n prompt or a menu, or needs interrupting → `keys` (**to interrupt a running Codex
  turn use `Escape`, not `C-c` — Ctrl-C quits Codex when it is idle**; a Codex approval prompt takes a
  letter: `y`/`a`/`d`).
- `chat`/`wait` said **"awaiting input"** → the agent is blocked on a prompt (permission / plan /
  select) and quoted its question + options. Answer it, then continue: `keys <t> <n>` picks a numbered
  option (add `keys <t> Enter` if it needs confirming; `menu <t> <label>` navigates to it by name);
  `send <t> "<text>"` types free-text; then `wait <t>` / `read <t>`. Each answer may reveal the next
  prompt (e.g. a plan approval → then a per-edit permission) — `wait` will surface each one.
- `chat`/`wait` **ran to timeout although the agent was clearly waiting** → the detector only fires on a
  cursor (`❯`/`›`) sitting on **one of two or more numbered** options — if *every* numbered line carries
  the glyph it is a markdown blockquote, not a menu, and is rejected. (The ASCII `>` cursor counts only
  on the Windows broker path, where Claude draws it that way.) A single-option prompt, a bare y/n with
  no numbering, or a searchable/type-to-filter picker is deliberately not matched (matching them would
  false-positive on ordinary prose). `peek <t>` to see what it is asking and answer with `keys`.

## Scope: what runs where

overseer is a **Linux controller** and drives two kinds of target:

- **Linux tmux panes** — local, or on another Linux host over ssh (`deploy` + `on`, which runs the
  whole program remote-side). tmux is client/server, so a pane attached from a VSCode Remote-SSH
  terminal is driven server-side and the user still sees it live. overseer both drives panes someone
  else opened and, with `start`/`stop`, creates and destroys its own **detached** sessions running a
  shell/claude/codex (the user runs `tmux attach -t <name>` to watch one) — the same local or via `on`.
- **Remote native Windows consoles** over plain ssh — the `win <host> <verb>` commands, which drive a
  PowerShell **broker** on the host's visible desktop. No tmux, no WSL, and overseer itself never runs there.

A **plain, non-tmux Linux terminal cannot be driven**: the kernel blocks keystroke injection into a
bare PTY (`dev.tty.legacy_tiocsti=0`) and its screen buffer lives in the client (e.g. xterm.js on the
user's machine), not here. To make such a terminal drivable, run it inside tmux. Direct **pane
discovery** (`list`, `%N` targets) is likewise Linux + tmux only — it reads `/proc`.

Windows prerequisites, the trust boundary, and the security notes live in
[docs/WINDOWS.md](../../../docs/WINDOWS.md); read it before running any `win <host> <verb>` command.

## Remote hosts (SSH / Tailscale)

To drive a pane on **another Linux machine** (e.g. across a Tailscale tailnet), do not remote each
tmux/`/proc`/transcript call — run the *whole* overseer program on that host over one ssh call, so all
of its reads stay co-located there and every command behaves exactly as it does locally:

```
overseer deploy sandbox                       # once: copy scripts to sandbox:~/.overseer (ssh+tar)
overseer on sandbox doctor                    # remote preflight — the real gate (tmux + an agent + jq)
overseer on sandbox list                      # discover the remote panes
overseer on sandbox chat --yes %0 'hi'        # drive the remote agent; the reply streams back
overseer on sandbox sh %3 'git pull'          # or drive a remote shell pane
```

- `<host>` is any ssh target: a `user@host`, a `~/.ssh/config` alias, or a Tailscale MagicDNS name.
  Identity/credentials are ssh's own (`~/.ssh`, agent, config) — overseer stores nothing and needs no
  daemon, DB, or token store. It only adds `ControlMaster`+`ControlPersist` so a burst of one-shot
  commands reuses one connection instead of re-handshaking.
- A blocking `chat`/`wait`/`sh` runs its poll loop **on the remote** (reading that host's own transcript
  and hook markers — the same truth signals as local), and ssh just holds the pipe until it returns. No
  separate event/streaming channel exists or is needed.
- Pass `--yes` for a remote `chat`/`send`: without a tty the interactive confirm can't prompt, so it
  fails closed (never submits) instead.
- Preconditions to actually drive a remote agent: that host has tmux, a running claude/codex, and your
  ssh key — exactly what `overseer on <host> doctor` verifies. Overrides: `OVERSEER_REMOTE_DIR` (where
  `deploy` writes, default `.overseer` under the remote `$HOME`) and `OVERSEER_REMOTE_BIN` (what `on`
  runs, default `~/.overseer/scripts/overseer`) — set one and you must set the other to match — plus
  `OVERSEER_SSH` / `OVERSEER_SSH_OPTS`, and `OVERSEER_SCP` for the Windows transcript fetch.
- **Survey first, then remediate.** `overseer hosts` (inventory from `$OVERSEER_HOSTS`, `~/.ssh/config`,
  or `--tailscale`; `-u USER` sets the login user for bare hosts) prints `HOST ONLINE OS SSH DRIVE`.
  Handle each: `SSH=deny` → wrong user/key (fix `User`/`IdentityFile` or pass `-u`/`user@host`);
  `SSH=hostkey` → accept the key (`StrictHostKeyChecking accept-new`); `SSH=unreach` → host/net down.
  `DRIVE=no:tmux`/`no:jq` → **`overseer provision <host>`** installs the base deps (root/passwordless
  sudo; `--dry-run` to preview), then re-survey; `DRIVE=win*` → drive it with `win <host> <verb>` (admin +
  console user + [WINDOWS.md](docs/WINDOWS.md) prereqs). `provision` does Linux base deps only — agents
  and Windows prereqs are manual.
- The `on`/`deploy` path is **Linux-only** (overseer itself needs `/proc` + tmux, so it can't run on a
  Windows host). A **Windows** machine in the tailnet is a first-class target through the `win <host>
  <verb>` commands instead: overseer runs locally and only ssh-executes PowerShell payloads there. The
  full lifecycle is start → drive → stop:

```
overseer win win-host start claude C:\repo     # start a VISIBLE claude on the user's desktop
overseer win win-host list                     # which brokers exist, their child, alive?
overseer win win-host chat --yes 'run the tests' 900   # send a prompt, wait the turn, print the reply
overseer win win-host read                     # last prompt + last reply, any time
overseer win win-host wait 900                 # resume waiting after a timeout, instead of re-sending
overseer win win-host stop                     # stop the broker and its child
```

  Use `win <host> start pwsh` plus `win <host> sh '<command>'` for a shell instead of an agent, and
  `win <host>/name start …` to run several side by side. `win <host> show [app]` is the one-shot
  cousin — it just opens a GUI app on the visible desktop and returns. An ssh login on Windows lands
  in the non-interactive **Session 0**, so a naive launch is
  invisible; `win <host> show` bridges to the logged-in **console session** with a transient interactive
  scheduled task (`-LogonType Interactive` as the live-resolved console user), and clears the silent
  traps — a laptop **on battery** (default tasks refuse to start, sitting `Queued` forever) and Windows
  Terminal's **app-alias** stub (launched by AUMID via `explorer.exe shell:AppsFolder\…`). It confirms a
  new top-level window and errors if nobody is at the console. Requires an **admin** ssh login there.

## How completion is detected

**Claude:** `chat`/`wait` know a turn ended by watching for an assistant message whose `stop_reason`
is not `tool_use` in the transcript (a turn = zero or more tool_use messages then one terminal
message). If **event mode** is installed (see below) a `Stop` hook also fires the moment a turn ends,
so the wait wakes immediately instead of at the next poll; the transcript is still the source of truth
for the reply, so the answer is never read half-written. Without the hook it falls back to polling.

**Codex:** a turn is an `event_msg` `task_started` … `task_complete` pair in the rollout jsonl; `wait`
polls for a new `task_complete` (there is no hook), and the reply is that event's `last_agent_message`.

Do **not** use the on-screen spinner to judge done — a finished turn leaves a stale
`Brewed/Churned for Ns` line on screen.

If the agent **exits mid-turn** (it crashes, you `quit` it, or the pane is killed outright), `chat`/`wait`
notice the pane is no longer running an agent and return an error at once instead of waiting out the
timeout for a reply that will never arrive. A turn that is hung but still alive is still bounded by
`[timeout]`.

`sh` is different: it **brackets** the command with two unique sentinels — one printed before it runs and
`<token>:<exit>` after — waits for the closing one, then reads strictly between them. The opening
sentinel is what keeps the shell's own echo of the command line out of the output. This is
prompt-agnostic — it does not depend on knowing the shell's `PS1`. If the output was long enough that
the opening sentinel scrolled out of the pane's history, `sh` prints the exit code and says the output
cannot be captured whole; re-run with `> out.txt 2>&1` and read the file instead.

## Navigating a Claude feature screen (`/status`, `/resume`, `/model`, ...)

Many slash commands open a **tabbed and/or scrollable** panel, not a single static view. Read the
WHOLE thing, do not stop at the first screen. The reliable loop:

1. Open it with `slash <t> /status`, then `peek <t>` — default `peek` shows the **full** screen, so a
   tall panel is not truncated.
2. To see **which tab or row is active**, use `peek raw <t>`. The active item carries a reverse-video
   (`ESC[7m`), background-color (`ESC[48;5;Nm`) or cyan-foreground (`ESC[38;5;6m`) highlight, or is
   marked by a bare cursor glyph (`❯ ▶ ► ● ➤ ›`) — **plain `peek` cannot show the colour ones**, so
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

## Safety rules for `send`/`sh`/`win <host> <verb>` (READ BEFORE SENDING)

1. **The target almost always runs with bypass permissions on** (`--dangerously-skip-permissions`).
   Anything you submit auto-executes in that agent with no confirmation gate. Treat `send`
   as running a command on a machine you do not control.
2. **Never `send` unless the user explicitly asked you to send that specific message.** Reading
   is fine to do proactively; sending is not.
3. **Do not pass `--yes`** unless the user explicitly authorized auto-submit. Without `--yes` the
   script types the message, verifies the input box contains exactly it, then waits for a
   keypress — relay the verified text to the user and get their confirmation before continuing.
4. Any length is fine (see the intro): everything is placed by bracketed paste and verified before
   submit. For **Claude** a first line starting with `/ ! # @` would open the TUI's
   command/bash/memory/file mode, so the script prepends one space to dodge that — Claude Code trims
   it back off, so the message still arrives literally. For **Codex** most messages are delivered
   exactly as given, but a message starting with `!` is **refused** — Codex runs `!…` as a shell
   command (its design), not as chat; use `sh <target> '<cmd>'` to run a command, or reword the message
   to not lead with `!`. A message whose text contains an `@`-mention token can pop Codex's file picker;
   if a send fails to verify on such a message, the picker intercepted it — `peek` + `keys`, or reword.
5. **`sh` auto-executes the command in the user's shell** the instant it is called (there is no
   confirm gate). Only use it when the user asked you to run that command in the terminal they are
   watching. It refuses any pane that is not an idle POSIX-ish shell (so it never types into a running program
   or a claude TUI), and runs **one command line** — chain with `;` or `&&`.
6. **`send`/`chat` refuse a session that is mid-turn** to avoid typing into a busy agent (Claude: the
   last transcript entry is a `tool_use`; Codex: a `task_started` has no matching `task_complete`). If
   you get "session looks mid-turn", either `wait <t>` for it to finish, or interrupt it with
   `keys <t> Escape`, then retry. If it is **actually idle** — a turn was aborted mid-tool (a
   false-busy deadlock) — rerun with `--force` to bypass the guard.
7. **The `win <host> <verb>` commands are remote execution on somebody's live desktop.** Rules 1–6 apply
   to `win <host> chat`/`keys`/`sh` exactly as to `chat`/`keys`/`sh`, plus: `win <host> start` spawns a
   **visible** window in the console user's session and `win <host> stop` kills that child — both are
   user-visible side effects on a screen a person is looking at, so run them only when asked. `win <host>
   sh` runs an arbitrary
   command line under the console user's credentials (it refuses a broker hosting an agent, so a
   command can never land in a chat box, but is otherwise unrestricted). The broker's named pipe is the
   trust boundary: its random name and auth token live in an ACL'd descriptor on the host — **never
   print, log, or relay a broker descriptor**. Prerequisites and the full model:
   [docs/WINDOWS.md](../../../docs/WINDOWS.md).
8. **`start` spawns a process; `stop` destroys a session.** `start` opens a new detached tmux session
   running a shell or agent; `stop` kills a `%N` pane or a whole named session and its child. Both are
   side effects on the user's machine — run them only when the user asked to create or tear down a
   session. `stop` is destructive (the child dies); it refuses to kill the session (or, for a `%N`
   target, the pane) overseer itself runs in, but will kill any other named session. Prefer `quit` when
   the user only wants to leave an agent's TUI while keeping the pane.

## Gotchas the script already handles (do not re-derive)

- **Never trust the spinner** to tell busy from idle. A finished turn leaves a stale
  `Brewed for Ns · N shells still running` line on screen. Busy vs. idle is decided from the
  **transcript**, never from the screen — see "How completion is detected" above.
- **Ghost suggestion vs. real typed text**: the ghost is rendered dim (`ESC[2m`). `capture-pane -e`
  keeps the color; the script uses it to tell an **empty input box** (only ghost) from one holding real
  text, so a suggestion can never be mistaken for, or mixed into, your message. This is about the box,
  not about busy/idle.
- **A non-breaking space (U+00A0) sits between `❯` and the text** — normalized before comparing.
- **The TUI renders with lag**: wait for a *specific condition* (the text appearing), never for
  "the screen stopped changing" — two identical captures usually mean "still stale", not "done".
- **The user scrolling the pane up** (tmux copy-mode) would otherwise freeze capture on the scrolled
  view and swallow keys — so the script cancels copy-mode before anything that **types** into the pane
  (`send`/`chat`/`sh`/`menu`) and before the **awaiting-prompt check** in `chat`/`wait`, and driving works
  even while they scroll to read. The read-only `peek`/`read` deliberately do **not** cancel it: they
  won't yank the view out from under someone reading history, so a `peek` of a scrolled pane shows the
  scrolled view — scroll back down (or `keys <t> q`) if you need the live screen.
- **Two overseer runs against the same pane** can't interleave keystrokes: every command that types
  (`send`/`chat`/`sh`/`quit`/`slash`/`menu`) takes a per-pane `flock` first and releases it before the
  reply wait, so a long `chat` never blocks a `read` of the same pane. Without `flock` it proceeds
  unlocked; if `flock` is present but the lock is still held after 30s it aborts with an error rather
  than proceeding unlocked.
- **Control bytes in a message** (a raw ESC, or an embedded `\e[201~` paste-end marker) are stripped
  before the bracketed paste, so pasted content can't terminate the paste early and inject keystrokes.
- **The input line is read at the cursor row** (`#{cursor_y}`), not "the last prompt glyph on screen",
  so a menu/autocomplete that draws its own glyph below the box can't be mistaken for the prompt. The
  prompt glyph is `❯` for Claude and `›` for Codex; both are handled.
- **A brand-new session with 0 turns has no transcript yet** — `chat` and `send` handle the first
  message anyway (they resolve the transcript once the turn begins); a bare `read`/`wait` still needs a
  completed turn to read.

## Event mode (bundled hooks — faster `chat`/`wait`/`send`)

By default the readers poll the transcript (correct, ~2s worst-case latency). To wake on events, the
plugin ships three hooks, all routed through one script (`hooks/hooks.json` →
`${CLAUDE_PLUGIN_ROOT}/hooks/turn-done.sh <subdir>`):

- `Stop` → `~/.claude/turn-done/<session_id>` — turn ended, so `chat`/`wait` wake in ~0.25s.
- `UserPromptSubmit` → `~/.claude/turn-started/<session_id>` — a prompt was accepted, so `send` confirms
  the turn started immediately instead of polling for the first transcript marker (which the harness does
  not write until the first token — the old sub-second race).
- `Notification` → `~/.claude/awaiting/<session_id>` — Claude raised a permission/menu prompt, so
  `chat`/`wait` look at the screen the moment it appears.

**All three are wired automatically when the plugin is installed** — no `settings.json` editing. A
user-scope install covers every session; there is no project-scope walk-up caveat.

Each hook only writes an mtime marker (files are reused per session, and markers idle for over a week
are swept by a prune that runs at most once every 24h — no unbounded growth). They are
pure accelerators: the transcript stays the source of truth for the reply and the on-screen prompt stays
the arbiter for awaiting, so a marker never causes a half-written read or a false prompt. A session the
hooks do not cover — or a Codex pane, which has none — falls back to the same size/mtime-gated poll.
Nothing breaks.

The fast path also needs the driven Claude session to share overseer's `~/.claude` (`CLAUDE_HOME`): the
hook writes the marker under *that session's* home and overseer's reader looks under *its own*, so a
session running as another user, under a custom `CLAUDE_HOME`, or launched before the plugin was
installed just polls — the same safe fallback, ~2s slower, never blocked.

## Requirements

- Linux (uses `/proc` to map pane pid → agent: Claude via `~/.claude/sessions/<pid>.json`, Codex via
  the rollout jsonl the codex process holds open), `tmux`, and **bash ≥ 4.1** (checked at startup).
  `jq` is needed by every transcript reader — `read`, `chat`, `wait`, and `fleet status|read|wait`.
- Run from **outside** the target session's tmux client (this is normal — you drive it from a
  separate shell).
- Optional environment overrides. `OVERSEER_TIMEOUT` (default `600`, the
  fallback `[timeout]` for `chat`/`wait`/`sh`) and `OVERSEER_POLL_INTERVAL` (default `0.25`, the poll
  cadence) are **validated at startup**, so a bad value fails loudly rather than misbehaving later;
  the rest are taken as given. `CLAUDE_HOME` (default `~/.claude`) points Claude discovery at a
  non-default state directory; `CODEX_HOME` (default `~/.codex`) is read only by `doctor` — live Codex
  discovery reads the open rollout off `/proc`, so it does not depend on it.

## Install

Distributed as a Claude Code plugin. From inside Claude Code:

```
/plugin marketplace add saigonbaddielover/sgbl-overseer
/plugin install overseer@sgbl
```

This installs the skill, the `overseer` script, and the turn-done hook together (the hook is wired
automatically — see Event mode). Requirements and safety notes are in the repo `README.md`.
