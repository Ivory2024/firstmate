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
{"author":{"login":"author"},"headRefOid":"$HEAD","baseRefName":"main","changedFiles":1,"statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"files":[{"path":"docs/operations.md"}]}
JSON
cat > "$TMP/reviews.json" <<JSON
[[{"state":"APPROVED","user":{"login":"reviewer"},"commit_id":"$HEAD","submitted_at":"2026-10-10T00:00:00Z"}, {"state":"APPROVED","user":{"login":"captain"},"commit_id":"$HEAD","submitted_at":"2026-10-10T00:00:00Z"}]]
JSON
cat > "$TMP/protection.json" <<'JSON'
{"required_status_checks":{"contexts":["ci"]},"required_pull_request_reviews":{}}
JSON
printf '%s\n' '[[]]' > "$TMP/rulesets.json"
# Real-shaped Checks API check-run objects: id, name, status, conclusion,
# started_at, completed_at, check_suite, app, output. They carry NO run_attempt
# (that field belongs to the workflow-run object, not the check run), so a
# collector that requires it refuses a normally successful GitHub Actions check.
cat > "$TMP/check-runs.json" <<JSON
[{"total_count":1,"check_runs":[{"id":1,"name":"ci","head_sha":"$HEAD","status":"completed","conclusion":"success","started_at":"2026-10-10T00:00:00Z","completed_at":"2026-10-10T00:00:30Z","check_suite":{"id":7},"app":{"id":17,"slug":"github-actions"},"output":{"title":"ok","summary":null,"text":null}}]}]
JSON
printf '%s\n' '[[]]' > "$TMP/statuses.json"
cat > "$TMP/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "pr view") cat "$FM_TEST_PR_JSON" ;;
  "api --paginate")
    case "$*" in
      *check-runs*) cat "$FM_TEST_CHECK_RUNS_JSON";;
      *statuses*) cat "$FM_TEST_STATUSES_JSON";;
      *pulls/9/reviews*) cat "$FM_TEST_REVIEWS_JSON";;
      *pulls/9/files*)
        # The collector now reads the paginated REST endpoint; when a test does
        # not stage its own page set, derive one from the view fixture so the
        # two always agree on file count.
        if [ -n "${FM_TEST_FILES_JSON:-}" ]; then cat "$FM_TEST_FILES_JSON"
        else jq -c '[.files | map({filename: .path})]' "$FM_TEST_PR_JSON"; fi;;
      *rules/branches/*) [ "${FM_TEST_FAIL_RULES:-}" != yes ] || exit 1; cat "$FM_TEST_RULESETS_JSON";;
      *) exit 2;;
    esac
    ;;
  "api user") printf '%s\n' '{"login":"captain"}' ;;
  "api repos/"*)
    case "$*" in
      *branches/*/protection*)
        if [ "${FM_TEST_PROTECTION_MISSING:-}" = yes ]; then
          printf '%s\n' 'gh: Not Found (HTTP 404)' >&2
          exit 1
        fi
        [ "${FM_TEST_FAIL_PROTECTION:-}" != yes ] || exit 1
        cat "$FM_TEST_PROTECTION_JSON";;
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
# The collector binds its `axi status` read to the task's own worktree, so the
# shared fixture records one; the cwd-binding case below drives a stub that only
# answers from that directory.
mkdir -p "$TMP/wt"
printf 'worktree=%s\n' "$TMP/wt" > "$TMP/home/state/$TASK.meta"
evidence_env=(PATH="$TMP/fakebin:$PATH" FM_HOME="$TMP/home" FM_STATE_OVERRIDE="$TMP/home/state" \
  FM_TEST_PR_JSON="$TMP/pr.json" FM_TEST_REVIEWS_JSON="$TMP/reviews.json" \
  FM_TEST_PROTECTION_JSON="$TMP/protection.json" FM_TEST_RULESETS_JSON="$TMP/rulesets.json" \
  FM_TEST_CHECK_RUNS_JSON="$TMP/check-runs.json" FM_TEST_STATUSES_JSON="$TMP/statuses.json" \
  FM_TEST_STATUS="$TMP/status")
out=$(env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "verified producer accepts matching forge evidence" "$(printf '%s' "$out" | jq -r .status)" PASS
# The `axi status` read is bound to the task's own worktree, never to the
# caller's inherited cwd: a supervisor shell parked in FM_HOME would otherwise
# read an unrelated repository's run and hold a PR that has valid evidence. This
# stub answers only from the recorded worktree, so it passes only when the
# collector changes directory into it first.
mkdir -p "$TMP/elsewhere" "$TMP/cwd-bin"
cat > "$TMP/cwd-bin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "$PWD" = "$FM_TEST_CWD_WT" ] || exit 1
cat "$FM_TEST_STATUS"
SH
chmod +x "$TMP/cwd-bin/no-mistakes"
out=$(cd "$TMP/elsewhere" && env "${evidence_env[@]}" \
  PATH="$TMP/cwd-bin:$TMP/fakebin:$PATH" FM_TEST_CWD_WT="$TMP/wt" \
  "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "axi status read is bound to the task worktree, not the caller cwd" \
  "$(printf '%s' "$out" | jq -r '.status + ":" + (.reasons | join(","))')" "PASS:"
cat > "$TMP/high-pr.json" <<JSON
{"author":{"login":"author"},"headRefOid":"$HEAD","baseRefName":"main","changedFiles":1,"files":[{"path":"bin/fm-watch.sh"}]}
JSON
cat > "$TMP/reviews.json" <<JSON
[[{"state":"APPROVED","user":{"login":"reviewer"},"commit_id":"$HEAD","submitted_at":"2026-10-10T00:00:00Z"},{"state":"APPROVED","user":{"login":"captain"},"commit_id":"$HEAD","submitted_at":"2026-10-10T00:00:00Z"},{"state":"CHANGES_REQUESTED","user":{"login":"captain"},"commit_id":"$HEAD","submitted_at":"2026-10-10T00:01:00Z"}]]
JSON
out=$(env "${evidence_env[@]}" FM_TEST_PR_JSON="$TMP/high-pr.json" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "later captain rejection invalidates approval" "$(printf '%s' "$out" | jq -r .reasons[0])" high-risk-captain-approval-missing-or-stale
cat > "$TMP/reviews.json" <<JSON
[[{"state":"APPROVED","user":{"login":"reviewer"},"commit_id":"$HEAD","submitted_at":"2026-10-10T00:00:00Z"},{"state":"APPROVED","user":{"login":"captain"},"commit_id":"$HEAD","submitted_at":"2026-10-10T00:00:00Z"}]]
JSON
out=$(env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
eq "verified producer holds stale SHA" "$(printf '%s' "$out" | jq -r .reasons[0])" stale-head
out=$(env "${evidence_env[@]}" FM_TEST_FAIL_PROTECTION=yes "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "verified producer holds forge API failure" "$(printf '%s' "$out" | jq -r .reasons[0])" branch-protection-unreadable
printf '%s\n' '[[]]' > "$TMP/rulesets.json"
out=$(env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "branch-effective endpoint omits non-applicable rules" "$(printf '%s' "$out" | jq -r .status)" PASS
cat > "$TMP/release-pr.json" <<JSON
{"author":{"login":"author"},"headRefOid":"$HEAD","baseRefName":"release/a","changedFiles":1,"files":[{"path":"docs/operations.md"}]}
JSON
cat > "$TMP/rulesets.json" <<'JSON'
[[],[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"security-scan","integration_id":17}]}}]]
JSON
out=$(env "${evidence_env[@]}" FM_TEST_PR_JSON="$TMP/release-pr.json" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "branch-effective ? pattern required check is enforced" "$(printf '%s' "$out" | jq -r .reasons[0])" required-checks-not-green-or-unconfigured
cat > "$TMP/excluded-pr.json" <<JSON
{"author":{"login":"author"},"headRefOid":"$HEAD","baseRefName":"release/nope","changedFiles":1,"files":[{"path":"docs/operations.md"}]}
JSON
printf '%s\n' '[[]]' > "$TMP/rulesets.json"
out=$(env "${evidence_env[@]}" FM_TEST_PR_JSON="$TMP/excluded-pr.json" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "branch-effective endpoint omits excluded patterns" "$(printf '%s' "$out" | jq -r .status)" PASS
out=$(env "${evidence_env[@]}" FM_TEST_FAIL_RULES=yes "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "unreadable branch rules hold" "$(printf '%s' "$out" | jq -r .reasons[0])" rulesets-unreadable

# --- ruleset-only branch ---
# A branch protected only by a ruleset answers 404 on the classic protection
# endpoint. That is an empty classic source, not an unreadable one, so the
# applicable ruleset's required check decides instead of a refusal.
cat > "$TMP/rulesets.json" <<'JSON'
[[],[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"security-scan","integration_id":17}]}}]]
JSON
cat > "$TMP/check-runs.json" <<JSON
[{"total_count":1,"check_runs":[{"id":9,"name":"security-scan","head_sha":"$HEAD","status":"completed","conclusion":"success","started_at":"2026-10-10T00:00:00Z","completed_at":"2026-10-10T00:00:30Z","check_suite":{"id":7},"app":{"id":17,"slug":"github-actions"},"output":{"title":"ok","summary":null,"text":null}}]}]
JSON
out=$(env "${evidence_env[@]}" FM_TEST_PROTECTION_MISSING=yes "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "ruleset-only branch enforces the effective ruleset check" "$(printf '%s' "$out" | jq -r '.status + ":" + (.reasons | join(","))')" "PASS:"
cat > "$TMP/check-runs.json" <<JSON
[{"total_count":1,"check_runs":[{"id":9,"name":"security-scan","head_sha":"$HEAD","status":"completed","conclusion":"failure","started_at":"2026-10-10T00:00:00Z","completed_at":"2026-10-10T00:00:30Z","check_suite":{"id":7},"app":{"id":17,"slug":"github-actions"},"output":{"title":"failed","summary":null,"text":null}}]}]
JSON
out=$(env "${evidence_env[@]}" FM_TEST_PROTECTION_MISSING=yes "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "ruleset-only branch holds a red ruleset check" "$(printf '%s' "$out" | jq -r .reasons[0])" required-checks-not-green-or-unconfigured
printf '%s\n' '[[]]' > "$TMP/rulesets.json"

# --- attended single-check waiver (--waived-check) ---
# The waiver arrives as an argument bound to one call, never from an environment
# variable or a file. It removes exactly the named check from the enforced set:
# every other configured check must still be green, and a repository that
# configures no check at all still holds.
cat > "$TMP/check-runs.json" <<JSON
[{"total_count":1,"check_runs":[{"id":1,"name":"ci","head_sha":"$HEAD","status":"completed","conclusion":"failure","started_at":"2026-10-10T00:00:00Z","completed_at":"2026-10-10T00:00:30Z","check_suite":{"id":7},"app":{"id":17,"slug":"github-actions"},"output":{"title":"failed","summary":null,"text":null}}]}]
JSON
out=$(env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "no waiver holds a red required check" "$(printf '%s' "$out" | jq -r .reasons[0])" required-checks-not-green-or-unconfigured
out=$(env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD" --waived-check ci)
eq "waived-check waives exactly its named required check" "$(printf '%s' "$out" | jq -r '.status + ":" + (.reasons | join(","))')" "PASS:"
cat > "$TMP/protection.json" <<'JSON'
{"required_status_checks":{"contexts":["ci","lint"]},"required_pull_request_reviews":{}}
JSON
cat > "$TMP/check-runs.json" <<JSON
[{"total_count":2,"check_runs":[{"id":1,"name":"ci","head_sha":"$HEAD","status":"completed","conclusion":"failure","started_at":"2026-10-10T00:00:00Z","completed_at":"2026-10-10T00:00:30Z","check_suite":{"id":7},"app":{"id":17,"slug":"github-actions"},"output":{"title":"failed","summary":null,"text":null}},{"id":2,"name":"lint","head_sha":"$HEAD","status":"completed","conclusion":"failure","started_at":"2026-10-10T00:00:00Z","completed_at":"2026-10-10T00:00:30Z","check_suite":{"id":7},"app":{"id":17,"slug":"github-actions"},"output":{"title":"failed","summary":null,"text":null}}]}]
JSON
out=$(env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD" --waived-check ci)
eq "waived-check leaves a different red required check holding" "$(printf '%s' "$out" | jq -r .reasons[0])" required-checks-not-green-or-unconfigured
if env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD" --waived-check >/dev/null 2>&1; then
  no "waived-check without a name is refused"
else
  ok "waived-check without a name is refused"
fi
cat > "$TMP/protection.json" <<'JSON'
{"required_status_checks":{"contexts":["ci"]},"required_pull_request_reviews":{}}
JSON
cat > "$TMP/check-runs.json" <<JSON
[{"total_count":1,"check_runs":[{"id":1,"name":"ci","head_sha":"$HEAD","status":"completed","conclusion":"success","started_at":"2026-10-10T00:00:00Z","completed_at":"2026-10-10T00:00:30Z","check_suite":{"id":7},"app":{"id":17,"slug":"github-actions"},"output":{"title":"ok","summary":null,"text":null}}]}]
JSON
cat > "$TMP/pr.json" <<JSON
{"author":{"login":"author"},"headRefOid":"$HEAD","baseRefName":"main","changedFiles":1,"files":[{"path":"docs/operations.md"}]}
JSON
out=$(env "${evidence_env[@]}" FM_TEST_FAIL_STATUS=yes "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "verified producer holds missing test evidence" "$(printf '%s' "$out" | jq -r .reasons[0])" test-evidence-missing-or-stale
cat > "$TMP/home/state/$TASK.test-evidence" <<JSON
{"command":"forged test","exit":0,"sha":"$HEAD","verdict":"PASS"}
JSON
chmod 600 "$TMP/home/state/$TASK.test-evidence"
out=$(env "${evidence_env[@]}" FM_TEST_FAIL_STATUS=yes "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "producer ignores caller-writable test record" "$(printf '%s' "$out" | jq -r .reasons[0])" test-evidence-missing-or-stale
rm -f "$TMP/home/state/$TASK.test-evidence"
cat > "$TMP/home/state/$TASK.review-evidence" <<JSON
{"reviewer":"reviewer","model":"independent","reviewed_sha":"$HEAD","verdict":"APPROVED"}
JSON
chmod 600 "$TMP/home/state/$TASK.review-evidence"
cat > "$TMP/reviews.json" <<'JSON'
[[]]
JSON
out=$(env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "producer ignores caller-writable review record" "$(printf '%s' "$out" | jq -r .reasons[0])" independent-review-missing-or-stale
cat > "$TMP/reviews.json" <<JSON
[[{"state":"APPROVED","user":{"login":"reviewer"},"commit_id":"$HEAD","submitted_at":"2026-10-10T00:00:00Z"}]]
JSON
cat > "$TMP/home/state/$TASK.gate0-approval" <<JSON
{"pr":"$PR","approved_sha":"$HEAD","scope":"forged","signer":"captain","at":"now"}
JSON
chmod 600 "$TMP/home/state/$TASK.gate0-approval"
cat > "$TMP/high-pr.json" <<JSON
{"author":{"login":"author"},"headRefOid":"$HEAD","baseRefName":"main","changedFiles":1,"files":[{"path":"bin/fm-watch.sh"}]}
JSON
out=$(env "${evidence_env[@]}" FM_TEST_PR_JSON="$TMP/high-pr.json" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "producer ignores caller-writable captain approval" "$(printf '%s' "$out" | jq -r .reasons[0])" high-risk-captain-approval-missing-or-stale
rm -f "$TMP/home/state/$TASK.gate0-approval"
cat > "$TMP/reviews.json" <<JSON
[[{"state":"APPROVED","user":{"login":"reviewer"},"commit_id":"$HEAD","submitted_at":"2026-10-10T00:00:00Z"},{"state":"APPROVED","user":{"login":"captain"},"commit_id":"$HEAD","submitted_at":"2026-10-10T00:00:00Z"}]]
JSON
cp "$TMP/check-runs.json" "$TMP/good-check-runs.json"
cat > "$TMP/check-runs.json" <<JSON
[{"total_count":2,"check_runs":[{"id":1,"name":"ci","head_sha":"$HEAD","status":"completed","conclusion":"success","started_at":"2026-10-10T00:00:00Z","completed_at":"2026-10-10T00:00:30Z","check_suite":{"id":7},"app":{"id":17,"slug":"github-actions"},"output":{"title":"ok","summary":null,"text":null}},{"id":2,"name":"ci","head_sha":"$HEAD","status":"completed","conclusion":"failure","started_at":"2026-10-10T00:01:00Z","completed_at":"2026-10-10T00:01:30Z","check_suite":{"id":7},"app":{"id":17,"slug":"github-actions"},"output":{"title":"failed","summary":null,"text":null}}]}]
JSON
out=$(env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "later failed check run invalidates success" "$(printf '%s' "$out" | jq -r .reasons[0])" required-checks-not-green-or-unconfigured
cat > "$TMP/check-runs.json" <<JSON
[{"total_count":2,"check_runs":[{"id":1,"name":"ci","head_sha":"$HEAD","status":"completed","conclusion":"success","started_at":"2026-10-10T00:00:00Z","completed_at":"2026-10-10T00:00:30Z","check_suite":{"id":7},"app":{"id":17,"slug":"github-actions"},"output":{"title":"ok","summary":null,"text":null}},{"id":2,"name":"ci","head_sha":"$HEAD","status":"in_progress","conclusion":null,"started_at":"2026-10-10T00:01:00Z","completed_at":null,"check_suite":{"id":7},"app":{"id":17,"slug":"github-actions"},"output":{"title":null,"summary":null,"text":null}}]}]
JSON
out=$(env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "later in-progress check run invalidates success" "$(printf '%s' "$out" | jq -r .reasons[0])" required-checks-not-green-or-unconfigured
printf '%s\n' '[{"total_count":0,"check_runs":[]}]' > "$TMP/check-runs.json"
cat > "$TMP/statuses.json" <<JSON
[[{"id":1,"created_at":"2026-10-10T00:00:00Z","context":"ci","sha":"$HEAD","state":"success"},{"id":2,"created_at":"2026-10-10T00:01:00Z","context":"ci","sha":"$HEAD","state":"failure"}]]
JSON
out=$(env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "later legacy status invalidates success" "$(printf '%s' "$out" | jq -r .reasons[0])" required-checks-not-green-or-unconfigured
cp "$TMP/good-check-runs.json" "$TMP/check-runs.json"
cat > "$TMP/statuses.json" <<JSON
[[{"id":3,"created_at":"2026-10-10T00:02:00Z","context":"ci","sha":"$HEAD","state":"failure"}]]
JSON
out=$(env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "newer legacy failure supersedes earlier check run" "$(printf '%s' "$out" | jq -r .reasons[0])" required-checks-not-green-or-unconfigured
cp "$TMP/good-check-runs.json" "$TMP/check-runs.json"
printf '%s\n' '[[]]' > "$TMP/statuses.json"
printf '%s\n' '[{"total_count":1,"check_runs":[{"id":1,"name":"ci","head_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","status":"completed","conclusion":"success","started_at":"2026-10-10T00:00:00Z","completed_at":"2026-10-10T00:00:30Z","check_suite":{"id":7},"app":{"id":17,"slug":"github-actions"},"output":{"title":"ok","summary":null,"text":null}}]}]' > "$TMP/check-runs.json"
out=$(env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "producer rejects required check at wrong SHA" "$(printf '%s' "$out" | jq -r .reasons[0])" required-checks-not-green-or-unconfigured
cp "$TMP/good-check-runs.json" "$TMP/check-runs.json"
if env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD" --ci pass >/dev/null 2>&1; then no "producer accepted caller evidence flags"; else ok "producer rejects caller evidence flags"; fi

GL_PR=https://gitlab.example/group/subgroup/project/-/merge_requests/7
cat > "$TMP/gl-pr.json" <<JSON
{"author":{"username":"author"},"sha":"$HEAD","target_branch":"main","head_pipeline":{"id":17,"sha":"$HEAD","status":"success"}}
JSON
cat > "$TMP/gl-approvals.json" <<'JSON'
{"approvals_left":0,"approved_by":[{"user":{"id":99,"username":"reviewer"}}]}
JSON
cat > "$TMP/gl-protected.json" <<'JSON'
[{"name":"main","required_pipeline":{"id":17}}]
JSON
cat > "$TMP/gl-changes.json" <<'JSON'
{"overflow":false,"changes_count":"1","changes":[{"new_path":"docs/operations.md"}]}
JSON
cat > "$TMP/gl-jobs.json" <<JSON
[{"status":"success","commit":{"id":"$HEAD"},"pipeline":{"id":17}}]
JSON
printf '%s\n' '{"reset_approvals_on_push":true}' > "$TMP/gl-project.json"
cat > "$TMP/fakebin/glab" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "mr view") cat "$FM_TEST_GL_PR_JSON" ;;
  "api --paginate") cat "$FM_TEST_GL_JOBS_JSON" ;;
  "api projects/"*)
    case "$*" in
      *protected_branches*) cat "$FM_TEST_GL_PROTECTED_JSON";;
      *approvals*) cat "$FM_TEST_GL_APPROVALS_JSON";;
      */pipelines/*/jobs*) cat "$FM_TEST_GL_JOBS_JSON";;
      *changes*) cat "$FM_TEST_GL_CHANGES_JSON";;
      *projects/*) cat "$FM_TEST_GL_PROJECT_JSON";;
      *) exit 2;;
    esac
    ;;
esac
SH
chmod +x "$TMP/fakebin/glab"
cp "$TMP/status" "$TMP/gl-status"
sed "s#$PR#$GL_PR#" "$TMP/status" > "$TMP/gl-status"
printf '%s\n' 'done: validated' > "$TMP/home/state/$TASK.status"
gl_env=(PATH="$TMP/fakebin:$PATH" FM_HOME="$TMP/home" FM_STATE_OVERRIDE="$TMP/home/state" \
  FM_TEST_GL_PR_JSON="$TMP/gl-pr.json" FM_TEST_GL_APPROVALS_JSON="$TMP/gl-approvals.json" \
  FM_TEST_GL_PROTECTED_JSON="$TMP/gl-protected.json" FM_TEST_GL_CHANGES_JSON="$TMP/gl-changes.json" \
  FM_TEST_GL_JOBS_JSON="$TMP/gl-jobs.json" FM_TEST_GL_PROJECT_JSON="$TMP/gl-project.json" \
  FM_TEST_STATUS="$TMP/gl-status")
out=$(env "${gl_env[@]}" "$EVIDENCE" collect "$TASK" "$GL_PR" "$HEAD")
eq "GitLab producer accepts matching forge evidence" "$(printf '%s' "$out" | jq -r '.status + ":" + (.reasons | join(","))')" "PASS:"
cat > "$TMP/gl-jobs.json" <<JSON
[{"status":"failed","commit":{"id":"$HEAD"}}]
JSON
out=$(env "${gl_env[@]}" "$EVIDENCE" collect "$TASK" "$GL_PR" "$HEAD")
eq "GitLab producer rejects failed pipeline job" "$(printf '%s' "$out" | jq -r .reasons[0])" required-checks-not-green-or-unconfigured
out=$(env "${gl_env[@]}" FM_TEST_GL_PR_JSON="$TMP/gl-pr.json" "$EVIDENCE" collect "$TASK" "$GL_PR" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
eq "GitLab producer holds stale SHA" "$(printf '%s' "$out" | jq -r .reasons[0])" stale-head

# --- GitLab required-set (protected branch required pipeline) ---
cat > "$TMP/gl-protected-req.json" <<'JSON'
[{"name":"main","required_pipeline":{"id":42},"approval_rules":[{"approvals_required":1,"user_ids":[99],"group_ids":[]}]}]
JSON
cat > "$TMP/gl-jobs-req.json" <<JSON
[{"status":"success","commit":{"id":"$HEAD"},"pipeline":{"id":42}},{"status":"success","commit":{"id":"$HEAD"},"pipeline":{"id":99}}]
JSON
out=$(env "${gl_env[@]}" FM_TEST_GL_PROTECTED_JSON="$TMP/gl-protected-req.json" FM_TEST_GL_JOBS_JSON="$TMP/gl-jobs-req.json" "$EVIDENCE" collect "$TASK" "$GL_PR" "$HEAD")
eq "GitLab producer accepts required pipeline success" "$(printf '%s' "$out" | jq -r .status)" PASS
cat > "$TMP/gl-jobs-req.json" <<JSON
[{"status":"failed","commit":{"id":"$HEAD"},"pipeline":{"id":42}}]
JSON
out=$(env "${gl_env[@]}" FM_TEST_GL_PROTECTED_JSON="$TMP/gl-protected-req.json" FM_TEST_GL_JOBS_JSON="$TMP/gl-jobs-req.json" "$EVIDENCE" collect "$TASK" "$GL_PR" "$HEAD")
eq "GitLab producer rejects failed required pipeline" "$(printf '%s' "$out" | jq -r .reasons[0])" required-checks-not-green-or-unconfigured
cat > "$TMP/gl-jobs-req.json" <<JSON
[{"status":"success","commit":{"id":"$HEAD"},"pipeline":{"id":99}}]
JSON
out=$(env "${gl_env[@]}" FM_TEST_GL_PROTECTED_JSON="$TMP/gl-protected-req.json" FM_TEST_GL_JOBS_JSON="$TMP/gl-jobs-req.json" "$EVIDENCE" collect "$TASK" "$GL_PR" "$HEAD")
eq "GitLab producer rejects missing required pipeline" "$(printf '%s' "$out" | jq -r .reasons[0])" required-checks-not-green-or-unconfigured

# --- changed-file completeness is fail-closed (GAP A) ---
# `gh pr view --json files` requests files(first:100) and silently caps there, so
# a protected path past the 100th file was invisible and the PR classified
# LOW/MEDIUM. The collector now reads the paginated pulls/<n>/files endpoint and
# requires its distinct path count to equal the PR's own changedFiles count.
# GitLab has the same class: an overflowing or under-reported `.changes` list
# must hold instead of classifying risk on a partial set.
cat > "$TMP/reviews.json" <<JSON
[[{"state":"APPROVED","user":{"login":"reviewer"},"commit_id":"$HEAD","submitted_at":"2026-10-10T00:00:00Z"}]]
JSON
# The view fixture carries exactly what `gh pr view --json files` returns for
# this PR: the first 100 files only. The paginated endpoint is the only source
# that can answer with the real 101st entry.
jq -cn --arg head "$HEAD" '{author:{login:"author"},headRefOid:$head,baseRefName:"main",changedFiles:101,
  files:[range(0;100) | {path:("docs/generated/f\(.).md")}]}' > "$TMP/cap-pr.json"
jq -c '[[.files[] | {filename:.path}]]' "$TMP/cap-pr.json" > "$TMP/cap-truncated.json"
jq -c '[[.files[] | {filename:.path}] + [{filename:"bin/fm-watch.sh"}]]' "$TMP/cap-pr.json" > "$TMP/cap-complete.json"
printf '%s\n' '[{"message":"Not Found"}]' > "$TMP/cap-garbage.json"
printf '%s\n' '[[]]' > "$TMP/cap-empty.json"
jq -cn --arg head "$HEAD" '{author:{login:"author"},headRefOid:$head,baseRefName:"main",files:[{path:"docs/operations.md"}]}' > "$TMP/nocount-pr.json"
gap_gh=(FM_TEST_PR_JSON="$TMP/cap-pr.json")
out=$(env "${evidence_env[@]}" "${gap_gh[@]}" FM_TEST_FILES_JSON="$TMP/cap-truncated.json" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "GitHub truncated changed-file list holds" "$(printf '%s' "$out" | jq -r .reasons[0])" changed-files-truncated
out=$(env "${evidence_env[@]}" "${gap_gh[@]}" FM_TEST_FILES_JSON="$TMP/cap-complete.json" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "GitHub protected path past file 100 is classified" "$(printf '%s' "$out" | jq -r .reasons[0])" high-risk-captain-approval-missing-or-stale
out=$(env "${evidence_env[@]}" "${gap_gh[@]}" FM_TEST_FILES_JSON="$TMP/cap-garbage.json" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "GitHub unreadable changed-file pages hold" "$(printf '%s' "$out" | jq -r .reasons[0])" changed-files-invalid
out=$(env "${evidence_env[@]}" "${gap_gh[@]}" FM_TEST_FILES_JSON="$TMP/cap-empty.json" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "GitHub empty changed-file pages hold" "$(printf '%s' "$out" | jq -r .reasons[0])" changed-files-unreadable
out=$(env "${evidence_env[@]}" FM_TEST_PR_JSON="$TMP/nocount-pr.json" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "GitHub missing changed-file count holds" "$(printf '%s' "$out" | jq -r .reasons[0])" changed-files-count-unreadable

cat > "$TMP/gl-changes-ok.json" <<'JSON'
{"overflow":false,"changes_count":"1","changes":[{"new_path":"docs/operations.md"}]}
JSON
cat > "$TMP/gl-changes-overflow.json" <<'JSON'
{"overflow":true,"changes_count":"120","changes":[{"new_path":"docs/operations.md"}]}
JSON
cat > "$TMP/gl-changes-mismatch.json" <<'JSON'
{"overflow":false,"changes_count":"3","changes":[{"new_path":"docs/operations.md"},{"new_path":"docs/other.md"}]}
JSON
cat > "$TMP/gl-changes-nooverflow.json" <<'JSON'
{"changes":[{"new_path":"docs/operations.md"}]}
JSON
cat > "$TMP/gl-changes-countgarbage.json" <<'JSON'
{"overflow":false,"changes_count":"many","changes":[{"new_path":"docs/operations.md"}]}
JSON
cat > "$TMP/gl-jobs-good.json" <<JSON
[{"status":"success","commit":{"id":"$HEAD"},"pipeline":{"id":17}}]
JSON
gl_gap=(FM_TEST_GL_PROTECTED_JSON="$TMP/gl-protected.json" FM_TEST_GL_JOBS_JSON="$TMP/gl-jobs-good.json")
out=$(env "${gl_env[@]}" "${gl_gap[@]}" FM_TEST_GL_CHANGES_JSON="$TMP/gl-changes-ok.json" "$EVIDENCE" collect "$TASK" "$GL_PR" "$HEAD")
eq "GitLab complete diff passes" "$(printf '%s' "$out" | jq -r '.status + ":" + (.reasons | join(","))')" "PASS:"
out=$(env "${gl_env[@]}" "${gl_gap[@]}" FM_TEST_GL_CHANGES_JSON="$TMP/gl-changes-overflow.json" "$EVIDENCE" collect "$TASK" "$GL_PR" "$HEAD")
eq "GitLab overflowing diff holds" "$(printf '%s' "$out" | jq -r .reasons[0])" changed-files-truncated
out=$(env "${gl_env[@]}" "${gl_gap[@]}" FM_TEST_GL_CHANGES_JSON="$TMP/gl-changes-mismatch.json" "$EVIDENCE" collect "$TASK" "$GL_PR" "$HEAD")
eq "GitLab changes/changes_count mismatch holds" "$(printf '%s' "$out" | jq -r .reasons[0])" changed-files-truncated
out=$(env "${gl_env[@]}" "${gl_gap[@]}" FM_TEST_GL_CHANGES_JSON="$TMP/gl-changes-nooverflow.json" "$EVIDENCE" collect "$TASK" "$GL_PR" "$HEAD")
eq "GitLab missing overflow flag holds" "$(printf '%s' "$out" | jq -r .reasons[0])" changed-files-overflow-unknown
out=$(env "${gl_env[@]}" "${gl_gap[@]}" FM_TEST_GL_CHANGES_JSON="$TMP/gl-changes-countgarbage.json" "$EVIDENCE" collect "$TASK" "$GL_PR" "$HEAD")
eq "GitLab unreadable changes_count holds" "$(printf '%s' "$out" | jq -r .reasons[0])" changed-files-count-unreadable

# Empty risk classification output (a policy helper that exits 0 silently) must
# hold rather than pass through an empty risk value.
make_evidence_dir() { # <dir> <evidence-script-src> <policy: real|empty>
  local dir=$1 src=$2 policy=$3 f
  mkdir -p "$dir"
  # Sibling scripts and libraries are symlinked so a copied collector resolves
  # whatever it sources; the two files it must not inherit are skipped.
  for f in "$ROOT"/bin/*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in fm-merge-evidence.sh|fm-merge-policy.sh) continue;; esac
    ln -sf "$f" "$dir/"
  done
  cp "$src" "$dir/fm-merge-evidence.sh"
  if [ "$policy" = empty ]; then
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/fm-merge-policy.sh"
  else
    ln -sf "$ROOT/bin/fm-merge-policy.sh" "$dir/fm-merge-policy.sh"
  fi
  chmod +x "$dir/fm-merge-evidence.sh" "$dir/fm-merge-policy.sh"
}
make_evidence_dir "$TMP/empty-bin" "$EVIDENCE" empty
out=$(env "${evidence_env[@]}" "$TMP/empty-bin/fm-merge-evidence.sh" collect "$TASK" "$PR" "$HEAD")
eq "empty risk classification output holds" "$(printf '%s' "$out" | jq -r .reasons[0])" risk-unknown

# --- bite-check: the same fixtures must NOT hold on the pre-fix logic ---
# The pre-fix collector had none of the completeness guards, so a fixture that
# still passes on it proves the new assertion, not the fixture, is what produces
# the HOLD. The pre-fix implementation must be a REAL prior revision, not a
# source edit: editing source with sed and asserting on its text would be a
# source-content-only test.
#
# The revision is resolved from this branch's own history rather than hardcoded,
# so the object is always an ancestor of the checked-out commit. A hardcoded SHA
# from a rewritten lineage is not an ancestor and a fresh checkout need not
# contain it, which made this suite fail before any behavioural assertion ran.
PREFIX_SRC="$TMP/prefix-src/fm-merge-evidence.sh"
mkdir -p "$TMP/prefix-src"
GUARD_COMMIT=$(git -C "$ROOT" log --format=%H -S'changed-files-truncated' -- bin/fm-merge-evidence.sh | tail -1)
PREFIX_REV=$(git -C "$ROOT" rev-parse --verify "${GUARD_COMMIT}^" 2>/dev/null) \
  || { echo "not ok - bite-check could not resolve the real pre-fix collector"; exit 1; }
git -C "$ROOT" show "$PREFIX_REV:bin/fm-merge-evidence.sh" > "$PREFIX_SRC" 2>/dev/null \
  || { echo "not ok - bite-check could not read the real pre-fix collector"; exit 1; }
make_evidence_dir "$TMP/prefix-bin" "$PREFIX_SRC" real
make_evidence_dir "$TMP/prefix-empty-bin" "$PREFIX_SRC" empty
PREFIX="$TMP/prefix-bin/fm-merge-evidence.sh"
out=$(env "${gl_env[@]}" "${gl_gap[@]}" FM_TEST_GL_CHANGES_JSON="$TMP/gl-changes-overflow.json" "$PREFIX" collect "$TASK" "$GL_PR" "$HEAD")
eq "bite: pre-fix logic accepts an overflowing GitLab diff" "$(printf '%s' "$out" | jq -r .status)" PASS
out=$(env "${gl_env[@]}" "${gl_gap[@]}" FM_TEST_GL_CHANGES_JSON="$TMP/gl-changes-mismatch.json" "$PREFIX" collect "$TASK" "$GL_PR" "$HEAD")
eq "bite: pre-fix logic accepts a mismatched GitLab diff" "$(printf '%s' "$out" | jq -r .status)" PASS
# This pre-fix revision predates the Checks-API field fix, so it demands the
# invented run_attempt field; its own fixture supplies that field. This run
# drives the pre-fix completeness logic, never the current collector's field
# expectations, which the real-shaped fixture above owns.
printf '%s\n' "[{\"total_count\":1,\"check_runs\":[{\"id\":1,\"run_attempt\":1,\"started_at\":\"2026-10-10T00:00:00Z\",\"app\":{\"id\":17},\"name\":\"ci\",\"head_sha\":\"$HEAD\",\"status\":\"completed\",\"conclusion\":\"success\"}]}]" > "$TMP/prefix-check-runs.json"
out=$(env "${evidence_env[@]}" FM_TEST_CHECK_RUNS_JSON="$TMP/prefix-check-runs.json" "$TMP/prefix-empty-bin/fm-merge-evidence.sh" collect "$TASK" "$PR" "$HEAD")
eq "bite: pre-fix logic accepts empty risk output" "$(printf '%s' "$out" | jq -r .status)" PASS

echo "# fm-merge-policy.test.sh PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
