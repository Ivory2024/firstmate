#!/usr/bin/env bash
# Disposable live-drive of the branch-protection verification change.
# Drives the REAL bin/fm-merge-evidence.sh and bin/fm-pr-merge.sh in this
# worktree against a throwaway, path-isolated forge fixture (the product's own
# documented isolation seam: the shipped collector is never replaced, only the
# forge CLI it reads is answered by a fixture). Nothing touches the operator's
# real fleet, home, or forge.
#
# Usage: bash drive-protection.sh <worktree> <outdir>
set -u

ROOT=$1
OUT=$2
mkdir -p "$OUT"

echo "==================================================================="
echo "PART A - real bin/fm-merge-evidence.sh (collector + branch-protection)"
echo "worktree: $ROOT"
echo "==================================================================="

A=$(mktemp -d "${TMPDIR:-/tmp}/fm-prot-drive.XXXXXX") || exit 1
trap 'rm -rf "$A"' EXIT
mkdir -p "$A/home/state" "$A/fakebin" "$A/wt"

TASK=protection-drive
PR=https://github.com/example/repo/pull/9
HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

cat > "$A/pr.json" <<JSON
{"author":{"login":"author"},"headRefOid":"$HEAD","baseRefName":"main","changedFiles":1,"files":[{"path":"docs/operations.md"}]}
JSON
cat > "$A/reviews.json" <<JSON
[[{"state":"APPROVED","user":{"login":"reviewer"},"commit_id":"$HEAD","submitted_at":"2026-10-10T00:00:00Z"},{"state":"APPROVED","user":{"login":"captain"},"commit_id":"$HEAD","submitted_at":"2026-10-10T00:01:00Z"}]]
JSON
cat > "$A/protection.json" <<'JSON'
{"required_status_checks":{"contexts":["ci"]},"required_pull_request_reviews":{}}
JSON
# The weakened protection the merge boundary must refuse: the required check the
# decision was made under is gone.
cat > "$A/protection-after.json" <<'JSON'
{"required_status_checks":{"contexts":[]},"required_pull_request_reviews":{}}
JSON
printf '%s\n' '[[]]' > "$A/rulesets.json"
cat > "$A/check-runs.json" <<JSON
[{"total_count":1,"check_runs":[{"id":1,"name":"ci","head_sha":"$HEAD","status":"completed","conclusion":"success","started_at":"2026-10-10T00:00:00Z","completed_at":"2026-10-10T00:00:30Z","check_suite":{"id":7},"app":{"id":17,"slug":"github-actions"},"output":{"title":"ok","summary":null,"text":null}}]}]
JSON
printf '%s\n' '[[]]' > "$A/statuses.json"

cat > "$A/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "pr view") cat "$FM_TEST_PR_JSON" ;;
  "api --paginate")
    case "$*" in
      *check-runs*) cat "$FM_TEST_CHECK_RUNS_JSON";;
      *statuses*) cat "$FM_TEST_STATUSES_JSON";;
      *pulls/9/reviews*) cat "$FM_TEST_REVIEWS_JSON";;
      *pulls/9/files*) jq -c '[.files | map({filename: .path})]' "$FM_TEST_PR_JSON";;
      *rules/branches/*) cat "$FM_TEST_RULESETS_JSON";;
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
        if [ -n "${FM_TEST_PROTECTION_AFTER:-}" ] && [ -f "${FM_TEST_PROTECTION_SWITCH:-/nonexistent}" ]; then
          cat "$FM_TEST_PROTECTION_AFTER"; exit 0
        fi
        cat "$FM_TEST_PROTECTION_JSON";;
      *) exit 2;;
    esac
    ;;
esac
SH
cat > "$A/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
cat "$FM_TEST_STATUS"
SH
chmod +x "$A/fakebin/gh" "$A/fakebin/no-mistakes"

cat > "$A/status" <<JSON
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
printf '%s\n' 'done: validated' > "$A/home/state/$TASK.status"
printf 'worktree=%s\n' "$A/wt" > "$A/home/state/$TASK.meta"

ev_env=(PATH="$A/fakebin:$PATH" FM_HOME="$A/home" FM_STATE_OVERRIDE="$A/home/state" \
  FM_TEST_PR_JSON="$A/pr.json" FM_TEST_REVIEWS_JSON="$A/reviews.json" \
  FM_TEST_PROTECTION_JSON="$A/protection.json" FM_TEST_RULESETS_JSON="$A/rulesets.json" \
  FM_TEST_CHECK_RUNS_JSON="$A/check-runs.json" FM_TEST_STATUSES_JSON="$A/statuses.json" \
  FM_TEST_STATUS="$A/status")

show() { printf '\n$ %s\n%s\n' "$1" "$2"; }

echo
echo "--- A1: collect a complete fixture: protection read from the forge ---"
out=$(env "${ev_env[@]}" "$ROOT/bin/fm-merge-evidence.sh" collect "$TASK" "$PR" "$HEAD")
show "fm-merge-evidence.sh collect $TASK $PR $HEAD" "$out"
SCOPE=$(printf '%s' "$out" | jq -r .protection_scope)
printf 'recorded protection_scope=%s\n' "$SCOPE"

echo
echo "--- A2: re-verify the same protection immediately before a merge ---"
out=$(env "${ev_env[@]}" "$ROOT/bin/fm-merge-evidence.sh" branch-protection "$PR" "$SCOPE")
show "fm-merge-evidence.sh branch-protection $PR $SCOPE" "$out"

echo
echo "--- A3: protection weakened after collection (TOCTOU) -> fail closed ---"
: > "$A/switch"
out=$(env "${ev_env[@]}" FM_TEST_PROTECTION_AFTER="$A/protection-after.json" \
  FM_TEST_PROTECTION_SWITCH="$A/switch" \
  "$ROOT/bin/fm-merge-evidence.sh" branch-protection "$PR" "$SCOPE")
show "branch-protection (protection weakened since collection)" "$out"

echo
echo "--- A4: base branch has no protection at all -> named gap, fail closed ---"
out=$(env "${ev_env[@]}" FM_TEST_PROTECTION_MISSING=yes \
  "$ROOT/bin/fm-merge-evidence.sh" branch-protection "$PR" "$SCOPE")
show "branch-protection (no protection on base branch)" "$out"

echo
echo "--- A5: caller cannot substitute a scope (malformed digest) ---"
set +e
out=$(env "${ev_env[@]}" "$ROOT/bin/fm-merge-evidence.sh" branch-protection "$PR" nothex 2>&1)
rc=$?
set -e
show "branch-protection $PR nothex" "$out"
printf 'exit code=%s\n' "$rc"

echo
echo "--- A6: re-verification is GitHub-only; a GitLab MR is refused ---"
set +e
out=$(env "${ev_env[@]}" "$ROOT/bin/fm-merge-evidence.sh" branch-protection \
  https://gitlab.example/group/project/-/merge_requests/7 "$SCOPE" 2>&1)
rc=$?
set -e
show "branch-protection <gitlab mr>" "$out"
printf 'exit code=%s\n' "$rc"

echo
echo "==================================================================="
echo "PART B - real bin/fm-pr-merge.sh merge boundary"
echo "==================================================================="

. "$ROOT/tests/lib.sh"
. "$ROOT/tests/fixtures.sh"
# Load the suite's helper and test functions without running its invocation
# list, then invoke only the two merge-boundary cases this change owns.
sed -e '/^test_[a-z0-9_]*$/d' \
  -e "s|\$(dirname \"\${BASH_SOURCE\[0\]}\")|$ROOT/tests|g" \
  "$ROOT/tests/fm-pr-merge.test.sh" > "$A/preamble.sh"
# shellcheck disable=SC1090
. "$A/preamble.sh"

echo
echo "--- B1: complete fixture -> the merge proceeds (gh pr merge is called) ---"
test_evidence_collector_passes_on_a_complete_fixture
B1="$TMP_ROOT/evidence-complete-fixture"
echo "merge stderr:"; cat "$B1/stderr"
echo "forge calls recorded:"; cat "$B1/gh.log"
cp "$B1/gh.log" "$OUT/merge-happy-gh-calls.log"

echo
echo "--- B2: protection changed after collection -> merge refuses, forge untouched ---"
set +e
test_merge_refuses_when_protection_changes_after_collection
rc=$?
set -e
B2="$TMP_ROOT/protection-changed-after-collection"
echo "merge exit path rc=$rc"
echo "merge stderr:"; cat "$B2/stderr"
echo "forge calls recorded:"; cat "$B2/gh.log"
cp "$B2/stderr" "$OUT/merge-protection-changed-stderr.txt"
cp "$B2/gh.log" "$OUT/merge-protection-changed-gh-calls.log"

echo
echo "--- B3: #135's recorded-decision line still enforced after the rebase ---"
test_merge_decision_is_persisted_and_survives_restart
test_merge_refuses_when_the_decision_cannot_be_recorded

echo
echo "DONE"
