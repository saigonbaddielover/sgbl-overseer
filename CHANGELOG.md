# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and versions follow [SemVer](https://semver.org/).

## [Unreleased]

## [0.3.1] - 2026-07-18

### Changed
- Internal: split the `overseer` script into a thin entry point that sources `scripts/lib/`
  (`discovery.sh`, `transcript.sh`, `tui.sh`, `commands.sh`). No behavior change; the largest file
  drops from ~620 to ~270 lines. CI shellchecks the entry with `-x` to follow the sources.

## [0.3.0] - 2026-07-18

### Added
- **Codex support.** `list`, `read`, `chat`, `send`, `wait` now auto-detect whether a pane runs
  Claude Code or Codex and read the right transcript — the same commands drive both. Codex discovery
  reads the rollout jsonl the codex process holds open (`/proc/<pid>/fd` →
  `~/.codex/sessions/**/rollout-*.jsonl`); turn completion is the rollout's `task_complete` event, and
  the reply its `last_agent_message`. `quit`/`slash`/`menu` stay Claude-only for now.
- `list` gained a **HARNESS** column (claude/codex).
- `overseer doctor` also checks the running Codex version + `~/.codex/sessions`, warning when Codex
  drifts from its tested baseline (`0.144.5`).
- `overseer doctor` checks the running Claude Code version and warns when it drifts from the tested
  baseline (`2.1.214`) — surfaces upstream layout-change risk without hard-blocking.
- README: `Updating` (apply with `/reload-plugins`, no restart), `Compatibility`, and a
  `Useful Claude Code commands` list.

### Changed
- Docs: apply overseer updates with `/reload-plugins` instead of restarting Claude Code (it re-wires
  the bundled `Stop` hook and reloads the skill in the current session).

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
