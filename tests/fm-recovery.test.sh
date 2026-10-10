#!/usr/bin/env bash
# Isolated tests for the FirstCrew recovery state machine: bounded retry,
# alternative search, the approval boundary and its exact HOLD, checkpoint
# restore after a worker death, concurrent-recovery dedupe from a clean initial
# state and under a held lease, original-state preservation, resume of the
# original work, retire, evidence-preserving rollback, the execution class, and
# the read-only measurement export.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REC="$ROOT/bin/fm-recovery.sh"
TMP_ROOT=$(fm_test_tmproot fm-recovery)
HAS_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAS_TASKS_AXI=1

# make_home <name>: an isolated home with the markdown backlog backend, a fake
# worker current-state read, and no credentials.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  cat > "$home/state/fake-crew-state" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: status-log · fixture\n' "${FM_FAKE_CREW_STATE:-unknown}"
SH
  chmod +x "$home/state/fake-crew-state"
  printf '%s\n' "$home"
}

run_rec() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_RECOVERY_CREW_STATE_BIN="$home/state/fake-crew-state" \
    "$REC" "$@"
}

# rec_state <home> <fp>: the recovery state the CLI reports.
rec_state() { run_rec "$1" status --fingerprint "$2" | sed -n 's/^recovery: \([A-Z_]*\) .*/\1/p'; }
rec_verb()  { run_rec "$1" status --fingerprint "$2" --verb; }

# add_row <home> <id>: a backlog row for the task under recovery.
add_row() {  # <home> <id>
  (cd "$1" && tasks-axi add "$2" "recovery fixture $2" --kind ship >/dev/null 2>&1)
}

fingerprint_of() {  # <home> <task>
  run_rec "$1" classify "$2" | sed -n 's/^fingerprint: //p'
}

# --- 1. bounded retry: the same error cannot loop forever -------------------
home=$(make_home retry)
out=$(run_rec "$home" begin t1 --class run-failed --signature "ci failed at step ci" --target fm/t1)
fp=$(printf '%s' "$out" | sed -n 's/^begun: \([^ ]*\) .*/\1/p')
[ -n "$fp" ] || fail "begin produced no fingerprint: $out"
assert_equals RETRYABLE "$(rec_state "$home" "$fp")" "a fresh retryable failure enters RETRYABLE"

run_rec "$home" attempt --fingerprint "$fp" --cause run-failed --result fail >/dev/null
assert_equals RETRYABLE "$(rec_state "$home" "$fp")" "first same-cause retry stays RETRYABLE"
run_rec "$home" attempt --fingerprint "$fp" --cause run-failed --result fail >/dev/null
assert_equals RETRYABLE "$(rec_state "$home" "$fp")" "second same-cause retry stays RETRYABLE"
run_rec "$home" attempt --fingerprint "$fp" --cause run-failed --result fail >/dev/null
assert_equals DIAGNOSING "$(rec_state "$home" "$fp")" "the third same-cause retry is refused and forces DIAGNOSING"
run_rec "$home" attempt --fingerprint "$fp" --cause run-failed --result fail >/dev/null
assert_equals DIAGNOSING "$(rec_state "$home" "$fp")" "repeated identical failures never re-enter RETRYABLE"
assert_grep "retries: 2/2" <(run_rec "$home" status --fingerprint "$fp") "the retry counter is capped at the pilot bound"
pass "bounded retry: no infinite retry on an identical error"

# --- 2. a safe alternative is searched after the first path fails ----------
home=$(make_home alt)
out=$(run_rec "$home" begin t2 --class pr-target-mismatch --signature "PR target mismatch" --target fm/t2)
fp=$(printf '%s' "$out" | sed -n 's/^begun: \([^ ]*\) .*/\1/p')
run_rec "$home" advance --fingerprint "$fp" ALTERNATIVE_SEARCH >/dev/null
out=$(run_rec "$home" alternative --fingerprint "$fp" --name isolated-worktree-reset)
assert_contains "$out" "validating:" "an alternative moves the recovery into VALIDATING"
assert_equals VALIDATING "$(rec_state "$home" "$fp")" "VALIDATING after selecting an alternative"
out=$(run_rec "$home" validate --fingerprint "$fp" --result fail --evidence "fixture test still red")
assert_equals ALTERNATIVE_SEARCH "$(rec_state "$home" "$fp")" "a failed verification switches to a different alternative"
run_rec "$home" alternative --fingerprint "$fp" --name isolated-branch-edit >/dev/null
run_rec "$home" validate --fingerprint "$fp" --result pass --evidence "fixture test green" >/dev/null
assert_equals RECOVERABLE "$(rec_state "$home" "$fp")" "a passing verification reaches RECOVERABLE"
assert_grep "alternatives: 2/3" <(run_rec "$home" status --fingerprint "$fp") "two alternatives were used of the pilot maximum of three"
pass "alternative search: a different alternative is tried after a failed verification"

# --- 3. the approval boundary raises the exact HOLD -------------------------
if [ "$HAS_TASKS_AXI" = 1 ]; then
  home=$(make_home approval)
  add_row "$home" t3
  out=$(run_rec "$home" begin t3 --class approval-boundary --signature "needs captain" --target fm/t3)
  fp=$(printf '%s' "$out" | sed -n 's/^begun: \([^ ]*\) .*/\1/p')
  assert_equals WAITING_APPROVAL "$(rec_state "$home" "$fp")" "an authority-boundary cause starts at WAITING_APPROVAL"
  assert_equals needs-decision "$(rec_verb "$home" "$fp")" "WAITING_APPROVAL projects onto the existing needs-decision verb"
  run_rec "$home" check --fingerprint "$fp" >/dev/null
  expect_code 0 "$?" "check stops the recovery at the approval boundary"
  run_rec "$home" escalate --fingerprint "$fp" --approval --reason "attestation reuse needs the captain" >/dev/null
  show=$(cd "$home" && tasks-axi show t3 2>/dev/null)
  assert_contains "$show" "captain" "the approval escalation recorded a real captain hold on the task"
  assert_contains "$show" "held: yes" "the captain hold is live on the backlog row"

  home=$(make_home exhausted)
  add_row "$home" t4
  out=$(run_rec "$home" begin t4 --class run-failed --signature "run failed" --target fm/t4)
  fp=$(printf '%s' "$out" | sed -n 's/^begun: \([^ ]*\) .*/\1/p')
  run_rec "$home" escalate --fingerprint "$fp" --reason "no safe alternative remains" >/dev/null
  assert_equals BLOCKED_EXHAUSTED "$(rec_state "$home" "$fp")" "an exhausted recovery reaches BLOCKED_EXHAUSTED"
  assert_equals blocked "$(rec_verb "$home" "$fp")" "BLOCKED_EXHAUSTED projects onto the existing blocked verb"
  show=$(cd "$home" && tasks-axi show t4 2>/dev/null)
  assert_not_contains "$show" "held: yes" "a plain exhaustion does not fake a captain hold"
  pass "approval boundary: exact HOLD raised only for the captain-owned boundary"
else
  echo "skip: live: tasks-axi absent"
fi

# --- 4. a worker death restores from the checkpoint ------------------------
home=$(make_home checkpoint)
out=$(FM_RECOVERY_NOW=1000 run_rec "$home" begin t5 --class worktree-base-contamination \
  --signature "base contamination detected" --target fm/t5)
fp=$(printf '%s' "$out" | sed -n 's/^begun: \([^ ]*\) .*/\1/p')
FM_RECOVERY_NOW=1010 run_rec "$home" advance --fingerprint "$fp" ALTERNATIVE_SEARCH >/dev/null
FM_RECOVERY_NOW=1015 run_rec "$home" alternative --fingerprint "$fp" --name isolated-worktree-reset >/dev/null
# The lease is still live, so a second recovery of the same failure is refused.
out=$(FM_RECOVERY_NOW=1020 run_rec "$home" begin t5 --class worktree-base-contamination \
  --signature "base contamination detected" --target fm/t5)
assert_contains "$out" "duplicate:" "a live recovery of the same failure refuses a second start"
# The worker dies: the lease ages past its TTL and the record must be resumed,
# not restarted.
out=$(FM_RECOVERY_NOW=1400 run_rec "$home" begin t5 --class worktree-base-contamination \
  --signature "base contamination detected" --target fm/t5)
assert_contains "$out" "resumed:" "a stale lease restores the recovery from its checkpoint"
assert_contains "$out" "state=VALIDATING" "the checkpoint kept the interrupted state"
assert_contains "$out" "alternatives=1" "the checkpoint kept the alternative counter"
assert_equals VALIDATING "$(rec_state "$home" "$fp")" "the resumed recovery is still VALIDATING"
begins=$(grep -c ' begin ' "$home/state/recovery/$fp.ledger")
assert_equals 1 "$begins" "the checkpoint restore did not record a second begin"
assert_grep "resume lease-reclaimed" "$home/state/recovery/$fp.ledger" "the restore is recorded in the ledger"
pass "checkpoint: a worker death resumes the same recovery instead of restarting it"

# --- 5a. clean initial state: two simultaneous starts -> exactly one begun --
home=$(make_home race-clean)
assert_absent "$home/state/recovery" "the concurrency fixture starts with no recovery record, ledger, or claim lock"
run_rec "$home" begin t6 --class run-failed --signature "shared failure" --target fm/t6 \
  > "$home/race.1" 2>&1 &
run_rec "$home" begin t6 --class run-failed --signature "shared failure" --target fm/t6 \
  > "$home/race.2" 2>&1 &
wait
req1=$(cat "$home/race.1")
req2=$(cat "$home/race.2")
begun=$(printf '%s\n%s\n' "$req1" "$req2" | grep -c '^begun:')
dup=$(printf '%s\n%s\n' "$req1" "$req2" | grep -c '^duplicate:')
assert_equals 1 "$begun" "exactly one of two simultaneous starts begins the recovery"
assert_equals 1 "$dup" "exactly one of two simultaneous starts is rejected as a duplicate"
records=$(find "$home/state/recovery" -name '*.rec' -type f 2>/dev/null | wc -l | tr -d ' ')
assert_equals 1 "$records" "exactly one recovery record exists after the race"
printf '  per-request: 1=[%s] 2=[%s]\n' "$req1" "$req2"
pass "concurrent recovery (clean state): exactly one begun, one duplicate"

# --- 5b. pre-existing live lease: both requests correctly rejected ---------
home=$(make_home race-held)
first=$(run_rec "$home" begin t6 --class run-failed --signature "shared failure" --target fm/t6)
assert_contains "$first" "begun:" "the fixture holds a live lease before the race"
for i in 1 2; do
  run_rec "$home" begin t6 --class run-failed --signature "shared failure" --target fm/t6 \
    > "$home/held.$i" 2>&1 &
done
wait
begun=$(cat "$home/held.1" "$home/held.2" | grep -c '^begun:')
dup=$(cat "$home/held.1" "$home/held.2" | grep -c '^duplicate:')
assert_equals 0 "$begun" "a held lease lets no second start begin"
assert_equals 2 "$dup" "a held lease rejects both concurrent starts"
printf '  per-request: 1=[%s] 2=[%s]\n' "$(cat "$home/held.1")" "$(cat "$home/held.2")"
pass "concurrent recovery (held lease): both requests rejected"

# --- 5c. bounded fan-out at the retained execution slot cap ---------------
home=$(make_home fanout)
for n in 6 7 8 9; do
  run_rec "$home" begin "t$n" --class run-failed --signature "distinct $n" --target "fm/t$n" >/dev/null
done
out=$(run_rec "$home" begin t10 --class run-failed --signature "distinct 10" --target fm/t10)
assert_contains "$out" "deferred: concurrent recovery cap 4 reached" "the fifth live recovery waits rather than exceeding the slot cap"
pass "concurrent recovery: fan-out capped at 4"

# --- 6. a failed recovery preserves the original work state ---------------
home=$(make_home preserve)
printf 'window=x\nworktree=/tmp/x\nkind=ship\nharness=claude\nbackend=herdr\nbranch=fm/t12\n' > "$home/state/t12.meta"
printf 'working: doing the original job\n' > "$home/state/t12.status"
meta_before=$(shasum -a 256 < "$home/state/t12.meta")
status_before=$(shasum -a 256 < "$home/state/t12.status")
out=$(run_rec "$home" begin t12 --class run-failed --signature "run failed" --target fm/t12)
fp=$(printf '%s' "$out" | sed -n 's/^begun: \([^ ]*\) .*/\1/p')
run_rec "$home" advance --fingerprint "$fp" ALTERNATIVE_SEARCH >/dev/null
for name in one two three; do
  run_rec "$home" alternative --fingerprint "$fp" --name "$name" >/dev/null
  run_rec "$home" validate --fingerprint "$fp" --result fail --evidence "still red" >/dev/null
done
assert_equals BLOCKED_EXHAUSTED "$(rec_state "$home" "$fp")" "exhausting three alternatives ends the recovery"
assert_equals "$meta_before" "$(shasum -a 256 < "$home/state/t12.meta")" "a failed recovery left the task metadata untouched"
assert_equals "$status_before" "$(shasum -a 256 < "$home/state/t12.status")" "a failed recovery left the task status log untouched"
pass "recovery failure: the original task state is preserved byte for byte"

# --- 7. a successful recovery hands the original work back -----------------
home=$(make_home resume)
out=$(run_rec "$home" begin t13 --class watcher-successor-none --signature "successor=none" --target fm/t13)
fp=$(printf '%s' "$out" | sed -n 's/^begun: \([^ ]*\) .*/\1/p')
run_rec "$home" advance --fingerprint "$fp" ALTERNATIVE_SEARCH >/dev/null
run_rec "$home" alternative --fingerprint "$fp" --name isolated-branch-edit >/dev/null
run_rec "$home" validate --fingerprint "$fp" --result pass --evidence "green" >/dev/null
out=$(run_rec "$home" resume --fingerprint "$fp")
assert_contains "$out" "state=RESUMED" "a verified recovery resumes the original work"
assert_contains "$out" "fm-control.sh t13 relaunch" "the resume plan uses the existing lifecycle owner"
assert_equals none "$(rec_verb "$home" "$fp")" "a resumed recovery stops projecting a registry verb"
run_rec "$home" check --fingerprint "$fp" >/dev/null
expect_code 1 "$?" "a resumed recovery no longer needs the supervisor"
pass "recovery success: the original work resumes through the existing control plane"

# --- 8. a wrong or unverified playbook cannot authorize a write -----------
home=$(make_home playbook)
out=$(run_rec "$home" begin t14 --class run-failed --signature "run failed" --target fm/t14)
fp=$(printf '%s' "$out" | sed -n 's/^begun: \([^ ]*\) .*/\1/p')
run_rec "$home" playbook add "$fp" run-failed verified merge claude/herdr "captain-approved once" >/dev/null
run_rec "$home" playbook add "$fp" run-failed hypothesis isolated-test-run claude/herdr "guess" >/dev/null
list=$(run_rec "$home" playbook list --scope claude/herdr)
assert_contains "$list" "verified" "a verified playbook entry reads verified in its own scope"
assert_contains "$list" "hypothesis" "an unverified playbook entry stays a hypothesis"
stale=$(run_rec "$home" playbook list --scope opencode/herdr)
assert_contains "$stale" "stale" "a verified entry reads stale once the environment scope moves"

run_rec "$home" apply --fingerprint "$fp" --action merge >/dev/null 2>&1
expect_code 5 "$?" "a reserved action is refused even with a verified playbook entry"
run_rec "$home" apply --fingerprint "$fp" --action upstream-write --approval-token granted >/dev/null 2>&1
expect_code 5 "$?" "an approval token cannot unlock a reserved action"
run_rec "$home" apply --fingerprint "$fp" --action production-deploy >/dev/null 2>&1
expect_code 5 "$?" "a production deploy is refused"
run_rec "$home" apply --fingerprint "$fp" --action frobnicate >/dev/null 2>&1
expect_code 6 "$?" "an unclassifiable action stops fail-closed"
run_rec "$home" apply --fingerprint "$fp" --action isolated-test-run >/dev/null 2>&1
expect_code 0 "$?" "an isolated verification action is permitted automatically"
run_rec "$home" apply --fingerprint "$fp" --action config-reload >/dev/null 2>&1
expect_code 4 "$?" "an approval-required action is refused without a token"
pass "playbook: neither a verified nor a stale entry can authorize a reserved write"

# --- 9. budgets and illegal transitions converge instead of looping -------
home=$(make_home budget)
out=$(FM_RECOVERY_NOW=1000 run_rec "$home" begin t15 --class unknown --signature "unclear" --target fm/t15)
fp=$(printf '%s' "$out" | sed -n 's/^begun: \([^ ]*\) .*/\1/p')
out=$(FM_RECOVERY_NOW=3000 run_rec "$home" advance --fingerprint "$fp" ALTERNATIVE_SEARCH)
assert_contains "$out" "state=BLOCKED_EXHAUSTED" "the whole-recovery budget forces an escalation instead of another attempt"
run_rec "$home" check --fingerprint "$fp" >/dev/null
expect_code 0 "$?" "an escalated recovery asks for the supervisor"

home=$(make_home illegal)
out=$(run_rec "$home" begin t16 --class run-failed --signature "run failed" --target fm/t16)
fp=$(printf '%s' "$out" | sed -n 's/^begun: \([^ ]*\) .*/\1/p')
run_rec "$home" advance --fingerprint "$fp" RECOVERABLE >/dev/null 2>&1
expect_code 1 "$?" "an illegal transition is refused"
run_rec "$home" advance --fingerprint "$fp" NOT_A_STATE >/dev/null 2>&1
expect_code 1 "$?" "an unknown state is refused"
pass "budgets: the recovery converges on an escalation and refuses illegal transitions"

# --- 10. deterministic classification from real evidence ------------------
home=$(make_home classify)
printf 'working: job under way\nblocked: no-mistakes PR target mismatch on the lane\n' > "$home/state/t17.status"
out=$(run_rec "$home" classify t17)
assert_contains "$out" "class: pr-target-mismatch" "a target-mismatch blocker classifies as pr-target-mismatch"
assert_contains "$out" "initial-state: RETRYABLE" "the mismatch class starts retryable"
printf 'blocked: watcher successor=none\n' > "$home/state/t18.status"
assert_contains "$(run_rec "$home" classify t18)" "class: watcher-successor-none" "a successor=none blocker classifies as watcher-successor-none"
printf 'blocked: worktree base contamination detected\n' > "$home/state/t19.status"
assert_contains "$(run_rec "$home" classify t19)" "class: worktree-base-contamination" "a contaminated base classifies as worktree-base-contamination"
printf 'paused: provider quota exhausted\n' > "$home/state/t20.status"
out=$(run_rec "$home" classify t20)
assert_contains "$out" "class: dependency-unavailable" "a provider outage classifies as dependency-unavailable"
assert_contains "$out" "initial-state: WAITING_DEPENDENCY" "an external cause starts as a declared wait"
printf 'blocked: no-mistakes daemon connection refused\n' > "$home/state/t21.status"
assert_contains "$(run_rec "$home" classify t21)" "class: daemon-down" "a refused daemon socket classifies as daemon-down"
pass "classification: deterministic cause classes from real evidence"

# --- 11. retire reopens a recurring failure without losing evidence --------
home=$(make_home retire)
out=$(run_rec "$home" begin t22 --class run-failed --signature "run failed" --target fm/t22)
fp=$(printf '%s' "$out" | sed -n 's/^begun: \([^ ]*\) .*/\1/p')
run_rec "$home" retire --fingerprint "$fp" >/dev/null 2>&1
expect_code 1 "$?" "a non-terminal recovery is refused by retire"
run_rec "$home" advance --fingerprint "$fp" ALTERNATIVE_SEARCH >/dev/null
for name in a b c; do
  run_rec "$home" alternative --fingerprint "$fp" --name "$name" >/dev/null
  run_rec "$home" validate --fingerprint "$fp" --result fail >/dev/null
done
assert_equals BLOCKED_EXHAUSTED "$(rec_state "$home" "$fp")" "the fixture recovery is terminal"
out=$(run_rec "$home" begin t22 --class run-failed --signature "run failed" --target fm/t22)
assert_contains "$out" "terminal BLOCKED_EXHAUSTED" "a terminal recovery is refused by its terminal state, not by lease freshness"
assert_contains "$out" "retire it to open a new recovery" "the refusal names the audited way forward"
out=$(run_rec "$home" retire --fingerprint "$fp")
assert_contains "$out" "retired:" "a terminal recovery is retired"
assert_absent "$home/state/recovery/$fp.rec" "the live record is moved out of the live store"
archive=$(find "$home/data/recovery-archive/$fp" -name '*.ledger' -type f 2>/dev/null | head -1)
assert_present "$archive" "the ledger is archived, not deleted"
assert_grep "retire" "$archive" "the archived ledger carries the retire event"
out=$(run_rec "$home" begin t22 --class run-failed --signature "run failed" --target fm/t22)
assert_contains "$out" "begun:" "a retired recovery lets the recurring failure open a new one"
pass "retire: a recurring failure reopens after an audited retire"

# --- 12. archive-all is an evidence-preserving rollback -------------------
home=$(make_home rollback)
out=$(run_rec "$home" begin t23 --class run-failed --signature "one" --target fm/t23)
fp1=$(printf '%s' "$out" | sed -n 's/^begun: \([^ ]*\) .*/\1/p')
out=$(run_rec "$home" begin t24 --class approval-boundary --signature "two" --target fm/t24)
fp2=$(printf '%s' "$out" | sed -n 's/^begun: \([^ ]*\) .*/\1/p')
run_rec "$home" escalate --fingerprint "$fp1" --reason "exhausted" >/dev/null
before_rec=$(shasum -a 256 < "$home/state/recovery/$fp1.rec")
before_led=$(shasum -a 256 < "$home/state/recovery/$fp1.ledger")
before_led2=$(shasum -a 256 < "$home/state/recovery/$fp2.ledger")
out=$(run_rec "$home" archive-all --reason "capability rollback rehearsal")
dest=$(printf '%s' "$out" | sed -n 's/^archived: //p')
assert_present "$dest/ROLLBACK.audit" "the rollback writes an audit record"
assert_present "$dest/$fp1.rec" "the terminal record survives the rollback"
assert_present "$dest/$fp2.ledger" "the open recovery's ledger survives the rollback"
assert_equals "$before_rec" "$(shasum -a 256 < "$dest/$fp1.rec")" "the archived record is byte-identical to the live one"
assert_equals "$before_led" "$(shasum -a 256 < "$dest/$fp1.ledger")" "the archived ledger is byte-identical to the live one"
assert_equals "$before_led2" "$(shasum -a 256 < "$dest/$fp2.ledger")" "every ledger is preserved, not only terminal ones"
audit=$(cat "$dest/ROLLBACK.audit")
assert_contains "$audit" "schema=fm-recovery-rollback.v1" "the rollback audit record is versioned"
assert_contains "$audit" "reason=capability rollback rehearsal" "the rollback records its reason"
assert_contains "$audit" "sha256=" "the rollback audit records a digest for every preserved file"
assert_contains "$audit" "never deleted by rollback" "the retention policy is stated in the audit record"
assert_grep "escalate" "$dest/$fp1.ledger" "incident-investigation evidence outlives the rollback"
pass "rollback: capability removed without destroying incident evidence"

# --- 13. execution class: test output can never be labelled production ----
home=$(make_home execclass)
run_rec "$home" begin t25 --class run-failed --signature "x" --target fm/t25 \
  --exec-class production > "$home/p.out" 2>&1
expect_code 1 "$?" "the engine refuses to record a production recovery"
assert_grep "separately approved control plane" "$home/p.out" "the refusal names where production classification belongs"
run_rec "$home" begin t26 --class run-failed --signature "x" --target fm/t26 > "$home/b26.out"
fp=$(sed -n 's/^begun: \([^ ]*\) .*/\1/p' "$home/b26.out")
out=$(run_rec "$home" status --fingerprint "$fp")
assert_contains "$out" "exec: isolated" "an unlabelled recovery is recorded as isolated, never production"
run_rec "$home" begin t27 --class run-failed --signature "x" --target fm/t27 --exec-class simulation > "$home/b27.out"
fp=$(sed -n 's/^begun: \([^ ]*\) .*/\1/p' "$home/b27.out")
out=$(run_rec "$home" status --fingerprint "$fp")
assert_contains "$out" "exec: simulation" "a simulation recovery is tagged as a simulation"
pass "execution class: production is unrecordable here, so test output cannot be read as operational"

# --- 14. measurement export is tagged, complete, and read-only -----------
home=$(make_home export)
out=$(run_rec "$home" begin t28 --class run-failed --signature "export probe" --target fm/t28 \
  --exec-class simulation)
fp=$(printf '%s' "$out" | sed -n 's/^begun: \([^ ]*\) .*/\1/p')
run_rec "$home" attempt --fingerprint "$fp" --cause run-failed --result fail >/dev/null
run_rec "$home" advance --fingerprint "$fp" ALTERNATIVE_SEARCH >/dev/null
run_rec "$home" alternative --fingerprint "$fp" --name isolated-test-run >/dev/null
run_rec "$home" validate --fingerprint "$fp" --result pass --evidence "green" >/dev/null
before_state=$(find "$home" -type f -exec shasum -a 256 {} + 2>/dev/null | LC_ALL=C sort | shasum -a 256)
events=$(run_rec "$home" export-events)
after_state=$(find "$home" -type f -exec shasum -a 256 {} + 2>/dev/null | LC_ALL=C sort | shasum -a 256)
assert_equals "$before_state" "$after_state" "the export writes nothing"
assert_contains "$events" '"schema":"fm-recovery-event.v1"' "the export is a versioned event stream"
assert_contains "$events" '"exec_class":"simulation"' "every event carries its execution class"
assert_contains "$events" '"failure_fingerprint":"'"$fp"'"' "every event carries the shared failure fingerprint"
assert_contains "$events" '"incident_id":"inc:' "every event carries the shared incident identity"
assert_contains "$events" '"recovery_attempt_id":"'"$fp"'-' "every event carries the shared recovery-attempt identity"
assert_contains "$events" '"failure_class":"run-failed"' "every event carries the failure class"
assert_contains "$events" '"stage":"VALIDATING"' "the stage is derived per event, not folded from the current record"
assert_not_contains "$events" 'production' "the export contains no production execution at all"
if command -v jq >/dev/null 2>&1; then
  lines=$(printf '%s\n' "$events" | wc -l | tr -d ' ')
  parsed=$(printf '%s\n' "$events" | jq -c . 2>/dev/null | wc -l | tr -d ' ')
  assert_equals "$lines" "$parsed" "every exported line is valid JSON"
  stages=$(printf '%s\n' "$events" | jq -r '.stage' | sort -u | tr '\n' ',')
  assert_contains "$stages" "VALIDATING" "the per-event stages read through jq and include the validating stage"
  assert_contains "$stages" "ALTERNATIVE_SEARCH" "the per-event stages include the earlier search stage, not only the current one"
  assert_contains "$stages" "RECOVERABLE" "the per-event stages include the final recoverable stage"
fi
pass "measurement export: tagged, complete, JSON-valid, and read-only"

echo "ok - fm-recovery state machine (all scenarios)"
