#!/usr/bin/env bash
# real-e2e.test.sh - the coordinator's REAL backend driven end to end with NO
# provider call. The adapter's real path (fm-spawn/fm-crew-state/fm-send) is
# pointed at tests/mockhome, a test double that replays the recorded canary
# fixture and can inject every failure the batch names. The state machine,
# evidence collector, auditor harvest, and deterministic judge are the real
# ones. A real provider call would replace only the mock home.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RMOCK=""
new_realhome() {
  new_home
  RMOCK=$(mktemp -d "${TMPDIR:-/tmp}/uc-mock.XXXXXX")
  cp -R "$TESTS_DIR/mockhome/." "$RMOCK/"
  chmod +x "$RMOCK"/bin/*.sh
  git -C "$RMOCK" init -q
  git -C "$RMOCK" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  mkdir -p "$RMOCK/project"
  export UC_FM_HOME="$RMOCK" UC_REAL_PROJECT="$RMOCK/project"
  export FM_UNATTENDED_ADAPTER=real
}
cleanup_real() { rm -rf "$UC_HOME" "$RMOCK"; unset FM_UNATTENDED_ADAPTER UC_FM_HOME UC_REAL_PROJECT UC_CREW_WAIT_SECS; }

mkreal() { # <file> <retry_limit> <tasks-json>
  cat > "$1" <<EOF
{ "batch_id": "b", "baseline_sha": "TESTBASE", "mode": "production",
  "allowed_paths": ["$RMOCK/project"],
  "forbidden_operations": ["github_write","credential_change","home_checkout_change","watcher_runtime_change","real_worker_call","wake_drain","backpass_change","kill_other_session_process","external_write"],
  "retry_limit": $2, "ack_timeout_secs": 3, "tasks": $3 }
EOF
}
TASK1='[{"task_id":"t1","depends_on":[],"approval_required":false,"required_tests":["real-e2e"],"executor":{"command":["true"],"intent":"mock executor mission","spec":"mock executor spec"},"audit":{"required":true,"intent":"mock auditor mission","spec":"mock auditor spec"}}]'
reason_has() { grep -q "task_id=$2 .*reason=$3" "$UC_HOME/batches/$1/state.jsonl" 2>/dev/null; }

# 1. full real path: dispatch -> ack -> run -> evidence -> separate auditor ->
#    judge -> VERIFIED_PASS -> durable handoff
new_realhome
mkreal "$UC_HOME/c.json" 2 "$TASK1"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
UC_CREW_WAIT_SECS=5 run_uc run --batch b >/dev/null
{ [ "$(task_state b t1)" = VERIFIED_PASS ] && [ "$(verdict_of b t1)" = VERIFIED_PASS ]; } \
  && ok "real: executor+auditor+judge => VERIFIED_PASS" || no "real normal (state=$(task_state b t1) verdict=$(verdict_of b t1))"
ew=$(cat "$UC_HOME/batches/b/evidence/runs/t1/executor/wd" 2>/dev/null)
aw=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["workdir"])' "$UC_HOME/batches/b/evidence/runs/t1/auditor/session.json" 2>/dev/null)
{ [ -n "$ew" ] && [ -n "$aw" ] && [ "$ew" != "$aw" ]; } \
  && ok "real: auditor worktree differs from executor worktree" || no "real workspace separation (exec=$ew aud=$aw)"
[ "$(ls "$UC_HOME/batches/b/sessions" | wc -l | tr -d ' ')" = 2 ] \
  && ok "real: exactly two crew sessions (executor + auditor)" || no "real sessions ($(ls "$UC_HOME/batches/b/sessions"))"
[ -f "$UC_HOME/batches/b/handoff.md" ] && ok "real: durable handoff written" || no "real handoff missing"
cleanup_real

# 2. spawn refused -> REWORK then HOLD at the retry limit
new_realhome; mkreal "$UC_HOME/c.json" 1 "$TASK1"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
MOCK_SPAWN_FAIL=1 run_uc run --batch b >/dev/null
{ [ "$(task_state b t1)" = HOLD ] && reason_has b t1 spawn-failed; } \
  && ok "real: spawn refused => HOLD (spawn-failed)" || no "real spawn-fail (state=$(task_state b t1))"
cleanup_real

# 3. endpoint dead at spawn: spawn returns 0 but no live agent => no ACK
new_realhome; mkreal "$UC_HOME/c.json" 1 "$TASK1"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
MOCK_DEAD=1 run_uc run --batch b >/dev/null
{ [ "$(task_state b t1)" = HOLD ] && reason_has b t1 ack-timeout; } \
  && ok "real: dead endpoint => no ACK => HOLD (ack-timeout)" || no "real ack (state=$(task_state b t1))"
cleanup_real

# 4. completion event missing: never a false success
new_realhome; mkreal "$UC_HOME/c.json" 2 "$TASK1"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
MOCK_NO_DONE=1 UC_CREW_WAIT_SECS=2 run_uc run --batch b >/dev/null
s=$(task_state b t1)
{ [ "$s" = RUNNING ] && [ "$(verdict_of b t1)" != VERIFIED_PASS ]; } \
  && ok "real: missing completion event stays RUNNING (not VERIFIED_PASS)" || no "real no-done (state=$s)"
cleanup_real

# 5. executor fails after ACK -> REWORK -> HOLD
new_realhome; mkreal "$UC_HOME/c.json" 1 "$TASK1"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
MOCK_FAIL=1 run_uc run --batch b >/dev/null
{ [ "$(task_state b t1)" = HOLD ] && reason_has b t1 worker-failed; } \
  && ok "real: executor failure => HOLD (worker-failed)" || no "real worker-fail (state=$(task_state b t1))"
cleanup_real

# 6. evidence incomplete (no report) -> HOLD, not a pass
new_realhome; mkreal "$UC_HOME/c.json" 1 "$TASK1"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
MOCK_NO_REPORT=1 run_uc run --batch b >/dev/null
{ [ "$(task_state b t1)" = HOLD ] && reason_has b t1 evidence-incomplete; } \
  && ok "real: missing report => HOLD (evidence-incomplete)" || no "real evidence-incomplete (state=$(task_state b t1))"
cleanup_real

# 7. the collected real evidence is hash-bound: tampering flips the judge to HOLD
new_realhome; mkreal "$UC_HOME/c.json" 2 "$TASK1"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
UC_CREW_WAIT_SECS=5 run_uc run --batch b >/dev/null
echo tampered >> "$UC_HOME/batches/b/evidence/runs/t1/executor/stdout/cmd.out"
tampered=$(EVIDENCE_ROOT="$UC_HOME/batches/b/evidence" "$UCX/fm-unattended-judge.sh" run t1 2>/dev/null | sed 's/^VERDICT=//;s/ .*//')
[ "$tampered" = HOLD ] && ok "real: tampered real evidence => HOLD (artifact-hash-mismatch)" || no "real tamper (verdict=$tampered)"
cleanup_real

# 8. auditor spawn refused -> capped audit retry -> HOLD
new_realhome; mkreal "$UC_HOME/c.json" 1 "$TASK1"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
MOCK_AUDIT_SPAWN_FAIL=1 UC_CREW_WAIT_SECS=5 run_uc run --batch b >/dev/null
{ [ "$(task_state b t1)" = HOLD ] && reason_has b t1 auditor-dispatch-failed; } \
  && ok "real: auditor spawn refused => HOLD (auditor-dispatch-failed)" || no "real audit-fail (state=$(task_state b t1))"
cleanup_real

# 9. auditor produces no verdict -> AUDIT_UNAVAILABLE (never VERIFIED_PASS)
new_realhome; mkreal "$UC_HOME/c.json" 1 "$TASK1"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
MOCK_NO_VERDICT=1 UC_CREW_WAIT_SECS=5 run_uc run --batch b >/dev/null
[ "$(task_state b t1)" = AUDIT_UNAVAILABLE ] && ok "real: no audit verdict => AUDIT_UNAVAILABLE" || no "real audit-unavailable (state=$(task_state b t1))"
cleanup_real

# 10. auditor conflict -> HOLD
new_realhome; mkreal "$UC_HOME/c.json" 1 "$TASK1"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
MOCK_AUDIT_VERDICT=CONFLICT UC_CREW_WAIT_SECS=5 run_uc run --batch b >/dev/null
{ [ "$(task_state b t1)" = HOLD ] && grep -q audit-conflict "$UC_HOME/batches/b/evidence/runs/t1/gate/verdict.json"; } \
  && ok "real: auditor conflict => HOLD (audit-conflict)" || no "real audit-conflict (state=$(task_state b t1))"
cleanup_real

# 11. auditor shares the executor workspace -> HOLD
new_realhome; mkreal "$UC_HOME/c.json" 1 "$TASK1"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
MOCK_SAME_WORKSPACE=1 UC_CREW_WAIT_SECS=5 run_uc run --batch b >/dev/null
{ [ "$(task_state b t1)" = HOLD ] && grep -q auditor-executor-same-workspace "$UC_HOME/batches/b/evidence/runs/t1/gate/verdict.json"; } \
  && ok "real: same workspace => HOLD (auditor-executor-same-workspace)" || no "real same-ws (state=$(task_state b t1))"
cleanup_real

# 12. coordinator SIGKILL mid-run -> resume adopts the live crew, no duplicate dispatch
new_realhome; mkreal "$UC_HOME/c.json" 2 "$TASK1"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
MOCK_DONE_DELAY=3 UC_CREW_WAIT_SECS=1 "$UCX/fm-unattended.sh" run --batch b >/dev/null 2>&1 &
cpid=$!; sleep 1
kill -9 "$cpid" 2>/dev/null; wait "$cpid" 2>/dev/null
MOCK_REFUSE_DUP=1 UC_CREW_WAIT_SECS=8 run_uc resume --batch b >/dev/null
disp=$(grep -c 'task_id=t1 .*new=DISPATCHING' "$UC_HOME/batches/b/state.jsonl")
[ "$disp" = 1 ] && ok "real: resume did not re-dispatch the executor (1 dispatch)" || no "real restart duplicate dispatch ($disp)"
[ "$(task_state b t1)" = VERIFIED_PASS ] && ok "real: resume completed via the adopted crew => VERIFIED_PASS" || no "real resume (state=$(task_state b t1))"
cleanup_real

# 12b. auditor takes longer than the ACK window: the coordinator must wait the
#      full crew budget, not judge on the ACK timeout (real-canary regression)
new_realhome; mkreal "$UC_HOME/c.json" 1 "$TASK1"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
MOCK_AUDIT_DONE_DELAY=5 UC_CREW_WAIT_SECS=12 run_uc run --batch b >/dev/null
[ "$(task_state b t1)" = VERIFIED_PASS ] \
  && ok "real: slow auditor completes within crew budget => VERIFIED_PASS" || no "real slow-auditor (state=$(task_state b t1) verdict=$(verdict_of b t1))"
cleanup_real

# 12c. AUDIT_UNAVAILABLE from an observation timeout is recoverable on resume
#      by adopting the SAME auditor (never a new crew)
new_realhome; mkreal "$UC_HOME/c.json" 1 "$TASK1"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
MOCK_AUDIT_DONE_DELAY=4 UC_CREW_WAIT_SECS=1 run_uc run --batch b >/dev/null
pre=$(task_state b t1)
MOCK_REFUSE_DUP=1 MOCK_AUDIT_DONE_DELAY=4 UC_CREW_WAIT_SECS=8 run_uc resume --batch b >/dev/null
aud=$(ls "$UC_HOME/batches/b/sessions" | grep -c 'audit')
{ [ "$pre" = AUDITING ] && [ "$(task_state b t1)" = VERIFIED_PASS ] && [ "$aud" = 1 ]; } \
  && ok "real: slow auditor parks at AUDITING, resume adopts the same auditor => VERIFIED_PASS" || no "real audit adopt (pre=$pre post=$(task_state b t1) auditors=$aud)"
cleanup_real

# 13. approval-required task is held, never dispatched
new_realhome
mkreal "$UC_HOME/c.json" 1 '[{"task_id":"t1","approval_required":true,"executor":{"command":["true"]},"audit":{"required":true}}]'
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
run_uc run --batch b >/dev/null
{ [ "$(task_state b t1)" = HOLD ] && [ "$(run_uc next --batch b)" = NONE ]; } \
  && ok "real: approval-required => HOLD, no safe next task" || no "real approval (state=$(task_state b t1))"
cleanup_real

# 14. production may never use the built-in fake auditor (real backend)
new_realhome
mkreal "$UC_HOME/c.json" 1 '[{"task_id":"t1","executor":{"command":["true"],"intent":"i","spec":"s"},"required_tests":["x"],"audit":{"required":true,"intent":"a","spec":"s","command":["bash","'"$UCX"'/fake-auditor.sh"]}}]'
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
UC_CREW_WAIT_SECS=5 run_uc run --batch b >/dev/null
{ [ "$(task_state b t1)" = HOLD ] && reason_has b t1 fake-auditor-in-production; } \
  && ok "real: fake auditor in production => HOLD (fake-auditor-in-production)" || no "real fake-auditor block (state=$(task_state b t1))"
cleanup_real

# 15. production fake-auditor block also holds on the fake backend
new_home
mkreal "$UC_HOME/c.json" 1 '[{"task_id":"t1","executor":{"command":["true"]},"required_tests":["x"],"audit":{"required":true}}]'
FM_UNATTENDED_ADAPTER=fake run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
FM_UNATTENDED_ADAPTER=fake run_uc run --batch b >/dev/null
{ [ "$(task_state b t1)" = HOLD ] && reason_has b t1 fake-auditor-in-production; } \
  && ok "production fake backend: no real audit => HOLD (fake-auditor-in-production)" || no "fake-backend production guard (state=$(task_state b t1))"
cleanup_home

# 16. real spawn with no mission brief is refused fail-closed (no crew spawned)
new_realhome
mkreal "$UC_HOME/c.json" 1 '[{"task_id":"t1","executor":{"command":["true"]},"required_tests":["x"],"audit":{"required":true}}]'
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
run_uc run --batch b >/dev/null
{ [ "$(task_state b t1)" = HOLD ] && reason_has b t1 spawn-failed && [ ! -f "$RMOCK/state/t1.meta" ]; } \
  && ok "real: no brief/mission => spawn refused, HOLD (no crew)" || no "real no-brief guard (state=$(task_state b t1))"
cleanup_real

# 17. Evidence Guard integrated, claim PASSES: the real path still reaches
#     VERIFIED_PASS (the guard is not a blanket blocker)
new_realhome
mkreal "$UC_HOME/c.json" 1 '[{"task_id":"t1","depends_on":[],"approval_required":false,"required_tests":["real-e2e"],"executor":{"command":["true"],"intent":"i","spec":"s","claims":[{"id":"toplevel","kind":"count","report_pattern":"Top level: ([0-9]+)","source":{"type":"cmd","cmd":"seq 1 244","reduce":"lines"}}]},"audit":{"required":true,"intent":"a","spec":"s"}}]'
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
UC_CREW_WAIT_SECS=5 run_uc run --batch b >/dev/null
{ [ "$(task_state b t1)" = VERIFIED_PASS ] && [ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["verdict"])' "$UC_HOME/batches/b/evidence/runs/t1/gate/guard.json")" = PASS ]; } \
  && ok "real: evidence guard claim passes => VERIFIED_PASS" || no "real guard pass (state=$(task_state b t1))"
cleanup_real

# 18. Evidence Guard blocks a false executor claim BEFORE the auditor is spent:
#     report says '14 families', canonical is 15 => HOLD, and NO auditor crew.
new_realhome
mkreal "$UC_HOME/c.json" 1 '[{"task_id":"t1","depends_on":[],"approval_required":false,"required_tests":["real-e2e"],"executor":{"command":["true"],"intent":"i","spec":"s","claims":[{"id":"families","kind":"count","report_pattern":"([0-9]+) families","source":{"type":"cmd","cmd":"seq 1 15","reduce":"lines"}}]},"audit":{"required":true,"intent":"a","spec":"s"}}]'
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
UC_CREW_WAIT_SECS=5 run_uc run --batch b >/dev/null
aud=$(ls "$UC_HOME/batches/b/sessions" 2>/dev/null | grep -c 'audit')
{ [ "$(task_state b t1)" = HOLD ] && reason_has b t1 evidence-guard-mismatch && [ "$aud" = 0 ] \
  && grep -q 'families:value-mismatch(14!=15)' "$UC_HOME/batches/b/evidence/runs/t1/gate/guard.json"; } \
  && ok "real: false executor claim => HOLD (evidence-guard-mismatch), no auditor spent" \
  || no "real guard block (state=$(task_state b t1) auditors=$aud)"
cleanup_real

echo "# real-e2e.test.sh PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
