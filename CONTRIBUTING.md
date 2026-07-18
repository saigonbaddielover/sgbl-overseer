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

After editing, refresh with `/plugin marketplace update sgbl` then `/plugin update overseer`, then
`/reload-plugins` to apply it in the current session — no restart. (A plain `SKILL.md` text edit is
picked up automatically or with `/reload-skills`; changes under `hooks/` need `/reload-plugins`.)
Remove with `/plugin uninstall overseer@sgbl --scope local` and
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

## Contribution flow

`main` is protected: land changes through a branch → pull request → green CI → merge, not by pushing
to `main` directly.

```
git switch -c my-change
# ... edit + validate ...
git push -u origin my-change
gh pr create --fill
```

## Release

1. On a branch, bump `version` in **both** `overseer/.claude-plugin/plugin.json` and the
   `.claude-plugin/marketplace.json` entry (they must match — `claude plugin tag` enforces it).
2. Move the `Unreleased` notes in `CHANGELOG.md` under the new version + date.
3. Open the PR, get CI green, merge to `main`.
4. From `main`, cut and push the tag — the `release` workflow publishes the GitHub Release automatically:

```
claude plugin tag ./overseer --push -m "overseer %s"   # tags overseer--v<version>, pushes it
```

Users update with `/plugin marketplace update sgbl` + `/plugin update overseer` + `/reload-plugins`
(no restart).

## Style

The scripts deliberately carry comments explaining the non-obvious tmux / TUI gotchas — keep that when
you touch the tricky logic. Target Linux + tmux + jq; keep it POSIX-ish bash.

## Adding an agent harness

Turn detection and reading are Claude Code–specific today (transcript under `~/.claude/…`,
`stop_reason`). Supporting another harness (Codex, OpenCode, ...) means teaching the same commands its
"is it idle / what did it reply" signal. Open an issue to discuss the seam before opening a PR.
