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

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
EVIDENCE="$ROOT/bin/fm-merge-evidence.sh"
TMP=$(mktemp -d "$ROOT/.fm-merge-evidence-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/state" "$TMP/fakebin"
TASK=merge-evidence-test
PR=https://github.com/example/repo/pull/9
HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cat > "$TMP/pr.json" <<JSON
{"author":{"login":"author"},"headRefOid":"$HEAD","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"files":[{"path":"docs/operations.md"}]}
JSON
cat > "$TMP/reviews.json" <<JSON
[{"state":"APPROVED","user":{"login":"reviewer"},"commit_id":"$HEAD"}]
JSON
cat > "$TMP/protection.json" <<'JSON'
{"required_status_checks":{},"required_pull_request_reviews":{}}
JSON
printf '%s\n' '[]' > "$TMP/rulesets.json"
cat > "$TMP/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "pr view") cat "$FM_TEST_PR_JSON" ;;
  "api --paginate")
    case "$*" in *pulls/9/reviews*) cat "$FM_TEST_REVIEWS_JSON";; *) exit 2;; esac
    ;;
  "api repos/"*)
    case "$*" in
      *branches/*/protection*) [ "${FM_TEST_FAIL_PROTECTION:-}" != yes ] || exit 1; cat "$FM_TEST_PROTECTION_JSON";;
      *rulesets*) cat "$FM_TEST_RULESETS_JSON";;
      *) exit 2;;
    esac
    ;;
esac
SH
cat > "$TMP/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${FM_TEST_FAIL_STATUS:-}" != yes ] || exit 1
cat "$FM_TEST_STATUS"
SH
chmod +x "$TMP/fakebin/gh" "$TMP/fakebin/no-mistakes" "$EVIDENCE"
cat > "$TMP/status" <<JSON
run:
  id: test-run-id
  status: completed
  head_sha: $HEAD
  pr: "$PR"
  findings: 0 awaiting
  steps[1]{step,status,findings,duration_ms}:
    test,completed,0,1
outcome: passed
JSON
printf '%s\n' 'done: validated' > "$TMP/home/state/$TASK.status"
evidence_env=(PATH="$TMP/fakebin:$PATH" FM_HOME="$TMP/home" FM_STATE_OVERRIDE="$TMP/home/state" \
  FM_TEST_PR_JSON="$TMP/pr.json" FM_TEST_REVIEWS_JSON="$TMP/reviews.json" \
  FM_TEST_PROTECTION_JSON="$TMP/protection.json" FM_TEST_RULESETS_JSON="$TMP/rulesets.json" \
  FM_TEST_STATUS="$TMP/status")
out=$(env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "verified producer accepts matching forge evidence" "$(printf '%s' "$out" | jq -r .status)" PASS
out=$(env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
eq "verified producer holds stale SHA" "$(printf '%s' "$out" | jq -r .reasons[0])" stale-head
out=$(env "${evidence_env[@]}" FM_TEST_FAIL_PROTECTION=yes "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "verified producer holds forge API failure" "$(printf '%s' "$out" | jq -r .reasons[0])" branch-protection-unreadable
out=$(env "${evidence_env[@]}" FM_TEST_FAIL_STATUS=yes "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "verified producer holds missing test evidence" "$(printf '%s' "$out" | jq -r .reasons[0])" test-evidence-missing-or-stale
cat > "$TMP/home/state/$TASK.test-evidence" <<JSON
{"command":"focused test","exit":0,"sha":"$HEAD","verdict":"PASS"}
JSON
chmod 600 "$TMP/home/state/$TASK.test-evidence"
out=$(env "${evidence_env[@]}" FM_TEST_FAIL_STATUS=yes "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "producer accepts matching recorded test evidence" "$(printf '%s' "$out" | jq -r .status)" PASS
sed "s/$HEAD/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/" "$TMP/home/state/$TASK.test-evidence" > "$TMP/stale-test-evidence"
chmod 600 "$TMP/stale-test-evidence"
cp "$TMP/stale-test-evidence" "$TMP/home/state/$TASK.test-evidence"
chmod 600 "$TMP/home/state/$TASK.test-evidence"
out=$(env "${evidence_env[@]}" FM_TEST_FAIL_STATUS=yes "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "producer rejects stale recorded test evidence" "$(printf '%s' "$out" | jq -r .reasons[0])" test-evidence-missing-or-stale
if env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD" --ci pass >/dev/null 2>&1; then no "producer accepted caller evidence flags"; else ok "producer rejects caller evidence flags"; fi

GL_PR=https://gitlab.example/group/subgroup/project/-/merge_requests/7
cat > "$TMP/gl-pr.json" <<JSON
{"author":{"username":"author"},"sha":"$HEAD","target_branch":"main","head_pipeline":{"sha":"$HEAD","status":"success"}}
JSON
cat > "$TMP/gl-approvals.json" <<'JSON'
{"approved_by":[{"user":{"username":"reviewer"}}]}
JSON
cat > "$TMP/gl-review.json" <<JSON
{"reviewer":"reviewer","model":"codex-independent","implementer_model":"claude-implementer","reviewed_sha":"$HEAD","verdict":"APPROVED"}
JSON
cat > "$TMP/gl-protected.json" <<'JSON'
[{"name":"main"}]
JSON
cat > "$TMP/gl-changes.json" <<'JSON'
{"changes":[{"new_path":"docs/operations.md"}]}
JSON
cat > "$TMP/fakebin/glab" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "mr view") cat "$FM_TEST_GL_PR_JSON" ;;
  "api projects/"*)
    case "$*" in
      *protected_branches*) cat "$FM_TEST_GL_PROTECTED_JSON";;
      *approvals*) cat "$FM_TEST_GL_APPROVALS_JSON";;
      *changes*) cat "$FM_TEST_GL_CHANGES_JSON";;
      *) exit 2;;
    esac
    ;;
esac
SH
chmod +x "$TMP/fakebin/glab"
cp "$TMP/status" "$TMP/gl-status"
sed "s#$PR#$GL_PR#" "$TMP/status" > "$TMP/gl-status"
printf '%s\n' 'done: validated' > "$TMP/home/state/$TASK.status"
chmod 600 "$TMP/gl-review.json"
cp "$TMP/gl-review.json" "$TMP/home/state/$TASK.review-evidence"
gl_env=(PATH="$TMP/fakebin:$PATH" FM_HOME="$TMP/home" FM_STATE_OVERRIDE="$TMP/home/state" \
  FM_TEST_GL_PR_JSON="$TMP/gl-pr.json" FM_TEST_GL_APPROVALS_JSON="$TMP/gl-approvals.json" \
  FM_TEST_GL_PROTECTED_JSON="$TMP/gl-protected.json" FM_TEST_GL_CHANGES_JSON="$TMP/gl-changes.json" \
  FM_TEST_STATUS="$TMP/gl-status")
out=$(env "${gl_env[@]}" "$EVIDENCE" collect "$TASK" "$GL_PR" "$HEAD")
eq "GitLab producer accepts matching forge evidence" "$(printf '%s' "$out" | jq -r .status)" PASS
out=$(env "${gl_env[@]}" FM_TEST_GL_PR_JSON="$TMP/gl-pr.json" "$EVIDENCE" collect "$TASK" "$GL_PR" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
eq "GitLab producer holds stale SHA" "$(printf '%s' "$out" | jq -r .reasons[0])" stale-head

echo "# fm-merge-policy.test.sh PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
