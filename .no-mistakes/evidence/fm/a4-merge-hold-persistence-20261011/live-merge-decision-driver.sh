#!/usr/bin/env bash
# Live driver for the durable merge-decision change.
#
# The product under test is firstmate's own merge boundary: the real
# bin/fm-pr-merge.sh, sourced on the real bin/fm-merge-decision-lib.sh, running
# end to end in a disposable home/state/worktree with a real git repo. Only the
# external forge CLIs (gh / gh-axi / glab) are stubbed, because the intent
# accepts "no live GitHub e2e run" and no disposable forge account exists here;
# the product itself is never stubbed.
#
# It reuses the repo's own integration fixtures by sourcing a definitions-only
# copy of tests/fm-pr-merge.test.sh (its trailing test invocations neutralized),
# so each scenario calls the same make_case/add_gh_mocks/run_pr_merge the suite
# uses, then asserts on the real product's observable output and durable record.
set -u

EVID="/Users/irene/.no-mistakes/evidence/01M4QKQEA9B3EY6SCRBE31PEB4"
WT="/Users/irene/.no-mistakes/worktrees/e10922160f77/01M4QKQEA9B3EY6SCRBE31PEB4"
LOG="$EVID/live-merge-decision.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

DEFS="$WT/tests/.fm-live-pr-merge-defs.$$.sh"
cleanup() { rm -f "$DEFS"; fm_test_cleanup; }
trap cleanup EXIT
sed -E 's/^test_[A-Za-z0-9_]+$/:/' "$WT/tests/fm-pr-merge.test.sh" > "$DEFS"
# shellcheck source=/dev/null
. "$DEFS"
# Sourcing lib.sh re-installs its own cleanup trap; keep both duties.
trap cleanup EXIT INT TERM

PASS=0
FAIL=0
ok() { printf 'LIVE-PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'LIVE-FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
field() { sed -n "${2}p" "$1"; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# Save the durable record, stderr, and forge logs next to the evidence.
snapshot() {  # <case_dir> <label>
  local case_dir=$1 label=$2
  {
    printf '=== %s ===\n' "$label"
    printf -- '--- state/task-x1.merge-decision ---\n'
    cat "$case_dir/state/task-x1.merge-decision" 2>/dev/null || printf '(absent)\n'
    printf -- '--- stderr ---\n'
    cat "$case_dir/stderr" 2>/dev/null || true
    printf -- '--- gh.log ---\n'
    cat "$case_dir/gh.log" 2>/dev/null || true
    printf -- '--- glab.log ---\n'
    cat "$case_dir/glab.log" 2>/dev/null || true
    printf '\n'
  } >> "$EVID/live-merge-decision-transcript.txt"
}

: > "$EVID/live-merge-decision-transcript.txt"

# ---------------------------------------------------------------------------
# Scenario G1: a GitHub HOLD is persisted durably and still refuses after a
# restart, never reaching `gh pr merge`.
# ---------------------------------------------------------------------------
g1() {
  local case_dir rc record head=4040404040404040404040404040404040404040
  case_dir=$(make_case live-github-hold)
  add_gh_mocks "$case_dir" "$head"
  : > "$case_dir/gh-axi.log"
  printf '%s\n' '[[]]' > "$case_dir/$EVIDENCE_DIRNAME/gh-reviews.json"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/73 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  record="$case_dir/state/task-x1.merge-decision"
  [ "$rc" -ne 0 ] || { bad "github-hold: a HOLD fixture merged (rc=0)"; return; }
  [ -f "$record" ] || { bad "github-hold: no durable record was written"; return; }
  [ "$(mode_of "$record")" = 600 ] || { bad "github-hold: record mode is $(mode_of "$record"), not 0600"; return; }
  [ "$(field "$record" 1)" = fm-merge-decision-v1 ] || { bad "github-hold: bad version"; return; }
  [ "$(field "$record" 7)" = HOLD ] || { bad "github-hold: recorded decision is $(field "$record" 7), not HOLD"; return; }
  [ "$(field "$record" 6)" = "$head" ] || { bad "github-hold: record head is not the run head"; return; }
  [ "$(field "$record" 5)" = 73 ] || { bad "github-hold: record PR number is not 73"; return; }
  grep -qF 'pr merge' "$case_dir/gh.log" 2>/dev/null \
    && { bad "github-hold: gh pr merge ran on a recorded HOLD"; return; }
  snapshot "$case_dir" "G1 github hold run 1"
  ok "github-hold: real fm-pr-merge recorded HOLD (mode 0600, bound to head/PR) and refused without calling gh pr merge"

  # Restart: a fresh process with nothing of run 1's shell. The durable record is
  # the only thing that can carry the HOLD forward.
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/73 \
    > "$case_dir/stdout2" 2> "$case_dir/stderr"
  rc=$?
  [ "$rc" -ne 0 ] || { bad "github-hold-restart: a HOLD fixture merged after restart (rc=0)"; return; }
  [ "$(field "$record" 7)" = HOLD ] || { bad "github-hold-restart: HOLD did not survive"; return; }
  grep -qF 'pr merge' "$case_dir/gh.log" 2>/dev/null \
    && { bad "github-hold-restart: gh pr merge ran after restart"; return; }
  snapshot "$case_dir" "G1 github hold run 2 (restart)"
  ok "github-hold: a HOLD recorded before a restart still refuses after it, with no forge merge"
}

# ---------------------------------------------------------------------------
# Scenario G2: a GitLab HOLD is persisted durably and still refuses after a
# restart, never reaching `glab mr merge`. This is the review round-1 gap fix.
# ---------------------------------------------------------------------------
g2() {
  local case_dir rc record
  case_dir=$(make_gitlab_case live-gitlab-hold)
  printf '%s\n' '{"approvals_left":0,"approved_by":[{"user":{"username":"author","id":1}}]}' \
    > "$case_dir/$EVIDENCE_DIRNAME/glab-approvals.json"

  run_pr_merge "$case_dir" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  record="$case_dir/state/task-x1.merge-decision"
  [ "$rc" -ne 0 ] || { bad "gitlab-hold: a HOLD fixture merged (rc=0)"; return; }
  [ -f "$record" ] || { bad "gitlab-hold: no durable record was written"; return; }
  [ "$(mode_of "$record")" = 600 ] || { bad "gitlab-hold: record mode is $(mode_of "$record"), not 0600"; return; }
  [ "$(field "$record" 2)" = gitlab ] || { bad "gitlab-hold: record provider is $(field "$record" 2), not gitlab"; return; }
  [ "$(field "$record" 7)" = HOLD ] || { bad "gitlab-hold: recorded decision is $(field "$record" 7), not HOLD"; return; }
  [ "$(field "$record" 6)" = "$MR_HEAD" ] || { bad "gitlab-hold: record head is not the run head"; return; }
  [ "$(field "$record" 5)" = 7 ] || { bad "gitlab-hold: record MR number is not 7"; return; }
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || { bad "gitlab-hold: glab mr merge ran on a recorded HOLD"; return; }
  snapshot "$case_dir" "G2 gitlab hold run 1"
  ok "gitlab-hold: real fm-pr-merge recorded a GitLab HOLD durably and refused without calling glab mr merge"

  run_pr_merge "$case_dir" task-x1 "$MR_URL" > "$case_dir/stdout2" 2> "$case_dir/stderr"
  rc=$?
  [ "$rc" -ne 0 ] || { bad "gitlab-hold-restart: a HOLD fixture merged after restart (rc=0)"; return; }
  [ "$(field "$record" 7)" = HOLD ] || { bad "gitlab-hold-restart: HOLD did not survive"; return; }
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || { bad "gitlab-hold-restart: glab mr merge ran after restart"; return; }
  snapshot "$case_dir" "G2 gitlab hold run 2 (restart)"
  ok "gitlab-hold: a GitLab HOLD recorded before a restart still refuses after it, with no forge merge"
}

# ---------------------------------------------------------------------------
# Scenario G3 (adversarial): an operator who exports FM_MERGE_DECISION_TTL
# cannot extend or shorten the record's lifetime; the in-script 3600 wins.
# ---------------------------------------------------------------------------
g3() {
  local case_dir rc record expiry now_before now_after head=4545454545454545454545454545454545454545
  case_dir=$(make_case live-ttl-hostile)
  add_gh_mocks "$case_dir" "$head"
  : > "$case_dir/gh-axi.log"
  printf '%s\n' '[[]]' > "$case_dir/$EVIDENCE_DIRNAME/gh-reviews.json"

  now_before=$(date +%s)
  export FM_MERGE_DECISION_TTL=999999
  run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/73 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  unset FM_MERGE_DECISION_TTL
  now_after=$(date +%s)
  record="$case_dir/state/task-x1.merge-decision"
  [ "$rc" -ne 0 ] || { bad "ttl-hostile: a HOLD fixture merged (rc=0)"; return; }
  [ -f "$record" ] || { bad "ttl-hostile: no durable record"; return; }
  expiry=$(field "$record" 10)
  case "$expiry" in
    ''|*[!0-9]*) bad "ttl-hostile: expiry '$expiry' is not numeric"; return ;;
  esac
  if [ "$expiry" -lt $((now_before + 3500)) ] || [ "$expiry" -gt $((now_after + 3700)) ]; then
    bad "ttl-hostile: FM_MERGE_DECISION_TTL=999999 leaked into the record (expiry=$expiry, now=$now_before..$now_after)"
    return
  fi
  # A tiny caller value must not shorten it either.
  case_dir=$(make_case live-ttl-short)
  add_gh_mocks "$case_dir" "$head"
  : > "$case_dir/gh-axi.log"
  printf '%s\n' '[[]]' > "$case_dir/$EVIDENCE_DIRNAME/gh-reviews.json"
  now_before=$(date +%s)
  export FM_MERGE_DECISION_TTL=1
  run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/73 > "$case_dir/stdout" 2> "$case_dir/stderr"
  unset FM_MERGE_DECISION_TTL
  now_after=$(date +%s)
  record="$case_dir/state/task-x1.merge-decision"
  expiry=$(field "$record" 10)
  if [ "$expiry" -lt $((now_before + 3500)) ] || [ "$expiry" -gt $((now_after + 3700)) ]; then
    bad "ttl-hostile: FM_MERGE_DECISION_TTL=1 leaked into the record (expiry=$expiry)"
    return
  fi
  snapshot "$case_dir" "G3 ttl hostile (FM_MERGE_DECISION_TTL=1)"
  ok "ttl-hostile: a caller-exported FM_MERGE_DECISION_TTL never changes the record's 3600s lifetime"
}

# ---------------------------------------------------------------------------
# Scenario G4 (adversarial, fail-closed): a record that cannot be published
# refuses the merge with its own cause instead of falling back to the transient
# verdict.
# ---------------------------------------------------------------------------
g4() {
  local case_dir rc
  case_dir=$(make_case live-unrecordable)
  add_gh_mocks "$case_dir" 4141414141414141414141414141414141414141
  : > "$case_dir/gh-axi.log"
  ln -s "$case_dir/elsewhere" "$case_dir/state/task-x1.merge-decision"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/73 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  [ "$rc" -ne 0 ] || { bad "unrecordable: the merge proceeded without a durable record"; return; }
  grep -qF 'could not be recorded durably' "$case_dir/stderr" \
    || { bad "unrecordable: refusal did not name the unrecordable decision"; return; }
  grep -qF 'pr merge' "$case_dir/gh.log" 2>/dev/null \
    && { bad "unrecordable: gh pr merge ran without a durable decision"; return; }
  [ -L "$case_dir/state/task-x1.merge-decision" ] \
    || { bad "unrecordable: the hostile destination was replaced"; return; }
  snapshot "$case_dir" "G4 unrecordable destination"
  ok "unrecordable: a merge whose decision cannot be published refuses fail-closed and never calls the forge"
}

# ---------------------------------------------------------------------------
# Scenario G5: a GitHub PASS is recorded with its risk and classified
# change-set digest, and the forge merge then runs on that recorded PASS.
# ---------------------------------------------------------------------------
g5() {
  local case_dir rc record scope risk head=4646464646464646464646464646464646464646
  case_dir=$(make_case live-github-pass)
  add_gh_mocks "$case_dir" "$head"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/73 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  record="$case_dir/state/task-x1.merge-decision"
  [ "$rc" -eq 0 ] || { bad "github-pass: a complete fixture did not merge (rc=$rc): $(cat "$case_dir/stderr")"; return; }
  [ -f "$record" ] || { bad "github-pass: no durable record"; return; }
  [ "$(field "$record" 7)" = PASS ] || { bad "github-pass: recorded decision is $(field "$record" 7), not PASS"; return; }
  risk=$(field "$record" 8)
  scope=$(field "$record" 9)
  [ -n "$risk" ] || { bad "github-pass: the record carries no classified risk"; return; }
  printf '%s' "$scope" | grep -Eq '^[0-9a-f]{64}$' \
    || { bad "github-pass: the record's scope '$scope' is not a sha256 change-set digest"; return; }
  grep -qF 'pr merge' "$case_dir/gh.log" 2>/dev/null \
    || { bad "github-pass: the forge merge did not run on the recorded PASS"; return; }
  snapshot "$case_dir" "G5 github PASS (risk=$risk scope=$scope)"
  ok "github-pass: a PASS is recorded with its risk and change-set digest and the forge merge runs on it"
}

# ---------------------------------------------------------------------------
# Scenario G6: the GitLab arm still merges a genuine PASS with its durable
# record in place. The review fix must not break the happy path.
# ---------------------------------------------------------------------------
g6() {
  local case_dir rc record
  case_dir=$(make_gitlab_case live-gitlab-pass)

  run_pr_merge "$case_dir" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  record="$case_dir/state/task-x1.merge-decision"
  [ "$rc" -eq 0 ] || { bad "gitlab-pass: a complete fixture did not merge (rc=$rc): $(cat "$case_dir/stderr")"; return; }
  [ -f "$record" ] || { bad "gitlab-pass: no durable record"; return; }
  [ "$(field "$record" 7)" = PASS ] || { bad "gitlab-pass: recorded decision is $(field "$record" 7), not PASS"; return; }
  [ "$(field "$record" 9)" != '' ] || { bad "gitlab-pass: the record carries no change-set digest"; return; }
  [ -n "$(glab_merge_line "$case_dir/glab.log")" ] \
    || { bad "gitlab-pass: the glab merge did not run on the recorded PASS"; return; }
  snapshot "$case_dir" "G6 gitlab PASS"
  ok "gitlab-pass: a genuine GitLab PASS is recorded and reaches the glab merge"
}

g1
g2
g3
g4
g5
g6

printf '\nLIVE SUMMARY: pass=%d fail=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
