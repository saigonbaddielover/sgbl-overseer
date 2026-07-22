# shellcheck shell=bash

cmd_winshow() {
  _need ssh; _need iconv; _need base64
  local host="${1:-}" app="${2:-Terminal}"
  [ -n "$host" ] || _die "usage: overseer winshow <host> [app]   (open a GUI app on the VISIBLE console session of a remote WINDOWS ssh host; app = a Start-menu name, an AUMID, or a full exe path; default Windows Terminal. e.g. overseer winshow admin@win-host 'Notepad')"
  local ps="$_dir/win-show.ps1"
  [ -f "$ps" ] || _die "missing launcher payload: $ps"
  local boot='$f=Join-Path $env:TEMP "overseer-winshow.ps1"; Set-Content -LiteralPath $f -Value ([Console]::In.ReadToEnd()) -Encoding UTF8; powershell -NoProfile -ExecutionPolicy Bypass -File $f; $e=$LASTEXITCODE; Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; exit $e'
  local bb64; bb64=$(printf '%s' "$boot" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n') || _die "could not encode the launcher bootstrap"
  local appb64; appb64=$(printf '%s' "$app" | base64 | tr -d '\n')
  local cmdir="${TMPDIR:-/tmp}/overseer-ssh-$UID"; mkdir -p "$cmdir" 2>/dev/null || true
  local i rc=0 out=''
  for i in 1 2 3; do
    rc=0
    # shellcheck disable=SC2086
    out=$({ printf "\$AppB64 = '%s'\n" "$appb64"; cat "$ps"; } \
      | ${OVERSEER_SSH:-ssh} -o ControlMaster=auto -o "ControlPath=$cmdir/%C" -o ControlPersist=60s \
        -o ConnectTimeout=12 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 ${OVERSEER_SSH_OPTS:-} -- "$host" "powershell -NoProfile -EncodedCommand $bb64" 2>&1) || rc=$?
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
      -o ConnectTimeout=12 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 ${OVERSEER_SSH_OPTS:-} -- "$host" "$cmd" 2>&1) || rc=$?
    [ "$rc" != 255 ] && break
    _nap
  done
  printf '%s\n' "${out//$'\r'/}"
  return "$rc"
}
_win_cp() {
  local i scp_bin="${OVERSEER_SCP:-scp}" via=''
  [ -n "${OVERSEER_SSH:-}" ] && via="-S ${OVERSEER_SSH}"
  for i in 1 2 3; do
    # shellcheck disable=SC2086
    "$scp_bin" $via -o ConnectTimeout=12 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 ${OVERSEER_SSH_OPTS:-} -- "$1" "$2" >/dev/null 2>&1 && return 0
    _nap
  done
  return 1
}
_win_txok() {
  case "$1" in
    *[!A-Za-z0-9/:._\ -]*|'') return 1 ;;
    [A-Za-z]:/*) case "$1" in *.jsonl) return 0 ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
}
_win_scp() { _win_cp "$2" "$1:$3"; }
_win_fetch() { _win_cp "$1:$2" "$3"; }
_win_stage() {
  local prep b64
  prep='$ErrorActionPreference="Stop"
$cu=(Get-CimInstance Win32_ComputerSystem).UserName
$r=Join-Path $env:ProgramData "overseer"
foreach($d in @($r,(Join-Path $r "payloads"),(Join-Path $r "brokers"))){
  New-Item -ItemType Directory -Force -Path $d | Out-Null
  $a=New-Object System.Security.AccessControl.DirectorySecurity
  $a.SetAccessRuleProtection($true,$false)
  foreach($id in @("BUILTIN\Administrators","NT AUTHORITY\SYSTEM")){
    $a.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id,"FullControl","ContainerInherit,ObjectInherit","None","Allow")))
  }
  if($cu){ $a.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($cu,"ReadAndExecute","ContainerInherit,ObjectInherit","None","Allow"))) }
  Set-Acl -LiteralPath $d -AclObject $a
}
"OK staged"'
  b64=$(printf '%s' "$prep" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n') || return 1
  case "$(_win_ssh "$_WH" "powershell -NoProfile -EncodedCommand $b64")" in *"OK staged"*) return 0 ;; *) return 1 ;; esac
}
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
_win_agent_cmd() {
  case "$1" in
    claude) printf '%s' "${OVERSEER_WIN_CLAUDE:-claude}" ;;
    codex)  printf '%s' "${OVERSEER_WIN_CODEX:-codex}" ;;
    *) printf '' ;;
  esac
}
_win_client() {
  _win_ssh "$_WH" "powershell -NoProfile -ExecutionPolicy Bypass -File \"%ProgramData%\\overseer\\payloads\\overseer-win-client.ps1\" -Op $1 -Broker ${_WP:-overseer-broker} ${2:-}"
}
_win_field() {
  case "$2" in
    transcript) printf '%s\n' "$1" | sed -n 's/.*[[:space:]]transcript=//p' | head -1 ;;
    *) printf '%s\n' "$1" | grep -oE "(^|[[:space:]])$2=[^[:space:]]+" | head -1 | cut -d= -f2- ;;
  esac
}
_win_snap() { _win_client snap | sed "s/$(printf '\302\240')/ /g"; }
_win_awaiting() { _awaiting_text "$(_win_snap)" '❯›>'; }
_win_report_awaiting() {
  printf 'awaiting input — the agent is asking:\n%s\n\nanswer it, then read the reply, e.g.:\n  overseer winkeys %s <n>            (choose a numbered option; add "overseer winkeys %s Enter" if it needs confirming)\n  overseer winkeys %s "<text>" Enter (type free-text into the prompt)\n  overseer winread %s\n' \
    "$2" "$1" "$1" "$1" "$1"
}
_win_undelivered() {
  local target="$1" q
  q=$(_win_awaiting) || { printf "could not place/verify the prompt in the agent's input box on %s — peek: overseer winpeek %s" "$target" "$target"; return 0; }
  printf 'not sent — the agent on %s is asking:\n%s\n\nanswer it first, then resend, e.g.:\n  overseer winkeys %s <n>            (choose a numbered option)\n  overseer winkeys %s "<text>" Enter (type free-text into the prompt)' \
    "$target" "$q" "$target" "$target"
}
_win_rmtmp() { [ -n "${_WTMP:-}" ] && rm -f "$_WTMP"; return 0; }
_win_call() {
  local out rc=0
  out=$(_win_client "$@") || rc=$?
  [ "$rc" = 0 ] || _die "the broker '${_WP:-overseer-broker}' on $_WH did not answer '$1' (exit $rc): ${out:-no output} — check it is running: overseer winlist $_WH"
  printf '%s' "$out"
}
_win_clear_box() { _win_client clear >/dev/null 2>&1 || return 1; }
_win_deliver() {
  local target="$1" kind="$2" msg="$3" b64 want nl i snap chip got
  msg=$(printf '%s' "$msg" | LC_ALL=C tr -d '\000-\010\013-\037\177')
  if [ "$kind" = claude ]; then
    case "$msg" in /*|'!'*|'#'*|'@'*) msg=" $msg" ;; esac
  else
    case "$(_trim "$msg")" in '!'*) _die "Codex runs a message starting with '!' as a shell command (by its design), not chat — reword it (e.g. lead with a word), or run a command with: overseer winsh $target '<cmd>'" ;; esac
  fi
  want=$(_trim "$msg"); nl=$(printf '%s' "$msg" | tr -cd '\n' | wc -c)
  _win_clear_box || return 2
  b64=$(printf '%s' "$msg" | base64 | tr -d '\n')
  _win_client paste "-B64 $b64" >/dev/null || return 3
  for i in $(seq 1 8); do
    snap=$(_win_snap) || { _nap; continue; }
    if [ "$nl" = 0 ]; then
      got=$(printf '%s\n' "$snap" | sed -nE 's/^[[:space:]]*[>❯›][[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' | tail -1)
      [ "$got" = "$want" ] && return 0
    else
      chip=$(printf '%s\n' "$snap" | grep -oE 'Pasted text #[0-9]+ \+[0-9]+ lines' | tail -1)
      if [ -n "$chip" ]; then
        got=$(printf '%s' "$chip" | grep -oE '\+[0-9]+' | tr -cd '0-9')
        { [ "$got" = "$nl" ] || [ "$got" = "$((nl + 1))" ]; } && return 0
      fi
      printf '%s\n' "$snap" | grep -qF "$(printf '%s' "$want" | tail -1)" && return 0
    fi
    _nap
  done
  _win_clear_box
  return 4
}
_win_sig() { printf '%s:%s' "$(_win_field "$1" mtime)" "$(_win_field "$1" size)"; }
_win_wait_turn() {
  local kind="$1" base="$2" lastsig="$3" timeout="$4" tmp="$5"
  local deadline=$((SECONDS + timeout)) st tx sig cur i=0
  while [ "$SECONDS" -lt "$deadline" ]; do
    _nap; _nap
    i=$((i + 1))
    st=$(_win_call stat)
    [ "$(_win_field "$st" alive)" = False ] && return 3
    tx=$(_win_field "$st" transcript); sig=$(_win_sig "$st")
    [ -n "$tx" ] && ! _win_txok "$tx" && _die "the broker on $_WH reported an unexpected transcript path ('$tx') — refusing to fetch it (a valid path is an absolute Windows .jsonl under the agent's session dir); peek: overseer winpeek $_WH"
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
  st=$(_win_call stat)
  _WKIND=$(_win_field "$st" kind)
  _WTX=$(_win_field "$st" transcript)
  _WSIG=$(_win_sig "$st")
  [ -n "$_WTX" ] && ! _win_txok "$_WTX" && _die "the broker on $target reported an unexpected transcript path ('$_WTX') — refusing to fetch it; peek: overseer winpeek $target"
  case "$_WKIND" in claude|codex) : ;; *) _die "the broker on $target is hosting '${_WKIND:-?}', not an agent — start one with: overseer winbroker $target claude|codex" ;; esac
  [ "$(_win_field "$st" alive)" = False ] && _die "the broker's agent on $target has exited — restart it: overseer winbroker $target $_WKIND"
  return 0
}
cmd_winbroker() {
  _need ssh; _need scp; _need base64
  local target="${1:-}" which="${2:-pwsh}" wd="${3:-}"
  [ -n "$target" ] || _die "usage: overseer winbroker <host>[/name] [pwsh|claude|codex] [workdir]   (start a VISIBLE broker on a remote WINDOWS host's console hosting pwsh/claude/codex; then drive it with winpeek/winkeys/winsh/winchat/winread/winwait. Add /name to run several side by side — see: overseer winlist <host>. Re-run to switch the child. Default child pwsh, default workdir = the host's Windows Terminal default)"
  _win_split "$target"
  case "$which" in pwsh|claude|codex) : ;; *) _die "child must be pwsh, claude, or codex (got '$which')" ;; esac
  local d="$_dir" f
  for f in win-broker.ps1 win-client.ps1 win-launch.ps1; do [ -f "$d/$f" ] || _die "missing payload: $d/$f"; done
  _lock_pane "win-$target"
  _win_stage \
    && _win_scp "$_WH" "$d/win-broker.ps1" C:/ProgramData/overseer/payloads/overseer-win-broker.ps1 \
    && _win_scp "$_WH" "$d/win-client.ps1" C:/ProgramData/overseer/payloads/overseer-win-client.ps1 \
    && _win_scp "$_WH" "$d/win-launch.ps1" C:/ProgramData/overseer/payloads/overseer-win-launch.ps1 \
    || { _unlock_pane; _die "could not stage payloads on $_WH (check ssh/scp and administrator access)"; }
  local wdb64 cmd cmdb64 out line snap i ready=0
  wdb64=$(printf '%s' "$wd" | base64 | tr -d '\n'); [ -n "$wdb64" ] || wdb64=fg==
  cmd=$(_win_agent_cmd "$which")
  case "$cmd" in *[!A-Za-z0-9_.-]*) _die "the agent command for '$which' must be letters, digits, '.', '_' or '-' (got '$cmd')" ;; esac
  cmdb64=$(printf '%s' "$cmd" | base64 | tr -d '\n'); [ -n "$cmdb64" ] || cmdb64=fg==
  if ! out=$(_win_ssh "$_WH" "powershell -NoProfile -ExecutionPolicy Bypass -File \"%ProgramData%\\overseer\\payloads\\overseer-win-launch.ps1\" -Broker $_WP -Which $which -WorkDirB64 $wdb64 -CmdB64 $cmdb64"); then
    _unlock_pane
    _die "could not start broker on $_WH: $out"
  fi
  line=$(printf '%s\n' "$out" | grep -aE '^(OK|ERR) ' | head -1)
  case "$line" in
    OK\ *)
      for i in $(seq 1 8); do
        if snap=$(_win_snap) && [ -n "$(printf '%s' "$snap" | tr -d '[:space:]')" ]; then ready=1; break; fi
        _nap
      done
      [ "$ready" = 1 ] || { _unlock_pane; _die "broker on $target started but its child did not paint a screen"; } ;;
    *) _unlock_pane; _die "broker launch failed on $target: ${line:-$out}" ;;
  esac
  _unlock_pane
  printf '%s\n' "$line"
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
  _win_snap
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
        out=$(_win_call key "-Name $a") ;;
      *)
        b64=$(printf '%s' "$a" | base64 | tr -d '\n')
        out=$(_win_call type "-B64 $b64") ;;
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
  _lock_pane "win-$target"
  local st kind
  st=$(_win_call stat); kind=$(_win_field "$st" kind)
  [ "$kind" = shell ] || { _unlock_pane; _die "the broker on $target is hosting '${kind:-?}', not a shell — winsh would type the command into the agent's chat box. Start a shell broker (overseer winbroker $target pwsh), or talk to the agent with: overseer winchat $target '<prompt>'"; }
  [ "$(_win_field "$st" alive)" = False ] && { _unlock_pane; _die "the broker's shell on $target has exited — restart it: overseer winbroker $target pwsh"; }
  local t1 t2 inject b64
  t1="OVSH1$$"; t2="OVSH2$$"
  inject='Write-Host "'"$t1"'"; $global:LASTEXITCODE = $null; '"$cmd"'; $o=$?; $c=$LASTEXITCODE; if ($null -eq $c) { $c = if ($o) { 0 } else { 1 } }; Write-Host "'"$t2"':$c"'
  b64=$(printf '%s\r' "$inject" | base64 | tr -d '\n')
  local out
  out=$(_win_client sh "-B64 $b64 -T1 $t1 -T2 $t2 -TimeoutSec $timeout") || true
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
  _lock_pane "win-$target"
  _win_agent_ctx "$target"
  local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/overseer-wintx.XXXXXX") || { _unlock_pane; _die "mktemp failed"; }
  _WTMP="$tmp"; trap '_win_rmtmp' EXIT
  trap '_win_rmtmp; trap - INT TERM EXIT; kill -INT $$' INT TERM
  local base=0 lastsig=''
  if [ -n "$_WTX" ]; then
    if ! _win_fetch "$_WH" "$_WTX" "$tmp"; then
      [ "$force" = 0 ] && { _unlock_pane; _die "could not fetch the transcript from $_WH, so the mid-turn guard cannot run — retry, or bypass it deliberately with --force"; }
    fi
    base=$(_h_turn_count "$_WKIND" "$tmp"); base="${base:-0}"
    lastsig="$_WSIG"
    if [ "$force" = 0 ] && _h_is_busy "$_WKIND" "$tmp"; then
      _unlock_pane
      _die "the agent on $target looks mid-turn; wait: overseer winwait $target — or interrupt it: overseer winkeys $target Escape. If it is actually idle (a turn was aborted mid-tool), rerun with --force"
    fi
  fi
  if ! _win_deliver "$target" "$_WKIND" "$prompt"; then
    _unlock_pane; rm -f "$tmp"
    _die "$(_win_undelivered "$target")"
  fi
  if [ "$confirm" = 1 ]; then
    printf 'verified in box:\n%s\n--- press Enter to send, Ctrl-C to abort: ' "$prompt"
    read -r _ </dev/tty || { _win_clear_box; _unlock_pane; rm -f "$tmp"; _die "aborted (the prompt was cleared from the remote input box)"; }
  fi
  if ! _win_client key "-Name Enter" >/dev/null; then
    _win_clear_box; _unlock_pane; rm -f "$tmp"
    _die "could not submit the prompt on $target — peek: overseer winpeek $target"
  fi
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
  local out; out=$(_win_client quit) || true
  _unlock_pane
  printf '%s\n' "$out"
  case "$out" in *ERR\ *) return 1 ;; esac
}
