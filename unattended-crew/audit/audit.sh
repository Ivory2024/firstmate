#!/usr/bin/env bash
# audit.sh - INDEPENDENT-PROCESS audit of the unattended-crew evidence.
#
# This is a separate process that does NOT trust the coordinator or its report:
# it recomputes the evidence artifact hashes, re-runs every suite from scratch in
# a fresh home, and compares pass counts. It is explicitly NOT a real AI/worker
# audit; auditor_kind is `independent_process` and real_ai_audit is false.
#
# Usage: audit.sh [UC_ROOT]
set -u
UC_ROOT=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
EVID="$UC_ROOT/evidence"
OUT="$UC_ROOT/audit"
mkdir -p "$OUT"
ISSUES=0

# 1. artifact manifest identity: recompute every recorded sha256
manifest_ok=true
while IFS= read -r line; do
  p=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["path"])' "$line" 2>/dev/null || echo "")
  h=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["sha256"])' "$line" 2>/dev/null || echo "")
  [ -n "$p" ] || continue
  cur=$(shasum -a 256 "$UC_ROOT/$p" 2>/dev/null | awk '{print $1}')
  [ "$cur" = "$h" ] || { manifest_ok=false; echo "MANIFEST MISMATCH: $p"; ISSUES=$((ISSUES+1)); }
done < "$EVID/artifact-manifest.json"

# 2. recorded suite exit codes must all be zero
log_ok=true
while IFS= read -r line; do
  rc=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["exit"])' "$line" 2>/dev/null || echo "?")
  [ "$rc" = "0" ] || { log_ok=false; echo "NONZERO RECORDED EXIT: $line"; ISSUES=$((ISSUES+1)); }
done < "$EVID/command-log.jsonl"

# 3. independent re-run from scratch in a fresh home
TMP=$(mktemp -d "${TMPDIR:-/tmp}/uc-audit.XXXXXX")
before=$(grep -h '^# ' "$EVID"/test-results/*.out 2>/dev/null | grep -c 'FAIL=0')
UC_EVIDENCE_DIR="$TMP/evidence" FM_UNATTENDED_ADAPTER=fake bash "$UC_ROOT/tests/run-all.sh" > "$TMP/rerun.out" 2>&1
rerun_rc=$?
after=$(grep -h '^# ' "$TMP/evidence"/test-results/*.out 2>/dev/null | grep -c 'FAIL=0')
rerun_cases=$(grep -ho 'PASS=[0-9]*' "$TMP/evidence"/test-results/*.out 2>/dev/null | sed 's/PASS=//' | paste -sd+ - | bc 2>/dev/null || echo 0)
orig_cases=$(grep -ho 'PASS=[0-9]*' "$EVID"/test-results/*.out 2>/dev/null | sed 's/PASS=//' | paste -sd+ - | bc 2>/dev/null || echo 0)

verdict=PASS
[ "$manifest_ok" = true ] || verdict=CONFLICT
[ "$log_ok" = true ] || verdict=CONFLICT
{ [ "$rerun_rc" -eq 0 ] && [ "$after" = "$before" ] && [ "$rerun_cases" = "$orig_cases" ]; } || verdict=CONFLICT

python3 - "$OUT/audit-status.json" "$verdict" "$manifest_ok" "$log_ok" "$before" "$after" "$orig_cases" "$rerun_cases" <<'PY'
import json,sys
out,verdict,mok,lok,before,after,oc,rc=sys.argv[1:9]
json.dump({
  "auditor_kind": "independent_process",
  "real_ai_audit": False,
  "note": "separate process; recomputed manifest hashes and re-ran all suites. NOT a real Codex/Claude audit.",
  "verdict": verdict,
  "manifest_identity_ok": mok=="true",
  "recorded_exits_ok": lok=="true",
  "suites_fail0_before": int(before), "suites_fail0_after": int(after),
  "cases_before": int(oc or 0), "cases_after": int(rc or 0)
}, open(out,"w"), indent=2)
print("audit verdict:", verdict)
PY

{
  echo "# Independent-process audit findings"
  echo
  echo "Auditor: separate OS process (NOT a real AI audit)."
  echo "Verdict: **$verdict**"
  echo
  echo "## Checks"
  echo "- artifact manifest sha256 recomputed: $manifest_ok"
  echo "- recorded suite exit codes all zero: $log_ok"
  echo "- suites with FAIL=0 before/after: $before/$after"
  echo "- total cases before/after: $orig_cases/$rerun_cases"
  echo "- re-run exit: $rerun_rc"
  echo
  echo "## Limitation"
  echo "This proves determinism and evidence integrity in a separate process. It is"
  echo "**not** an independent AI/worker audit; the final audit status is"
  echo "AUDIT_UNAVAILABLE until a real out-of-session auditor runs."
} > "$OUT/findings.md"

rm -rf "$TMP"
[ "$verdict" = PASS ]
