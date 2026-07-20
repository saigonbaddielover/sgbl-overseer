#!/usr/bin/env bash
input="$(cat)"
sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"

[ -z "$sid" ] && exit 0
dir="${CLAUDE_HOME:-$HOME/.claude}/turn-done"
mkdir -p "$dir"
touch "$dir/$sid"
