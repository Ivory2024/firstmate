#!/usr/bin/env bash
# quota.test.sh - per-window quota / concurrency gate: cap enforcement, free
# allow-list, paid-model refusal, safe HOLD on unknown quota, duplicate/retry
# accounting, and the coordinator integration (block before spawn; no further
# dispatch once the batch is held).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

Q="$UCX/fm-unattended-quota.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/uc-q.XXXXXX")
HOME1="$W/home"; mkdir -p "$HOME1/state"

mkcfg() { # <file> <max_conc> <max_calls> <free-json> <allow_paid>
  cat > "$1" <<EOF
{ "quota": { "max_concurrent_crews": $2, "max_provider_calls": $3,
             "free_models": $4, "allow_paid_models": $5 } }
EOF
}

# 1. model allow-list
mkcfg "$W/c.json" 1 2 '["free/x"]' false
"$Q" check-model --model free/x --config "$W/c.json" >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "check-model: free model allowed" || no "free model blocked"
"$Q" check-model --model paid/y --config "$W/c.json" >/dev/null 2>&1
[ "$?" -eq 3 ] && ok "check-model: unapproved paid model blocked" || no "paid model not blocked"
"$Q" check-model --model '' --config "$W/c.json" >/dev/null 2>&1
[ "$?" -eq 4 ] && ok "check-model: unknown (empty) model => HOLD" || no "unknown model not held"
mkcfg "$W/cpaid.json" 1 2 '["free/x"]' true
"$Q" check-model --model paid/y --config "$W/cpaid.json" >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "check-model: paid approved when allow_paid_models" || no "paid approve failed"

# 2. provider-call cap
mkcfg "$W/c.json" 1 1 '["free/x"]' false
"$Q" reserve --batch b --role executor --home "$HOME1" --config "$W/c.json" >/dev/null 2>&1
r1=$?
"$Q" reserve --batch b --role auditor --home "$HOME1" --config "$W/c.json" >/dev/null 2>&1; r2=$?
out=$("$Q" reserve --batch b --role executor --home "$HOME1" --config "$W/c.json" 2>&1)
{ [ "$r1" -eq 0 ] && [ "$r2" -eq 3 ] && printf '%s' "$out" | grep -q 'provider-calls-exhausted'; } \
  && ok "reserve: provider-call cap enforced (2nd blocked)" || no "call cap (r1=$r1 r2=$r2 out=$out)"
# release frees a concurrent slot (with provider budget still available)
"$Q" reset --batch r --home "$HOME1" >/dev/null 2>&1
mkcfg "$W/crel.json" 1 2 '["free/x"]' false
"$Q" reserve --batch r --role executor --home "$HOME1" --config "$W/crel.json" >/dev/null 2>&1
"$Q" reserve --batch r --role auditor --home "$HOME1" --config "$W/crel.json" >/dev/null 2>&1; rblock=$?
"$Q" release --batch r --home "$HOME1" --config "$W/crel.json" >/dev/null 2>&1
"$Q" reserve --batch r --role auditor --home "$HOME1" --config "$W/crel.json" >/dev/null 2>&1; rfree=$?
{ [ "$rblock" -eq 3 ] && [ "$rfree" -eq 0 ]; } \
  && ok "release: frees a concurrent slot" || no "release did not free a slot (block=$rblock free=$rfree)"

# 3. concurrency cap (independent of the call cap)
"$Q" reset --batch c --home "$HOME1" >/dev/null 2>&1
mkcfg "$W/cconc.json" 1 5 '["free/x"]' false
"$Q" reserve --batch c --role executor --home "$HOME1" --config "$W/cconc.json" >/dev/null 2>&1
o=$("$Q" reserve --batch c --role auditor --home "$HOME1" --config "$W/cconc.json" 2>&1); r=$?
{ [ "$r" -eq 3 ] && printf '%s' "$o" | grep -q 'concurrency-exhausted'; } \
  && ok "reserve: concurrency cap enforced" || no "concurrency cap (r=$r out=$o)"

# 4. unknown quota => safe HOLD (exit 4)
printf '{ "quota": { "free_models": ["free/x"] } }\n' > "$W/cunknown.json"
"$Q" reserve --batch u --role executor --home "$HOME1" --config "$W/cunknown.json" >/dev/null 2>&1
[ "$?" -eq 4 ] && ok "reserve: unknown cap => fail-closed HOLD" || no "unknown cap not held"
rm -rf "$W"

# ---- coordinator integration (real path, mock home, no provider) ------------
RMOCK=""
new_realhome() {
  new_home
  RMOCK=$(mktemp -d "${TMPDIR:-/tmp}/uc-qmock.XXXXXX")
  cp -R "$TESTS_DIR/mockhome/." "$RMOCK/"
  chmod +x "$RMOCK"/bin/*.sh
  git -C "$RMOCK" init -q
  git -C "$RMOCK" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  mkdir -p "$RMOCK/project"
  export UC_FM_HOME="$RMOCK" UC_REAL_PROJECT="$RMOCK/project"
  export FM_UNATTENDED_ADAPTER=real UC_REAL_MODEL=free/x UC_QUOTA_ENFORCE=1
}
cleanup_real() { rm -rf "$UC_HOME" "$RMOCK" "$QCFG" 2>/dev/null; unset FM_UNATTENDED_ADAPTER UC_FM_HOME UC_REAL_PROJECT UC_CREW_WAIT_SECS UC_REAL_MODEL UC_QUOTA_ENFORCE UC_CONFIG_FILE; }
qcfg() { QCFG="$UC_HOME/quota.json"; mkcfg "$QCFG" 1 "$1" '["free/x"]' "${2:-false}"; export UC_CONFIG_FILE="$QCFG"; }
mkreal() {
  cat > "$1" <<EOF
{ "batch_id": "b", "baseline_sha": "TESTBASE", "mode": "production",
  "allowed_paths": ["$RMOCK/project"],
  "forbidden_operations": ["github_write","credential_change","home_checkout_change","watcher_runtime_change","real_worker_call","wake_drain","backpass_change","kill_other_session_process","external_write"],
  "retry_limit": 1, "ack_timeout_secs": 3, "tasks": $2 }
EOF
}
TASK1='[{"task_id":"t1","depends_on":[],"approval_required":false,"required_tests":["real-e2e"],"executor":{"command":["true"],"intent":"mission","spec":"spec"},"audit":{"required":true,"intent":"am","spec":"as"}}]'

# 5. provider-call cap blocks the auditor BEFORE a second spawn
new_realhome; qcfg 1; mkreal "$UC_HOME/c.json" "$TASK1"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
UC_CREW_WAIT_SECS=5 run_uc run --batch b >/dev/null
sess=$(ls "$UC_HOME/batches/b/sessions" 2>/dev/null | wc -l | tr -d ' ')
{ [ "$(task_state b t1)" = HOLD ] && [ "$(task_state b t1)" ] && grep -q 'reason=quota-blocked' "$UC_HOME/batches/b/state.jsonl" && [ "$sess" = 1 ]; } \
  && ok "quota cap: auditor blocked before spawn => HOLD quota-blocked (1 crew)" \
  || no "quota integration (state=$(task_state b t1) crews=$sess)"
# 5b. HOLD latch: a later resume dispatches nothing further
d1=$(grep -c 'task_id=t1 .*new=DISPATCHING' "$UC_HOME/batches/b/state.jsonl")
run_uc resume --batch b >/dev/null
d2=$(grep -c 'task_id=t1 .*new=DISPATCHING' "$UC_HOME/batches/b/state.jsonl")
[ "$d1" = "$d2" ] && ok "HOLD latch: no further dispatch after HOLD" || no "latch ($d1->$d2)"
cleanup_real

# 6. sufficient budget => normal VERIFIED_PASS (quota does not over-block)
new_realhome; qcfg 2; mkreal "$UC_HOME/c.json" "$TASK1"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
UC_CREW_WAIT_SECS=5 run_uc run --batch b >/dev/null
[ "$(task_state b t1)" = VERIFIED_PASS ] && ok "quota within budget: VERIFIED_PASS" || no "quota over-block (state=$(task_state b t1))"
cleanup_real

# 7. unapproved paid model blocked before any spawn
new_realhome; qcfg 2 false; export UC_REAL_MODEL=paid/y; mkreal "$UC_HOME/c.json" "$TASK1"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
UC_CREW_WAIT_SECS=5 run_uc run --batch b >/dev/null
sess=$(ls "$UC_HOME/batches/b/sessions" 2>/dev/null | wc -l | tr -d ' ')
{ [ "$(task_state b t1)" = HOLD ] && [ "$sess" = 0 ] && grep -q 'model-not-allowed' "$UC_HOME/batches/b/evidence/runs/t1/gate/quota-block.txt"; } \
  && ok "paid model: blocked before spawn => HOLD, no crew" \
  || no "paid block (state=$(task_state b t1) crews=$sess)"
cleanup_real

# 8. unknown quota => HOLD before spawn
new_realhome
QCFG="$UC_HOME/quota.json"; printf '{ "quota": { "free_models": ["free/x"] } }\n' > "$QCFG"; export UC_CONFIG_FILE="$QCFG"
mkreal "$UC_HOME/c.json" "$TASK1"
run_uc init --batch b --contract "$UC_HOME/c.json" >/dev/null
UC_CREW_WAIT_SECS=5 run_uc run --batch b >/dev/null
sess=$(ls "$UC_HOME/batches/b/sessions" 2>/dev/null | wc -l | tr -d ' ')
{ [ "$(task_state b t1)" = HOLD ] && [ "$sess" = 0 ]; } \
  && ok "unknown quota: fail-closed HOLD before spawn" || no "unknown quota (state=$(task_state b t1) crews=$sess)"
cleanup_real

echo "# quota.test.sh PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
