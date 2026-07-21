# shellcheck shell=bash

cmd_list() {
  _need tmux
  if [ "${1:-}" = --all ]; then
    printf 'SESSION\tPANE\tPANE_PID\tCOMMAND\tCWD\n'
    while IFS=$'\t' read -r s pid_id pp cmd; do
      local cwd; cwd=$(_p_cwd "$pp" || echo '?')
      printf '%s\t%s\t%s\t%s\t%s\n' "$s" "$pid_id" "$pp" "$cmd" "$cwd"
    done < <(tmux list-panes -a -F '#{session_name}	#{pane_id}	#{pane_pid}	#{pane_current_command}' 2>/dev/null)
    return
  fi
  printf 'SESSION\tPANE\tPANE_PID\tHARNESS\tCWD\n'
  _panes
}
cmd_read() {
  _need tmux; _need jq
  local target="${1:-}"; [ -n "$target" ] || _die "usage: overseer read <pane|session>"
  local ctx pane kind path; ctx=$(_target_ctx "$target") || _die "no agent pane (claude/codex) for target: $target (if the session is split, target the pane id %N — see: overseer list)"
  IFS=$'\t' read -r pane kind path <<< "$ctx"
  [ -n "$path" ] && [ -f "$path" ] || _die "no transcript yet for '$target' (a brand-new session with 0 turns has none)"
  printf '# pane=%s harness=%s\n## last user prompt:\n%s\n\n## last assistant reply:\n%s\n' \
    "$pane" "$kind" "$(_h_last_prompt "$kind" "$path")" "$(_h_last_reply "$kind" "$path")"
}
# dump the pane's current screen. default: the WHOLE visible screen (features like /status fill it;
# truncating loses the top). `raw` keeps ANSI colors so an active tab / selected row — shown by a
# background highlight, invisible in plain text — can be read, which menu navigation needs. an
# optional trailing line count caps plain output to the last N lines.
cmd_peek() {
  _need tmux
  local raw=0
  case "${1:-}" in raw|-e|--raw) raw=1; shift ;; esac
  local target="${1:-}" n="${2:-0}"
  [ -n "$target" ] || _die "usage: overseer peek [raw] <pane|session> [lines]"
  local pane; pane=$(_resolve_pane "$target") || _die "no tmux pane for target: $target"
  if [ "$raw" = 1 ]; then
    tmux capture-pane -e -p -t "$pane" 2>/dev/null
  elif [ "$n" -gt 0 ] 2>/dev/null; then
    tmux capture-pane -p -t "$pane" 2>/dev/null | grep -vE '^\s*$' | tail -n "$n"
  else
    tmux capture-pane -p -t "$pane" 2>/dev/null | grep -vE '^\s*$'
  fi
}
# send raw tmux keys (Enter, Escape, y, Up, Down, C-c, ...) — for answering prompts / menus.
cmd_keys() {
  _need tmux
  local target="${1:-}"; shift || true
  [ -n "$target" ] && [ "$#" -gt 0 ] || _die "usage: overseer keys <pane|session> <key>..."
  local pane; pane=$(_resolve_pane "$target") || _die "no tmux pane for target: $target"
  tmux send-keys -t "$pane" "$@"
  printf 'sent keys to %s: %s\n' "$pane" "$*"
}
cmd_send() {
  _need tmux
  local confirm=1 force=0
  while :; do case "${1:-}" in --yes) confirm=0; shift ;; --force) force=1; shift ;; *) break ;; esac; done
  local target="${1:-}" msg
  [ -n "$target" ] || _die "usage: overseer send [--yes] [--force] <pane|session> <message|->"
  msg=$(_read_msg "${2:-}")
  [ -n "$msg" ] || _die "usage: overseer send [--yes] [--force] <pane|session> <message|->  (empty message)"
  local ctx pane kind path; ctx=$(_target_ctx "$target") || _die "no agent pane (claude/codex) for target: $target (if the session is split, target the pane id %N — see: overseer list)"
  IFS=$'\t' read -r pane kind path <<< "$ctx"
  _lock_pane "$pane"
  [ "$force" = 0 ] && [ -n "$path" ] && [ -f "$path" ] && _h_is_busy "$kind" "$path" && _die "session looks mid-turn; wait: overseer wait $target — or interrupt: overseer keys $target Escape. If it is actually idle (a turn was aborted mid-tool), rerun with --force"
  local base; base=$(_h_turn_count "$kind" "$path" 2>/dev/null); base="${base:-0}"
  local bbytes; bbytes=$(_fsize "$path")
  local sid=''; [ "$kind" = claude ] && [ -n "$path" ] && [ -f "$path" ] && sid=$(_sid_from_jsonl "$path")

  _deliver "$pane" "$kind" "$msg" || _die "could not place/verify message in input box"
  if [ "$confirm" = 1 ]; then
    printf 'verified in box:\n%s\n--- press Enter to send, Ctrl-C to abort: ' "$msg"
    read -r _ </dev/tty || { _clear_box "$pane"; _die "aborted"; }
  fi
  local since; since=$(date +%s)
  _submit "$pane" || _die "could not confirm the message submitted (it may still be in the input box) — peek: overseer peek $target"
  _unlock_pane
  local rc=0; path=$(_wait_started "$target" "$kind" "$path" "$base" 10 "$pane" "$sid" "$since" "$bbytes") || rc=$?
  case "$rc" in
    2) printf 'sent to %s:\n%s\n' "$pane" "$msg"; _report_awaiting "$pane" "$target" ;;
    1) printf 'sent to %s:\n%s\n(could not confirm the turn started within 10s — peek: overseer peek %s)\n' "$pane" "$msg" "$target" ;;
    *) printf 'sent to %s (turn started):\n%s\n' "$pane" "$msg" ;;
  esac
}
# send + wait for the turn to finish + print the reply (the human round-trip).
cmd_chat() {
  _need tmux; _need jq
  local confirm=1 force=0
  while :; do case "${1:-}" in --yes) confirm=0; shift ;; --force) force=1; shift ;; *) break ;; esac; done
  local target="${1:-}" msg
  [ -n "$target" ] || _die "usage: overseer chat [--yes] [--force] <pane|session> <message|-> [timeout_s]"
  msg=$(_read_msg "${2:-}")
  [ -n "$msg" ] || _die "usage: overseer chat [--yes] [--force] <pane|session> <message|-> [timeout_s]  (empty message)"
  local timeout="${3:-$DEFAULT_TIMEOUT}"; _uint "$timeout"
  local ctx pane kind path; ctx=$(_target_ctx "$target") || _die "no agent pane (claude/codex) for target: $target (if the session is split, target the pane id %N — see: overseer list)"
  IFS=$'\t' read -r pane kind path <<< "$ctx"
  _lock_pane "$pane"
  local has_tx=0; { [ -n "$path" ] && [ -f "$path" ]; } && has_tx=1
  [ "$force" = 0 ] && [ "$has_tx" = 1 ] && _h_is_busy "$kind" "$path" && _die "session looks mid-turn; wait: overseer wait $target — or interrupt: overseer keys $target Escape. If it is actually idle (a turn was aborted mid-tool), rerun with --force"

  local sid='' base=0 since bbytes=''
  if [ "$has_tx" = 1 ]; then
    [ "$kind" = claude ] && sid=$(_sid_from_jsonl "$path"); base=$(_h_turn_count "$kind" "$path"); bbytes=$(_fsize "$path")
  fi
  _deliver "$pane" "$kind" "$msg" || _die "could not place/verify message in input box"
  if [ "$confirm" = 1 ]; then
    printf 'verified in box:\n%s\n--- press Enter to send, Ctrl-C to abort: ' "$msg"
    read -r _ </dev/tty || { _clear_box "$pane"; _die "aborted"; }
  fi
  since=$(date +%s)
  _submit "$pane" || _die "could not confirm the message submitted (it may still be in the input box) — peek: overseer peek $target"
  _unlock_pane
  printf '# sent to %s (waiting for reply...)\n' "$pane" >&2
  if [ "$has_tx" = 0 ]; then
    path=$(_wait_started "$target" "$kind" "$path" 0 30 "$pane") || true
    { [ -z "$path" ] || [ ! -f "$path" ]; } && _die "sent, but no transcript appeared for '$target' within 30s — check it with: overseer peek $target ; then resume: overseer wait $target"
    [ "$kind" = claude ] && sid=$(_sid_from_jsonl "$path")
  fi
  local rc=0; _wait_reply "$kind" "$path" "$base" "$timeout" "$sid" "$since" "$pane" "$bbytes" || rc=$?
  case "$rc" in
    0) if _awaiting "$pane" >/dev/null 2>&1; then _report_awaiting "$pane" "$target"
       else printf '## reply:\n%s\n' "$(_h_last_reply "$kind" "$path")"; fi ;;
    2) _report_awaiting "$pane" "$target" ;;
    3) _die "the agent in $pane exited mid-turn (its pane dropped to a shell) — no reply was produced; peek: overseer peek $target" ;;
    *) _die "timeout after ${timeout}s — the turn is still running. Do NOT rerun chat (it would send the message again); resume waiting instead: overseer wait $target   then   overseer read $target" ;;
  esac
}
cmd_wait() {
  _need tmux; _need jq
  local target="${1:-}" timeout="${2:-$DEFAULT_TIMEOUT}"; [ -n "$target" ] || _die "usage: overseer wait <pane|session> [timeout_s]"
  _uint "$timeout"
  local ctx pane kind path; ctx=$(_target_ctx "$target") || _die "no agent pane (claude/codex) for target: $target (if the session is split, target the pane id %N — see: overseer list)"
  IFS=$'\t' read -r pane kind path <<< "$ctx"
  if _awaiting "$pane" >/dev/null 2>&1; then _report_awaiting "$pane" "$target"; return 0; fi
  [ -n "$path" ] && [ -f "$path" ] || _die "no transcript yet for '$target' (a brand-new session with 0 turns has none)"
  # already ended a turn -> idle; mid-turn -> wait for the turn to end
  if _h_is_busy "$kind" "$path"; then
    local sid rc; sid=''; [ "$kind" = claude ] && sid=$(_sid_from_jsonl "$path")
    rc=0; _wait_reply "$kind" "$path" "$(_h_turn_count "$kind" "$path")" "$timeout" "$sid" "$(date +%s)" "$pane" "$(_fsize "$path")" || rc=$?
    case "$rc" in
      0) if _awaiting "$pane" >/dev/null 2>&1; then _report_awaiting "$pane" "$target"; else echo "idle"; fi ;;
      2) _report_awaiting "$pane" "$target" ;;
      3) _die "the agent in $pane exited mid-turn (its pane dropped to a shell); peek: overseer peek $target" ;;
      *) _die "timeout after ${timeout}s" ;;
    esac
  else
    echo "idle"
  fi
}
_fleet_status() {
  local pane="$1" ctx kind path state
  ctx=$(_target_ctx "$pane") || { printf '%s\t?\t(not an agent)\n' "$pane"; return 0; }
  IFS=$'\t' read -r pane kind path <<< "$ctx"
  if _awaiting "$pane" >/dev/null 2>&1; then state=awaiting
  elif [ -n "$path" ] && [ -f "$path" ] && _h_is_busy "$kind" "$path"; then state=busy
  elif [ -n "$path" ] && [ -f "$path" ]; then state=idle
  else state='idle(0-turn)'; fi
  printf '%s\t%s\t%s\n' "$pane" "$kind" "$state"
}
cmd_fleet() {
  _need tmux
  local action="${1:-status}"; shift || true
  local -a targets=(); local sess pane pid kind cwd p msg
  local -a fl=()
  while IFS=$'\t' read -r sess pane pid kind cwd; do targets+=("$pane"); done < <(_panes)
  [ "${#targets[@]}" -gt 0 ] || _die "no agent panes found (see: overseer list)"
  case "$action" in
    status) _need jq; printf 'PANE\tHARNESS\tSTATE\n'; for p in "${targets[@]}"; do ( _fleet_status "$p" ) || true; done ;;
    read)   _need jq; for p in "${targets[@]}"; do printf '===== %s =====\n' "$p"; ( cmd_read "$p" ) || printf '(unavailable)\n'; done ;;
    wait)   _need jq; for p in "${targets[@]}"; do printf '# %s: ' "$p"; ( cmd_wait "$p" "$@" ) || true; done ;;
    send|chat)
      [ "$action" = chat ] && _need jq
      while :; do case "${1:-}" in --yes|--force) fl+=("$1"); shift ;; *) break ;; esac; done
      msg="${1:-}"; [ -n "$msg" ] || _die "usage: overseer fleet $action [--yes] [--force] <message>  (broadcasts to every agent pane)"
      for p in "${targets[@]}"; do
        printf '===== %s =====\n' "$p"
        if [ "$action" = send ]; then ( cmd_send ${fl[@]+"${fl[@]}"} "$p" "$msg" ) || true
        else ( cmd_chat ${fl[@]+"${fl[@]}"} "$p" "$msg" ) || true; fi
      done ;;
    *) _die "usage: overseer fleet [status|read|wait [timeout]|send [--yes] [--force] <msg>|chat [--yes] [--force] <msg>]  (no subcommand = status)" ;;
  esac
}
# turn-based interaction with a PLAIN shell pane (not a claude TUI): run one command line, wait for
# it to finish, print its output + exit code. completion is a unique sentinel line the wrapped
# command prints last (prompt-agnostic, unlike watching for PS1). the user watches it run live.
cmd_sh() {
  _need tmux
  local target="${1:-}" cmd="${2:-}" timeout="${3:-$DEFAULT_TIMEOUT}"
  [ -n "$target" ] && [ -n "$cmd" ] || _die "usage: overseer sh <pane|session> <command> [timeout_s]"
  _uint "$timeout"
  case "$cmd" in *$'\n'*) _die "one command line only (chain with ; or &&)" ;; esac
  local pane cur
  pane=$(_resolve_pane "$target") || _die "no tmux pane for target: $target"
  cur=$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null) || _die "pane $pane vanished"
  _is_shell "$cur" || _die "pane $pane is running '$cur', not an idle shell; refusing (try keys/peek, or chat for a claude pane)"
  _lock_pane "$pane"
  local tok; tok="TMC_$$_$(date +%s%N | tail -c 7)"
  local esc; esc=$(printf '%s' "$cmd" | sed "s/'/'\\\\''/g")   # for a single-quoted eval arg
  # BEGIN/END sentinels (each printf on its own line) delimit the output so the command echo can't
  # leak in. run the command via `eval` under a TEMPORARY env: pagers -> cat (git log / man / less
  # won't seize the pane), NO_COLOR for clean capture, and stdin from /dev/null (cat / python / ssh
  # get EOF instead of hanging). the env prefix does not persist and eval runs in the CURRENT shell,
  # so cd/export in the command still take effect. $? is the command's exit (BEGIN printf ran first).
  local wrapped="printf '\n%s\n' ${tok}B ; PAGER=cat GIT_PAGER=cat SYSTEMD_PAGER=cat NO_COLOR=1 eval '$esc' </dev/null ; printf '\n%s:%s\n' $tok \"\$?\""
  _wake_pane "$pane"
  tmux send-keys -t "$pane" C-u
  tmux send-keys -t "$pane" -l "$wrapped"
  tmux send-keys -t "$pane" Enter
  local deadline=$((SECONDS + timeout)) found=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    tmux capture-pane -p -t "$pane" 2>/dev/null | grep -qE "^${tok}:[0-9]+$" && { found=1; break; }
    _nap
  done
  # a non-terminating command (infinite loop) still runs past the timeout; Ctrl-C it so the pane is
  # left at a usable prompt instead of stuck, then fail.
  [ -n "$found" ] || { tmux send-keys -t "$pane" C-c; _die "timeout after ${timeout}s (sent Ctrl-C to stop it; peek: overseer peek $target)"; }
  local cap out rc
  cap=$(tmux capture-pane -p -S - -t "$pane" 2>/dev/null)
  rc=$(printf '%s\n' "$cap" | grep -E "^${tok}:[0-9]+$" | tail -1); rc=${rc##*:}
  if ! printf '%s\n' "$cap" | grep -qF "${tok}B"; then
    printf '# pane=%s exit=%s\n(the output was longer than the pane scrollback, so its start scrolled out of tmux history and cannot be captured whole; re-run redirecting to a file — append " > out.txt 2>&1" — then read the file)\n' "$pane" "$rc"
    return 0
  fi
  out=$(printf '%s\n' "$cap" | awk -v b="${tok}B" -v e="^${tok}:[0-9]+$" '
    $0 == b { s=1; next }
    s && $0 ~ e { exit }
    s { print }
  ')
  printf '# pane=%s exit=%s\n%s\n' "$pane" "$rc" "$out"
}
# quit the Claude Code TUI in a pane WITHOUT killing tmux, revealing the shell underneath. exit is
# two Ctrl-C within a short window ("Press Ctrl-C again to exit"), so the taps must go together —
# across separate calls the second arrives after the window closes. clears the box first (so C-c
# triggers exit, not a text-clear), then confirms the pane actually left claude.
cmd_quit() {
  _need tmux
  local target="${1:-}"; [ -n "$target" ] || _die "usage: overseer quit <pane|session>"
  local pane pp kind; pane=$(_resolve_pane "$target") || _die "no tmux pane for target: $target"
  pp=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null) || _die "pane $pane vanished"
  kind=$(_harness_of "$pp") || _die "pane $pane is running '$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null)', not a claude/codex agent; nothing to quit"
  _lock_pane "$pane"
  _clear_box "$pane" || true
  tmux send-keys -t "$pane" C-c
  [ "$kind" = claude ] && { _nap; tmux send-keys -t "$pane" C-c; }
  local i now
  for i in $(seq 1 20); do
    now=$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null)
    _is_shell "$now" && { printf '%s exited; pane %s is now: %s\n' "$kind" "$pane" "$now"; return 0; }
    [ "$i" = 8 ] && { tmux send-keys -t "$pane" C-c; [ "$kind" = claude ] && { _nap; tmux send-keys -t "$pane" C-c; }; }
    _nap
  done
  _die "sent Ctrl-C but pane $pane still shows '$now' (peek it — maybe mid-turn or a dialog is open)"
}
# invoke a Claude slash command in a pane (/resume, /clear, /model, ...). send/chat can't: they
# prepend a space so a leading / stays literal text; this types it AS a command and submits. commands
# that open a menu (/resume, /model) then need keys + peek to navigate (Up/Down, Enter, Esc).
cmd_slash() {
  _need tmux
  local target="${1:-}" slash="${2:-}"
  [ -n "$target" ] && [ -n "$slash" ] || _die "usage: overseer slash <pane|session> </command>"
  case "$slash" in /*) : ;; *) slash="/$slash" ;; esac   # accept 'resume' or '/resume'
  case "$slash" in *$'\n'*) _die "one slash command line only" ;; esac
  local pane pp kind; pane=$(_resolve_pane "$target") || _die "no tmux pane for target: $target"
  pp=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null)
  kind=$(_harness_of "$pp") || _die "pane $pane is not a claude/codex agent; slash commands need an agent TUI"
  _lock_pane "$pane"
  _clear_box "$pane" || _die "could not clear the input box"
  tmux send-keys -t "$pane" -l "$slash"
  local i got; for i in $(seq 1 40); do [ "$(_realtext "$pane")" = "$slash" ] && break; _nap; done
  got=$(_realtext "$pane")
  [ "$got" = "$slash" ] || { _clear_box "$pane"; _die "input shows '$got', expected '$slash'"; }
  tmux send-keys -t "$pane" Enter
  printf 'ran %s in %s (harness=%s) — peek it (a menu needs keys to navigate: Up/Down, Enter, Esc)\n' "$slash" "$pane" "$kind"
}
# navigate a tab bar / highlighted list so <name> becomes the active item, then stop. verify-driven:
# press ONE nav key, re-read the highlight, repeat until <name> is active or we have cycled — never
# counts keystrokes (a key can double-register and a tab bar wraps, so counting is unreliable).
# nav-key defaults to Right (a tab bar); pass Down (or Up) for a vertical list. does NOT select —
# follow with `keys <t> Enter` to pick, or `peek` to read the tab you landed on.
cmd_menu() {
  _need tmux
  local target="${1:-}" name="${2:-}" navkey="${3:-Right}"
  [ -n "$target" ] && [ -n "$name" ] || _die "usage: overseer menu <pane|session> <item-name> [nav-key]"
  local pane; pane=$(_resolve_pane "$target") || _die "no tmux pane for target: $target"
  _lock_pane "$pane"
  _wake_pane "$pane"
  local i sig
  local -A seen=()
  for i in $(seq 1 60); do
    _is_active "$pane" "$name" && { printf 'active: %s (pane %s)\n' "$name" "$pane"; return 0; }
    # stop when the screen repeats a state already seen: the menu has wrapped a full cycle without
    # the item appearing. handles a short tab bar and a long scrolling list alike, no magic count.
    sig=$(tmux capture-pane -e -p -t "$pane" 2>/dev/null | head -n -3 | cksum | cut -d' ' -f1)
    [ -n "${seen[$sig]:-}" ] && break
    seen[$sig]=1
    tmux send-keys -t "$pane" "$navkey"
    _nap; _nap   # let the highlight settle before re-reading
  done
  _is_active "$pane" "$name" && { printf 'active: %s (pane %s)\n' "$name" "$pane"; return 0; }
  _die "could not make '$name' active (cycled the whole view without it becoming highlighted — is it an item here? try: overseer peek raw $target)"
}
_doctor_probe() {
  local kind="$1" jl rc n
  jl=$(_probe_contract "$kind") && rc=0 || rc=$?
  case "$rc" in
    0) n=$(_h_turn_count "$kind" "$jl"); printf '  [ok]   %s transcript readable (overseer parsed %s completed turns from the newest session)\n' "$kind" "$n" ;;
    1) printf '  [warn] %s transcript has completed turns but overseer cannot read the reply — its on-disk schema may have changed (see README caveats): %s\n' "$kind" "$jl" ;;
    2) printf '  [ok]   no %s session with a completed turn yet — nothing to probe\n' "$kind" ;;
  esac
}
_doctor_live() {
  command -v tmux >/dev/null 2>&1 || { printf '  [skip] live self-test: tmux not available\n'; return 0; }
  local sess="overseer-doctor-$$" pane out rc=0
  tmux new-session -d -s "$sess" -x 80 -y 24 2>/dev/null || { printf '  [skip] live self-test: could not open a throwaway tmux session\n'; return 0; }
  pane=$(tmux list-panes -t "$sess" -F '#{pane_id}' 2>/dev/null | head -1)
  if [ -n "$pane" ]; then
    out=$( ( cmd_sh "$pane" 'echo overseer-live-uptest' 15 ) 2>/dev/null ) || true
    if printf '%s' "$out" | grep -q overseer-live-uptest; then
      printf '  [ok]   live self-test: sh round-trip on a throwaway pane (send -> sentinel -> capture works end to end)\n'
    else
      printf '  [FAIL] live self-test: sh round-trip returned no marker — the tmux send-keys/capture-pane path may be broken\n'
      rc=1
    fi
  else
    printf '  [skip] live self-test: no pane in the throwaway session\n'
  fi
  tmux kill-session -t "$sess" 2>/dev/null || true
  return "$rc"
}
# preflight the runtime: the requirements (Linux/proc, tmux, jq) and — crucially — whether Claude
# Code's on-disk session state is where discovery expects it. Run this first when a pane "can't be
# found": a missing sessions dir usually means no claude is running OR Claude Code changed its layout.
cmd_doctor() {
  local bad=0 n cver cxv live=0
  case "${1:-}" in --live|live) live=1 ;; esac
  printf 'overseer doctor (CLAUDE_HOME=%s)\n' "$CLAUDE_HOME"
  if [ "$OVERSEER_OS" = Linux ]; then printf '  [ok]   Linux\n'; else printf '  [FAIL] not Linux (%s) — /proc discovery is unimplemented here; the macOS ps/lsof backend is specified in docs/PORTING.md but not built\n' "$OVERSEER_OS"; bad=1; fi
  [ -d /proc ] && printf '  [ok]   /proc present\n' || { printf '  [FAIL] /proc missing\n'; bad=1; }
  if command -v tmux >/dev/null 2>&1; then printf '  [ok]   tmux (%s)\n' "$(tmux -V 2>/dev/null)"; else printf '  [FAIL] tmux not found\n'; bad=1; fi
  if command -v jq >/dev/null 2>&1; then printf '  [ok]   jq (%s)\n' "$(jq --version 2>/dev/null)"; else printf '  [FAIL] jq not found — needed by read/chat/wait\n'; bad=1; fi
  if command -v claude >/dev/null 2>&1; then
    cver=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    printf '  [ok]   claude %s\n' "${cver:-unknown}"
  else
    printf '  [warn] claude CLI not on PATH — cannot drive claude panes\n'
  fi
  if tmux info >/dev/null 2>&1; then printf '  [ok]   tmux server running\n'; else printf '  [warn] no tmux server yet (start a tmux session to drive)\n'; fi
  if [ -d "$CLAUDE_HOME/sessions" ] && ls "$CLAUDE_HOME"/sessions/*.json >/dev/null 2>&1; then
    n=$(ls "$CLAUDE_HOME"/sessions/*.json 2>/dev/null | wc -l)
    printf '  [ok]   Claude session state found (%s/sessions/*.json: %s)\n' "$CLAUDE_HOME" "$n"
  else
    printf '  [warn] no %s/sessions/*.json — no claude running, OR Claude Code changed its on-disk layout (would break discovery; see README caveats)\n' "$CLAUDE_HOME"
  fi
  _doctor_probe claude
  if command -v codex >/dev/null 2>&1; then
    cxv=$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    printf '  [ok]   codex %s\n' "${cxv:-unknown}"
  else
    printf '  [warn] codex CLI not on PATH — codex panes cannot be driven (claude still works)\n'
  fi
  [ -d "$CODEX_HOME/sessions" ] && printf '  [ok]   Codex session state dir present (%s/sessions)\n' "$CODEX_HOME" \
    || printf '  [warn] no %s/sessions — no codex has run yet, or Codex changed its layout\n' "$CODEX_HOME"
  _doctor_probe codex
  if _awaiting_text "$(printf 'proceed?\n❯ 1. yes\n  2. no\n')" >/dev/null 2>&1; then
    printf '  [ok]   awaiting-prompt detector matches a sample menu (glyph + locale OK)\n'
  else
    printf '  [warn] awaiting-prompt detector failed on a sample menu — check the UTF-8 locale (grep may not match ❯/›); wait/chat could miss permission prompts\n'
  fi
  [ "$live" = 1 ] && { _doctor_live || bad=1; }
  [ "$bad" = 0 ] && printf 'doctor: OK\n' || { printf 'doctor: missing hard requirements above\n'; return 1; }
}
cmd_on() {
  _need ssh
  local host="${1:-}"; shift || true
  [ -n "$host" ] && [ "$#" -gt 0 ] || _die "usage: overseer on <host> <command> [args]   (run any overseer command on a remote ssh host, e.g. overseer on sandbox chat %0 'hi')"
  local bin="${OVERSEER_REMOTE_BIN:-\$HOME/.overseer/scripts/overseer}"
  local cmdir="${TMPDIR:-/tmp}/overseer-ssh-$UID"
  mkdir -p "$cmdir" 2>/dev/null || true
  local rargs; printf -v rargs ' %q' "$@"
  # shellcheck disable=SC2086
  exec ${OVERSEER_SSH:-ssh} -o ControlMaster=auto -o "ControlPath=$cmdir/%C" -o ControlPersist=60s \
    -o ConnectTimeout=10 ${OVERSEER_SSH_OPTS:-} "$host" "$bin$rargs"
}
cmd_deploy() {
  _need ssh; _need tar
  local host="${1:-}"; shift || true
  [ -n "$host" ] || _die "usage: overseer deploy <host>   (copy overseer's scripts to ~/.overseer on a remote ssh host, do this once before 'overseer on <host> ...')"
  local dest="${OVERSEER_REMOTE_DIR:-.overseer}"
  # shellcheck disable=SC2086
  tar -C "$_dir/.." -cf - scripts | ${OVERSEER_SSH:-ssh} ${OVERSEER_SSH_OPTS:-} "$host" "mkdir -p \"\$HOME/$dest\" && exec tar -C \"\$HOME/$dest\" -xf -" \
    && printf 'overseer: deployed scripts to %s:~/%s/\n' "$host" "$dest"
}
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
_win_scp() {
  # shellcheck disable=SC2086
  scp -o ConnectTimeout=12 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 ${OVERSEER_SSH_OPTS:-} "$2" "$1:$3" >/dev/null 2>&1
}
_win_fetch() {
  # shellcheck disable=SC2086
  scp -o ConnectTimeout=12 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 ${OVERSEER_SSH_OPTS:-} "$1:$2" "$3" >/dev/null 2>&1
}
_win_client() {
  _win_ssh "$1" "powershell -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%\\overseer-win-client.ps1\" -Op $2 -Pipe overseer-broker ${3:-}"
}
cmd_winbroker() {
  _need ssh; _need scp
  local host="${1:-}" which="${2:-pwsh}" wd="${3:-}"
  [ -n "$host" ] || _die "usage: overseer winbroker <host> [pwsh|claude|codex] [workdir]   (start a VISIBLE broker on a remote WINDOWS host's console hosting pwsh/claude/codex; then drive it with winpeek/winkeys/winsh/winchat. Re-run to switch the child. Default child pwsh, default workdir = the host's Windows Terminal default)"
  case "$which" in pwsh|claude|codex) : ;; *) _die "child must be pwsh, claude, or codex (got '$which')" ;; esac
  local d="$_dir" f
  for f in win-broker.ps1 win-client.ps1 win-launch.ps1; do [ -f "$d/$f" ] || _die "missing payload: $d/$f"; done
  _win_scp "$host" "$d/win-broker.ps1" overseer-win-broker.ps1 \
    && _win_scp "$host" "$d/win-client.ps1" overseer-win-client.ps1 \
    && _win_scp "$host" "$d/win-launch.ps1" overseer-win-launch.ps1 \
    || _die "could not copy payloads to $host (check ssh/scp to the host)"
  local wdq="${wd//\"/}"
  local out; out=$(_win_ssh "$host" "powershell -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%\\overseer-win-launch.ps1\" -Pipe overseer-broker -Which $which -WorkDir \"$wdq\"")
  local line; line=$(printf '%s\n' "$out" | grep -aE '^(OK|ERR) ' | head -1)
  printf '%s\n' "${line:-$out}"
}
cmd_winpeek() {
  _need ssh
  local host="${1:-}"; [ -n "$host" ] || _die "usage: overseer winpeek <host>   (snapshot the remote WINDOWS broker's screen; run 'overseer winbroker <host>' first)"
  _win_client "$host" snap
}
cmd_winkeys() {
  _need ssh; _need base64
  local host="${1:-}"; shift || true
  [ -n "$host" ] && [ "$#" -gt 0 ] || _die "usage: overseer winkeys <host> <key|text>...   (send named keys — Enter Escape Up Down Tab Backspace C-c ... — or literal text, to the remote WINDOWS broker's child)"
  local a b64 out=''
  for a in "$@"; do
    case "$a" in
      Enter|Escape|Tab|Backspace|Space|Delete|Up|Down|Left|Right|Home|End|PageUp|PageDown|C-[a-zA-Z])
        out=$(_win_client "$host" key "-Name $a") ;;
      *)
        b64=$(printf '%s' "$a" | base64 | tr -d '\n')
        out=$(_win_client "$host" type "-B64 $b64") ;;
    esac
    printf '%s\n' "$out"
  done
}
cmd_winsh() {
  _need ssh; _need base64
  local host="${1:-}" cmd="${2:-}" timeout="${3:-$DEFAULT_TIMEOUT}"
  [ -n "$host" ] && [ -n "$cmd" ] || _die "usage: overseer winsh <host> <command> [timeout_s]   (run one command line in the remote WINDOWS broker's pwsh child; start it with 'overseer winbroker <host> pwsh')"
  _uint "$timeout"
  case "$cmd" in *$'\n'*) _die "one command line only (chain with ; )" ;; esac
  local t1 t2 inject b64
  t1="OVSH1$$"; t2="OVSH2$$"
  inject='Write-Host "'"$t1"'"; '"$cmd"'; Write-Host "'"$t2"':$LASTEXITCODE"'
  b64=$(printf '%s\r' "$inject" | base64 | tr -d '\n')
  local out; out=$(_win_client "$host" sh "-B64 $b64 -T1 $t1 -T2 $t2 -TimeoutSec $timeout")
  if printf '%s\n' "$out" | grep -qaE '^EXIT '; then
    local rc body
    rc=$(printf '%s\n' "$out" | grep -aE '^EXIT ' | head -1 | awk '{print $2}')
    body=$(printf '%s\n' "$out" | awk '/^<<<OUT$/{f=1;next} /^>>>OUT$/{f=0} f{print}')
    printf '# host=%s exit=%s\n%s\n' "$host" "$rc" "$body"
  else
    printf '%s\n' "$out"
  fi
}
cmd_winchat() {
  _need ssh; _need jq; _need base64; _need scp
  local host="${1:-}" prompt="${2:-}" timeout="${3:-$DEFAULT_TIMEOUT}"
  [ -n "$host" ] && [ -n "$prompt" ] || _die "usage: overseer winchat <host> <prompt> [timeout_s]   (send a prompt to the remote WINDOWS broker's claude/codex, wait for the turn via its transcript, print the reply; start it with 'overseer winbroker <host> claude|codex')"
  _uint "$timeout"
  local info kind tx
  info=$(_win_client "$host" info)
  kind=$(printf '%s\n' "$info" | grep -oE 'kind=[a-z]+' | head -1 | cut -d= -f2)
  tx=$(printf '%s\n' "$info" | grep -oE 'transcript=[^ ]+' | head -1 | cut -d= -f2-)
  case "$kind" in claude|codex) : ;; *) _die "the broker on $host is hosting '${kind:-?}', not an agent — start one with: overseer winbroker $host claude|codex" ;; esac
  local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/overseer-wintx.XXXXXX") || _die "mktemp failed"
  local base=0
  [ -n "$tx" ] && _win_fetch "$host" "$tx" "$tmp" && base=$(_h_turn_count "$kind" "$tmp"); base="${base:-0}"
  local b64; b64=$(printf '%s' "$prompt" | base64 | tr -d '\n')
  _win_client "$host" type "-B64 $b64" >/dev/null
  _win_client "$host" key "-Name Enter" >/dev/null
  printf '# sent to %s (waiting for the turn...)\n' "$host" >&2
  local deadline=$((SECONDS + timeout)) cur
  while [ "$SECONDS" -lt "$deadline" ]; do
    _nap; _nap
    if [ -z "$tx" ]; then
      info=$(_win_client "$host" info); tx=$(printf '%s\n' "$info" | grep -oE 'transcript=[^ ]+' | head -1 | cut -d= -f2-)
      [ -n "$tx" ] || continue
    fi
    _win_fetch "$host" "$tx" "$tmp" || continue
    cur=$(_h_turn_count "$kind" "$tmp"); cur="${cur:-0}"
    if [ "$cur" -gt "$base" ]; then
      printf '## reply:\n%s\n' "$(_h_last_reply "$kind" "$tmp")"
      rm -f "$tmp"; return 0
    fi
  done
  rm -f "$tmp"
  _die "timeout after ${timeout}s waiting for the turn on $host (peek: overseer winpeek $host)"
}
cmd_winstop() {
  _need ssh
  local host="${1:-}"; [ -n "$host" ] || _die "usage: overseer winstop <host>   (stop the remote WINDOWS broker and its child)"
  _win_client "$host" quit
}
