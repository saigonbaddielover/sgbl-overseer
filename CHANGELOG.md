# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and versions follow [SemVer](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-07-18

### Added
- `overseer doctor` — preflight check (Linux/`/proc`, `tmux`, `jq`, tmux server, and whether Claude
  Code's `~/.claude/sessions/*.json` layout is where discovery expects it). Run it first when a pane
  "can't be found".
- Contributor scaffolding: GitHub Actions validation workflow, issue/PR templates, `CONTRIBUTING.md`,
  `SECURITY.md`, `.gitattributes`.

### Fixed
- Shellcheck-clean: split two `local` + command-substitution assignments (SC2318/SC2155) so a
  just-assigned value and command exit codes are not masked.

## [0.1.0] - 2026-07-18

Initial release as a Claude Code plugin distributed via the `sgbl` marketplace.

### Added
- `overseer` script with 11 commands: `list`, `read`, `peek`, `chat`, `send`, `wait`,
  `quit`, `slash`, `menu`, `sh`, `keys`.
- Bundled Claude Code skill (`skills/overseer/SKILL.md`) so an agent can drive/read another
  session or a shell in a tmux pane.
- Bundled `Stop` hook (`hooks/turn-done.sh`, wired via `hooks/hooks.json`) for event mode — wakes
  `chat`/`wait` the instant a turn ends. Wired automatically on install.
- Plugin manifest (`.claude-plugin/plugin.json`) and single-plugin marketplace
  (`.claude-plugin/marketplace.json`, name `sgbl`).

### Notes
- Linux only (agent discovery reads `/proc`). Requires `tmux` and `jq`.
- Reads Claude Code's on-disk session/transcript layout, which is internal and may change
  between Claude Code releases.
