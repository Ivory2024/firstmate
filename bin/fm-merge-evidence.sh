#!/usr/bin/env bash
# Read-only collector for the fixed Gate 0 forge and task-state evidence sources.
# Usage: fm-merge-evidence.sh collect <task-id> <pr-url> <expected-head>
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
. "$SCRIPT_DIR/fm-pr-lib.sh"
. "$SCRIPT_DIR/fm-classify-lib.sh"

hold() {
  jq -cn --arg reason "$1" --arg head "${LIVE_HEAD:-}" \
    '{status:"HOLD",head_sha:$head,reasons:[$reason]}'
}

valid_sha() { [[ ${1:-} =~ ^[0-9a-fA-F]{40}$ ]]; }

record_is_trusted_local_file() {
  local path=$1 mode links
  [ -f "$path" ] && [ ! -L "$path" ] && [ -O "$path" ] || return 1
  mode=$(stat -f '%Lp' "$path" 2>/dev/null) || mode=
  case "$mode" in *[!0-7]*|'') mode=$(stat -c '%a' "$path" 2>/dev/null) || return 1;; esac
  links=$(stat -f '%l' "$path" 2>/dev/null) || links=
  case "$links" in *[!0-9]*|'') links=$(stat -c '%h' "$path" 2>/dev/null) || return 1;; esac
  [ "$links" = 1 ] || return 1
  case "$mode" in *[2367][0-9]|*[0-9][2367]) return 1;; esac
}

test_evidence_ok() {
  local task_id=$1 head=$2 pr=$3 run_status=${4:-} evidence_file=''
  if [ -n "$run_status" ] && printf '%s\n' "$run_status" | awk -v head="$head" -v pr="$pr" '
    /^  head_sha: / { h=$2; gsub(/"/, "", h) }
    /^  pr: / { p=$2; gsub(/"/, "", p) }
    /^  status: / { s=$2; gsub(/"/, "", s) }
    /^  findings: / { f=$2; gsub(/"/, "", f) }
    /^    test,/ { split($0,a,","); ts=a[2]; tf=a[3] }
    /^outcome: / { o=$2; gsub(/"/, "", o) }
    END { exit !(h == head && p == pr && s == "completed" && f == 0 && ts == "completed" && tf == 0 && o ~ /^passed/) }
  '; then
    return 0
  fi
  evidence_file="$STATE/$task_id.test-evidence"
  record_is_trusted_local_file "$evidence_file" || return 1
  jq -e --arg head "$head" '(.command | type == "string" and length > 0) and .exit == 0 and .sha == $head and .verdict == "PASS"' "$evidence_file" >/dev/null 2>&1
}

collect_github() {
  local task_id=$1 expected=$2 pr_json reviews protection rulesets
  local author base owner repo number check_count review_ok=false findings test_ok=false
  local evidence_file='' approval_file scope paths risk approval_ok=false run_status path
  local -a changed_paths=()
  owner=$FM_PR_OWNER repo=$FM_PR_REPO number=$FM_PR_NUMBER
  pr_json=$(gh pr view "$FM_PR_URL" --json author,headRefOid,baseRefName,statusCheckRollup,files 2>/dev/null) \
    || { hold forge-pr-unreadable; return 0; }
  LIVE_HEAD=$(printf '%s' "$pr_json" | jq -er '.headRefOid | select(type == "string")' 2>/dev/null) \
    || { hold forge-head-unreadable; return 0; }
  valid_sha "$LIVE_HEAD" || { hold forge-head-invalid; return 0; }
  [ "$LIVE_HEAD" = "$expected" ] || { hold stale-head; return 0; }
  author=$(printf '%s' "$pr_json" | jq -er '.author.login | select(type == "string" and length > 0)' 2>/dev/null) \
    || { hold forge-author-unreadable; return 0; }
  base=$(printf '%s' "$pr_json" | jq -er '.baseRefName | select(type == "string" and length > 0)' 2>/dev/null) \
    || { hold forge-base-unreadable; return 0; }
  check_count=$(printf '%s' "$pr_json" | jq -er '.statusCheckRollup | if type == "array" then length else error("missing") end' 2>/dev/null) \
    || { hold ci-unreadable; return 0; }
  [ "$check_count" -gt 0 ] || { hold CI_NOT_CONFIGURED; return 0; }
  if ! printf '%s' "$pr_json" | jq -e 'all(.statusCheckRollup[];
      if .__typename == "CheckRun" then .status == "COMPLETED" and (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED")
      elif .__typename == "StatusContext" then .state == "SUCCESS" else false end)' >/dev/null 2>&1; then
    hold ci-not-green; return 0
  fi
  local base_encoded
  base_encoded=$(jq -rn --arg value "$base" '$value | @uri') || { hold base-encode-failed; return 0; }
  protection=$(gh api "repos/$owner/$repo/branches/$base_encoded/protection" 2>/dev/null) \
    || { hold branch-protection-unreadable; return 0; }
  printf '%s' "$protection" | jq -e 'type == "object" and has("required_status_checks") and has("required_pull_request_reviews")' >/dev/null 2>&1 \
    || { hold branch-protection-incomplete; return 0; }
  rulesets=$(gh api "repos/$owner/$repo/rulesets?includes_parents=true" 2>/dev/null) \
    || { hold rulesets-unreadable; return 0; }
  printf '%s' "$rulesets" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || { hold rulesets-invalid; return 0; }
  reviews=$(gh api --paginate "repos/$owner/$repo/pulls/$number/reviews" 2>/dev/null) \
    || reviews='[]'
  review_ok=$(printf '%s' "$reviews" | jq -r --arg author "$author" --arg head "$LIVE_HEAD" \
    'if type != "array" then false else any(.[]; .state == "APPROVED" and .user.login != $author and .commit_id == $head) end' 2>/dev/null) || review_ok=false
  if [ "$review_ok" != true ]; then
    evidence_file="$STATE/$task_id.review-evidence"
    if record_is_trusted_local_file "$evidence_file"; then
      review_ok=$(jq -r --arg head "$LIVE_HEAD" --arg author "$author" \
        '(.reviewer | type == "string" and length > 0) and (.model | type == "string" and length > 0) and (.implementer_model | type == "string" and length > 0) and .reviewer != $author and .model != .implementer_model and .reviewed_sha == $head and .verdict == "APPROVED"' "$evidence_file" 2>/dev/null) || review_ok=false
    fi
  fi
  [ "$review_ok" = true ] || { hold independent-review-missing-or-stale; return 0; }
  [ -f "$STATE/$task_id.status" ] && [ -r "$STATE/$task_id.status" ] && [ ! -L "$STATE/$task_id.status" ] \
    || { hold task-ledger-unreadable; return 0; }
  findings=$(status_open_decisions "$STATE/$task_id.status" 2>/dev/null) || { hold task-ledger-unreadable; return 0; }
  [ -z "$findings" ] || { hold task-open-decisions; return 0; }
  run_status=''
  if command -v no-mistakes >/dev/null 2>&1; then run_status=$(no-mistakes axi status 2>/dev/null) || run_status=''; fi
  test_evidence_ok "$task_id" "$LIVE_HEAD" "$FM_PR_URL" "$run_status" || { hold test-evidence-missing-or-stale; return 0; }
  paths=$(printf '%s' "$pr_json" | jq -r '.files[]?.path // empty' 2>/dev/null) || { hold changed-files-unreadable; return 0; }
  [ -n "$paths" ] || { hold changed-files-unreadable; return 0; }
  scope=$(printf '%s\n' "$paths" | LC_ALL=C sort -u | shasum -a 256 | awk '{print $1}') || { hold scope-unreadable; return 0; }
  while IFS= read -r path; do changed_paths+=("$path"); done <<< "$paths"
  risk=$("$SCRIPT_DIR/fm-merge-policy.sh" classify-risk "${changed_paths[@]}" 2>/dev/null) || { hold risk-unknown; return 0; }
  if [ "$risk" = HIGH ]; then
    approval_file="$STATE/$task_id.gate0-approval"
    if record_is_trusted_local_file "$approval_file"; then
      approval_ok=$(jq -r --arg pr "$FM_PR_URL" --arg head "$LIVE_HEAD" --arg scope "$scope" \
        '.pr == $pr and .approved_sha == $head and .scope == $scope and .signer == "captain" and (.at | type == "string" and length > 0)' "$approval_file" 2>/dev/null) || approval_ok=false
    fi
    [ "$approval_ok" = true ] || { hold high-risk-captain-approval-missing-or-stale; return 0; }
  fi
  jq -cn --arg head "$LIVE_HEAD" --arg risk "$risk" --arg scope "$scope" \
    '{status:"PASS",head_sha:$head,risk:$risk,scope:$scope,reasons:[]}'
}

collect_gitlab() {
  local task_id=$1 expected=$2 encoded pr_json pipeline_status approval_file evidence_file
  local author approvals review_ok=false findings run_status changes paths scope risk path approval_ok=false
  local -a changed_paths=()
  encoded=$(jq -rn --arg value "$FM_PR_PATH" '$value | @uri') || { hold project-encode-failed; return 0; }
  local project_url="https://$FM_PR_HOST/$FM_PR_PATH"
  pr_json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$FM_PR_NUMBER" -R "$project_url" -F json 2>/dev/null) \
    || { hold forge-mr-unreadable; return 0; }
  LIVE_HEAD=$(printf '%s' "$pr_json" | jq -er '.sha | select(type == "string")' 2>/dev/null) \
    || { hold forge-head-unreadable; return 0; }
  valid_sha "$LIVE_HEAD" || { hold forge-head-invalid; return 0; }
  [ "$LIVE_HEAD" = "$expected" ] || { hold stale-head; return 0; }
  pipeline_status=$(printf '%s' "$pr_json" | jq -r --arg head "$LIVE_HEAD" '.head_pipeline | select(.sha == $head) | .status // ""' 2>/dev/null) || pipeline_status=''
  [ "$pipeline_status" = success ] || { hold ci-not-green-or-not-configured; return 0; }
  local protected
  protected=$(GITLAB_HOST="$FM_PR_HOST" glab api "projects/$encoded/protected_branches" 2>/dev/null) \
    || { hold protected-branches-unreadable; return 0; }
  printf '%s' "$protected" | jq -e --arg branch "$(printf '%s' "$pr_json" | jq -r '.target_branch // empty')" \
    'type == "array" and any(.[]; .name == $branch)' >/dev/null 2>&1 || { hold protected-branch-missing; return 0; }
  author=$(printf '%s' "$pr_json" | jq -er '.author.username | select(type == "string" and length > 0)' 2>/dev/null) \
    || { hold forge-author-unreadable; return 0; }
  approvals=$(GITLAB_HOST="$FM_PR_HOST" glab api "projects/$encoded/merge_requests/$FM_PR_NUMBER/approvals" 2>/dev/null) \
    || { hold forge-approvals-unreadable; return 0; }
  review_ok=$(printf '%s' "$approvals" | jq -r --arg author "$author" \
    'if (.approved_by | type) != "array" then false else any(.approved_by[]; .user.username != $author) end' 2>/dev/null) || review_ok=false
  evidence_file="$STATE/$task_id.review-evidence"
  record_is_trusted_local_file "$evidence_file" || { hold independent-review-evidence-unavailable; return 0; }
  jq -e --arg head "$LIVE_HEAD" --arg author "$author" \
    '(.reviewer | type == "string" and length > 0) and .reviewer != $author and (.model | type == "string" and length > 0) and (.implementer_model | type == "string" and length > 0) and .model != .implementer_model and .reviewed_sha == $head and .verdict == "APPROVED"' "$evidence_file" >/dev/null 2>&1 \
    && [ "$review_ok" = true ] || { hold independent-review-missing-or-stale; return 0; }
  local findings
  [ -f "$STATE/$task_id.status" ] && [ -r "$STATE/$task_id.status" ] && [ ! -L "$STATE/$task_id.status" ] \
    || { hold task-ledger-unreadable; return 0; }
  findings=$(status_open_decisions "$STATE/$task_id.status" 2>/dev/null) || { hold task-ledger-unreadable; return 0; }
  [ -z "$findings" ] || { hold task-open-decisions; return 0; }
  run_status=''
  if command -v no-mistakes >/dev/null 2>&1; then run_status=$(no-mistakes axi status 2>/dev/null) || run_status=''; fi
  test_evidence_ok "$task_id" "$LIVE_HEAD" "$FM_PR_URL" "$run_status" || { hold test-evidence-missing-or-stale; return 0; }
  changes=$(GITLAB_HOST="$FM_PR_HOST" glab api "projects/$encoded/merge_requests/$FM_PR_NUMBER/changes" 2>/dev/null) \
    || { hold changed-files-unreadable; return 0; }
  paths=$(printf '%s' "$changes" | jq -r '.changes[]?.new_path // empty' 2>/dev/null) || { hold changed-files-unreadable; return 0; }
  [ -n "$paths" ] || { hold changed-files-unreadable; return 0; }
  scope=$(printf '%s\n' "$paths" | LC_ALL=C sort -u | shasum -a 256 | awk '{print $1}') || { hold scope-unreadable; return 0; }
  while IFS= read -r path; do changed_paths+=("$path"); done <<< "$paths"
  risk=$("$SCRIPT_DIR/fm-merge-policy.sh" classify-risk "${changed_paths[@]}" 2>/dev/null) || { hold risk-unknown; return 0; }
  if [ "$risk" = HIGH ]; then
    approval_file="$STATE/$task_id.gate0-approval"
    if record_is_trusted_local_file "$approval_file"; then
      approval_ok=$(jq -r --arg pr "$FM_PR_URL" --arg head "$LIVE_HEAD" --arg scope "$scope" \
        '.pr == $pr and .approved_sha == $head and .scope == $scope and .signer == "captain" and (.at | type == "string" and length > 0)' "$approval_file" 2>/dev/null) || approval_ok=false
    fi
    [ "$approval_ok" = true ] || { hold high-risk-captain-approval-missing-or-stale; return 0; }
  fi
  jq -cn --arg head "$LIVE_HEAD" --arg risk "$risk" --arg scope "$scope" \
    '{status:"PASS",head_sha:$head,risk:$risk,scope:$scope,reasons:[]}'
}

if [ "$#" -ne 4 ] || [ "$1" != collect ] || ! fm_pr_task_id_valid "$2" || ! fm_pr_url_parse "$3" || ! valid_sha "$4"; then
  echo 'usage: fm-merge-evidence.sh collect <task-id> <pr-url> <expected-head>' >&2
  exit 2
fi
case "$FM_PR_PROVIDER" in
  github) collect_github "$2" "$4" ;;
  gitlab) collect_gitlab "$2" "$4" ;;
  *) hold unsupported-provider ;;
esac
