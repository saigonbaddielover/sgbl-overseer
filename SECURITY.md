# Security

overseer drives *other* live sessions by injecting keystrokes into their tmux panes. Target Claude
Code sessions typically run with `--dangerously-skip-permissions`, so anything `send` / `chat` / `sh`
submits **auto-executes** in that session with no confirmation gate. Only point it at panes you own and
trust, and an agent using it must never send a message it was not explicitly asked to send.

## Reporting a vulnerability

Please use GitHub's private **"Report a vulnerability"** advisory on this repository, or open a regular
issue for non-sensitive reports. Include the `overseer doctor` output and clear steps to reproduce.
