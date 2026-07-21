# Security

overseer drives *other* live sessions by injecting keystrokes into them. Target Claude Code sessions
typically run with `--dangerously-skip-permissions`, so anything `send` / `chat` / `sh` submits
**auto-executes** in that session with no confirmation gate. Only point it at sessions you own and
trust, and an agent using it must never send a message it was not explicitly asked to send.

## Linux targets (tmux)

Keystrokes go into a tmux pane on the controller host, or on another Linux host over ssh via
`deploy` + `on`. Identity is ssh's own — overseer stores no credentials, runs no daemon, and keeps no
token store. A remote `chat`/`send` has no tty, so it **fails closed** unless `--yes` is passed.

## Windows targets (the `win*` commands)

These are remote execution on somebody's live desktop and deserve the same care as `sh`:

- `winbroker` spawns a **visible** process in the console user's session; `winkeys`, `winsh` and
  `winchat` type into it; `winstop` kills it and its descendants. All of it happens on a screen a
  person is looking at, under their credentials. Never run one unless the user explicitly asked.
- `winsh` runs an arbitrary command line in a `pwsh` child. It refuses a broker hosting an agent, so a
  command can never be typed into a chat box — but it is otherwise unrestricted.
- The SSH login must be an **administrator** on the Windows host (registering the interactive
  scheduled task requires it), so a compromised controller key is an admin foothold there.
- The **trust boundary is the named pipe**: a random GUID name plus a mandatory 256-bit `AUTH` token,
  both held in a descriptor under `%ProgramData%\overseer\brokers\` ACL'd to Administrators, SYSTEM
  and the console user. Any local principal able to read that descriptor can fully drive the hosted
  agent; the pipe is not a boundary against a local administrator. Tokens are never logged or printed.

See [docs/WINDOWS.md](docs/WINDOWS.md) for the full prerequisites and security model.

## Reporting a vulnerability

Please use GitHub's private **"Report a vulnerability"** advisory on this repository, or open a regular
issue for non-sensitive reports. Include the `overseer doctor` output and clear steps to reproduce.
