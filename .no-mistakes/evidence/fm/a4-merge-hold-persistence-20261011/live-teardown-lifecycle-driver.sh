#!/usr/bin/env bash
# Live driver for fm-teardown's merge-decision lifecycle.
#
# Drives the real bin/fm-teardown.sh end to end in a disposable home/state/
# worktree (real git repo). It reuses the repo's own teardown integration
# fixtures by sourcing a definitions-only copy of tests/fm-teardown.test.sh, so
# make_case/write_meta/run_teardown are exactly the suite's.
set -u

EVID="/Users/irene/.no-mistakes/evidence/01M4QKQEA9B3EY6SCRBE31PEB4"
WT="/Users/irene/.no-mistakes/worktrees/e10922160f77/01M4QKQEA9B3EY6SCRBE31PEB4"
LOG="$EVID/live-teardown-lifecycle.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

DEFS="$WT/tests/.fm-live-teardown-defs.$$.sh"
cleanup() { rm -f "$DEFS"; fm_test_cleanup; }
trap cleanup EXIT
sed -E 's/^test_[A-Za-z0-9_]+$/:/' "$WT/tests/fm-teardown.test.sh" > "$DEFS"
# shellcheck source=/dev/null
. "$DEFS"
# Sourcing lib.sh re-installs its own cleanup trap; keep both duties.
trap cleanup EXIT INT TERM

PASS=0
FAIL=0
ok() { printf 'LIVE-PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'LIVE-FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

write_decision_record() {  # <case_dir> <mode>
  local case_dir=$1 mode=$2 state_dir="$1/state" id=task-x1
  {
    printf '%s\n' fm-merge-decision-v1 github github.com example/repo 7 \
      4545454545454545454545454545454545454545 PASS LOW deadbeef "$(( $(date +%s) + 3600 ))"
  } > "$state_dir/$id.merge-decision"
  chmod "$mode" "$state_dir/$id.merge-decision"
}

snapshot() {  # <case_dir> <label>
  local case_dir=$1 label=$2
  {
    printf '=== %s ===\n' "$label"
    printf -- '--- state listing ---\n'
    ls -la "$case_dir/state" 2>/dev/null | grep -E 'merge-decision|task-x1|^total' || true
    printf -- '--- stderr ---\n'
    cat "$case_dir/stderr" 2>/dev/null || true
    printf '\n'
  } >> "$EVID/live-teardown-lifecycle-transcript.txt"
}

: > "$EVID/live-teardown-lifecycle-transcript.txt"

# ---------------------------------------------------------------------------
# Scenario T1: a successful teardown removes the durable merge-decision record
# with the rest of the task's PR-check artifacts.
# ---------------------------------------------------------------------------
t1() {
  local case_dir rc record
  case_dir=$(make_case live-teardown-removes)
  write_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  write_decision_record "$case_dir" 600
  record="$case_dir/state/task-x1.merge-decision"
  [ -f "$record" ] || { bad "teardown-removes: fixture record was not created"; return; }

  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  snapshot "$case_dir" "T1 teardown removes decision record (rc=$rc)"
  [ "$rc" -eq 0 ] || { bad "teardown-removes: teardown exited $rc: $(cat "$case_dir/stderr")"; return; }
  [ ! -e "$record" ] || { bad "teardown-removes: teardown left task-x1.merge-decision behind"; return; }
  [ ! -e "$case_dir/state/task-x1.meta" ] || { bad "teardown-removes: task meta survived"; return; }
  ok "teardown-removes: a successful teardown removes the durable merge-decision record with the task state"
}

# ---------------------------------------------------------------------------
# Scenario T2 (adversarial): a world-readable merge-decision record is an unsafe
# PR-check artifact; teardown must refuse and preserve the task state rather
# than delete it.
# ---------------------------------------------------------------------------
t2() {
  local case_dir rc record
  case_dir=$(make_case live-teardown-unsafe-mode)
  write_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  write_decision_record "$case_dir" 644
  record="$case_dir/state/task-x1.merge-decision"

  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  snapshot "$case_dir" "T2 teardown refuses unsafe mode (rc=$rc)"
  [ "$rc" -ne 0 ] || { bad "teardown-unsafe-mode: teardown accepted a 0644 decision record"; return; }
  grep -qF 'unsafe task PR-check artifact' "$case_dir/stderr" \
    || { bad "teardown-unsafe-mode: refusal did not name the unsafe artifact"; return; }
  [ -e "$record" ] || { bad "teardown-unsafe-mode: the unsafe record was removed anyway"; return; }
  [ -e "$case_dir/state/task-x1.meta" ] || { bad "teardown-unsafe-mode: task state was not preserved"; return; }
  ok "teardown-unsafe-mode: a 0644 merge-decision record makes teardown refuse and preserve task state"
}

# ---------------------------------------------------------------------------
# Scenario T3 (adversarial): a symlinked merge-decision path is unsafe; teardown
# must refuse and preserve the task state.
# ---------------------------------------------------------------------------
t3() {
  local case_dir rc record
  case_dir=$(make_case live-teardown-symlink)
  write_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  record="$case_dir/state/task-x1.merge-decision"
  ln -s "$case_dir/elsewhere" "$record"

  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  snapshot "$case_dir" "T3 teardown refuses symlinked record (rc=$rc)"
  [ "$rc" -ne 0 ] || { bad "teardown-symlink: teardown accepted a symlinked decision record"; return; }
  grep -qF 'unsafe task PR-check artifact' "$case_dir/stderr" \
    || { bad "teardown-symlink: refusal did not name the unsafe artifact"; return; }
  [ -L "$record" ] || { bad "teardown-symlink: the symlink was removed anyway"; return; }
  [ -e "$case_dir/state/task-x1.meta" ] || { bad "teardown-symlink: task state was not preserved"; return; }
  ok "teardown-symlink: a symlinked merge-decision path makes teardown refuse and preserve task state"
}

t1
t2
t3

printf '\nLIVE SUMMARY: pass=%d fail=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
