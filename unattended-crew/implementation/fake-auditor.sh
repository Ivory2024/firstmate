#!/usr/bin/env bash
# fake-auditor.sh - the AUDIT ADAPTER's default implementation for mode=test.
#
# It proves the audit lifecycle and recomputes the executor's raw evidence in a
# SEPARATE process and a SEPARATE working directory. It is explicitly NOT a
# real AI/worker audit: it is marked auditor_kind=fake, and the judge refuses
# VERIFIED_PASS for a fake auditor outside mode=test. Replacing this with a real
# out-of-session auditor is the unapproved integration step
# (handoff/integration-plan.md).
#
# Usage: fake-auditor.sh <executor-run-dir>
# Env overrides for failure injection:
#   FM_FAKE_AUDIT_VERDICT=CONFLICT|UNAVAILABLE  force a non-PASS verdict
#   FM_FAKE_AUDIT_NONE=1                        write NO findings (audit missing)
set -u
run_dir=${1:?usage: fake-auditor.sh <executor-run-dir>}
d="$run_dir"
mkdir -p "$d/auditor"

# the auditor runs in its OWN workspace regardless of where it was called
aw=$(mktemp -d)
cd "$aw" || exit 1
printf '{"session_id":"%s","role":"auditor","identity":"%s","workdir":"%s","auditor_kind":"fake"}\n' \
  "auditor-$$" "auditor-$$" "$aw" > "$d/auditor/session.json"

echo "DISPATCH"
sleep 0.05
echo "ACK"
echo "ACTIVE"

verdict="PASS"; note="independent recompute of raw evidence; protocol fake, not a real audit"
if [ "${FM_FAKE_AUDIT_NONE:-0}" = 1 ]; then
  echo "NO_FINDINGS"; echo "ARTIFACT_MISSING"; exit 0
fi

rc=$(cat "$d/executor/rc" 2>/dev/null || echo MISSING)
if [ "$rc" != "0" ]; then verdict="CONFLICT"; note="executor exit code $rc"; fi

# independently recompute every artifact hash recorded in the manifest
if [ -f "$d/executor/artifact-manifest.json" ]; then
  while IFS= read -r line; do
    p=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["path"])' "$line" 2>/dev/null || echo "")
    h=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["sha256"])' "$line" 2>/dev/null || echo "")
    [ -n "$p" ] || continue
    cur=$(shasum -a 256 "$d/$p" 2>/dev/null | awk '{print $1}')
    if [ -n "$cur" ] && [ "$cur" != "$h" ]; then verdict="CONFLICT"; note="artifact hash mismatch: $p"; fi
  done < "$d/executor/artifact-manifest.json"
fi

[ -n "${FM_FAKE_AUDIT_VERDICT:-}" ] && { verdict="$FM_FAKE_AUDIT_VERDICT"; note="forced by FM_FAKE_AUDIT_VERDICT"; }

echo "COMPLETE"
printf '{"verdict":"%s","auditor_kind":"fake","recomputed":true,"note":"%s"}\n' "$verdict" "$note" > "$d/auditor/findings.json"
echo "ARTIFACT_RECEIVED"
