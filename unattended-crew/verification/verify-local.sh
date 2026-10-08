#!/usr/bin/env bash
# verify-local.sh - a SEPARATE local verification process for the real-E2E
# integration. It re-runs the full suite in a fresh environment, re-derives the
# suite tallies from the raw output, independently exercises the deterministic
# judge floor and the production fake-auditor block, and confirms the real path
# routes only through bin/fm-spawn.sh. It runs NO provider call and starts NO
# AI audit session, so a green result is a LOCAL check only and is never
# reported as an independent AI audit.
#
# Usage: verify-local.sh [out-dir]
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UC_ROOT=$(cd "$HERE/.." && pwd)
OUT=${1:-$UC_ROOT/verification}
mkdir -p "$OUT"
EVID="$OUT/verify-evidence"

pass=0; fail=0
ck() { # <label> <0|1>
  if [ "$2" = 0 ]; then pass=$((pass+1)); printf 'ok   %s\n' "$1"; else fail=$((fail+1)); printf 'FAIL %s\n' "$1"; fi
}

# 1. full suite, fresh evidence dir
UC_EVIDENCE_DIR="$EVID" bash "$UC_ROOT/tests/run-all.sh" > "$OUT/run-all.out" 2>&1; run_rc=$?
ck "full suite exit 0" "$run_rc"
total_p=0; total_f=0
for s in coordinator judge guard restart real-e2e; do
  line=$(grep -E "^# $s.test.sh PASS=" "$EVID/test-results/$s.out" 2>/dev/null | tail -1)
  p=$(printf '%s' "$line" | sed -n 's/.*PASS=\([0-9]*\).*/\1/p')
  f=$(printf '%s' "$line" | sed -n 's/.*FAIL=\([0-9]*\).*/\1/p')
  total_p=$((total_p + ${p:-0})); total_f=$((total_f + ${f:-0}))
  ck "suite $s has 0 failures" "$([ "${f:-1}" = 0 ] && echo 0 || echo 1)"
done
printf 'tally: %s passed, %s failed\n' "$total_p" "$total_f"

# 2. deterministic judge floor: tamper must flip a clean run to HOLD
W=$(mktemp -d "${TMPDIR:-/tmp}/uc-verify.XXXXXX")
ER="$UC_ROOT/implementation/fm-unattended-evidence.sh"; JD="$UC_ROOT/implementation/fm-unattended-judge.sh"
mkdir -p "$W/runs/case/auditor" "$W/runs/case/gate"
printf '{"mode":"production","required_tests":["x"]}\n' > "$W/runs/case/task-contract.json"
EVIDENCE_ROOT="$W" "$ER" run case -- true >/dev/null 2>&1
printf '/tmp/exec-ws\n' > "$W/runs/case/executor/wd"
printf '{"session_id":"a","workdir":"/tmp/aud-ws","auditor_kind":"real"}\n' > "$W/runs/case/auditor/session.json"
printf '{"verdict":"PASS","auditor_kind":"real"}\n' > "$W/runs/case/auditor/findings.json"
v1=$(EVIDENCE_ROOT="$W" "$JD" run case 2>/dev/null | sed 's/^VERDICT=//;s/ .*//')
echo tamper >> "$W/runs/case/executor/stdout/cmd.out"
v2=$(EVIDENCE_ROOT="$W" "$JD" run case 2>/dev/null | sed 's/^VERDICT=//;s/ .*//')
[ "$v1" = VERIFIED_PASS ] && ck "clean production audit => VERIFIED_PASS" 0 || ck "clean production audit (got $v1)" 1
[ "$v2" = HOLD ] && ck "tampered evidence => HOLD" 0 || ck "tampered evidence (got $v2)" 1
rm -rf "$W"

# 3. production fake auditor is refused on both backends
T=$(mktemp -d "${TMPDIR:-/tmp}/uc-verify.XXXXXX")
cat > "$T/c.json" <<EOF
{ "batch_id":"b","baseline_sha":"T","mode":"production","forbidden_operations":["github_write","real_worker_call"],
  "retry_limit":1,"ack_timeout_secs":2,"tasks":[{"task_id":"t1","executor":{"command":["true"]},"required_tests":["x"],"audit":{"required":true}}] }
EOF
UC_HOME="$T/uc" FM_UNATTENDED_ADAPTER=fake bash "$UC_ROOT/implementation/fm-unattended.sh" init --batch b --contract "$T/c.json" >/dev/null
UC_HOME="$T/uc" FM_UNATTENDED_ADAPTER=fake bash "$UC_ROOT/implementation/fm-unattended.sh" run --batch b >/dev/null
st=$(sed -n 's/^new=//p' "$T/uc/batches/b/tasks/t1.state" 2>/dev/null)
[ "$st" = HOLD ] && ck "production + fake backend (no real audit) => HOLD" 0 || ck "production fake-backend guard (got $st)" 1
rm -rf "$T"

# 4. the real path routes through the existing firstmate primitives only
if grep -q 'fm-spawn.sh' "$UC_ROOT/implementation/fm-unattended-adapter.sh" \
   && grep -q 'fm-crew-state.sh' "$UC_ROOT/implementation/fm-unattended-adapter.sh" \
   && grep -q 'fm-send.sh' "$UC_ROOT/implementation/fm-unattended-adapter.sh"; then
  ck "real adapter reuses fm-spawn/fm-crew-state/fm-send" 0
else
  ck "real adapter primitive reuse" 1
fi
# and no new framework: no direct provider CLI invocation anywhere in implementation/
if grep -rEn 'claude |codex |opencode |gemini |agy ' "$UC_ROOT/implementation"/*.sh >/dev/null 2>&1; then
  ck "implementation calls no provider CLI directly" 1
else
  ck "implementation calls no provider CLI directly" 0
fi

printf 'local verification: %s ok, %s fail\n' "$pass" "$fail"
printf '{"check":"local-independent-verify","ok":%s,"fail":%s,"total":%s,"at":"%s","independent_ai_audit":false}\n' \
  "$pass" "$fail" "$((pass+fail))" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OUT/local-check.json"
cat "$OUT/local-check.json"
[ "$fail" -eq 0 ]
