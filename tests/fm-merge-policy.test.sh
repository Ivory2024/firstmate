#!/usr/bin/env bash
# fm-merge-policy.test.sh - risk classification + fail-closed merge eligibility.
set -u
P="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/fm-merge-policy.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok - $1"; }
no(){ FAIL=$((FAIL+1)); echo "NOT OK - $1"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }

# --- risk classification ---
eq "docs -> LOW"            "$($P classify-risk docs/operations/x.md)" LOW
eq "test -> LOW"            "$($P classify-risk tests/foo.test.sh)" LOW
eq "pipeline py -> MEDIUM"  "$($P classify-risk pipelines/notion-address-filler/run.py)" MEDIUM
eq "automation py -> MEDIUM" "$($P classify-risk AutomationSync/governance_autofix_route.py)" MEDIUM
eq "watcher -> HIGH"        "$($P classify-risk bin/fm-watch.sh)" HIGH
eq "PR merge -> HIGH"       "$($P classify-risk bin/fm-pr-merge.sh)" HIGH
eq "local merge -> HIGH"    "$($P classify-risk bin/fm-merge-local.sh)" HIGH
eq "workflow -> HIGH"       "$($P classify-risk .github/workflows/ci.yml)" HIGH
eq "credential -> HIGH"     "$($P classify-risk config/credentials.json)" HIGH
eq "credential markdown -> HIGH" "$($P classify-risk config/credentials.md)" HIGH
eq "secret markdown -> HIGH" "$($P classify-risk docs/secrets.md)" HIGH
eq "unknown path -> HIGH"   "$($P classify-risk weird/thing.xyz)" HIGH
eq "missing path detection -> HIGH" "$($P classify-risk)" HIGH
eq "mixed docs+bin -> HIGH" "$($P classify-risk docs/a.md bin/fm-spawn.sh)" HIGH

# --- merge eligibility fails closed until forge evidence is available ---
eq "forged passing flags -> HOLD" "$($P merge-eligible --risk LOW --ci pass --review pass --head-match yes --protected no --unresolved no --scope low)" "MERGE_HOLD reason=verified-evidence-required"
eq "caller approval record -> HOLD" "$($P merge-eligible --risk HIGH --ci pass --review pass --head-match yes --protected yes --unresolved no --scope high --approved-pr 115 --approved-sha abc --head-sha abc --approval-record /dev/null)" "MERGE_HOLD reason=verified-evidence-required"

if "$P" review-route --risk LOW >/dev/null 2>&1; then no "review-route command is unavailable"; else ok "review-route command is unavailable"; fi
# --- independence requires provenance, not caller model names ---
eq "caller model names -> HOLD" "$($P independent-ok opencode/x codex/y)" "REVIEW_INDEPENDENCE_HOLD reason=verified-review-provenance-required"

echo "# fm-merge-policy.test.sh PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
