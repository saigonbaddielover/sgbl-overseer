# shellcheck shell=bash

# count of assistant messages that ENDED a turn (stop_reason present and not tool_use).
# a turn = zero or more tool_use messages then exactly one terminal message, so this counts turns.
_turn_count() {
  local n; n=$(jq -c 'select(.type=="assistant" and .message.stop_reason!=null and .message.stop_reason!="tool_use")' "$1" 2>/dev/null | wc -l)
  echo "${n:-0}"
}
_last_stop() { jq -r 'select(.type=="assistant") | .message.stop_reason // empty' "$1" 2>/dev/null | tail -1; }
# busy = the last turn ended in a tool_use (the session is mid-turn, running a tool). arg: jsonl.
_is_busy() { [ "$(_last_stop "$1")" = tool_use ]; }
_last_prompt() {
  local jl="$1" p
  p=$(jq -r 'select(.type=="last-prompt") | .lastPrompt' "$jl" 2>/dev/null | tail -1)
  if [ -z "$p" ] || [ "$p" = null ]; then
    # pasted prompts have no last-prompt entry; take the last real user string message
    # whole (message-wise, so multi-line content is preserved intact).
    p=$(jq -rs '[ .[] | select(.type=="user" and (.message.content|type=="string"))
                     | .message.content | select(test("^\\s*[<{]")|not) ] | last // empty' \
        "$jl" 2>/dev/null)
  fi
  printf '%s' "$p"
}
_last_reply() {
  jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' "$1" 2>/dev/null | tail -1
}
# ---- Codex rollout readers (~/.codex/sessions/**/rollout-*.jsonl) ----------
# a Codex turn is an `event_msg` task_started ... task_complete pair; task_complete even carries the
# reply verbatim as last_agent_message. so turns = completed count, busy = a start with no matching
# complete, reply = the last complete's message, prompt = the last real user input_text (skip the
# injected AGENTS.md `#...` / `<environment_context>` wrappers, like the claude reader does).
_cx_turn_count() { local n; n=$(jq -c 'select(.type=="event_msg" and .payload.type=="task_complete")' "$1" 2>/dev/null | wc -l); echo "${n:-0}"; }
_cx_is_busy() {
  local st ct
  st=$(jq -c 'select(.type=="event_msg" and .payload.type=="task_started")' "$1" 2>/dev/null | wc -l)
  ct=$(jq -c 'select(.type=="event_msg" and .payload.type=="task_complete")' "$1" 2>/dev/null | wc -l)
  [ "${st:-0}" -gt "${ct:-0}" ]
}
_cx_last_reply() { jq -r 'select(.type=="event_msg" and .payload.type=="task_complete") | .payload.last_agent_message // empty' "$1" 2>/dev/null | tail -1; }
_cx_last_prompt() {
  jq -r 'select(.type=="response_item" and .payload.type=="message" and .payload.role=="user")
         | .payload.content[]? | select(.type=="input_text") | .text
         | select(test("^\\s*[<#{]")|not)' "$1" 2>/dev/null | tail -1
}
# ---- harness-dispatched reads (kind, transcript_path) ----------------------
_h_turn_count() { case "$1" in claude) _turn_count "$2" ;; codex) _cx_turn_count "$2" ;; esac; }
_h_is_busy()    { case "$1" in claude) _is_busy "$2" ;;    codex) _cx_is_busy "$2" ;;    esac; }
_h_last_reply() { case "$1" in claude) _last_reply "$2" ;; codex) _cx_last_reply "$2" ;; esac; }
_h_last_prompt(){ case "$1" in claude) _last_prompt "$2" ;; codex) _cx_last_prompt "$2" ;; esac; }
# a turn-done signal for this session at or after `since`: the Stop hook touches
# ~/.claude/turn-done/<session_id> at each turn end, so its mtime is the last turn-end time.
_signal_since() {   # sid since_epoch
  local f="$CLAUDE_HOME/turn-done/$1" m
  [ -f "$f" ] || return 1
  m=$(stat -c %Y "$f" 2>/dev/null) || return 1
  [ "$m" -ge "$2" ]
}
# block until the turn started by our send has ended, i.e. the turn count passes the baseline.
# claude: prefer the Stop-hook signal (event-driven, ~0.25s), fall back to polling the transcript
# every ~2s so a session the hook does not cover still resolves. codex: no hook, so poll the rollout
# every tick. args: kind, transcript_path, baseline_turn_count, timeout_s, [claude sid], [since_epoch].
_wait_reply() {
  local kind="$1" path="$2" base="$3" timeout="${4:-600}" sid="${5:-}" since="${6:-0}" pane="${7:-}" i=0 woke=0
  local deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$kind" = claude ] && [ "$woke" = 0 ] && [ -n "$sid" ] && _signal_since "$sid" "$since" && woke=1
    # the signal only says "look now"; correctness is the transcript actually showing the new turn,
    # so a reply is never read before it is flushed. codex has no signal -> check every tick.
    if { [ "$woke" = 1 ] || [ "$kind" = codex ] || [ $((i % 8)) -eq 0 ]; } && [ "$(_h_turn_count "$kind" "$path")" -gt "$base" ]; then
      return 0
    fi
    [ -n "$pane" ] && [ "$i" -gt 0 ] && [ $((i % 4)) -eq 0 ] && _awaiting "$pane" >/dev/null 2>&1 && return 2
    i=$((i + 1)); _nap
  done
  return 1
}
