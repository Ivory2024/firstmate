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

# The engine exposes only risk classification: the collector alone decides merge
# eligibility, so no eligibility mode belongs here.
if "$P" review-route --risk LOW >/dev/null 2>&1; then no "review-route command is unavailable"; else ok "review-route command is unavailable"; fi

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
      *rules/branches/*)
        [ "${FM_TEST_FAIL_RULES:-}" != yes ] || exit 1
        [ -z "${FM_TEST_RULES_ERR:-}" ] || { printf '%s\n' "$FM_TEST_RULES_ERR" >&2; exit 1; }
        cat "$FM_TEST_RULESETS_JSON";;
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
        [ -z "${FM_TEST_PROTECTION_ERR:-}" ] || { printf '%s\n' "$FM_TEST_PROTECTION_ERR" >&2; exit 1; }
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

# --- independent branch-protection verification ---
# The base branch's protection and its applicable rulesets are read from the
# forge, never taken from a caller flag, and the verdict carries that evidence's
# digest so the merge boundary can re-read the same sources immediately before
# the forge command and refuse when protection was removed or weakened after
# collection.
cat > "$TMP/check-runs.json" <<JSON
[{"total_count":1,"check_runs":[{"id":1,"name":"ci","head_sha":"$HEAD","status":"completed","conclusion":"success","started_at":"2026-10-10T00:00:00Z","completed_at":"2026-10-10T00:00:30Z","check_suite":{"id":7},"app":{"id":17,"slug":"github-actions"},"output":{"title":"ok","summary":null,"text":null}}]}]
JSON
out=$(env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "collector marks the verified protection evidence" \
  "$(printf '%s' "$out" | jq -r '.status + ":" + (.protection | tostring)')" "PASS:true"
prot_scope=$(printf '%s' "$out" | jq -r .protection_scope)
eq "collector records a protection evidence digest" \
  "$(printf '%s' "$prot_scope" | grep -cE '^[0-9a-f]{64}$')" 1
out=$(env "${evidence_env[@]}" "$EVIDENCE" branch-protection "$PR" "$prot_scope")
eq "re-verification passes on unchanged protection" "$(printf '%s' "$out" | jq -r .status)" PASS
eq "the protection digest is stable across reads" \
  "$(printf '%s' "$out" | jq -r .protection_scope)" "$prot_scope"
out=$(env "${evidence_env[@]}" "$EVIDENCE" branch-protection "$PR" "$(printf '%064d' 0)")
eq "re-verification holds when protection changed after collection" \
  "$(printf '%s' "$out" | jq -r .reasons[0])" branch-protection-changed
out=$(env "${evidence_env[@]}" FM_TEST_FAIL_PROTECTION=yes "$EVIDENCE" branch-protection "$PR" "$prot_scope")
eq "re-verification holds an unreadable protection read" \
  "$(printf '%s' "$out" | jq -r .reasons[0])" branch-protection-unreadable
out=$(env "${evidence_env[@]}" FM_TEST_FAIL_RULES=yes "$EVIDENCE" branch-protection "$PR" "$prot_scope")
eq "re-verification holds an unreadable ruleset read" \
  "$(printf '%s' "$out" | jq -r .reasons[0])" rulesets-unreadable
# A base branch with no protection at all is named as its own gap rather than
# folded into the unconfigured-required-check refusal, because one has no gate
# and the other has a gate with nothing in it.
printf '%s\n' '{}' > "$TMP/protection.json"
out=$(env "${evidence_env[@]}" FM_TEST_PROTECTION_MISSING=yes "$EVIDENCE" branch-protection "$PR" "$prot_scope")
eq "re-verification holds a branch with no protection" \
  "$(printf '%s' "$out" | jq -r .reasons[0])" branch-protection-missing
out=$(env "${evidence_env[@]}" FM_TEST_PROTECTION_MISSING=yes "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "collector names a branch with no protection" \
  "$(printf '%s' "$out" | jq -r .reasons[0])" branch-protection-missing
cat > "$TMP/protection.json" <<'JSON'
{"required_status_checks":{"contexts":["ci"]},"required_pull_request_reviews":{}}
JSON
env "${evidence_env[@]}" "$EVIDENCE" branch-protection "$PR" nothex >/dev/null 2>&1
eq "re-verification rejects a malformed scope" "$?" 2

# --- plan-gated protection reads ---
# A repository whose GitHub plan cannot expose branch protection or branch rules
# at all answers 403 "Upgrade to GitHub Pro or make this repository public" on
# both endpoints. bin/fm-pr-merge.sh already resolves that exact 403 to "no rule
# of any kind" rather than to an error, so the collector resolves it the same
# way: when BOTH sources are refused by that one plan message, the required set
# is provably empty, so the verdict passes as "no enforceable required check"
# instead of holding a source it never failed to read. The relaxation is
# recorded on the verdict as protection_source=unavailable-by-plan so the reason
# is traceable, and only that plan refusal is relaxed: every other 403, every
# 5xx, a permission refusal, and every repository that does carry protection
# still hold below.
PLAN_403_ERR='gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)'
UNRELATED_403_ERR='gh: Resource not accessible by integration (HTTP 403)'
SERVER_500_ERR='gh: Internal Server Error (HTTP 500)'
plan_env=(FM_TEST_PROTECTION_ERR="$PLAN_403_ERR" FM_TEST_RULES_ERR="$PLAN_403_ERR")
out=$(env "${evidence_env[@]}" "${plan_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "plan-gated 403 on both protection sources resolves to no enforceable required check" \
  "$(printf '%s' "$out" | jq -r '.status + ":" + (.reasons | join(","))')" "PASS:"
eq "the plan resolution records why the gate was not enforced" \
  "$(printf '%s' "$out" | jq -r .protection_source)" unavailable-by-plan
plan_relaxation=$(printf '%s' "$out" | jq -r .protection_source)
eq "the plan resolution does not claim protection exists" \
  "$(printf '%s' "$out" | jq -r '.protection | tostring')" false
plan_scope=$(printf '%s' "$out" | jq -r .protection_scope)
eq "the plan resolution still records a protection evidence digest" \
  "$(printf '%s' "$plan_scope" | grep -cE '^[0-9a-f]{64}$')" 1
out=$(env "${evidence_env[@]}" "${plan_env[@]}" "$EVIDENCE" branch-protection "$PR" "$plan_scope")
eq "re-verification resolves the same plan-gated 403 to the same unenforced gate" \
  "$(printf '%s' "$out" | jq -r '.status + ":" + .protection_source + ":" + .protection_scope')" \
  "PASS:unavailable-by-plan:$plan_scope"
out=$(env "${evidence_env[@]}" "${plan_env[@]}" "$EVIDENCE" branch-protection "$PR" "$prot_scope")
eq "re-verification refuses protection that appeared after a plan-gated collection" \
  "$(printf '%s' "$out" | jq -r .reasons[0])" branch-protection-changed
# The negative controls. The plan refusal is a narrow exception, so two further
# boundaries are pinned: a plan refusal on one source while the other still
# reads is ordinary evidence, and an unrelated refusal never relaxes anything.
out=$(env "${evidence_env[@]}" FM_TEST_PROTECTION_ERR="$PLAN_403_ERR" FM_TEST_RULES_ERR="$SERVER_500_ERR" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "a plan refusal on one source only still holds the other source's failure" \
  "$(printf '%s' "$out" | jq -r .reasons[0])" rulesets-unreadable
out=$(env "${evidence_env[@]}" FM_TEST_PROTECTION_ERR="$UNRELATED_403_ERR" FM_TEST_RULES_ERR="$PLAN_403_ERR" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "a plan refusal on branch rules does not excuse a permission refusal on protection" \
  "$(printf '%s' "$out" | jq -r .reasons[0])" branch-protection-unreadable
out=$(env "${evidence_env[@]}" FM_TEST_PROTECTION_ERR="$UNRELATED_403_ERR" FM_TEST_RULES_ERR="$UNRELATED_403_ERR" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "an unrelated 403 still holds an unreadable protection read" \
  "$(printf '%s' "$out" | jq -r .reasons[0])" branch-protection-unreadable
out=$(env "${evidence_env[@]}" FM_TEST_PROTECTION_ERR="$SERVER_500_ERR" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "a 5xx still holds an unreadable protection read" \
  "$(printf '%s' "$out" | jq -r .reasons[0])" branch-protection-unreadable
out=$(env "${evidence_env[@]}" FM_TEST_RULES_ERR="$UNRELATED_403_ERR" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "an unrelated 403 still holds an unreadable branch-rules read" \
  "$(printf '%s' "$out" | jq -r .reasons[0])" rulesets-unreadable
out=$(env "${evidence_env[@]}" FM_TEST_RULES_ERR="$SERVER_500_ERR" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "a 5xx still holds an unreadable branch-rules read" \
  "$(printf '%s' "$out" | jq -r .reasons[0])" rulesets-unreadable
out=$(env "${evidence_env[@]}" FM_TEST_RULES_ERR="$PLAN_403_ERR" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "plan-gated 403 on branch rules alone leaves the classic source in force" \
  "$(printf '%s' "$out" | jq -r '.status + ":" + (.reasons | join(","))')" "PASS:"
eq "plan-gated 403 on branch rules alone records no relaxation" \
  "$(printf '%s' "$out" | jq -r '.protection_source // "none"')" none
# A repository that DOES carry protection is never relaxed: the gate is read,
# and an empty or red required set still holds exactly as before.
cat > "$TMP/protection.json" <<'JSON'
{"required_pull_request_reviews":{}}
JSON
out=$(env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "protection present with no required check still holds" \
  "$(printf '%s' "$out" | jq -r .reasons[0])" required-checks-not-green-or-unconfigured
eq "protection present with an empty required set records no relaxation" \
  "$(printf '%s' "$out" | jq -r '.protection_source // "none"')" none
cat > "$TMP/protection.json" <<'JSON'
{"required_status_checks":{"contexts":["ci"]},"required_pull_request_reviews":{}}
JSON
cat > "$TMP/check-runs.json" <<JSON
[{"total_count":1,"check_runs":[{"id":1,"name":"ci","head_sha":"$HEAD","status":"completed","conclusion":"failure","started_at":"2026-10-10T00:00:00Z","completed_at":"2026-10-10T00:00:30Z","check_suite":{"id":7},"app":{"id":17,"slug":"github-actions"},"output":{"title":"failed","summary":null,"text":null}}]}]
JSON
out=$(env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "protection present with a red required check still holds" \
  "$(printf '%s' "$out" | jq -r .reasons[0])" required-checks-not-green-or-unconfigured
cat > "$TMP/check-runs.json" <<JSON
[{"total_count":1,"check_runs":[{"id":1,"name":"ci","head_sha":"$HEAD","status":"completed","conclusion":"success","started_at":"2026-10-10T00:00:00Z","completed_at":"2026-10-10T00:00:30Z","check_suite":{"id":7},"app":{"id":17,"slug":"github-actions"},"output":{"title":"ok","summary":null,"text":null}}]}]
JSON
out=$(env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "protection present and green still passes with no relaxation" \
  "$(printf '%s' "$out" | jq -r '.status + ":" + (.protection | tostring) + ":" + (.protection_source // "none")')" "PASS:true:none"

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
# A status that never states its findings is not clean evidence. An unset awk
# variable compares equal to 0, so a parser that only tests `f == 0` passes on a
# field it never read; the line itself is required.
cat > "$TMP/status-no-findings" <<JSON
run:
  id: test-run-id
  status: completed
  head_sha: $HEAD
  pr: "$PR"
  steps[1]{step,status,findings,duration_ms}:
    test,completed,0,1
outcome: passed
JSON
out=$(env "${evidence_env[@]}" FM_TEST_STATUS="$TMP/status-no-findings" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
eq "producer holds a status that never states its findings" "$(printf '%s' "$out" | jq -r .reasons[0])" test-evidence-missing-or-stale
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

# A completed required check is green to GitHub when its conclusion is success,
# neutral, or skipped: GitHub accepts all three for a required status check, and
# bin/fm-pr-merge.sh's own verifier already treats them as green. A conditional
# required job that GitHub skips must therefore not turn a valid merge into a
# HOLD, so the collector must accept exactly the same three conclusions.
for verdict in neutral skipped; do
  cat > "$TMP/check-runs.json" <<JSON
[{"total_count":1,"check_runs":[{"id":1,"name":"ci","head_sha":"$HEAD","status":"completed","conclusion":"$verdict","started_at":"2026-10-10T00:00:00Z","completed_at":"2026-10-10T00:00:30Z","check_suite":{"id":7},"app":{"id":17,"slug":"github-actions"},"output":{"title":"ok","summary":null,"text":null}}]}]
JSON
  out=$(env "${evidence_env[@]}" "$EVIDENCE" collect "$TASK" "$PR" "$HEAD")
  eq "completed required check with conclusion $verdict is accepted" "$(printf '%s' "$out" | jq -r .status)" PASS
done
cp "$TMP/good-check-runs.json" "$TMP/check-runs.json"

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
# hold rather than pass through an empty risk value. The collector copy resolves
# its sibling scripts and libraries through symlinks, but gets a stub risk policy.
make_evidence_dir() { # <dir> <evidence-script-src>
  local dir=$1 src=$2 f
  mkdir -p "$dir"
  for f in "$ROOT"/bin/*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in fm-merge-evidence.sh|fm-merge-policy.sh) continue;; esac
    ln -sf "$f" "$dir/"
  done
  cp "$src" "$dir/fm-merge-evidence.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/fm-merge-policy.sh"
  chmod +x "$dir/fm-merge-evidence.sh" "$dir/fm-merge-policy.sh"
}
make_evidence_dir "$TMP/empty-bin" "$EVIDENCE"
out=$(env "${evidence_env[@]}" "$TMP/empty-bin/fm-merge-evidence.sh" collect "$TASK" "$PR" "$HEAD")
eq "empty risk classification output holds" "$(printf '%s' "$out" | jq -r .reasons[0])" risk-unknown

# --- the relaxation is reported, not silent ---
# A merge that passed because the plan could not express a gate must say so where
# the captain reads the outcome. bin/fm-merge-outcome-lib.sh appends it to the
# same durable line it already publishes - the parent channel in a mate home, the
# merge wake in a main home - and takes the value from the evidence verdict's
# protection_source through bin/fm-pr-merge.sh.
outcome_state="$TMP/outcome-state"
mkdir -p "$outcome_state"
( . "$ROOT/bin/fm-merge-outcome-lib.sh"
  fm_merge_outcome_report "$TMP/home" "$outcome_state" outcome-task "$PR" self '' "$plan_relaxation" ) >/dev/null 2>&1
eq "the merge outcome reports a plan-relaxed gate" \
  "$(grep -c 'merge landed: outcome-task .* gate-relaxed(unavailable-by-plan)' "$outcome_state/.wake-queue" 2>/dev/null)" 1
outcome_plain="$TMP/outcome-plain"
mkdir -p "$outcome_plain"
( . "$ROOT/bin/fm-merge-outcome-lib.sh"
  fm_merge_outcome_report "$TMP/home" "$outcome_plain" outcome-plain "$PR" self ) >/dev/null 2>&1
eq "an ordinary merge outcome carries no relaxation tag" \
  "$(grep -c 'gate-relaxed' "$outcome_plain/.wake-queue" 2>/dev/null)" 0
( . "$ROOT/bin/fm-merge-outcome-lib.sh"
  fm_merge_outcome_report "$TMP/home" "$outcome_state" outcome-task "$PR" self '' bogus ) >/dev/null 2>&1
eq "an unknown gate relaxation is refused" "$?" 2

echo "# fm-merge-policy.test.sh PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
