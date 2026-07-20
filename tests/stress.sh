#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
O="$ROOT/overseer/skills/overseer/scripts/overseer"
LIB="$ROOT/overseer/skills/overseer/scripts/lib"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; for s in "${SESS[@]:-}"; do [ -n "$s" ] && tmux kill-session -t "$s" 2>/dev/null; done' EXIT
export CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
declare -a SESS=()
pass=0; fail=0
PERF_LASTREPLY="${OVERSEER_STRESS_PERF_LASTREPLY:-3}"
PERF_TURNS="${OVERSEER_STRESS_PERF_TURNS:-1}"
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

command -v tmux >/dev/null 2>&1 || { echo "stress: tmux required (this harness is manual, not CI)"; exit 2; }

echo "== A: 8 throwaway shell panes, concurrent sh (multi-pane isolation) =="
declare -a P=()
for i in $(seq 1 8); do
  s="ovS_A_${i}_$$"; tmux new-session -d -s "$s" -x 80 -y 24 2>/dev/null
  SESS+=("$s"); P+=("$(tmux list-panes -t "$s" -F '#{pane_id}' | head -1)")
done
for i in $(seq 0 7); do ( bash "$O" sh "${P[$i]}" "echo STRESS-$i-mark; sleep 0.1; echo DONE-$i" >"$TMP/A_$i.txt" 2>&1 ) & done
wait
aok=0
for i in $(seq 0 7); do grep -q "STRESS-$i-mark" "$TMP/A_$i.txt" && grep -q "DONE-$i" "$TMP/A_$i.txt" && aok=$((aok+1)); done
[ "$aok" = 8 ] && ok "8 panes each correct + isolated" || no "only $aok/8 panes correct"

echo "== B: 5 concurrent sh on the SAME pane (per-pane lock serializes) =="
sb="ovS_B_$$"; tmux new-session -d -s "$sb" -x 80 -y 24 2>/dev/null; SESS+=("$sb")
BP=$(tmux list-panes -t "$sb" -F '#{pane_id}' | head -1)
for i in $(seq 1 5); do ( bash "$O" sh "$BP" "echo BLOCK-$i-start; echo BLOCK-$i-end" >"$TMP/B_$i.txt" 2>&1 ) & done
wait
bok=0
for i in $(seq 1 5); do grep -q "BLOCK-$i-start" "$TMP/B_$i.txt" && grep -q "BLOCK-$i-end" "$TMP/B_$i.txt" && bok=$((bok+1)); done
[ "$bok" = 5 ] && ok "5 same-pane sh completed (serialized, no interleave)" || no "only $bok/5 same-pane sh ok"

echo "== C: large-transcript reader perf (streaming + incremental) =="
CX="$TMP/big-rollout.jsonl"
awk 'BEGIN{ for(i=0;i<120000;i++){ print "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"filler line " i " padding padding padding\"}]}}"; if(i%50==0) print "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"last_agent_message\":\"reply " i "\"}}" } }' > "$CX"
sz=$(stat -c %s "$CX"); echo "  rollout: $((sz/1024/1024)) MB / $(wc -l <"$CX") lines"
POLL_INTERVAL=0.25; _nap(){ sleep "$POLL_INTERVAL"; }
# shellcheck source=/dev/null
. "$LIB/discovery.sh"; . "$LIB/transcript.sh"; . "$LIB/tui.sh"
t0=$(date +%s.%N); _cx_last_reply "$CX" >/dev/null; t1=$(date +%s.%N)
awk "BEGIN{exit !($t1-$t0 < $PERF_LASTREPLY)}" && ok "_cx_last_reply < ${PERF_LASTREPLY}s on $((sz/1024/1024))MB ($(awk "BEGIN{printf \"%.2f\",$t1-$t0}")s)" || no "_cx_last_reply too slow (>= ${PERF_LASTREPLY}s)"
t0=$(date +%s.%N); _turns_after codex "$CX" $((sz-5000)) >/dev/null; t1=$(date +%s.%N)
awk "BEGIN{exit !($t1-$t0 < $PERF_TURNS)}" && ok "_turns_after(near-end offset) < ${PERF_TURNS}s ($(awk "BEGIN{printf \"%.2f\",$t1-$t0}")s)" || no "_turns_after too slow (>= ${PERF_TURNS}s)"

echo "== E: crash liveness (harness gone -> rc=3, not timeout) =="
se="ovS_E_$$"; tmux new-session -d -s "$se" -x 80 -y 24 2>/dev/null; SESS+=("$se")
EP=$(tmux list-panes -t "$se" -F '#{pane_id}' | head -1)
t0=$(date +%s); rc=0; _wait_reply codex /nope.jsonl 0 30 "" 0 "$EP" "" || rc=$?; el=$(( $(date +%s) - t0 ))
{ [ "$rc" = 3 ] && [ "$el" -lt 10 ]; } && ok "liveness rc=3 in ${el}s (not 30s)" || no "liveness rc=$rc el=${el}s"

if [ -n "${OVERSEER_STRESS_CODEX_PANE:-}" ]; then
  CP="$OVERSEER_STRESS_CODEX_PANE"
  echo "== D: codex send-path safety on $CP =="
  if bash "$O" send "$CP" '!rm -rf danger' >/dev/null 2>&1; then no "codex '!' NOT refused (would run as a shell command!)"; else ok "codex '!' refused (safety)"; fi
  if bash "$O" send "$CP" '   !still-danger' >/dev/null 2>&1; then no "codex leading-space '!' NOT refused"; else ok "codex leading-space '!' refused"; fi
else
  echo "== D: skipped (set OVERSEER_STRESS_CODEX_PANE=%N for the codex send-path safety check) =="
fi

echo
echo "STRESS: pass=$pass fail=$fail"
[ "$fail" = 0 ]
