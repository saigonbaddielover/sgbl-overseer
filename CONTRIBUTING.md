# Contributing

## Layout

- `overseer/` — the plugin: `.claude-plugin/plugin.json`, `skills/overseer/` (the skill + `scripts/overseer`), `hooks/`.
- `.claude-plugin/marketplace.json` — the `sgbl` marketplace that lists the plugin.

## Test locally (no publish)

Add this repo as a **local** marketplace and install from your working tree:

```
/plugin marketplace add ./sgbl-overseer --scope local
/plugin install overseer@sgbl --scope local
```

After editing, refresh with `/plugin marketplace update sgbl` then `/plugin update overseer` (restart
Claude Code to apply). Remove with `/plugin uninstall overseer@sgbl --scope local` and
`/plugin marketplace remove sgbl --scope local`.

## Validate before you push

```
claude plugin validate --strict ./overseer   # the plugin
claude plugin validate --strict .             # the marketplace
bash -n overseer/skills/overseer/scripts/overseer
shellcheck -S warning overseer/skills/overseer/scripts/overseer overseer/hooks/turn-done.sh
overseer/skills/overseer/scripts/overseer doctor   # runtime preflight
```

CI (`.github/workflows/validate.yml`) runs the JSON/version/shellcheck checks on every push and PR.

## Release

1. Bump `version` in **both** `overseer/.claude-plugin/plugin.json` and the `.claude-plugin/marketplace.json`
   entry (they must match — `claude plugin tag` enforces it).
2. Move the `Unreleased` notes in `CHANGELOG.md` under the new version + date.
3. Commit, then:

```
claude plugin tag ./overseer --push -m "overseer %s"   # tags overseer--v<version> and pushes it
git push
gh release create overseer--v<version> --notes-from-tag
```

Users update with `/plugin marketplace update sgbl` + `/plugin update overseer`.

## Style

The scripts deliberately carry comments explaining the non-obvious tmux / TUI gotchas — keep that when
you touch the tricky logic. Target Linux + tmux + jq; keep it POSIX-ish bash.

## Adding an agent harness

Turn detection and reading are Claude Code–specific today (transcript under `~/.claude/…`,
`stop_reason`). Supporting another harness (Codex, OpenCode, ...) means teaching the same commands its
"is it idle / what did it reply" signal. Open an issue to discuss the seam before opening a PR.
