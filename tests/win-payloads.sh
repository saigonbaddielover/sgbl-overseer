#!/usr/bin/env bash
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PWSH="${OVERSEER_PWSH:-pwsh}"

command -v "$PWSH" >/dev/null 2>&1 || {
  printf 'tests/win-payloads.sh: no PowerShell found (looked for %s)\n' "$PWSH" >&2
  printf '  install pwsh, or point OVERSEER_PWSH at one: OVERSEER_PWSH=/path/to/pwsh bash tests/win-payloads.sh\n' >&2
  exit 2
}
printf 'using %s (%s)\n' "$PWSH" "$("$PWSH" --version)"

"$PWSH" -NoProfile -File "$HERE/win-parse.ps1"
"$PWSH" -NoProfile -File "$HERE/win-contracts.ps1"
