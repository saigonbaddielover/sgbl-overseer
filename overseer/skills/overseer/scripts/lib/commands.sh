# shellcheck shell=bash

cmd_list() {
  _need tmux
  if [ "${1:-}" = --all ]; then
    printf 'SESSION\tPANE\tPANE_PID\tCOMMAND\tCWD\n'
    while IFS=$'\t' read -r s pid_id pp cmd; do
      local cwd; cwd=$(readlink "/proc/$pp/cwd" 2>/dev/null || echo '?')
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
  [ "$force" = 0 ] && [ -n "$path" ] && [ -f "$path" ] && _h_is_busy "$kind" "$path" && _die "session looks mid-turn; wait: overseer wait $target — or interrupt: overseer keys $target Escape. If it is actually idle (a turn was aborted mid-tool), rerun with --force"

  _deliver "$pane" "$kind" "$msg" || _die "could not place/verify message in input box"
  if [ "$confirm" = 1 ]; then
    printf 'verified in box:\n%s\n--- press Enter to send, Ctrl-C to abort: ' "$msg"
    read -r _ </dev/tty || { _clear_box "$pane"; _die "aborted"; }
  fi
  _submit "$pane" || _die "could not confirm the message submitted (it may still be in the input box) — peek: overseer peek $target"
  printf 'sent to %s:\n%s\n' "$pane" "$msg"
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
  local timeout="${3:-600}"; _uint "$timeout"
  local ctx pane kind path; ctx=$(_target_ctx "$target") || _die "no agent pane (claude/codex) for target: $target (if the session is split, target the pane id %N — see: overseer list)"
  IFS=$'\t' read -r pane kind path <<< "$ctx"
  [ -n "$path" ] && [ -f "$path" ] || _die "no transcript yet for '$target' (a brand-new session with 0 turns has none) — send its first message with: overseer send $target '<msg>' (send needs no transcript); after one turn chat/read/wait work"
  [ "$force" = 0 ] && _h_is_busy "$kind" "$path" && _die "session looks mid-turn; wait: overseer wait $target — or interrupt: overseer keys $target Escape. If it is actually idle (a turn was aborted mid-tool), rerun with --force"

  local sid base since; sid=''; [ "$kind" = claude ] && sid=$(basename "$path" .jsonl); base=$(_h_turn_count "$kind" "$path")
  _deliver "$pane" "$kind" "$msg" || _die "could not place/verify message in input box"
  if [ "$confirm" = 1 ]; then
    printf 'verified in box:\n%s\n--- press Enter to send, Ctrl-C to abort: ' "$msg"
    read -r _ </dev/tty || { _clear_box "$pane"; _die "aborted"; }
  fi
  since=$(date +%s)
  _submit "$pane" || _die "could not confirm the message submitted (it may still be in the input box) — peek: overseer peek $target"
  printf '# sent to %s (waiting for reply...)\n' "$pane" >&2
  local rc=0; _wait_reply "$kind" "$path" "$base" "$timeout" "$sid" "$since" "$pane" || rc=$?
  case "$rc" in
    0) if _awaiting "$pane" >/dev/null 2>&1; then _report_awaiting "$pane" "$target"
       else printf '## reply:\n%s\n' "$(_h_last_reply "$kind" "$path")"; fi ;;
    2) _report_awaiting "$pane" "$target" ;;
    *) _die "timeout after ${timeout}s — the turn is still running. Do NOT rerun chat (it would send the message again); resume waiting instead: overseer wait $target   then   overseer read $target" ;;
  esac
}
cmd_wait() {
  _need tmux; _need jq
  local target="${1:-}" timeout="${2:-600}"; [ -n "$target" ] || _die "usage: overseer wait <pane|session> [timeout_s]"
  _uint "$timeout"
  local ctx pane kind path; ctx=$(_target_ctx "$target") || _die "no agent pane (claude/codex) for target: $target (if the session is split, target the pane id %N — see: overseer list)"
  IFS=$'\t' read -r pane kind path <<< "$ctx"
  if _awaiting "$pane" >/dev/null 2>&1; then _report_awaiting "$pane" "$target"; return 0; fi
  [ -n "$path" ] && [ -f "$path" ] || _die "no transcript yet for '$target' (a brand-new session with 0 turns has none)"
  # already ended a turn -> idle; mid-turn -> wait for the turn to end
  if _h_is_busy "$kind" "$path"; then
    local sid rc; sid=''; [ "$kind" = claude ] && sid=$(basename "$path" .jsonl)
    rc=0; _wait_reply "$kind" "$path" "$(_h_turn_count "$kind" "$path")" "$timeout" "$sid" "$(date +%s)" "$pane" || rc=$?
    case "$rc" in
      0) if _awaiting "$pane" >/dev/null 2>&1; then _report_awaiting "$pane" "$target"; else echo "idle"; fi ;;
      2) _report_awaiting "$pane" "$target" ;;
      *) _die "timeout after ${timeout}s" ;;
    esac
  else
    echo "idle"
  fi
}
# turn-based interaction with a PLAIN shell pane (not a claude TUI): run one command line, wait for
# it to finish, print its output + exit code. completion is a unique sentinel line the wrapped
# command prints last (prompt-agnostic, unlike watching for PS1). the user watches it run live.
cmd_sh() {
  _need tmux
  local target="${1:-}" cmd="${2:-}" timeout="${3:-600}"
  [ -n "$target" ] && [ -n "$cmd" ] || _die "usage: overseer sh <pane|session> <command> [timeout_s]"
  _uint "$timeout"
  case "$cmd" in *$'\n'*) _die "one command line only (chain with ; or &&)" ;; esac
  local pane cur
  pane=$(_resolve_pane "$target") || _die "no tmux pane for target: $target"
  cur=$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null) || _die "pane $pane vanished"
  case "$cur" in
    bash|zsh|sh|fish|dash|ksh|-bash|-zsh|-sh) : ;;
    *) _die "pane $pane is running '$cur', not an idle shell; refusing (try keys/peek, or chat for a claude pane)" ;;
  esac
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
  _clear_box "$pane" || true
  tmux send-keys -t "$pane" C-c
  [ "$kind" = claude ] && { _nap; tmux send-keys -t "$pane" C-c; }
  local i now
  for i in $(seq 1 20); do
    now=$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null)
    case "$now" in
      bash|zsh|sh|fish|dash|ksh|-bash|-zsh|-sh) printf '%s exited; pane %s is now: %s\n' "$kind" "$pane" "$now"; return 0 ;;
    esac
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
    2) printf '  [ok]   no %s transcript on disk yet — nothing to probe\n' "$kind" ;;
    3) printf '  [ok]   newest %s transcript has no completed turn yet — nothing to probe\n' "$kind" ;;
  esac
}
# preflight the runtime: the requirements (Linux/proc, tmux, jq) and — crucially — whether Claude
# Code's on-disk session state is where discovery expects it. Run this first when a pane "can't be
# found": a missing sessions dir usually means no claude is running OR Claude Code changed its layout.
cmd_doctor() {
  local bad=0 n cver cxv
  printf 'overseer doctor (CLAUDE_HOME=%s)\n' "$CLAUDE_HOME"
  if [ "$(uname -s)" = Linux ]; then printf '  [ok]   Linux\n'; else printf '  [FAIL] not Linux — discovery needs /proc\n'; bad=1; fi
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
  [ "$bad" = 0 ] && printf 'doctor: OK\n' || { printf 'doctor: missing hard requirements above\n'; return 1; }
}
