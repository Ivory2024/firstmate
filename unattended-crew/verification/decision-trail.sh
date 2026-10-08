#!/usr/bin/env bash
# decision-trail.sh - read-only view of the coordinator's durable decision trail
# in the pstack "show me your work" column shape (ts / phase / decision / why /
# evidence / result). It derives everything from the EXISTING records
# (state.jsonl and the evidence gate) and creates no new store.
#
# Usage: decision-trail.sh <batch-dir>
set -u
bd=${1:?usage: decision-trail.sh <batch-dir>}
sl="$bd/state.jsonl"
[ -f "$sl" ] || { echo "decision-trail: no state.jsonl under $bd" >&2; exit 2; }
printf '| ts | phase | decision | why | evidence | result |\n'
printf '|---|---|---|---|---|---|\n'
while IFS= read -r line; do
  [ -n "$line" ] || continue
  at=$(printf '%s' "$line" | sed -n 's/.*at=\([^ ]*\).*/\1/p')
  task=$(printf '%s' "$line" | sed -n 's/.*task_id=\([^ ]*\).*/\1/p')
  prev=$(printf '%s' "$line" | sed -n 's/.*prev=\([^ ]*\).*/\1/p')
  new=$(printf '%s' "$line" | sed -n 's/.*new=\([^ ]*\).*/\1/p')
  reason=$(printf '%s' "$line" | sed -n 's/.*reason=\([^ ]*\).*/\1/p')
  ev=$(printf '%s' "$line" | sed -n 's/.*evidence=\([^ ]*\).*/\1/p')
  [ -n "$ev" ] || ev="state.jsonl"
  printf '| %s | %s | %s -> %s | %s | %s | %s |\n' "$at" "$task" "$prev" "$new" "$reason" "$ev" "$new"
done < "$sl"
