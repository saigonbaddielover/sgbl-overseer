# Security

overseer drives *other* live sessions by injecting keystrokes into them. Target Claude Code sessions
typically run with `--dangerously-skip-permissions`, so anything `send` / `chat` / `sh` submits
**auto-executes** in that session with no confirmation gate. Only point it at sessions you own and
trust, and an agent using it must never send a message it was not explicitly asked to send.

## Linux targets (tmux)

Keystrokes go into a tmux pane on the controller host, or on another Linux host over ssh via
`deploy` + `on`. Identity is ssh's own — overseer stores no credentials, runs no daemon, and keeps no
token store. A remote `chat`/`send` has no tty, so it **fails closed** unless `--yes` is passed.

`start` and `stop` are local side effects, the tmux analogue of the Windows `win <host> start` /
`win <host> stop` pair: `start` spawns a new detached tmux session running a shell or agent (on the
controller, or via `on` the remote host), and `stop` destroys a `%N` pane or a whole named session,
SIGHUPping its child. `stop` is destructive — run it only when asked, prefer `quit` to merely leave an
agent's TUI, and note it refuses to kill the session (or, for a `%N` target, the pane) overseer itself
is running in.

## Windows targets (the `win <host> <verb>` commands)

These are remote execution on somebody's live desktop and deserve the same care as `sh`:

- `win <host> start` spawns a **visible** process in the console user's session; `win <host> keys`, `sh`
  and `chat` type into it; `win <host> stop` kills it and its descendants. All of it happens on a screen
  a person is looking at, under their credentials. Never run one unless the user explicitly asked.
- `win <host> sh` runs an arbitrary command line in a `pwsh` child. It refuses a broker hosting an agent,
  so a command can never be typed into a chat box — but it is otherwise unrestricted.
- The SSH login must be an **administrator** on the Windows host (registering the interactive
  scheduled task requires it), so a compromised controller key is an admin foothold there.
- **The broker runs as the console user**, so that user is *trusted*, not sandboxed — a fully-malicious
  console user can always spoof broker responses (the broker's process is theirs). What overseer
  protects is the admin SSH client and any third, unprivileged local account. The pipe name and 256-bit
  `AUTH` token live in `%ProgramData%\overseer\brokers\<broker>.json`, ACL'd to Administrators/SYSTEM
  and the console user **read-only**; the runtime transcript claim is a separate console-user-writable
  `<broker>.state.json`, so the console user cannot rewrite the pipe to hijack the control channel. No
  console-user-supplied value (transcript path, `win <host> show` app) is ever run as admin code or fed to
  `scp` unchecked; the shared tree is ACL-locked before staging. Tokens are never logged or printed.

See [docs/WINDOWS.md](docs/WINDOWS.md) for the full prerequisites and security model.

## Reporting a vulnerability

Please use GitHub's private **"Report a vulnerability"** advisory on this repository, or open a regular
issue for non-sensitive reports. Include the `overseer doctor` output and clear steps to reproduce.
