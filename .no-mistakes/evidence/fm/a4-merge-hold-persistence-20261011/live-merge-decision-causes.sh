#!/usr/bin/env bash
# Live driver: every refusal cause of the real durable merge-decision reader.
#
# Executes the shipped bin/fm-merge-decision-lib.sh (over the shipped
# bin/fm-pr-lib.sh) directly and prints, for each tampered or mismatched state,
# the concrete cause it refuses with. This is the "each with its own cause"
# requirement of the intent, driven against the product code rather than read.
set -u

EVID="/Users/irene/.no-mistakes/evidence/01M4QKQEA9B3EY6SCRBE31PEB4"
WT="/Users/irene/.no-mistakes/worktrees/e10922160f77/01M4QKQEA9B3EY6SCRBE31PEB4"
OUT="$EVID/live-merge-decision-causes.txt"
: > "$OUT"
exec > >(tee -a "$OUT") 2>&1

# shellcheck source=tests/lib.sh
. "$WT/tests/lib.sh"

TMP=$(fm_test_tmproot fm-live-decision-causes)
STATE="$TMP/state"
META="$STATE/task-d1.meta"
mkdir -p "$STATE"
export FM_STATE_OVERRIDE="$STATE"
export FM_HOME="$TMP/home"
mkdir -p "$FM_HOME"
# shellcheck source=/dev/null
. "$WT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-merge-decision-lib.sh
. "$WT/bin/fm-merge-decision-lib.sh"

PR=https://github.com/example/repo/pull/9
HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OTHER_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SCOPE=deadbeef
NOW=1000000000
EXPIRY=$((NOW + 3600))

persist() { fm_merge_decision_persist "$STATE" task-d1 "$META" github github.com example/repo 9 "$@" || { echo 'persist FAILED'; exit 1; }; }
read_at() { fm_merge_decision_read "$STATE" task-d1 github github.com example/repo 9 "$@"; }
read_num() { fm_merge_decision_read "$STATE" task-d1 github github.com example/repo "$1" "$HEAD" "$NOW"; }

show() {  # <label> <rc>
  if [ "$2" -eq 0 ]; then
    printf '%-30s -> ACCEPT decision=%s\n' "$1" "$FM_MERGE_DECISION"
  else
    printf '%-30s -> REFUSE reason=%s\n' "$1" "$FM_MERGE_DECISION_REASON"
  fi
}

printf 'Durable merge-decision reader refusal causes (real bin/fm-merge-decision-lib.sh)\n'
printf 'pr=%s\n' "$PR" > "$META"

persist "$HEAD" PASS LOW "$SCOPE" "$EXPIRY"
read_at "$HEAD" "$NOW" && rc=0 || rc=$?; show 'valid identity + head' "$rc"
read_at "$OTHER_HEAD" "$NOW" && rc=0 || rc=$?; show 'mismatched head SHA' "$rc"
read_num 10 && rc=0 || rc=$?; show 'mismatched PR number' "$rc"
read_at "$HEAD" "$EXPIRY" && rc=0 || rc=$?; show 'lapsed (at expiry)' "$rc"
read_at "$HEAD" "$((EXPIRY - 1))" && rc=0 || rc=$?; show 'current (1s before expiry)' "$rc"

rm -f "$STATE/task-d1.merge-decision"
read_at "$HEAD" "$NOW" && rc=0 || rc=$?; show 'absent record' "$rc"

persist "$HEAD" PASS LOW "$SCOPE" "$EXPIRY"
printf 'extra\n' >> "$STATE/task-d1.merge-decision"
read_at "$HEAD" "$NOW" && rc=0 || rc=$?; show 'malformed (extra field)' "$rc"

persist "$HEAD" PASS LOW "$SCOPE" "$EXPIRY"
chmod 0644 "$STATE/task-d1.merge-decision"
read_at "$HEAD" "$NOW" && rc=0 || rc=$?; show 'unreadable (mode 0644)' "$rc"

chmod 0600 "$STATE/task-d1.merge-decision"
persist "$HEAD" HOLD HIGH "$SCOPE" "$EXPIRY"
read_at "$HEAD" "$NOW" && rc=0 || rc=$?; show 'recorded HOLD read back' "$rc"
