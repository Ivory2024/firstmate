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

test_evidence_ok() {
  local head=$1 pr=$2 run_status=$3
  [ -n "$run_status" ] || return 1
  printf '%s\n' "$run_status" | awk -v head="$head" -v pr="$pr" '
    /^  head_sha: / { h=$2; gsub(/"/, "", h) }
    /^  pr: / { p=$2; gsub(/"/, "", p) }
    /^  status: / { s=$2; gsub(/"/, "", s) }
    /^  findings: / { f=$2; gsub(/"/, "", f) }
    /^    test,/ { split($0,a,","); ts=a[2]; tf=a[3] }
    /^outcome: / { o=$2; gsub(/"/, "", o) }
    END { exit !(h == head && p == pr && s == "completed" && f == 0 && ts == "completed" && tf == 0 && o ~ /^passed/) }
  '
}

github_required_checks_ok() {
  local protection=$1 rulesets=$2 check_runs=$3 statuses=$4 head=$5 required
  required=$(jq -cn --argjson protection "$protection" --argjson rulesets "$rulesets" '
    [($protection.required_status_checks.contexts // [] | map({context:., app_id:null})),
     ($protection.required_status_checks.checks // [] | map({context:.context, app_id:(.app_id // null)})),
     ([$rulesets[] | select(.enforcement == "active") | .rules[]? |
       select(.type == "required_status_checks") | .parameters.required_status_checks[]? |
       {context:.context, app_id:(.integration_id // .app_id // null)}])]
    | flatten | map(select(.context | type == "string" and length > 0)) | unique_by([.context,.app_id])') || return 1
  [ "$(printf '%s' "$required" | jq 'length')" -gt 0 ] || return 1
  jq -en --argjson required "$required" --argjson runs "$check_runs" --argjson statuses "$statuses" --arg head "$head" '
    ($runs | type == "array") and ($statuses | type == "array") and
    all($required[]; . as $requirement |
      (any($runs[]; .name == $requirement.context and .head_sha == $head and .status == "completed" and .conclusion == "success" and
        ($requirement.app_id == null or .app.id == $requirement.app_id)) or
       ($requirement.app_id == null and any($statuses[]; .context == $requirement.context and .sha == $head and .state == "success"))))
  ' >/dev/null 2>&1
}

collect_github() {
  local task_id=$1 expected=$2 pr_json reviews protection rulesets check_runs statuses check_runs_json statuses_json captain
  local author base owner repo number review_ok=false findings run_status path
  local approval_ok=false scope paths risk
  local -a changed_paths=()
  owner=$FM_PR_OWNER repo=$FM_PR_REPO number=$FM_PR_NUMBER
  pr_json=$(gh pr view "$FM_PR_URL" --json author,headRefOid,baseRefName,files 2>/dev/null) \
    || { hold forge-pr-unreadable; return 0; }
  LIVE_HEAD=$(printf '%s' "$pr_json" | jq -er '.headRefOid | select(type == "string")' 2>/dev/null) \
    || { hold forge-head-unreadable; return 0; }
  valid_sha "$LIVE_HEAD" || { hold forge-head-invalid; return 0; }
  [ "$LIVE_HEAD" = "$expected" ] || { hold stale-head; return 0; }
  author=$(printf '%s' "$pr_json" | jq -er '.author.login | select(type == "string" and length > 0)' 2>/dev/null) \
    || { hold forge-author-unreadable; return 0; }
  base=$(printf '%s' "$pr_json" | jq -er '.baseRefName | select(type == "string" and length > 0)' 2>/dev/null) \
    || { hold forge-base-unreadable; return 0; }
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
  check_runs_json=$(gh api --paginate --slurp "repos/$owner/$repo/commits/$LIVE_HEAD/check-runs?per_page=100" 2>/dev/null) \
    || { hold required-checks-unreadable; return 0; }
  check_runs=$(printf '%s' "$check_runs_json" | jq -ce '[.[] | .check_runs[]?]') \
    || { hold required-checks-invalid; return 0; }
  statuses_json=$(gh api --paginate --slurp "repos/$owner/$repo/commits/$LIVE_HEAD/statuses?per_page=100" 2>/dev/null) \
    || { hold required-statuses-unreadable; return 0; }
  statuses=$(printf '%s' "$statuses_json" | jq -ce '[.[] | .[]?]') \
    || { hold required-statuses-invalid; return 0; }
  github_required_checks_ok "$protection" "$rulesets" "$check_runs" "$statuses" "$LIVE_HEAD" \
    || { hold required-checks-not-green-or-unconfigured; return 0; }
  reviews=$(gh api --paginate --slurp "repos/$owner/$repo/pulls/$number/reviews" 2>/dev/null) \
    || { hold forge-reviews-unreadable; return 0; }
  reviews=$(printf '%s' "$reviews" | jq -ce '[.[][]?] | if all(.[]; type == "object") then . else error("invalid review pages") end') \
    || { hold forge-reviews-invalid; return 0; }
  captain=$(gh api user --jq .login 2>/dev/null) || { hold captain-identity-unreadable; return 0; }
  [ -n "$captain" ] || { hold captain-identity-unreadable; return 0; }
  review_ok=$(printf '%s' "$reviews" | jq -r --arg author "$author" --arg head "$LIVE_HEAD" '
    . as $all | ([.[].user.login] | unique) as $users |
    any($users[]; . as $u | ([$all[] | select(.user.login == $u)] | sort_by(.submitted_at // "") | last) as $r |
      $r.state == "APPROVED" and $r.user.login != $author and $r.commit_id == $head)') \
    || review_ok=false
  [ "$review_ok" = true ] || { hold independent-review-missing-or-stale; return 0; }
  approval_ok=$(printf '%s' "$reviews" | jq -r --arg captain "$captain" --arg head "$LIVE_HEAD" \
    'any(.[]; .user.login == $captain and .state == "APPROVED" and .commit_id == $head)') || approval_ok=false
  [ -f "$STATE/$task_id.status" ] && [ -r "$STATE/$task_id.status" ] && [ ! -L "$STATE/$task_id.status" ] \
    || { hold task-ledger-unreadable; return 0; }
  findings=$(status_open_decisions "$STATE/$task_id.status" 2>/dev/null) || { hold task-ledger-unreadable; return 0; }
  [ -z "$findings" ] || { hold task-open-decisions; return 0; }
  run_status=''
  if command -v no-mistakes >/dev/null 2>&1; then run_status=$(no-mistakes axi status 2>/dev/null) || run_status=''; fi
  test_evidence_ok "$LIVE_HEAD" "$FM_PR_URL" "$run_status" || { hold test-evidence-missing-or-stale; return 0; }
  paths=$(printf '%s' "$pr_json" | jq -r '.files[]?.path // empty' 2>/dev/null) || { hold changed-files-unreadable; return 0; }
  [ -n "$paths" ] || { hold changed-files-unreadable; return 0; }
  scope=$(printf '%s\n' "$paths" | LC_ALL=C sort -u | shasum -a 256 | awk '{print $1}') || { hold scope-unreadable; return 0; }
  while IFS= read -r path; do changed_paths+=("$path"); done <<< "$paths"
  risk=$("$SCRIPT_DIR/fm-merge-policy.sh" classify-risk "${changed_paths[@]}" 2>/dev/null) || { hold risk-unknown; return 0; }
  if [ "$risk" = HIGH ]; then
    [ "$approval_ok" = true ] || { hold high-risk-captain-approval-missing-or-stale; return 0; }
  fi
  jq -cn --arg head "$LIVE_HEAD" --arg risk "$risk" --arg scope "$scope" \
    '{status:"PASS",head_sha:$head,risk:$risk,scope:$scope,reasons:[]}'
}

collect_gitlab() {
  local task_id=$1 expected=$2 encoded pr_json pipeline_id pipeline_jobs approvals approval_settings
  local author review_ok=false findings run_status changes paths scope risk path
  local -a changed_paths=()
  encoded=$(jq -rn --arg value "$FM_PR_PATH" '$value | @uri') || { hold project-encode-failed; return 0; }
  local project_url="https://$FM_PR_HOST/$FM_PR_PATH"
  pr_json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$FM_PR_NUMBER" -R "$project_url" -F json 2>/dev/null) \
    || { hold forge-mr-unreadable; return 0; }
  LIVE_HEAD=$(printf '%s' "$pr_json" | jq -er '.sha | select(type == "string")' 2>/dev/null) \
    || { hold forge-head-unreadable; return 0; }
  valid_sha "$LIVE_HEAD" || { hold forge-head-invalid; return 0; }
  [ "$LIVE_HEAD" = "$expected" ] || { hold stale-head; return 0; }
  pipeline_id=$(printf '%s' "$pr_json" | jq -er --arg head "$LIVE_HEAD" '.head_pipeline | select(.sha == $head) | .id | select(type == "number")' 2>/dev/null) \
    || { hold pipeline-unreadable; return 0; }
  local protected
  protected=$(GITLAB_HOST="$FM_PR_HOST" glab api "projects/$encoded/protected_branches" 2>/dev/null) \
    || { hold protected-branches-unreadable; return 0; }
  printf '%s' "$protected" | jq -e --arg branch "$(printf '%s' "$pr_json" | jq -r '.target_branch // empty')" \
    'type == "array" and any(.[]; .name == $branch)' >/dev/null 2>&1 || { hold protected-branch-missing; return 0; }
  pipeline_jobs=$(GITLAB_HOST="$FM_PR_HOST" glab api --paginate "projects/$encoded/pipelines/$pipeline_id/jobs?per_page=100" 2>/dev/null) \
    || { hold required-checks-unreadable; return 0; }
  printf '%s' "$pipeline_jobs" | jq -e --arg head "$LIVE_HEAD" \
    'type == "array" and length > 0 and all(.[]; .status == "success" and .commit.id == $head)' >/dev/null 2>&1 \
    || { hold required-checks-not-green-or-unconfigured; return 0; }
  approval_settings=$(GITLAB_HOST="$FM_PR_HOST" glab api "projects/$encoded" 2>/dev/null) \
    || { hold approval-policy-unreadable; return 0; }
  printf '%s' "$approval_settings" | jq -e '.reset_approvals_on_push == true' >/dev/null 2>&1 \
    || { hold approval-head-binding-unverified; return 0; }
  author=$(printf '%s' "$pr_json" | jq -er '.author.username | select(type == "string" and length > 0)' 2>/dev/null) \
    || { hold forge-author-unreadable; return 0; }
  approvals=$(GITLAB_HOST="$FM_PR_HOST" glab api "projects/$encoded/merge_requests/$FM_PR_NUMBER/approvals" 2>/dev/null) \
    || { hold forge-approvals-unreadable; return 0; }
  review_ok=$(printf '%s' "$approvals" | jq -r --arg author "$author" \
    '.approvals_left == 0 and (.approved_by | type == "array") and any(.approved_by[]; .user.username != $author)') || review_ok=false
  [ "$review_ok" = true ] || { hold independent-review-missing-or-stale; return 0; }
  [ -f "$STATE/$task_id.status" ] && [ -r "$STATE/$task_id.status" ] && [ ! -L "$STATE/$task_id.status" ] \
    || { hold task-ledger-unreadable; return 0; }
  findings=$(status_open_decisions "$STATE/$task_id.status" 2>/dev/null) || { hold task-ledger-unreadable; return 0; }
  [ -z "$findings" ] || { hold task-open-decisions; return 0; }
  run_status=''
  if command -v no-mistakes >/dev/null 2>&1; then run_status=$(no-mistakes axi status 2>/dev/null) || run_status=''; fi
  test_evidence_ok "$LIVE_HEAD" "$FM_PR_URL" "$run_status" || { hold test-evidence-missing-or-stale; return 0; }
  changes=$(GITLAB_HOST="$FM_PR_HOST" glab api "projects/$encoded/merge_requests/$FM_PR_NUMBER/changes" 2>/dev/null) \
    || { hold changed-files-unreadable; return 0; }
  paths=$(printf '%s' "$changes" | jq -r '.changes[]?.new_path // empty' 2>/dev/null) || { hold changed-files-unreadable; return 0; }
  [ -n "$paths" ] || { hold changed-files-unreadable; return 0; }
  scope=$(printf '%s\n' "$paths" | LC_ALL=C sort -u | shasum -a 256 | awk '{print $1}') || { hold scope-unreadable; return 0; }
  while IFS= read -r path; do changed_paths+=("$path"); done <<< "$paths"
  risk=$("$SCRIPT_DIR/fm-merge-policy.sh" classify-risk "${changed_paths[@]}" 2>/dev/null) || { hold risk-unknown; return 0; }
  if [ "$risk" = HIGH ]; then
    hold high-risk-captain-approval-missing-or-stale
    return 0
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
