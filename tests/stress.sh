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
NO_PERF="${OVERSEER_STRESS_NO_PERF:-0}"
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
info(){ printf '  info %s\n' "$1"; }

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
lr=$(awk "BEGIN{printf \"%.2f\",$t1-$t0}")
t0=$(date +%s.%N); _turns_after codex "$CX" $((sz-5000)) >/dev/null; t1=$(date +%s.%N)
ta=$(awk "BEGIN{printf \"%.2f\",$t1-$t0}")
if [ "$NO_PERF" = 1 ]; then
  info "_cx_last_reply on $((sz/1024/1024))MB: ${lr}s   _turns_after(near-end): ${ta}s   (timing only, not asserted — set OVERSEER_STRESS_NO_PERF=0 to gate)"
else
  awk "BEGIN{exit !($lr < $PERF_LASTREPLY)}" && ok "_cx_last_reply < ${PERF_LASTREPLY}s on $((sz/1024/1024))MB (${lr}s)" || no "_cx_last_reply too slow (>= ${PERF_LASTREPLY}s)"
  awk "BEGIN{exit !($ta < $PERF_TURNS)}" && ok "_turns_after(near-end offset) < ${PERF_TURNS}s (${ta}s)" || no "_turns_after too slow (>= ${PERF_TURNS}s)"
fi

echo "== E: crash liveness (harness gone -> rc=3, not timeout) =="
se="ovS_E_$$"; tmux new-session -d -s "$se" -x 80 -y 24 2>/dev/null; SESS+=("$se")
EP=$(tmux list-panes -t "$se" -F '#{pane_id}' | head -1)
t0=$(date +%s); rc=0; _wait_reply codex /nope.jsonl 0 30 "" 0 "$EP" "" || rc=$?; el=$(( $(date +%s) - t0 ))
{ [ "$rc" = 3 ] && [ "$el" -lt 10 ]; } && ok "liveness rc=3 in ${el}s (not 30s)" || no "liveness rc=$rc el=${el}s"

echo "== E2: a completed turn is never masked as rc=3 (died-after-completion -> reply/drained, not error) =="
CT="$HERE/fixtures/codex-turn.jsonl"
rc=0; _wait_reply   codex "$CT" 0 30 "" 0 "$EP" "" || rc=$?
[ "$rc" = 0 ] && ok "wait_reply: completed transcript on a shell pane -> rc=0 (not rc=3)" || no "wait_reply completed-turn invariant rc=$rc"
rc=0; _wait_drained codex "$CT" 30 "$EP" || rc=$?
[ "$rc" = 0 ] && ok "wait_drained: finished-then-quit pane -> rc=0 (drained, not died)" || no "wait_drained completed-turn invariant rc=$rc"

echo "== F: start/stop lifecycle (create -> drive -> destroy a shell session) =="
FN="ovS_F_$$"; SESS+=("$FN")
bash "$O" start "$FN" shell >/dev/null 2>&1
if tmux has-session -t "=$FN" 2>/dev/null; then
  ok "start created the shell session"
  fo=$(bash "$O" sh "$FN" 'echo START-STOP-OK' 15 2>&1)
  case "$fo" in *START-STOP-OK*) ok "the started session is drivable via sh" ;; *) no "started session not drivable" ;; esac
  bash "$O" stop "$FN" >/dev/null 2>&1
  tmux has-session -t "=$FN" 2>/dev/null && no "stop did not remove the session" || ok "stop removed the session"
else
  no "start did not create a shell session"
fi
if bash "$O" start 'bad.name' shell >/dev/null 2>&1; then no "start accepted an invalid name (bad.name)"; else ok "start refuses an invalid name"; fi

echo "== F2: stop %N kills one pane, keeps the session =="
sp="ovS_Fp_$$"; tmux new-session -d -s "$sp" -x 80 -y 24 2>/dev/null; SESS+=("$sp")
tmux split-window -t "$sp" 2>/dev/null
before=$(tmux list-panes -t "$sp" 2>/dev/null | wc -l)
victim=$(tmux list-panes -t "$sp" -F '#{pane_id}' 2>/dev/null | tail -1)
bash "$O" stop "$victim" >/dev/null 2>&1
after=$(tmux list-panes -t "$sp" 2>/dev/null | wc -l)
{ [ "$before" = 2 ] && [ "$after" = 1 ]; } && ok "stop %N kills one pane (before=$before after=$after)" || no "stop %N pane count wrong (before=$before after=$after)"

if command -v codex >/dev/null 2>&1; then
  echo "== F3: start a real codex, assert readiness via list, stop =="
  cn="ovS_Fc_$$"; SESS+=("$cn")
  bash "$O" start "$cn" codex >/dev/null 2>&1
  if bash "$O" list 2>/dev/null | grep -q "$cn"; then ok "start codex came up (listed as an agent)"; else no "start codex not detected as an agent"; fi
  bash "$O" stop "$cn" >/dev/null 2>&1
  tmux has-session -t "=$cn" 2>/dev/null && no "stop did not remove the codex session" || ok "stop removed the codex session"
else
  echo "== F3: skipped (no codex on PATH; the shell start/stop above needs no agent) =="
fi

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
