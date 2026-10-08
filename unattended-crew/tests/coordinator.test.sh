#!/usr/bin/env bash
# coordinator.test.sh - fake-backend E2E for the unattended batch coordinator:
# the normal path, dependency ordering, idempotency under duplicate wakes, and
# the worker-side failure paths. No real worker/provider is called.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FIX="$TESTS_DIR/fixtures"

# 1. normal path + dependency ordering + judge VERIFIED_PASS
new_home
run_uc init --batch b --contract "$FIX/normal.contract.json" >/dev/null
run_uc run --batch b >/dev/null
{ [ "$(task_state b t1)" = VERIFIED_PASS ] && [ "$(task_state b t2)" = VERIFIED_PASS ]; } \
  && ok "normal: t1,t2 VERIFIED_PASS" || no "normal path (t1=$(task_state b t1) t2=$(task_state b t2))"
# dependency: t2 must not be dispatched before t1 reached VERIFIED_PASS
first_t2=$(grep -n 'task_id=t2 .*new=DISPATCHING' "$UC_HOME/batches/b/state.jsonl" | head -1 | cut -d: -f1)
first_t1_pass=$(grep -n 'task_id=t1 .*new=VERIFIED_PASS' "$UC_HOME/batches/b/state.jsonl" | head -1 | cut -d: -f1)
{ [ -n "$first_t2" ] && [ -n "$first_t1_pass" ] && [ "$first_t2" -gt "$first_t1_pass" ]; } \
  && ok "dependency: t2 dispatched after t1 VERIFIED_PASS" || no "dependency order"
cleanup_home

# 2. idempotency / duplicate-completion: re-running changes nothing
new_home
run_uc init --batch b --contract "$FIX/normal.contract.json" >/dev/null
run_uc run --batch b >/dev/null
before=$(grep -c 'new=VERIFIED_PASS' "$UC_HOME/batches/b/state.jsonl")
sessions_before=$(ls "$UC_HOME/batches/b/sessions" | wc -l | tr -d ' ')
run_uc run --batch b >/dev/null
after=$(grep -c 'new=VERIFIED_PASS' "$UC_HOME/batches/b/state.jsonl")
sessions_after=$(ls "$UC_HOME/batches/b/sessions" | wc -l | tr -d ' ')
{ [ "$before" = "$after" ] && [ "$sessions_before" = "$sessions_after" ]; } \
  && ok "duplicate wake: no new transition or session" || no "duplicate wake (vp $before->$after, sessions $sessions_before->$sessions_after)"
cleanup_home

# 3. ACK missing -> retryable, then HOLD when the retry limit is reached
new_home
printf '{"batch_id":"b","baseline_sha":"T","mode":"test","retry_limit":1,"tasks":[{"task_id":"t1","executor":{"command":["true"]},"audit":{"required":true},"required_tests":["t1"]}]}' > "$UC_HOME/c.json"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
FM_FAKE_NO_ACK=1 run_uc run --batch b >/dev/null
[ "$(task_state b t1)" = HOLD ] && [ "$(task_reason b t1 HOLD)" = retry-exhausted ] \
  && ok "no ACK => HOLD retry-exhausted" || no "no ACK (state=$(task_state b t1) reason=$(task_reason b t1 HOLD))"
cleanup_home

# 4. worker failure -> REWORK, retry, then HOLD retry-exhausted
new_home
printf '{"batch_id":"b","baseline_sha":"T","mode":"test","retry_limit":2,"tasks":[{"task_id":"t1","executor":{"command":["bash","-c","exit 7"]},"audit":{"required":true},"required_tests":["t1"]}]}' > "$UC_HOME/c.json"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
run_uc run --batch b >/dev/null
attempts=$(cat "$UC_HOME/batches/b/tasks/t1.attempts")
[ "$(task_state b t1)" = HOLD ] && [ "$(task_reason b t1 HOLD)" = retry-exhausted ] && [ "$attempts" = 2 ] \
  && ok "worker failure => REWORK x2 => HOLD at limit" || no "worker failure (state=$(task_state b t1) attempts=$attempts)"
cleanup_home

# 5. session identity mismatch -> HOLD
new_home
printf '{"batch_id":"b","baseline_sha":"T","mode":"test","retry_limit":1,"tasks":[{"task_id":"t1","executor":{"command":["true"]},"audit":{"required":true},"required_tests":["t1"]}]}' > "$UC_HOME/c.json"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
FM_FAKE_WRONG_IDENTITY=1 run_uc run --batch b >/dev/null
{ [ "$(task_state b t1)" = HOLD ] && [ "$(task_reason b t1 HOLD)" = identity-mismatch ]; } \
  && ok "session id mismatch => HOLD" || no "identity mismatch (state=$(task_state b t1))"
cleanup_home

# 6. audit findings missing -> AUDIT_UNAVAILABLE (never VERIFIED_PASS)
new_home
printf '{"batch_id":"b","baseline_sha":"T","mode":"test","retry_limit":1,"tasks":[{"task_id":"t1","executor":{"command":["true"]},"audit":{"required":true},"required_tests":["t1"]}]}' > "$UC_HOME/c.json"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
FM_FAKE_AUDIT_NONE=1 run_uc run --batch b >/dev/null
[ "$(task_state b t1)" = AUDIT_UNAVAILABLE ] && ok "missing audit => AUDIT_UNAVAILABLE" || no "missing audit (state=$(task_state b t1))"
cleanup_home

# 7. auditor/executor conflict -> HOLD
new_home
printf '{"batch_id":"b","baseline_sha":"T","mode":"test","retry_limit":1,"tasks":[{"task_id":"t1","executor":{"command":["true"]},"audit":{"required":true},"required_tests":["t1"]}]}' > "$UC_HOME/c.json"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
FM_FAKE_AUDIT_VERDICT=CONFLICT run_uc run --batch b >/dev/null
{ [ "$(task_state b t1)" = HOLD ] && [ "$(verdict_of b t1)" = HOLD ] && grep -q audit-conflict "$UC_HOME/batches/b/evidence/runs/t1/gate/verdict.json"; } \
  && ok "auditor conflict => HOLD" || no "audit conflict (state=$(task_state b t1) verdict=$(verdict_of b t1))"
cleanup_home

# 8. approval-required task is held, never dispatched
new_home
printf '{"batch_id":"b","baseline_sha":"T","mode":"test","retry_limit":1,"tasks":[{"task_id":"t1","approval_required":true,"executor":{"command":["true"]},"audit":{"required":true}}]}' > "$UC_HOME/c.json"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
run_uc run --batch b >/dev/null
[ "$(task_state b t1)" = HOLD ] && [ "$(task_reason b t1 HOLD)" = approval-required ] \
  && ok "approval_required => HOLD approval-required" || no "approval (state=$(task_state b t1))"
[ "$(run_uc next --batch b)" = NONE ] && ok "no safe next task => NONE" || no "next should be NONE"
cleanup_home

# 9. worker interrupted (dead runner, no exit code) -> HOLD
new_home
printf '{"batch_id":"b","baseline_sha":"T","mode":"test","retry_limit":2,"tasks":[{"task_id":"t1","executor":{"command":["true"]},"audit":{"required":true},"required_tests":["t1"]}]}' > "$UC_HOME/c.json"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
# forge a RUNNING task whose runner died without writing an exit code
mkdir -p "$UC_HOME/batches/b/evidence/runs/t1/executor"
printf '999999\n' > "$UC_HOME/batches/b/evidence/runs/t1/executor-runner.pid"
printf 'new=RUNNING\n' > "$UC_HOME/batches/b/tasks/t1.state"
printf '1\n' > "$UC_HOME/batches/b/tasks/t1.attempts"
printf '1\n' > "$UC_HOME/batches/b/evidence/runs/t1/attempt"
run_uc resume --batch b >/dev/null
{ [ "$(task_state b t1)" = HOLD ] && [ "$(task_reason b t1 HOLD)" = worker-interrupted ]; } \
  && ok "interrupted worker => HOLD" || no "interrupted worker (state=$(task_state b t1))"
cleanup_home

# 10. cleanup refuses while a tracked test is still running
W=$(mktemp -d "${TMPDIR:-/tmp}/uc-evid.XXXXXX")
EVIDENCE_ROOT="$W" "$UCX/fm-unattended-evidence.sh" run slow -- bash -c 'sleep 3' >/dev/null 2>&1 &
sp=$!
sleep 0.5
EVIDENCE_ROOT="$W" "$UCX/fm-unattended-evidence.sh" cleanup slow >/dev/null 2>&1; crc=$?
wait "$sp" 2>/dev/null || true
[ "$crc" -eq 3 ] && ok "cleanup refused while test alive (rc=$crc)" || no "cleanup refusal (rc=$crc)"
rm -rf "$W"

echo "# coordinator.test.sh PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
