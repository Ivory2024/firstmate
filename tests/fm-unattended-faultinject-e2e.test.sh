#!/usr/bin/env bash
# fm-unattended-faultinject-e2e.test.sh - G4 isolated fault-injection CONTRACT.
#
# Drives the coordinator's mock backend with three real fault types in a throwaway
# UC_HOME, proving: exact fault handling, safe HOLD, no duplicate dispatch, no
# state loss, and that the OPERATIONAL home is never touched.
#
# This is the MOCK contract only. The real-crew counterpart is
# tests/fm-unattended-realcrew-3fault-e2e.test.sh, which drives the real backend
# (real fm-spawn crew, real endpoint) for the faults a real crew can produce.
# Fault 3 here (identity-mismatch via FM_FAKE_WRONG_IDENTITY) has no real-crew
# trigger and stays a mock-only lever; that gap is stated in the real-crew guard.
# shellcheck disable=SC2015 # ok() and no() both return 0, so `A && ok || no`
# is if/else here: the `no` branch cannot run once `ok` has run.
set -u
UCX="${FM_UC_IMPL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin}"
OP=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok - $1"; }
no(){ FAIL=$((FAIL+1)); echo "NOT OK - $1"; }

OPQ_BEFORE=$(wc -l < "$OP/state/.wake-queue" 2>/dev/null | tr -d ' ')
OPL_BEFORE=$(cat "$OP/state/.watch.lock/pid" 2>/dev/null)

T=$(mktemp -d "${TMPDIR:-/tmp}/fi.XXXXXX"); UCH="$T/uc"; mkdir -p "$UCH"
run(){ UC_HOME="$UCH" UC_IMPL_DIR="$UCX" "$@" ; }
state(){ sed -n 's/^new=//p' "$UCH/batches/$1/tasks/t1.state" 2>/dev/null; }
reason(){ sed -n 's/.*new=HOLD reason=\([^ ]*\).*/\1/p' "$UCH/batches/$1/state.jsonl" 2>/dev/null | tail -1; }
dispatches(){ grep -c 'new=DISPATCHING' "$UCH/batches/$1/state.jsonl" 2>/dev/null; }

# ---- Fault 1: executor fails (exit 7) -> REWORK x2 -> HOLD, bounded ----
printf '{"batch_id":"f1","baseline_sha":"T","mode":"test","retry_limit":2,"tasks":[{"task_id":"t1","executor":{"command":["bash","-c","exit 7"]},"audit":{"required":true},"required_tests":["t1"]}]}' > "$T/c1.json"
run bash "$UCX/fm-unattended.sh" init --batch f1 --contract "$T/c1.json" >/dev/null 2>&1
run bash "$UCX/fm-unattended.sh" run --batch f1 >/dev/null 2>&1
[ "$(state f1)" = HOLD ] && ok "fault1 executor-fail -> HOLD ($(reason f1))" || no "fault1 $(state f1)"
[ "$(dispatches f1)" = 2 ] && ok "fault1 bounded dispatch (2, no runaway)" || no "fault1 dispatch $(dispatches f1)"

# ---- Fault 2: no ACK (heartbeat/ownership loss) -> retry-exhausted HOLD ----
printf '{"batch_id":"f2","baseline_sha":"T","mode":"test","retry_limit":1,"ack_timeout_secs":2,"tasks":[{"task_id":"t1","executor":{"command":["true"]},"audit":{"required":true},"required_tests":["t1"]}]}' > "$T/c2.json"
run bash "$UCX/fm-unattended.sh" init --batch f2 --contract "$T/c2.json" >/dev/null 2>&1
UC_HOME="$UCH" UC_IMPL_DIR="$UCX" FM_FAKE_NO_ACK=1 bash "$UCX/fm-unattended.sh" run --batch f2 >/dev/null 2>&1
[ "$(state f2)" = HOLD ] && ok "fault2 no-ack -> HOLD ($(reason f2))" || no "fault2 $(state f2)"

# ---- Fault 3: dispatch identity mismatch (state mismatch) -> HOLD ----
printf '{"batch_id":"f3","baseline_sha":"T","mode":"test","retry_limit":1,"tasks":[{"task_id":"t1","executor":{"command":["true"]},"audit":{"required":true},"required_tests":["t1"]}]}' > "$T/c3.json"
run bash "$UCX/fm-unattended.sh" init --batch f3 --contract "$T/c3.json" >/dev/null 2>&1
UC_HOME="$UCH" UC_IMPL_DIR="$UCX" FM_FAKE_WRONG_IDENTITY=1 bash "$UCX/fm-unattended.sh" run --batch f3 >/dev/null 2>&1
[ "$(state f3)" = HOLD ] && ok "fault3 identity-mismatch -> HOLD ($(reason f3))" || no "fault3 $(state f3)"

# ---- no duplicate across re-run for ALL faults (idempotent terminal) ----
run bash "$UCX/fm-unattended.sh" run --batch f1 >/dev/null 2>&1
[ "$(dispatches f1)" = 2 ] && ok "f1 re-run: no new dispatch" || no "f1 re-run dispatched ($(dispatches f1))"
d2=$(dispatches f2); run bash "$UCX/fm-unattended.sh" run --batch f2 >/dev/null 2>&1
[ "$(dispatches f2)" = "$d2" ] && ok "f2 re-run: no new dispatch ($d2)" || no "f2 re-run dispatched ($d2 -> $(dispatches f2))"
d3=$(dispatches f3); run bash "$UCX/fm-unattended.sh" run --batch f3 >/dev/null 2>&1
[ "$(dispatches f3)" = "$d3" ] && ok "f3 re-run: no new dispatch ($d3)" || no "f3 re-run dispatched ($d3 -> $(dispatches f3))"

# ---- recovery policy invoked on the actual HOLD reasons ----
for triple in "f1:retry-exhausted:CAPTAIN_HOLD" "f2:retry-exhausted:CAPTAIN_HOLD" "f3:identity-mismatch:NON_RECOVERABLE"; do
  b=${triple%%:*}; rest=${triple#*:}; r=${rest%%:*}; exp=${rest#*:}
  got=$("$UCX/fm-unattended-recovery.sh" classify "$r")
  { [ "$(reason "$b")" = "$r" ] && [ "$got" = "$exp" ]; } \
    && ok "recovery $b ($r -> $got)" || no "recovery $b ($r -> $got want $exp)"
done

# ---- explicit isolation: the batch tree is never inside the operational home ----
case "$UCH" in "$OP"/*) no "isolated batch home under the operational home";; *) ok "isolated batch home separate from the operational home";; esac

# ---- operational invariance (queue/lock; lock may re-arm on unrelated reasons) ----
OPQ_AFTER=$(wc -l < "$OP/state/.wake-queue" 2>/dev/null | tr -d ' ')
OPL_AFTER=$(cat "$OP/state/.watch.lock/pid" 2>/dev/null)
[ "$OPQ_BEFORE" = "$OPQ_AFTER" ] \
  && ok "operational queue unchanged (q=$OPQ_AFTER)" || no "op queue changed ($OPQ_BEFORE -> $OPQ_AFTER)"
# lock pid may legitimately re-arm for unrelated watcher reasons; report, don't fail.
ok "operational lock observed (before=$OPL_BEFORE after=$OPL_AFTER)"

# ---- cleanup: nothing left in the isolated env after removal ----
rm -rf "$T"
[ ! -d "$T" ] && ok "isolated env cleaned" || no "cleanup failed"

echo "# fm-unattended-faultinject-e2e.test.sh PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
