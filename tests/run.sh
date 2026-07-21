#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LIB="$HERE/../overseer/skills/overseer/scripts/lib"
FIX="$HERE/fixtures"
export CLAUDE_HOME="$HERE/.home" CODEX_HOME="$HERE/.home"

# shellcheck source=../overseer/skills/overseer/scripts/lib/transcript.sh
. "$LIB/transcript.sh"
# shellcheck source=../overseer/skills/overseer/scripts/lib/tui.sh
. "$LIB/tui.sh"
# shellcheck source=../overseer/skills/overseer/scripts/lib/discovery.sh
. "$LIB/discovery.sh"

fail=0
eq() {
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"
    fail=$((fail + 1))
  fi
}

C="$FIX/claude-turn.jsonl"
eq "claude turn_count"     "2"                         "$(_turn_count "$C")"
eq "claude turns_after(0)" "2"                         "$(_turns_after claude "$C" 0)"
eq "claude not busy"       ""                          "$(_is_busy "$C" && echo busy)"
eq "claude last_reply"     $'final reply\nsecond line' "$(_last_reply "$C")"
eq "claude last_prompt"    "second prompt"             "$(_last_prompt "$C")"
eq "claude sid"            "test-sid-123"              "$(_sid_from_jsonl "$C")"

CB="$FIX/claude-busy.jsonl"
eq "claude busy"           "busy"                      "$(_is_busy "$CB" && echo busy)"
eq "claude busy turns"     "0"                         "$(_turn_count "$CB")"

X="$FIX/codex-turn.jsonl"
eq "codex turn_count"      "1"                         "$(_cx_turn_count "$X")"
eq "codex turns_after(0)"  "1"                         "$(_turns_after codex "$X" 0)"
eq "codex not busy"        ""                          "$(_cx_is_busy "$X" && echo busy)"
eq "codex last_reply"      "codex reply text"          "$(_cx_last_reply "$X")"
eq "codex last_prompt"     "codex prompt here"         "$(_cx_last_prompt "$X")"

eq "codex busy"            "busy"                      "$(_cx_is_busy "$FIX/codex-busy.jsonl" && echo busy)"
eq "codex aborted!=busy"   ""                          "$(_cx_is_busy "$FIX/codex-aborted.jsonl" && echo busy)"

eq "awaiting claude"       "0"                         "$(_awaiting_text "$(cat "$FIX/awaiting-claude.txt")" >/dev/null 2>&1; echo $?)"
eq "awaiting codex"        "0"                         "$(_awaiting_text "$(cat "$FIX/awaiting-codex.txt")" >/dev/null 2>&1; echo $?)"
eq "awaiting none"         "1"                         "$(_awaiting_text "$(cat "$FIX/awaiting-none.txt")" >/dev/null 2>&1; echo $?)"
eq "awaiting win console"  "0"                         "$(_awaiting_text "$(cat "$FIX/awaiting-windows-console.txt")" >/dev/null 2>&1; echo $?)"

eq "is_shell bash"         "0"                         "$(_is_shell bash; echo $?)"
eq "is_shell login -zsh"   "0"                         "$(_is_shell -zsh; echo $?)"
eq "is_shell fish"         "0"                         "$(_is_shell fish; echo $?)"
eq "is_shell nu"           "0"                         "$(_is_shell nu; echo $?)"
eq "is_shell reject node"  "1"                         "$(_is_shell node; echo $?)"
eq "is_shell reject claude" "1"                        "$(_is_shell claude; echo $?)"

ENTRY="$HERE/../overseer/skills/overseer/scripts/overseer"
README="$HERE/../README.md"
SKILL="$HERE/../overseer/skills/overseer/SKILL.md"

_dispatch_cmds() { sed -nE 's/^[[:space:]]+([a-z]+)\)[[:space:]]+cmd_.*/\1/p' "$ENTRY" | sort -u; }
_help_cmds()     { bash "$ENTRY" --help 2>/dev/null | sed -nE 's/^  ([a-z]+)[[:space:]]+[<[].*/\1/p' | sort -u; }
_table_cmds()    { sed -nE 's/^\| `([a-z]+)[ `].*/\1/p' "$1" | sort -u; }

DISPATCH=$(_dispatch_cmds)
eq "dispatch surface is non-empty" "yes" "$([ -n "$DISPATCH" ] && echo yes || echo no)"

for surface in help README SKILL; do
  case "$surface" in
    help)   documented=$(_help_cmds) ;;
    README) documented=$(_table_cmds "$README") ;;
    SKILL)  documented=$(_table_cmds "$SKILL") ;;
  esac
  missing=$(comm -23 <(printf '%s\n' "$DISPATCH") <(printf '%s\n' "$documented") | tr '\n' ' ')
  extra=$(comm -13 <(printf '%s\n' "$DISPATCH") <(printf '%s\n' "$documented") | tr '\n' ' ')
  eq "$surface documents every dispatched command" "" "$(printf '%s' "$missing" | sed 's/ *$//')"
  eq "$surface documents no command that does not exist" "" "$(printf '%s' "$extra" | sed 's/ *$//')"
done

if [ "$fail" = 0 ]; then
  printf 'PASS: all parser fixture tests\n'; exit 0
else
  printf 'FAIL: %s test(s) failed\n' "$fail"; exit 1
fi
