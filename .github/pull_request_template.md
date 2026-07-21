## What

<!-- What does this change, and why? -->

## Checklist

- [ ] `bash -n` and `shellcheck -S warning` pass on any changed scripts
- [ ] `claude plugin validate --strict ./overseer` passes (and `claude plugin validate --strict .` for the marketplace)
- [ ] For a releasable change: bumped `version` in **both** `overseer/.claude-plugin/plugin.json` and the `.claude-plugin/marketplace.json` entry (they must agree)
- [ ] Updated `CHANGELOG.md` (under `Unreleased`)
- [ ] `bash tests/run.sh` passes
- [ ] `overseer doctor` still passes on a Linux + tmux box
- [ ] **If `windows.sh` or any `win-*.ps1` changed:** ran `bash tests/win-payloads.sh` **and** the
      live Windows checklist in [CONTRIBUTING.md](../CONTRIBUTING.md#windows-live-verification) — CI
      cannot see that path
