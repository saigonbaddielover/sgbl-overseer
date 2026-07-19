# shellcheck shell=bash

# ---- pane discovery ---------------------------------------------------------
# For a pane shell pid, return the child pid that owns a ~/.claude/sessions/<pid>.json
_agent_pid() {
  local pane_pid="$1" c
  for c in "$pane_pid" $(cat "/proc/$pane_pid/task/$pane_pid/children" 2>/dev/null); do
    [ -f "$CLAUDE_HOME/sessions/$c.json" ] || continue
    [ "$(cat "/proc/$c/comm" 2>/dev/null)" = claude ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}
# every descendant pid of a pid (recursive /proc children walk), one per line.
_descendants() {
  local p="$1" c
  for c in $(cat "/proc/$p/task/$p/children" 2>/dev/null); do
    printf '%s\n' "$c"; _descendants "$c"
  done
}
# Codex has no pid-named session file; instead the running codex process holds its rollout jsonl
# OPEN, so read it straight off /proc/<pid>/fd. codex sits a level below the pane's node launcher, so
# scan all descendants. echoes the rollout path (the transcript), returns 1 if the pane runs no codex.
_codex_rollout() {
  local pane_pid="$1" pid fd tgt
  for pid in $(_descendants "$pane_pid"); do
    for fd in /proc/"$pid"/fd/*; do
      tgt=$(readlink "$fd" 2>/dev/null) || continue
      case "$tgt" in */.codex/sessions/*rollout-*.jsonl) printf '%s' "$tgt"; return 0 ;; esac
    done
  done
  return 1
}
_codex_pid() {
  local pane_pid="$1" p
  for p in $(_descendants "$pane_pid"); do
    [ "$(cat "/proc/$p/comm" 2>/dev/null)" = codex ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}
# which agent harness runs in a pane (by pane_pid): claude | codex, or return 1 for neither.
_harness_of() {
  _agent_pid "$1" >/dev/null 2>&1 && { printf claude; return 0; }
  _codex_pid "$1" >/dev/null 2>&1 && { printf codex; return 0; }
  return 1
}
# emit: <session>\t<pane_id>\t<pane_pid>\t<harness>\t<cwd> for each agent pane (claude or codex).
# prune by pane command first (claude runs as `claude`, codex as `node`) so the fd scan only runs
# on plausible panes.
_panes() {
  local s pid_id pp cmd kind cwd
  while IFS=$'\t' read -r s pid_id pp cmd; do
    case "$cmd" in
      claude) _agent_pid "$pp" >/dev/null 2>&1 && kind=claude || continue ;;
      node)   _codex_pid "$pp" >/dev/null 2>&1 && kind=codex || continue ;;
      *) continue ;;
    esac
    cwd=$(readlink "/proc/$pp/cwd" 2>/dev/null || echo '?')
    printf '%s\t%s\t%s\t%s\t%s\n' "$s" "$pid_id" "$pp" "$kind" "$cwd"
  done < <(tmux list-panes -a -F '#{session_name}	#{pane_id}	#{pane_pid}	#{pane_current_command}' 2>/dev/null)
}
# ---- session-id + transcript resolution ------------------------------------
_encode_cwd() { local p="$1"; p="${p//\//-}"; p="${p//./-}"; p="${p//_/-}"; printf '%s' "$p"; }
_sid_of() {
  local sid
  sid=$(jq -r '.sessionId // empty' "$CLAUDE_HOME/sessions/$1.json" 2>/dev/null || true)
  [ -n "$sid" ] && printf '%s' "$sid"
}
_jsonl_of() {
  local sid="$1" cwd="$2" enc f
  enc=$(_encode_cwd "$cwd")
  f=$(ls "$CLAUDE_HOME/projects/$enc/$sid"*.jsonl 2>/dev/null | head -1)
  [ -n "$f" ] || f=$(ls "$CLAUDE_HOME"/projects/*/"$sid"*.jsonl 2>/dev/null | head -1)
  printf '%s' "$f"
}
# resolve target -> "pane_id<TAB>harness<TAB>transcript_path". uses the SAME pane resolution as
# peek/keys/sh (the pane tmux would act on: a %N as-is, a session/window name -> its ACTIVE pane), so
# every command targets one pane — no split-window divergence where chat drives one pane and peek
# reads another. requires that pane to run a claude OR codex agent; returns 1 otherwise (target the
# agent pane by %N if it is split). transcript_path may be empty for a 0-turn claude session.
_target_ctx() {
  local pane pp apid cwd sid jl rf
  pane=$(_resolve_pane "$1") || return 1
  pp=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null) || return 1
  if apid=$(_agent_pid "$pp"); then
    cwd=$(readlink "/proc/$pp/cwd" 2>/dev/null || echo '?')
    sid=$(_sid_of "$apid") || true
    if [ -n "$sid" ]; then jl=$(_jsonl_of "$sid" "$cwd"); else jl=''; fi
    printf '%s\t%s\t%s' "$pane" claude "$jl"; return 0
  fi
  if _codex_pid "$pp" >/dev/null 2>&1; then
    rf=$(_codex_rollout "$pp" 2>/dev/null || true)
    printf '%s\t%s\t%s' "$pane" codex "$rf"; return 0
  fi
  return 1
}
# ---- commands ---------------------------------------------------------------
# resolve any target (pane id %N, or a session/window name) to the pane id tmux would act on.
# unlike _resolve, not restricted to claude panes — used by peek/keys/sh.
_resolve_pane() {
  local p; p=$(tmux display-message -p -t "$1" '#{pane_id}' 2>/dev/null) || return 1
  [ -n "$p" ] && printf '%s' "$p"
}
