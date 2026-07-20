# Contributing

## Layout

- `overseer/` — the plugin: `.claude-plugin/plugin.json`, `skills/overseer/` (the skill + `scripts/`), `hooks/`.
- `skills/overseer/scripts/overseer` — the entry point (config, `main`, help); it sources `scripts/lib/`:
  `discovery.sh` (pane → harness → transcript path), `transcript.sh` (Claude + Codex readers, turn-done),
  `tui.sh` (screen read + keyboard/paste delivery), `commands.sh` (the `cmd_*` surface).
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
bash -n overseer/skills/overseer/scripts/overseer overseer/skills/overseer/scripts/lib/*.sh
shellcheck -x -S warning overseer/skills/overseer/scripts/overseer   # -x follows the sourced lib/*.sh
shellcheck -S warning overseer/hooks/turn-done.sh
bash tests/run.sh                                  # parser fixture tests (no tmux needed)
overseer/skills/overseer/scripts/overseer doctor --live   # runtime preflight + throwaway-pane round trip
```

## Tests

- **`tests/run.sh`** — asserts the pure transcript/screen parsers against fixtures in `tests/fixtures/`,
  for both harnesses. No tmux, no agent, fast. This is the drift tripwire; add a fixture + assertion
  whenever you touch a parser.
- **`tests/stress.sh`** — exercises the live paths fixtures can't: multi-pane concurrency, per-pane lock
  serialization, large-rollout reader perf, and mid-turn crash liveness. Needs tmux; the checks above use
  throwaway *shell* panes, so no Claude/Codex is required. Set `OVERSEER_STRESS_CODEX_PANE=%N` to also
  assert the Codex `!`-refuse safety against a real Codex pane. Run it by hand when touching the
  delivery, lock, or reader paths. Reader-perf ceilings are tunable via
  `OVERSEER_STRESS_PERF_LASTREPLY` / `OVERSEER_STRESS_PERF_TURNS`.

CI (`.github/workflows/validate.yml`) runs two jobs on every push and PR: **validate** (JSON manifests,
plugin/marketplace version agreement, `bash -n` + shellcheck, `tests/run.sh`) and **stress** (installs
tmux and runs the harness-free subset of `tests/stress.sh`). Only the Codex `!`-refuse check stays manual.

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
   `.claude-plugin/marketplace.json` entry (they must match — CI and `claude plugin tag` enforce it).
2. Move the `Unreleased` notes in `CHANGELOG.md` under the new version + date. CI **fails the PR** if the
   version changed without a matching `## [x.y.z]` heading.
3. Open the PR, get CI green, merge to `main`.

That is the whole flow — **tagging and releasing are automatic**. On every push to `main` the `autotag`
workflow reads the plugin version and, if `overseer--v<version>` does not already exist, creates the tag
and publishes the GitHub Release. It is idempotent: a merge that doesn't bump the version is a no-op.

You can still cut a tag by hand (`claude plugin tag ./overseer --push`) — `autotag` sees the tag already
exists and stands down, and the `release` workflow handles that path. Note `autotag` publishes the
release itself rather than leaning on `release.yml`, because a tag pushed by a workflow using the default
`GITHUB_TOKEN` deliberately does not trigger further workflows.

Users update with `/plugin marketplace update sgbl` + `/plugin update overseer` + `/reload-plugins`
(no restart).

## Style

The scripts deliberately carry comments explaining the non-obvious tmux / TUI gotchas — keep that when
you touch the tricky logic. Target Linux + tmux + jq; keep it POSIX-ish bash.

## Adding an agent harness

Turn detection and reading are Claude Code–specific today (transcript under `~/.claude/…`,
`stop_reason`). Supporting another harness (Codex, OpenCode, ...) means teaching the same commands its
"is it idle / what did it reply" signal. Open an issue to discuss the seam before opening a PR.
