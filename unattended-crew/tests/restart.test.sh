#!/usr/bin/env bash
# restart.test.sh - cross-process restart / session pickup. The coordinator is
# actually killed (SIGKILL) mid-task; a fresh process must resume from durable
# state, adopt the live run instead of re-dispatching, and never re-run finished
# work. A mere "the JSON file exists" check is not accepted.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ER="$UCX/fm-unattended-evidence.sh"

# 1. kill the coordinator while the executor is running, then resume
new_home
printf '{"batch_id":"b","baseline_sha":"T","mode":"test","retry_limit":2,"tasks":[{"task_id":"t1","executor":{"command":["bash","-c","sleep 3; echo done"]},"audit":{"required":true},"required_tests":["t1"]}]}' > "$UC_HOME/c.json"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
"$UCX/fm-unattended.sh" run --batch b >/dev/null 2>&1 &
pid=$!
sleep 1
state_at_kill=$(task_state b t1)
kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
[ "$state_at_kill" = RUNNING ] && ok "coordinator killed while RUNNING" || no "expected RUNNING at kill (got $state_at_kill)"
run_uc resume --batch b >/dev/null 2>&1
[ "$(task_state b t1)" = VERIFIED_PASS ] && ok "resume completed the task => VERIFIED_PASS" || no "resume (got $(task_state b t1))"
sess=$(ls "$UC_HOME/batches/b/sessions" 2>/dev/null | grep -c 't1-executor')
[ "$sess" = 1 ] && ok "resume did not duplicate the executor session" || no "duplicate executor sessions=$sess"
# evidence persisted across the process boundary
[ -f "$UC_HOME/batches/b/evidence/runs/t1/executor/rc" ] && ok "evidence rc persisted across restart" || no "evidence missing after restart"
cleanup_home

# 2. resuming a finished batch changes nothing
new_home
run_uc init --batch b --contract "$(dirname "${BASH_SOURCE[0]}")/fixtures/normal.contract.json" >/dev/null
run_uc run --batch b >/dev/null
n1=$(wc -l < "$UC_HOME/batches/b/state.jsonl"); s1=$(ls "$UC_HOME/batches/b/sessions" | wc -l | tr -d ' ')
run_uc resume --batch b >/dev/null
n2=$(wc -l < "$UC_HOME/batches/b/state.jsonl"); s2=$(ls "$UC_HOME/batches/b/sessions" | wc -l | tr -d ' ')
{ [ "$n1" = "$n2" ] && [ "$s1" = "$s2" ]; } && ok "resume of finished batch is a no-op" || no "resume changed finished batch ($n1->$n2, $s1->$s2)"
cleanup_home

# 3. a task parked at AUDIT_PENDING is never falsely completed without an audit
new_home
printf '{"batch_id":"b","baseline_sha":"T","mode":"test","retry_limit":1,"tasks":[{"task_id":"t1","executor":{"command":["true"]},"audit":{"required":true},"required_tests":["t1"]}]}' > "$UC_HOME/c.json"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
bd="$UC_HOME/batches/b"
mkdir -p "$bd/evidence/runs/t1/executor" "$bd/evidence/runs/t1/auditor" "$bd/evidence/runs/t1/gate" "$bd/tasks"
cp "$UC_HOME/c.json" "$bd/evidence/runs/t1/task-contract.json"
EVIDENCE_ROOT="$bd/evidence" "$ER" run t1 -- true >/dev/null 2>&1
printf '1\n' > "$bd/evidence/runs/t1/attempt"
printf 'new=AUDIT_PENDING\n' > "$bd/tasks/t1.state"
printf '1\n' > "$bd/tasks/t1.attempts"
[ "$(task_state b t1)" = AUDIT_PENDING ] && ok "task parked at AUDIT_PENDING before resume" || no "park setup"
FM_FAKE_AUDIT_NONE=1 run_uc resume --batch b >/dev/null 2>&1
v=$(task_state b t1)
{ [ "$v" = AUDIT_UNAVAILABLE ]; } && ok "incomplete audit => AUDIT_UNAVAILABLE, never VERIFIED_PASS" || no "audit-pending resume (got $v)"
cleanup_home

echo "# restart.test.sh PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
