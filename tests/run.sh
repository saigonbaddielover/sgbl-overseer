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
_die() { printf 'overseer: %s\n' "$1" >&2; exit 1; }
# shellcheck source=../overseer/skills/overseer/scripts/lib/windows.sh
. "$LIB/windows.sh"
# shellcheck source=../overseer/skills/overseer/scripts/lib/commands.sh
. "$LIB/commands.sh"

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
eq "awaiting win console"  "0"                         "$(_awaiting_text "$(cat "$FIX/awaiting-windows-console.txt")" '❯›>' >/dev/null 2>&1; echo $?)"
eq "linux ignores ascii >"        "1"                  "$(_awaiting_text "$(cat "$FIX/awaiting-windows-console.txt")" >/dev/null 2>&1; echo $?)"
eq "markdown quote not awaiting"  "1"                  "$(_awaiting_text "$(cat "$FIX/awaiting-none-markdown-quote.txt")" >/dev/null 2>&1; echo $?)"
eq "markdown quote not awaiting on windows" "1"        "$(_awaiting_text "$(cat "$FIX/awaiting-none-markdown-quote.txt")" '❯›>' >/dev/null 2>&1; echo $?)"
eq "plain numbered list not awaiting" "1"              "$(_awaiting_text "$(cat "$FIX/awaiting-none-numbered-list.txt")" >/dev/null 2>&1; echo $?)"
eq "plain numbered list not awaiting on windows" "1"   "$(_awaiting_text "$(cat "$FIX/awaiting-none-numbered-list.txt")" '❯›>' >/dev/null 2>&1; echo $?)"
eq "all options marked is not a menu" "1"              "$(_awaiting_text "$(printf '> 1. yes\n> 2. no\n')" '❯›>' >/dev/null 2>&1; echo $?)"

_aw() { _awaiting_text "$1" "${2:-❯›}" >/dev/null 2>&1 && echo awaiting || echo no; }
eq "a numbered reply line + a numbered composer is not a menu" "no" \
   "$(_aw "$(printf 'here are the steps\n2. do the thing\n❯ 1. do X first\n')")"
eq "options must be consecutively numbered"   "no"       "$(_aw "$(printf '2. b\n❯ 1. a\n')")"
eq "a real menu under a numbered reply is found" "awaiting" \
   "$(_aw "$(printf '1. alpha\n2. beta\nProceed?\n❯ 1. Yes\n  2. No\n')")"
eq "a menu not starting at 1 still counts"    "awaiting" "$(_aw "$(printf 'Proceed?\n❯ 4. Yes\n  5. No\n')")"
eq "a lone marked option is not a menu"       "no"       "$(_aw "$(printf 'Proceed?\n❯ 1. Yes\n')")"

eq "posix shell accepts bash"   "yes" "$(_is_posix_shell bash && echo yes || echo no)"
eq "posix shell accepts -zsh"   "yes" "$(_is_posix_shell -zsh && echo yes || echo no)"
eq "posix shell refuses fish"   "no"  "$(_is_posix_shell fish && echo yes || echo no)"
eq "posix shell refuses nu"     "no"  "$(_is_posix_shell nu && echo yes || echo no)"
eq "_is_shell still accepts fish" "yes" "$(_is_shell fish && echo yes || echo no)"

_shpane() {
  ( _need() { :; }
    _resolve_pane() { printf '%%9'; }
    _lock_pane() { printf 'LOCKED-BEFORE-GATE'; }
    _shell_under_test="$1"
    tmux() { case "$*" in *pane_current_command*) printf '%s' "$_shell_under_test" ;; *) return 0 ;; esac; }
    cmd_sh %9 'ls' 1 ) 2>&1
}
eq "sh refuses a fish pane before locking"  "yes" "$(case "$(_shpane fish)"  in *"cannot drive"*) echo yes ;; *) echo no ;; esac)"
eq "sh refuses a nu pane"                   "yes" "$(case "$(_shpane nu)"    in *"cannot drive"*) echo yes ;; *) echo no ;; esac)"
eq "sh names the shells it can drive"       "yes" "$(case "$(_shpane tcsh)"  in *"sh, bash, zsh, dash, ksh, mksh, ash"*) echo yes ;; *) echo no ;; esac)"
eq "sh does not refuse a bash pane"         "yes" "$(case "$(_shpane bash)"  in *"cannot drive"*) echo no ;; *) echo yes ;; esac)"

_cxpid() { ( _want="$1"
             _p_comm() { [ "$1" = "$_want" ] && printf codex || printf node; }
             _p_children() { [ "$1" = 100 ] && printf '200\n'; }
             _codex_pid 100 ) }
eq "codex found when a descendant is codex" "200" "$(_cxpid 200)"
eq "codex found when the pane pid IS codex" "100" "$(_cxpid 100)"

_probe() { ( _rc="$1"
             _probe_contract() { printf 'x.jsonl'; return "$_rc"; }
             _h_turn_count() { printf 3; }
             _doctor_probe claude >/dev/null; echo "rc=$?" ) }
eq "doctor probe ok"                 "rc=0" "$(_probe 0)"
eq "doctor probe schema shift FAILS" "rc=1" "$(_probe 1)"
eq "doctor probe no-session is ok"   "rc=0" "$(_probe 2)"
eq "doctor probe schema shift is not a warn" "yes" \
   "$( ( _probe_contract() { printf 'x.jsonl'; return 1; }; case "$(_doctor_probe claude)" in *'[FAIL]'*) echo yes ;; *) echo no ;; esac ) )"

_delivered() { ( _paste_verified() { printf '%s' "$2"; }; _deliver pane "$1" "$2" ) }
eq "claude leading slash is space-guarded"  " /clear"  "$(_delivered claude '/clear')"
eq "claude leading bang is space-guarded"   " !ls"     "$(_delivered claude '!ls')"
eq "claude leading hash is space-guarded"   " #note"   "$(_delivered claude '#note')"
eq "claude leading at is space-guarded"     " @file"   "$(_delivered claude '@file')"
eq "claude plain text is untouched"         "hello"    "$(_delivered claude 'hello')"
eq "codex plain text is untouched"          "/clear"   "$(_delivered codex '/clear')"
eq "codex refuses a leading bang"           "refused"  "$( (_delivered codex '!rm -rf /') >/dev/null 2>&1 || echo refused)"
eq "codex refuses an indented bang"         "refused"  "$( (_delivered codex '   !rm -rf /') >/dev/null 2>&1 || echo refused)"

_undeliv() { ( _awaiting() { [ "$1" = menu ] && { printf 'proceed?\n❯ 1. yes\n  2. no'; return 0; }; return 1; }
              _win_awaiting() { _awaiting menu; }
              "$@" ) }
eq "undelivered names the question when a menu is up" "yes" \
   "$(case "$(_undeliv _undelivered menu %9)" in *'not sent'*'❯ 1. yes'*) echo yes ;; *) echo no ;; esac)"
eq "undelivered suggests answering it first"          "yes" \
   "$(case "$(_undeliv _undelivered menu %9)" in *'overseer keys %9 <n>'*) echo yes ;; *) echo no ;; esac)"
eq "undelivered keeps the plain error with no menu"   "could not place/verify message in input box" \
   "$(_undeliv _undelivered plain %9)"
eq "win undelivered names the question when a menu is up" "yes" \
   "$(case "$(_undeliv _win_undelivered win/two)" in *'not sent'*'win/two'*'❯ 1. yes'*) echo yes ;; *) echo no ;; esac)"
eq "win undelivered keeps the plain error with no menu"   "yes" \
   "$(_win_awaiting() { return 1; }; case "$(_win_undelivered win/two)" in *'could not place/verify the prompt'*'winpeek win/two'*) echo yes ;; *) echo no ;; esac)"

eq "is_shell bash"         "0"                         "$(_is_shell bash; echo $?)"
eq "is_shell login -zsh"   "0"                         "$(_is_shell -zsh; echo $?)"
eq "is_shell fish"         "0"                         "$(_is_shell fish; echo $?)"
eq "is_shell nu"           "0"                         "$(_is_shell nu; echo $?)"
eq "is_shell reject node"  "1"                         "$(_is_shell node; echo $?)"
eq "is_shell reject claude" "1"                        "$(_is_shell claude; echo $?)"

_split() { ( _win_split "$1" >/dev/null 2>&1 && printf '%s %s' "$_WH" "$_WP" ) || printf 'rejected'; }
eq "win_split bare host"    "win1 overseer-broker"           "$(_split win1)"
eq "win_split user@ip"      "ndman@10.0.0.9 overseer-broker" "$(_split ndman@10.0.0.9)"
eq "win_split named broker" "win1 overseer-broker-v10"       "$(_split win1/v10)"
eq "win_split name w/ -_"   "win1 overseer-broker-a_b-2"     "$(_split win1/a_b-2)"
eq "win_split reject punct" "rejected"                       "$(_split 'win1/oops!')"
eq "win_split reject empty" "rejected"                       "$(_split 'win1/')"
eq "win_split reject nohost" "rejected"                      "$(_split '/v10')"

STAT='kind=claude alive=True size=48213 mtime=1753070000 transcript=C:/Users/u/.claude/projects/D--Workspace/abc-123.jsonl'
eq "win_field kind"        "claude"                          "$(_win_field "$STAT" kind)"
eq "win_field alive"       "True"                            "$(_win_field "$STAT" alive)"
eq "win_field size"        "48213"                           "$(_win_field "$STAT" size)"
eq "win_field mtime"       "1753070000"                      "$(_win_field "$STAT" mtime)"
eq "win_field transcript"  "C:/Users/u/.claude/projects/D--Workspace/abc-123.jsonl" "$(_win_field "$STAT" transcript)"
eq "win_sig gates on both" "1753070000:48213"                "$(_win_sig "$STAT")"
INFO='kind=shell workdir=D:\Workspace childPid=15272 alive=False transcript='
eq "win_field absent tx"   ""                                "$(_win_field "$INFO" transcript)"
eq "win_field alive False" "False"                           "$(_win_field "$INFO" alive)"
eq "win_sig no transcript" ":"                               "$(_win_sig "$INFO")"

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

WINDOC="$HERE/../docs/WINDOWS.md"
SECDOC="$HERE/../SECURITY.md"
CONTRIB="$HERE/../CONTRIBUTING.md"
PRTPL="$HERE/../.github/pull_request_template.md"

_has() { grep -qF "$2" "$1" && echo yes || echo no; }
_hasre() { grep -qE "$2" "$1" && echo yes || echo no; }

eq "README states the Linux controller / Windows target support model" "yes" "$(_hasre "$README" '^## Support model')"
eq "SKILL frontmatter names the Windows broker commands" "yes" "$(sed -n '2p' "$SKILL" | grep -qE 'winbroker.*winchat|winchat.*winbroker' && echo yes || echo no)"
eq "SKILL scope section covers both target kinds" "yes" "$(_hasre "$SKILL" '^## Scope: what runs where')"
for v in OVERSEER_REMOTE_DIR OVERSEER_REMOTE_BIN OVERSEER_SSH OVERSEER_SSH_OPTS OVERSEER_SCP OVERSEER_WIN_CLAUDE OVERSEER_WIN_CODEX OVERSEER_TIMEOUT OVERSEER_POLL_INTERVAL; do
  eq "README documents $v" "yes" "$(_has "$README" "$v")"
done

ENTRYLIB="$HERE/../overseer/skills/overseer/scripts/lib"
eq "README quotes the real no-agent-pane error" "yes" "$(_has "$README" 'no agent pane (claude/codex) for target')"
eq "that error string still exists in the code" "yes" "$(_has "$ENTRYLIB/commands.sh" 'no agent pane (claude/codex) for target')"
eq "README does not claim overseer opens panes" "no" "$(_hasre "$README" 'opens \(or attaches\) a tmux pane|launches an agent harness')"

eq "README describes the Windows poll as mtime:size gated" "yes" "$(_has "$README" 'mtime:size')"
eq "SKILL describes the Windows poll as mtime:size gated" "yes" "$(_has "$SKILL" 'mtime:size')"
eq "README links the Windows doc" "yes" "$(_has "$README" 'docs/WINDOWS.md')"
eq "SKILL links the Windows doc" "yes" "$(_has "$SKILL" 'docs/WINDOWS.md')"
eq "Windows doc has a prerequisites section" "yes" "$(_hasre "$WINDOC" '^## Prerequisites')"
eq "Windows doc has a security model section" "yes" "$(_hasre "$WINDOC" '^## Security model')"
eq "SECURITY covers the Windows commands" "yes" "$(_has "$SECDOC" 'winbroker')"
eq "SKILL safety rules cover the win* commands" "yes" "$(_hasre "$SKILL" '^## Safety rules for .*win\*')"
eq "CONTRIBUTING has the Windows live-verification checklist" "yes" "$(_hasre "$CONTRIB" '^### Windows live verification')"
eq "CONTRIBUTING documents the Windows contract tests" "yes" "$(_has "$CONTRIB" 'tests/win-contracts.ps1')"
eq "CONTRIBUTING documents the local PowerShell runner" "yes" "$(_has "$CONTRIB" 'OVERSEER_PWSH')"
eq "Windows doc points at the local PowerShell runner" "yes" "$(_has "$WINDOC" 'tests/win-payloads.sh')"
eq "Windows doc names the CI parse script" "yes" "$(_has "$WINDOC" 'tests/win-parse.ps1')"
eq "CI runs the windows payload scripts natively" "yes" "$(_has "$HERE/../.github/workflows/validate.yml" './tests/win-parse.ps1')"
eq "PR template requires the Windows payload run" "yes" "$(_has "$PRTPL" 'tests/win-payloads.sh')"
eq "README walkthrough shows the broker lifecycle" "yes" "$(_hasre "$README" 'overseer winstop')"
eq "SKILL walkthrough shows the broker lifecycle" "yes" "$(_hasre "$SKILL" 'overseer winstop')"

_poll() { OVERSEER_POLL_INTERVAL="$1" bash "$ENTRY" --help >/dev/null 2>&1 && echo ok || echo rejected; }
for good in 0.25 1 1.0 .5 2.5; do
  eq "poll interval '$good' is accepted" "ok" "$(_poll "$good")"
done
eq "poll interval empty falls back to the default" "ok" "$(_poll '')"
for bad in . 1..2 0 0.0 .0 abc 1x -1 00 000 0. 0.000 0.0000 .00; do
  eq "poll interval '$bad' is rejected" "rejected" "$(_poll "$bad")"
done

if [ "$fail" = 0 ]; then
  printf 'PASS: all parser fixture tests\n'; exit 0
else
  printf 'FAIL: %s test(s) failed\n' "$fail"; exit 1
fi
