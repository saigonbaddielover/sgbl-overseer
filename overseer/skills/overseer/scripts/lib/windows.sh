# shellcheck shell=bash

cmd_winshow() {
  _need ssh; _need iconv; _need base64
  local host="${1:-}" app="${2:-Terminal}"
  [ -n "$host" ] || _die "usage: overseer winshow <host> [app]   (open a GUI app on the VISIBLE console session of a remote WINDOWS ssh host; app = a Start-menu name, an AUMID, or a full exe path; default Windows Terminal. e.g. overseer winshow ndman@100.77.19.60 'Notepad')"
  local ps="$_dir/win-show.ps1"
  [ -f "$ps" ] || _die "missing launcher payload: $ps"
  local boot='$f=Join-Path $env:TEMP "overseer-winshow.ps1"; Set-Content -LiteralPath $f -Value ([Console]::In.ReadToEnd()) -Encoding UTF8; powershell -NoProfile -ExecutionPolicy Bypass -File $f; $e=$LASTEXITCODE; Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; exit $e'
  local bb64; bb64=$(printf '%s' "$boot" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n') || _die "could not encode the launcher bootstrap"
  local esc="${app//\'/\'\'}"
  local cmdir="${TMPDIR:-/tmp}/overseer-ssh-$UID"; mkdir -p "$cmdir" 2>/dev/null || true
  local i rc=0 out=''
  for i in 1 2 3; do
    rc=0
    # shellcheck disable=SC2086
    out=$({ printf "\$App = '%s'\n" "$esc"; cat "$ps"; } \
      | ${OVERSEER_SSH:-ssh} -o ControlMaster=auto -o "ControlPath=$cmdir/%C" -o ControlPersist=60s \
        -o ConnectTimeout=12 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 ${OVERSEER_SSH_OPTS:-} "$host" "powershell -NoProfile -EncodedCommand $bb64" 2>&1) || rc=$?
    [ "$rc" = 255 ] || break
    _nap
  done
  out=${out//$'\r'/}
  local line; line=$(printf '%s\n' "$out" | grep -aE '^(OK|ERR) ' | head -1)
  printf '%s\n' "${line:-$out}"
  return "$rc"
}
_win_ssh() {
  local host="$1" cmd="$2" rc=0 out='' i cmdir
  cmdir="${TMPDIR:-/tmp}/overseer-ssh-$UID"; mkdir -p "$cmdir" 2>/dev/null || true
  for i in 1 2 3; do
    rc=0
    # shellcheck disable=SC2086
    out=$(${OVERSEER_SSH:-ssh} -o ControlMaster=auto -o "ControlPath=$cmdir/%C" -o ControlPersist=60s \
      -o ConnectTimeout=12 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 ${OVERSEER_SSH_OPTS:-} "$host" "$cmd" 2>&1) || rc=$?
    [ "$rc" != 255 ] && break
    _nap
  done
  printf '%s\n' "${out//$'\r'/}"
  return "$rc"
}
_win_cp() {
  local i
  for i in 1 2 3; do
    # shellcheck disable=SC2086
    scp -o ConnectTimeout=12 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 ${OVERSEER_SSH_OPTS:-} "$1" "$2" >/dev/null 2>&1 && return 0
    _nap
  done
  return 1
}
_win_scp() { _win_cp "$2" "$1:$3"; }
_win_fetch() { _win_cp "$1:$2" "$3"; }
_win_split() {
  _WH="${1%%/*}"
  case "$1" in
    */*)
      local n="${1#*/}"
      case "$n" in ''|*[!0-9A-Za-z_-]*) _die "broker name after '/' must be letters, digits, '-' or '_' (got '$n')" ;; esac
      _WP="overseer-broker-$n" ;;
    *) _WP="overseer-broker" ;;
  esac
  [ -n "$_WH" ] || _die "missing host in target '$1' (expected <host> or <host>/<broker-name>)"
}
_win_client() {
  _win_ssh "$_WH" "powershell -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%\\overseer-win-client.ps1\" -Op $1 -Pipe ${_WP:-overseer-broker} ${2:-}"
}
_win_field() {
  case "$2" in
    transcript) printf '%s\n' "$1" | sed -n 's/.*[[:space:]]transcript=//p' | head -1 ;;
    *) printf '%s\n' "$1" | grep -oE "(^|[[:space:]])$2=[^[:space:]]+" | head -1 | cut -d= -f2- ;;
  esac
}
_win_snap() { _win_client snap; }
_win_awaiting() { _awaiting_text "$(_win_snap)"; }
_win_report_awaiting() {
  printf 'awaiting input — the agent is asking:\n%s\n\nanswer it, then read the reply, e.g.:\n  overseer winkeys %s <n>            (choose a numbered option; add "overseer winkeys %s Enter" if it needs confirming)\n  overseer winkeys %s "<text>" Enter (type free-text into the prompt)\n  overseer winread %s\n' \
    "$2" "$1" "$1" "$1" "$1"
}
_win_deliver() {
  local target="$1" kind="$2" msg="$3" b64 probe i snap
  msg=$(printf '%s' "$msg" | LC_ALL=C tr -d '\000-\010\013-\037\177')
  if [ "$kind" = claude ]; then
    case "$msg" in /*|'!'*|'#'*|'@'*) msg=" $msg" ;; esac
  else
    case "$(_trim "$msg")" in '!'*) _die "Codex runs a message starting with '!' as a shell command (by its design), not chat — reword it (e.g. lead with a word), or run a command with: overseer winsh $target '<cmd>'" ;; esac
  fi
  b64=$(printf '%s' "$msg" | base64 | tr -d '\n')
  _win_client paste "-B64 $b64" >/dev/null || return 3
  probe=$(printf '%s' "$(_trim "$msg")" | head -1 | cut -c1-24)
  [ -n "$probe" ] || return 4
  for i in 1 2 3 4; do
    snap=$(_win_snap)
    case "$snap" in *"$probe"*) return 0 ;; esac
    printf '%s\n' "$snap" | grep -qE 'Pasted text #[0-9]+' && return 0
    _nap
  done
  return 4
}
_win_sig() { printf '%s:%s' "$(_win_field "$1" mtime)" "$(_win_field "$1" size)"; }
_win_wait_turn() {
  local kind="$1" base="$2" lastsig="$3" timeout="$4" tmp="$5"
  local deadline=$((SECONDS + timeout)) st tx sig cur i=0
  while [ "$SECONDS" -lt "$deadline" ]; do
    _nap; _nap
    i=$((i + 1))
    st=$(_win_client stat)
    [ "$(_win_field "$st" alive)" = False ] && return 3
    tx=$(_win_field "$st" transcript); sig=$(_win_sig "$st")
    if [ -n "$tx" ] && [ "$sig" != "$lastsig" ]; then
      lastsig="$sig"
      if _win_fetch "$_WH" "$tx" "$tmp"; then
        cur=$(_h_turn_count "$kind" "$tmp"); cur="${cur:-0}"
        [ "$cur" -gt "$base" ] && return 0
      fi
    fi
    [ $((i % 8)) = 0 ] && _win_awaiting >/dev/null && return 2
  done
  return 1
}
_win_agent_ctx() {
  local target="$1" st
  st=$(_win_client stat)
  _WKIND=$(_win_field "$st" kind)
  _WTX=$(_win_field "$st" transcript)
  _WSIG=$(_win_sig "$st")
  case "$_WKIND" in claude|codex) : ;; *) _die "the broker on $target is hosting '${_WKIND:-?}', not an agent — start one with: overseer winbroker $target claude|codex" ;; esac
  [ "$(_win_field "$st" alive)" = False ] && _die "the broker's agent on $target has exited — restart it: overseer winbroker $target $_WKIND"
  return 0
}
cmd_winbroker() {
  _need ssh; _need scp
  local target="${1:-}" which="${2:-pwsh}" wd="${3:-}"
  [ -n "$target" ] || _die "usage: overseer winbroker <host>[/name] [pwsh|claude|codex] [workdir]   (start a VISIBLE broker on a remote WINDOWS host's console hosting pwsh/claude/codex; then drive it with winpeek/winkeys/winsh/winchat/winread/winwait. Add /name to run several side by side — see: overseer winlist <host>. Re-run to switch the child. Default child pwsh, default workdir = the host's Windows Terminal default)"
  _win_split "$target"
  case "$which" in pwsh|claude|codex) : ;; *) _die "child must be pwsh, claude, or codex (got '$which')" ;; esac
  local d="$_dir" f
  for f in win-broker.ps1 win-client.ps1 win-launch.ps1; do [ -f "$d/$f" ] || _die "missing payload: $d/$f"; done
  _win_scp "$_WH" "$d/win-broker.ps1" overseer-win-broker.ps1 \
    && _win_scp "$_WH" "$d/win-client.ps1" overseer-win-client.ps1 \
    && _win_scp "$_WH" "$d/win-launch.ps1" overseer-win-launch.ps1 \
    || _die "could not copy payloads to $_WH (check ssh/scp to the host)"
  local wdq="${wd//\"/}"
  _lock_pane "win-$target"
  local out; out=$(_win_ssh "$_WH" "powershell -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%\\overseer-win-launch.ps1\" -Pipe $_WP -Which $which -WorkDir \"$wdq\"")
  local line; line=$(printf '%s\n' "$out" | grep -aE '^(OK|ERR) ' | head -1)
  case "$line" in
    OK\ *)
      local i
      for i in $(seq 1 8); do
        [ -n "$(_win_snap | tr -d '[:space:]')" ] && break
        _nap
      done ;;
  esac
  _unlock_pane
  printf '%s\n' "${line:-$out}"
}
cmd_winlist() {
  _need ssh
  local target="${1:-}"; [ -n "$target" ] || _die "usage: overseer winlist <host>   (list the overseer brokers running on a remote WINDOWS host: name, child kind, workdir, alive)"
  _win_split "$target"
  _win_client list
}
cmd_winpeek() {
  _need ssh
  local target="${1:-}"; [ -n "$target" ] || _die "usage: overseer winpeek <host>[/name]   (snapshot the remote WINDOWS broker's screen; run 'overseer winbroker <host>' first)"
  _win_split "$target"
  _win_client snap
}
cmd_winkeys() {
  _need ssh; _need base64
  local target="${1:-}"; shift || true
  [ -n "$target" ] && [ "$#" -gt 0 ] || _die "usage: overseer winkeys <host>[/name] <key|text>...   (send named keys — Enter Escape Up Down Tab Backspace C-c ... — or literal text, to the remote WINDOWS broker's child)"
  _win_split "$target"
  local a b64 out=''
  _lock_pane "win-$target"
  for a in "$@"; do
    case "$a" in
      Enter|Escape|Tab|Backspace|Space|Delete|Up|Down|Left|Right|Home|End|PageUp|PageDown|C-[a-zA-Z])
        out=$(_win_client key "-Name $a") ;;
      *)
        b64=$(printf '%s' "$a" | base64 | tr -d '\n')
        out=$(_win_client type "-B64 $b64") ;;
    esac
    printf '%s\n' "$out"
  done
  _unlock_pane
}
cmd_winsh() {
  _need ssh; _need base64
  local target="${1:-}" cmd="${2:-}" timeout="${3:-$DEFAULT_TIMEOUT}"
  [ -n "$target" ] && [ -n "$cmd" ] || _die "usage: overseer winsh <host>[/name] <command> [timeout_s]   (run one command line in the remote WINDOWS broker's pwsh child; start it with 'overseer winbroker <host> pwsh')"
  _uint "$timeout"
  case "$cmd" in *$'\n'*) _die "one command line only (chain with ; )" ;; esac
  _win_split "$target"
  local st kind
  st=$(_win_client stat); kind=$(_win_field "$st" kind)
  [ "$kind" = shell ] || _die "the broker on $target is hosting '${kind:-?}', not a shell — winsh would type the command into the agent's chat box. Start a shell broker (overseer winbroker $target pwsh), or talk to the agent with: overseer winchat $target '<prompt>'"
  [ "$(_win_field "$st" alive)" = False ] && _die "the broker's shell on $target has exited — restart it: overseer winbroker $target pwsh"
  local t1 t2 inject b64
  t1="OVSH1$$"; t2="OVSH2$$"
  inject='Write-Host "'"$t1"'"; '"$cmd"'; $o=$?; $c=$LASTEXITCODE; if ($null -eq $c) { $c = if ($o) { 0 } else { 1 } }; Write-Host "'"$t2"':$c"'
  b64=$(printf '%s\r' "$inject" | base64 | tr -d '\n')
  local out; _lock_pane "win-$target"
  out=$(_win_client sh "-B64 $b64 -T1 $t1 -T2 $t2 -TimeoutSec $timeout")
  _unlock_pane
  if printf '%s\n' "$out" | grep -qaE '^EXIT '; then
    local rc body
    rc=$(printf '%s\n' "$out" | grep -aE '^EXIT ' | head -1 | awk '{print $2}')
    body=$(printf '%s\n' "$out" | awk '/^<<<OUT$/{f=1;next} /^>>>OUT$/{f=0} f{print}')
    printf '# host=%s exit=%s\n%s\n' "$target" "$rc" "$body"
  else
    printf '%s\n' "$out"
  fi
}
cmd_winread() {
  _need ssh; _need jq; _need scp
  local target="${1:-}"
  [ -n "$target" ] || _die "usage: overseer winread <host>[/name]   (print the last user prompt + last assistant reply from the WINDOWS broker's agent, read from its transcript)"
  _win_split "$target"
  _win_agent_ctx "$target"
  [ -n "$_WTX" ] || _die "no transcript yet for '$target' (a brand-new session with 0 turns has none)"
  local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/overseer-wintx.XXXXXX") || _die "mktemp failed"
  _win_fetch "$_WH" "$_WTX" "$tmp" || { rm -f "$tmp"; _die "could not fetch the transcript from $_WH"; }
  printf '# host=%s harness=%s\n## last user prompt:\n%s\n\n## last assistant reply:\n%s\n' \
    "$target" "$_WKIND" "$(_h_last_prompt "$_WKIND" "$tmp")" "$(_h_last_reply "$_WKIND" "$tmp")"
  rm -f "$tmp"
}
cmd_winwait() {
  _need ssh; _need jq; _need scp
  local target="${1:-}" timeout="${2:-$DEFAULT_TIMEOUT}"
  [ -n "$target" ] || _die "usage: overseer winwait <host>[/name] [timeout_s]   (block until the WINDOWS broker's agent finishes its current turn, or return the question if it stops at an interactive prompt)"
  _uint "$timeout"
  _win_split "$target"
  local q
  if q=$(_win_awaiting); then _win_report_awaiting "$target" "$q"; return 0; fi
  _win_agent_ctx "$target"
  [ -n "$_WTX" ] || _die "no transcript yet for '$target' (a brand-new session with 0 turns has none)"
  local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/overseer-wintx.XXXXXX") || _die "mktemp failed"
  _win_fetch "$_WH" "$_WTX" "$tmp" || { rm -f "$tmp"; _die "could not fetch the transcript from $_WH"; }
  if ! _h_is_busy "$_WKIND" "$tmp"; then rm -f "$tmp"; echo idle; return 0; fi
  local base rc=0
  base=$(_h_turn_count "$_WKIND" "$tmp"); base="${base:-0}"
  _win_wait_turn "$_WKIND" "$base" "$_WSIG" "$timeout" "$tmp" || rc=$?
  rm -f "$tmp"
  case "$rc" in
    0) if q=$(_win_awaiting); then _win_report_awaiting "$target" "$q"; else echo idle; fi ;;
    2) q=$(_win_awaiting) && _win_report_awaiting "$target" "$q" ;;
    3) _die "the agent on $target exited mid-turn; peek: overseer winpeek $target" ;;
    *) _die "timeout after ${timeout}s — the turn is still running on $target" ;;
  esac
}
cmd_winchat() {
  _need ssh; _need jq; _need base64; _need scp
  local confirm=1 force=0
  while :; do case "${1:-}" in --yes) confirm=0; shift ;; --force) force=1; shift ;; *) break ;; esac; done
  local target="${1:-}" prompt
  [ -n "$target" ] || _die "usage: overseer winchat [--yes] [--force] <host>[/name] <prompt|-> [timeout_s]   (send a prompt to the remote WINDOWS broker's claude/codex, wait for the turn via its transcript, print the reply; start it with 'overseer winbroker <host> claude|codex')"
  prompt=$(_read_msg "${2:-}")
  [ -n "$prompt" ] || _die "usage: overseer winchat [--yes] [--force] <host>[/name] <prompt|-> [timeout_s]  (empty prompt)"
  local timeout="${3:-$DEFAULT_TIMEOUT}"; _uint "$timeout"
  _win_split "$target"
  _win_agent_ctx "$target"
  local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/overseer-wintx.XXXXXX") || _die "mktemp failed"
  local base=0 lastsig=''
  if [ -n "$_WTX" ] && _win_fetch "$_WH" "$_WTX" "$tmp"; then
    base=$(_h_turn_count "$_WKIND" "$tmp"); base="${base:-0}"
    lastsig="$_WSIG"
    if [ "$force" = 0 ] && _h_is_busy "$_WKIND" "$tmp"; then
      rm -f "$tmp"
      _die "the agent on $target looks mid-turn; wait: overseer winwait $target — or interrupt it: overseer winkeys $target Escape. If it is actually idle (a turn was aborted mid-tool), rerun with --force"
    fi
  fi
  _lock_pane "win-$target"
  if ! _win_deliver "$target" "$_WKIND" "$prompt"; then
    _unlock_pane; rm -f "$tmp"
    _die "could not place/verify the prompt in the agent's input box on $target — peek: overseer winpeek $target"
  fi
  if [ "$confirm" = 1 ]; then
    printf 'verified in box:\n%s\n--- press Enter to send, Ctrl-C to abort: ' "$prompt"
    read -r _ </dev/tty || { _unlock_pane; rm -f "$tmp"; _die "aborted"; }
  fi
  _win_client key "-Name Enter" >/dev/null
  _unlock_pane
  printf '# sent to %s (waiting for the turn...)\n' "$target" >&2
  local rc=0 q
  _win_wait_turn "$_WKIND" "$base" "$lastsig" "$timeout" "$tmp" || rc=$?
  case "$rc" in
    0) if q=$(_win_awaiting); then rm -f "$tmp"; _win_report_awaiting "$target" "$q"; return 0; fi
       printf '## reply:\n%s\n' "$(_h_last_reply "$_WKIND" "$tmp")"; rm -f "$tmp" ;;
    2) rm -f "$tmp"; q=$(_win_awaiting) && _win_report_awaiting "$target" "$q" ;;
    3) rm -f "$tmp"; _die "the agent on $target exited mid-turn — no reply was produced; peek: overseer winpeek $target" ;;
    *) rm -f "$tmp"; _die "timeout after ${timeout}s — the turn is still running. Do NOT rerun winchat (it would send the prompt again); resume waiting instead: overseer winwait $target   then   overseer winread $target" ;;
  esac
}
cmd_winstop() {
  _need ssh
  local target="${1:-}"; [ -n "$target" ] || _die "usage: overseer winstop <host>[/name]   (stop the remote WINDOWS broker and its child)"
  _win_split "$target"
  _lock_pane "win-$target"
  _win_client quit
  _unlock_pane
}
