# Contributing

## Layout

- `overseer/` — the plugin: `.claude-plugin/plugin.json`, `skills/overseer/` (the skill + `scripts/`), `hooks/`.
- `skills/overseer/scripts/overseer` — the entry point (config, `main`, help); it sources `scripts/lib/`:
  `discovery.sh` (pane → harness → transcript path), `transcript.sh` (Claude + Codex readers, turn-done),
  `tui.sh` (screen read + keyboard/paste delivery), `commands.sh` (the local + ssh `cmd_*` surface),
  `windows.sh` (the `win*` surface: broker payload transfer, pipe client, remote turn wait).
- `skills/overseer/scripts/win-*.ps1` — the PowerShell payloads copied to a Windows host on demand;
  see [docs/WINDOWS.md](docs/WINDOWS.md) for the mechanism and its non-obvious constraints.
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
bash tests/win-flow.sh                             # win* orchestration, mocked ssh
bash tests/win-payloads.sh                         # the same two .ps1 files CI's windows job runs (needs pwsh)
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
- **`tests/win-flow.sh`** — mocks the two remote chokepoints (`_win_client`, `_win_fetch`) and runs the
  real `win*` bash orchestration against a recorded call log: the mid-turn and scp-failure guards, the
  `pwsh`/dead-child/Codex-`!` refusals, box cleanup after a failed submit or unverified delivery, the
  `mtime:size` gating, and broker-target parsing. No ssh, no host, runs in CI.
- **`tests/win-payloads.sh`** — parses every shipped `win-*.ps1` with
  `System.Management.Automation.Language.Parser` and then runs **`tests/win-contracts.ps1`**, whose
  assertions cover the AUTH handshake, the pipe-constructor fallback, exclusive rollout claiming, the
  agent-command override, descriptor cleanup on `quit`, no workdir interpolation, and no assignment to
  the read-only `$pid`. **CI is the authority**: the `windows-latest` job runs `tests/win-parse.ps1`
  and `tests/win-contracts.ps1` natively under `pwsh`. `win-payloads.sh` just runs those same two
  scripts for you locally — it is a convenience, not the gate.

  **PowerShell runs on Linux**, so run it before pushing rather than waiting for CI — it has caught
  defects (an unterminated string, a `$line:` scope parse) that every other check passed:

  ```
  bash tests/win-payloads.sh                       # pwsh on PATH
  OVERSEER_PWSH=/path/to/pwsh bash tests/win-payloads.sh   # or point it at one
  ```

  Exit 1 means a payload failed, 2 means no PowerShell was found.

CI (`.github/workflows/validate.yml`) runs three jobs on every push and PR:

| job | runner | steps |
|---|---|---|
| **validate** | ubuntu | `jq empty` on the three JSON manifests · plugin/marketplace version agreement · a CHANGELOG entry for a version bump (PRs only) · `bash -n` + shellcheck over the entry, `lib/*.sh`, the hook and every `tests/*.sh` · `tests/run.sh` · `tests/win-flow.sh` |
| **powershell** | windows | `tests/win-parse.ps1` · `tests/win-contracts.ps1`, both natively under `pwsh` |
| **stress** | ubuntu | installs tmux, runs the harness-free subset of `tests/stress.sh` |

Only the Codex `!`-refuse check in `tests/stress.sh` and the Windows live checklist below stay manual.

### Windows live verification

Static checks and the Linux jobs cannot see the Windows path — see the verification rule in
[docs/WINDOWS.md](docs/WINDOWS.md). **If your change touches `windows.sh` or any `win-*.ps1`**, run
against a real Windows host and tick these in the PR:

- [ ] `winbroker <host> claude` and `winbroker <host>/two codex` — both paint, both appear in `winlist`
- [ ] a **multi-line** `winchat`, then `winread` — the transcript shows the exact prompt, not a
      run-together one line
- [ ] two brokers of the same kind own **different** transcripts
- [ ] abort a confirmation and prove the composer is left clear
- [ ] `winsh` with output **taller than the window** returns output + exit code, not a timeout
- [ ] `winstop` leaves no descendant process and no descriptor behind

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

The existing comments in `scripts/lib/*.sh` explain non-obvious tmux / TUI gotchas — **preserve them
verbatim** when you touch the surrounding logic. The project convention is otherwise *no prose
comments*: write self-documenting code and put new rationale in the commit, the PR, or `docs/`.
Functional comments (shebangs, `# shellcheck …` directives, license headers) are the exception.
Target a Linux controller with tmux + jq; keep it POSIX-ish bash. The `win-*.ps1` payloads follow the
same rule — their rationale lives in [docs/WINDOWS.md](docs/WINDOWS.md).

## Adding an agent harness

**Claude Code and Codex are both supported today.** Turn detection lives behind one seam in
`transcript.sh`: per-harness `_turn_count` / `_is_busy` / `_last_reply` / `_last_prompt`, dispatched by
`kind` through the `_h_*` wrappers. Supporting a third harness (OpenCode, …) means implementing those
four functions for it and adding its pane detection to `discovery.sh` — the whole command surface,
Linux and Windows alike, then works unchanged. Open an issue to discuss the seam before opening a PR.
