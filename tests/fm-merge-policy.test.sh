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
eq "workflow -> HIGH"       "$($P classify-risk .github/workflows/ci.yml)" HIGH
eq "credential -> HIGH"     "$($P classify-risk config/credentials.json)" HIGH
eq "unknown path -> HIGH"   "$($P classify-risk weird/thing.xyz)" HIGH
eq "mixed docs+bin -> HIGH" "$($P classify-risk docs/a.md bin/fm-spawn.sh)" HIGH

# --- merge eligibility (fail-closed) ---
eq "LOW all-pass+scope -> eligible" "$($P merge-eligible --risk LOW --ci pass --review pass --head-match yes --protected no --unresolved no --scope low)" MERGE_ELIGIBLE
eq "MEDIUM+med scope -> eligible"   "$($P merge-eligible --risk MEDIUM --ci pass --review pass --head-match yes --protected no --unresolved no --scope med)" MERGE_ELIGIBLE
AR=$(mktemp); printf 'signer=captain\npr=115\nhead=abc\nscope=high\nat=2026-10-10\n' > "$AR"
eq "HIGH+high scope+approval+record -> eligible" "$($P merge-eligible --risk HIGH --ci pass --review pass --head-match yes --protected no --unresolved no --scope high --approved-pr 115 --approved-sha abc --head-sha abc --approval-record "$AR")" MERGE_ELIGIBLE
eq "protected HIGH+captain approval -> eligible" "$($P merge-eligible --risk HIGH --ci pass --review pass --head-match yes --protected yes --unresolved no --scope high --approved-pr 115 --approved-sha abc --head-sha abc --approval-record "$AR")" MERGE_ELIGIBLE
eq "HIGH no record -> HOLD" "$($P merge-eligible --risk HIGH --ci pass --review pass --head-match yes --protected no --unresolved no --scope high --approved-pr 115 --approved-sha abc --head-sha abc)" "MERGE_HOLD reason=no-approval-record"
FA=$(mktemp); printf 'signer=auto\npr=115\nhead=abc\n' > "$FA"
eq "HIGH forged record (non-captain) -> HOLD" "$($P merge-eligible --risk HIGH --ci pass --review pass --head-match yes --protected no --unresolved no --scope high --approved-pr 115 --approved-sha abc --head-sha abc --approval-record "$FA")" "MERGE_HOLD reason=approval-not-captain"
WR=$(mktemp); printf 'signer=captain\npr=999\nhead=abc\n' > "$WR"
eq "HIGH wrong-pr record -> HOLD" "$($P merge-eligible --risk HIGH --ci pass --review pass --head-match yes --protected no --unresolved no --scope high --approved-pr 115 --approved-sha abc --head-sha abc --approval-record "$WR")" "MERGE_HOLD reason=approval-pr-mismatch"
PREFIX_SIGNER=$(mktemp); printf 'signer=captainx\npr=115\nhead=abc\n' > "$PREFIX_SIGNER"
eq "HIGH signer prefix spoof -> HOLD" "$($P merge-eligible --risk HIGH --ci pass --review pass --head-match yes --protected no --unresolved no --scope high --approved-pr 115 --approved-sha abc --head-sha abc --approval-record "$PREFIX_SIGNER")" "MERGE_HOLD reason=approval-not-captain"
PREFIX_PR=$(mktemp); printf 'signer=captain\npr=1156\nhead=abc\n' > "$PREFIX_PR"
eq "HIGH PR prefix spoof -> HOLD" "$($P merge-eligible --risk HIGH --ci pass --review pass --head-match yes --protected no --unresolved no --scope high --approved-pr 115 --approved-sha abc --head-sha abc --approval-record "$PREFIX_PR")" "MERGE_HOLD reason=approval-pr-mismatch"
PREFIX_HEAD=$(mktemp); printf 'signer=captain\npr=115\nhead=abcdef\n' > "$PREFIX_HEAD"
eq "HIGH head prefix spoof -> HOLD" "$($P merge-eligible --risk HIGH --ci pass --review pass --head-match yes --protected no --unresolved no --scope high --approved-pr 115 --approved-sha abc --head-sha abc --approval-record "$PREFIX_HEAD")" "MERGE_HOLD reason=approval-head-mismatch"
rm -f "$AR" "$FA" "$WR" "$PREFIX_SIGNER" "$PREFIX_PR" "$PREFIX_HEAD"
eq "HIGH high-scope no approval-pr -> HOLD" "$($P merge-eligible --risk HIGH --ci pass --review pass --head-match yes --protected no --unresolved no --scope high)" "MERGE_HOLD reason=high-scope-needs-approval-pr"
eq "HIGH approval sha mismatch -> HOLD" "$($P merge-eligible --risk HIGH --ci pass --review pass --head-match yes --protected no --unresolved no --scope high --approved-pr 115 --approved-sha abc --head-sha def)" "MERGE_HOLD reason=high-scope-sha-mismatch"
eq "core-control path -> HIGH" "$($P classify-risk bin/fm-crew-state.sh)" HIGH
eq "classify-lib path -> HIGH" "$($P classify-risk bin/fm-classify-lib.sh)" HIGH
eq "HIGH no scope -> HOLD"          "$($P merge-eligible --risk HIGH --ci pass --review pass --head-match yes --protected no --unresolved no --scope none)" "MERGE_HOLD reason=high-needs-explicit-scope"
eq "MEDIUM low scope -> HOLD"       "$($P merge-eligible --risk MEDIUM --ci pass --review pass --head-match yes --protected no --unresolved no --scope low)" "MERGE_HOLD reason=scope-med-required"
eq "CI fail -> HOLD"                "$($P merge-eligible --risk LOW --ci fail --review pass --head-match yes --protected no --unresolved no --scope low)" "MERGE_HOLD reason=ci-not-pass"
eq "no review -> HOLD"              "$($P merge-eligible --risk LOW --ci pass --review fail --head-match yes --protected no --unresolved no --scope low)" "MERGE_HOLD reason=no-independent-review"
eq "head changed -> HOLD"           "$($P merge-eligible --risk LOW --ci pass --review pass --head-match no --protected no --unresolved no --scope low)" "MERGE_HOLD reason=head-changed"
eq "protected without high approval -> HOLD" "$($P merge-eligible --risk LOW --ci pass --review pass --head-match yes --protected yes --unresolved no --scope low)" "MERGE_HOLD reason=protected-path"
eq "unresolved -> HOLD"             "$($P merge-eligible --risk LOW --ci pass --review pass --head-match yes --protected no --unresolved yes --scope low)" "MERGE_HOLD reason=unresolved-findings"
eq "unknown risk -> HOLD"           "$($P merge-eligible --risk UNKNOWN --ci pass --review pass --head-match yes --protected no --unresolved no --scope none)" "MERGE_HOLD reason=unknown-risk"

# --- review routing (free-first, escalate HIGH) ---
eq "LOW -> free reviewer"    "$($P review-route --risk LOW | sed -n 's/.*tier=\([a-z0-9-]*\).*/\1/p')" free
eq "MEDIUM -> free cross"    "$($P review-route --risk MEDIUM | sed -n 's/.*tier=\([a-z0-9-]*\).*/\1/p')" free-x2
eq "HIGH -> escalated"       "$($P review-route --risk HIGH | sed -n 's/.*tier=\([a-z0-9-]*\).*/\1/p')" high-capability
eq "unknown risk -> HOLD"    "$($P review-route --risk UNKNOWN | sed -n 's/.*action=\([A-Z]*\).*/\1/p')" HOLD
# --- independence gate (fail-closed) ---
eq "same model -> HOLD"      "$($P independent-ok opencode/x opencode/x | sed -n 's/^\([A-Z_]*\).*/\1/p')" REVIEW_INDEPENDENCE_HOLD
eq "different model -> ok"   "$($P independent-ok opencode/x codex/y)" INDEPENDENT_OK
eq "missing model -> HOLD"   "$($P independent-ok '' codex/y | sed -n 's/^\([A-Z_]*\).*/\1/p')" REVIEW_INDEPENDENCE_HOLD

echo "# fm-merge-policy.test.sh PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
