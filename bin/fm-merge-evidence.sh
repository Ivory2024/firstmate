#!/usr/bin/env bash
# Read-only collector for the fixed Gate 0 forge and task-state evidence sources.
# Usage: fm-merge-evidence.sh collect <task-id> <pr-url> <expected-head> [--waived-check <check-name>]
#        fm-merge-evidence.sh branch-protection <pr-url> <expected-protection-scope>
#
# The base branch's protection and its applicable rulesets are read from the
# forge, never taken from a caller flag, and a base branch with no protection at
# all holds as its own named gap. The PASS verdict carries that evidence's
# digest, so the merge boundary can re-read the same two sources immediately
# before the forge command and refuse when protection was removed or weakened
# after collection; `branch-protection` is that re-verification.
#
# A repository whose plan cannot expose branch protection or branch rules at all
# (GitHub's "Upgrade to GitHub Pro or make this repository public" 403, matched
# by bin/fm-pr-lib.sh's github_branch_rules_unavailable_on_plan) answers that same
# refusal on both endpoints, which proves its required set is empty rather than
# unreadable. That case is resolved as "no enforceable required check" instead of
# held, and the PASS verdict then carries `protection_source:
# "unavailable-by-plan"` beside `protection: false` and the same evidence digest,
# so the relaxation is recorded on the verdict rather than inferred from an empty
# source. Every other 403, a 5xx, a permission refusal, an unreadable read, and
# any repository that does carry protection keep the ordinary gate and still
# hold.
#
# --waived-check is the attended single-check waiver carried from
# bin/fm-pr-merge.sh's own --allow-red as an argument bound to this one call, so
# no ambient environment or file can stand in for it. It removes exactly that
# named check from the enforced set; every other configured check must still be
# green, and a repository with no configured check still holds.
#
# The run-evidence read (`no-mistakes axi status`) is bound to the task's own
# worktree, resolved from state/<task>.meta, never to the caller's inherited
# cwd; an unbindable worktree holds instead of reading an unrelated run.
#
# The changed-file set must be COMPLETE before risk is classified, because a
# truncated list hides protected paths and silently downgrades the risk verdict.
# GitHub reads the paginated pulls/<n>/files endpoint and requires its distinct
# path count to equal the PR's own changedFiles count; GitLab rejects an
# overflowing diff and requires changes|length to equal changes_count. Any
# mismatch, overflow, unreadable count, or empty classification output holds.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

hold() {
  jq -cn --arg reason "$1" --arg head "${LIVE_HEAD:-}" \
    '{status:"HOLD",head_sha:$head,reasons:[$reason]}'
}

# The branch-protection re-verification's own verdict shape. It carries no head
# SHA because it decides one question only - whether the protection evidence the
# merge decision was made under is still the same evidence - so a caller cannot
# read a head binding into it that it never proved.
hold_protection() {
  jq -cn --arg reason "$1" \
    '{status:"HOLD",protection:false,protection_scope:"",reasons:[$reason]}'
}

valid_sha() { [[ ${1:-} =~ ^[0-9a-fA-F]{40}$ ]]; }

valid_protection_scope() { [[ ${1:-} =~ ^[0-9a-f]{64}$ ]]; }

# The task's own worktree, from its private metadata. The `axi status` read must
# be bound to this directory, never to the caller's inherited cwd: a supervisor
# shell parked in FM_HOME would otherwise read an unrelated repository's run and
# hold a pull request that has valid evidence. An absent, unreadable, empty, or
# missing worktree cannot bind the read, so the caller holds rather than falling
# back to the ambient directory.
task_worktree() {  # <task-id>
  local wt
  [ -f "$STATE/$1.meta" ] && [ ! -L "$STATE/$1.meta" ] && [ -r "$STATE/$1.meta" ] || return 1
  wt=$(grep '^worktree=' "$STATE/$1.meta" | tail -1 | cut -d= -f2- || true)
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  printf '%s' "$wt"
}

test_evidence_ok() {
  local head=$1 pr=$2 run_status=$3
  [ -n "$run_status" ] || return 1
  # The findings field is required: a status that never states it leaves f
  # unset, and an unset awk variable compares equal to 0, so the gate would
  # pass on evidence it never read. saw_findings keeps that absence fatal.
  printf '%s\n' "$run_status" | awk -v head="$head" -v pr="$pr" '
    /^  head_sha: / { h=$2; gsub(/"/, "", h) }
    /^  pr: / { p=$2; gsub(/"/, "", p) }
    /^  status: / { s=$2; gsub(/"/, "", s) }
    /^  findings: / { f=$2; gsub(/"/, "", f); saw_findings=1 }
    /^    test,/ { split($0,a,","); ts=a[2]; tf=a[3] }
    /^outcome: / { o=$2; gsub(/"/, "", o) }
    END { exit !(h == head && p == pr && s == "completed" && saw_findings && (f == 0 || f == "none") && ts == "completed" && tf == 0 && o ~ /^passed/) }
  '
}

github_required_checks_ok() {
  local protection=$1 rulesets=$2 check_runs=$3 statuses=$4 head=$5 waived=${6:-} required
  required=$(jq -cn --argjson protection "$protection" --argjson rulesets "$rulesets" '
    [($protection.required_status_checks.contexts // [] | map({context:., app_id:null})),
     ($protection.required_status_checks.checks // [] | map({context:.context, app_id:(.app_id // null)})),
     ([$rulesets[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]? |
       {context:.context, app_id:(.integration_id // .app_id // null)}])]
    | flatten | map(select(.context | type == "string" and length > 0)) | unique_by([.context,.app_id])') || return 1
  # A repository that configures no required check still holds. Only after that
  # is the attended single-check waiver applied, so waiving every configured
  # check leaves an empty enforced set instead of an "unconfigured" refusal.
  [ "$(printf '%s' "$required" | jq 'length')" -gt 0 ] || return 1
  required=$(printf '%s' "$required" | jq -c --arg waived "$waived" 'map(select(.context != $waived))') || return 1
  jq -en --argjson required "$required" --argjson runs "$check_runs" --argjson statuses "$statuses" --arg head "$head" '
    ($runs | type == "array") and ($statuses | type == "array") and
    all($required[]; . as $requirement |
      ([$runs[] | select(.name == $requirement.context and .head_sha == $head and
        ($requirement.app_id == null or .app.id == $requirement.app_id))]) as $matching_runs |
      (if $requirement.app_id == null then
        [$statuses[] | select(.context == $requirement.context and .sha == $head)]
       else [] end) as $matching_statuses |
      (all($matching_runs[]; (.started_at | type == "string" and length > 0) and
        (.id | type == "number") and
        (.app.id | type == "number") and (.status | type == "string") and
        ((.conclusion == null) or (.conclusion | type == "string"))) and
       all($matching_statuses[]; (.created_at | type == "string" and length > 0) and
        (.id | type == "number") and (.state | type == "string"))) as $ordered |
      if ((($matching_runs | length) + ($matching_statuses | length)) == 0) or ($ordered | not) then false
      else
        # A completed required check is green to GitHub when its conclusion is
        # success, neutral, or skipped, so a conditional required job that GitHub
        # skips must not turn a valid merge into a HOLD. This is the same set the
        # verifier in bin/fm-pr-merge.sh accepts, so the collector and the
        # verifier agree on what counts as a passing required check.
        ([$matching_runs[] | {time:.started_at,success:(.status == "completed" and (.conclusion == "success" or .conclusion == "neutral" or .conclusion == "skipped"))} ] +
         [$matching_statuses[] | {time:.created_at,success:(.state == "success")}]) as $results |
        ($results | map(.time) | max) as $latest_time |
        all($results[] | select(.time == $latest_time); .success)
      end)
  ' >/dev/null 2>&1
}

gitlab_required_checks_ok() {
  local protected=$1 pipeline_jobs=$2 approvals=$3 head=$4 branch=$5
  local required_pipelines approval_rules
  required_pipelines=$(printf '%s' "$protected" | jq -r --arg branch "$branch" '
    .[] | select(.name == $branch) | .required_pipeline?.id // empty' 2>/dev/null) || return 1
  approval_rules=$(printf '%s' "$protected" | jq -c --arg branch "$branch" '
    .[] | select(.name == $branch) | .approval_rules // []' 2>/dev/null) || return 1
  [ -n "$required_pipelines" ] || [ "$(printf '%s' "$approval_rules" | jq 'length')" -gt 0 ] || return 1
  if [ -n "$required_pipelines" ]; then
    printf '%s' "$pipeline_jobs" | jq -e --arg head "$head" --argjson required "$(printf '%s' "$required_pipelines" | jq -Rs 'split("\n") | map(select(length > 0) | tonumber)')" --argjson jobs "$pipeline_jobs" '
      ($required | type == "array" and length > 0) and
      all($required[]; . as $pid |
        ([$jobs[] | select(.pipeline.id == $pid and .commit.id == $head and .status == "success")] | length > 0)
      )' >/dev/null 2>&1 || return 1
  fi
  if [ "$(printf '%s' "$approval_rules" | jq 'length')" -gt 0 ]; then
    printf '%s' "$approvals" | jq -e --argjson rules "$approval_rules" --argjson appr "$approvals" '
      ($rules | type == "array" and length > 0) and
      all($rules[]; . as $rule |
        (if $rule.approvals_required > 0 then
           ($appr.approved_by | type == "array") and
           ([$appr.approved_by[].user.id] | map(select(. != null)) | length >= ($rule.approvals_required | tonumber))
         else true end)
      )' >/dev/null 2>&1 || return 1
  fi
  return 0
}

# Read the base branch's protection and its applicable rulesets independently
# from the forge. Sets GH_PROTECTION_JSON and GH_RULESETS_JSON and returns 0, or
# returns 1 with GH_PROTECTION_HOLD naming the concrete cause.
#
# A branch protected only by a ruleset has no classic branch protection, so the
# classic endpoint answers 404. That is an empty classic source rather than an
# unreadable one: the applicable rulesets are what enforce its required checks.
# A repository whose plan cannot expose branch protection or branch rules at all
# (GitHub's plan-gated 403, recognised by the shared
# github_branch_rules_unavailable_on_plan) answers that same 403 on both
# endpoints, and each one resolves to an empty source there, because such a
# repository has no protection and no ruleset rule to enforce: the plan cannot
# expose them, this collector did not fail to read them. Any other failure still
# holds, and a non-object payload is still incomplete.
# The two plan refusals are additionally recorded together in
# GH_PROTECTION_PLAN_UNAVAILABLE, which is true only when BOTH endpoints answered
# that exact plan refusal. Only then does the caller know the required set is
# provably empty because no source can express one; one endpoint answering it
# while the other still reads is an ordinary evidence read, not that proof.
# stderr is captured to its own file rather than merged into the payload, so a
# forge that writes anything to stderr cannot corrupt an otherwise valid read.
GH_PROTECTION_PLAN_UNAVAILABLE=false
read_github_branch_protection() {  # <owner> <repo> <base-encoded>
  local owner=$1 repo=$2 base_encoded=$3 protection_err
  local rulesets_json rulesets_err rulesets_err_text protection_plan_403=false
  GH_PROTECTION_JSON=
  GH_RULESETS_JSON=
  GH_PROTECTION_HOLD=
  GH_PROTECTION_PLAN_UNAVAILABLE=false
  protection_err=$(mktemp "${TMPDIR:-/tmp}/fm-merge-evidence-protection.XXXXXX") || {
    GH_PROTECTION_HOLD='branch-protection-unreadable'
    return 1
  }
  if ! GH_PROTECTION_JSON=$(gh api "repos/$owner/$repo/branches/$base_encoded/protection" 2>"$protection_err"); then
    if grep -q 'HTTP 404' "$protection_err"; then
      GH_PROTECTION_JSON='{}'
    elif github_branch_rules_unavailable_on_plan "$(cat "$protection_err" 2>/dev/null)"; then
      GH_PROTECTION_JSON='{}'
      protection_plan_403=true
    else
      rm -f "$protection_err"
      GH_PROTECTION_HOLD='branch-protection-unreadable'
      return 1
    fi
  fi
  rm -f "$protection_err"
  printf '%s' "$GH_PROTECTION_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 || {
    GH_PROTECTION_HOLD='branch-protection-incomplete'
    return 1
  }
  rulesets_err=$(mktemp "${TMPDIR:-/tmp}/fm-merge-evidence-rulesets.XXXXXX") || {
    GH_PROTECTION_HOLD='rulesets-unreadable'
    return 1
  }
  if rulesets_json=$(gh api --paginate --slurp "repos/$owner/$repo/rules/branches/$base_encoded" 2>"$rulesets_err"); then
    rm -f "$rulesets_err"
  else
    rulesets_err_text=$(cat "$rulesets_err" 2>/dev/null)
    rm -f "$rulesets_err"
    # A repository whose plan cannot expose branch rules cannot have a rule of
    # any kind, so this specific refusal resolves to an empty source exactly as
    # the merge boundary already resolves it; every other failure stays
    # unreadable. With the classic source also refused by that same plan message,
    # nothing this repository's plan can express is left to enforce, and the read
    # records that so the caller resolves an empty required set instead of
    # holding a source it never failed to read.
    github_branch_rules_unavailable_on_plan "$rulesets_err_text" || {
      GH_PROTECTION_HOLD='rulesets-unreadable'
      return 1
    }
    rulesets_json='[]'
    [ "$protection_plan_403" = true ] && GH_PROTECTION_PLAN_UNAVAILABLE=true
  fi
  GH_RULESETS_JSON=$(printf '%s' "$rulesets_json" | jq -ce 'if type == "array" and all(.[]; type == "array" and all(.[]; type == "object")) then [.[][]] else error("invalid branch rules") end') || {
    GH_PROTECTION_HOLD='rulesets-invalid'
    return 1
  }
  printf '%s' "$GH_RULESETS_JSON" | jq -e 'all(.[]; .type != "required_status_checks" or (.parameters.required_status_checks | type == "array"))' >/dev/null 2>&1 || {
    GH_PROTECTION_HOLD='rulesets-invalid'
    return 1
  }
  return 0
}

# Whether the base branch carries any protection at all: a non-empty classic
# protection object, or at least one applicable rule. Prints true or false.
github_branch_protected() {  # <protection-json> <rulesets-json>
  jq -rn --argjson protection "$1" --argjson rulesets "$2" \
    '(($protection | type) == "object" and ($protection | length) > 0)
     or (($rulesets | type) == "array" and ($rulesets | length) > 0)'
}

# A stable digest of the protection evidence a decision was made under. The
# merge boundary re-reads the same two sources immediately before the forge
# command and refuses when this digest has moved, so protection removed or
# weakened after evidence collection cannot ride on the earlier verdict. The
# rules array is sorted by its own serialization so a reordered response is not
# mistaken for a changed requirement, while any content change is.
github_protection_scope() {  # <protection-json> <rulesets-json>
  jq -S -c -n --argjson protection "$1" --argjson rulesets "$2" \
    '{protection:$protection, rulesets:($rulesets | sort_by(tojson))}' \
    | shasum -a 256 | awk '{print $1}'
}

# Re-verify the base branch's protection immediately before a merge. The base
# branch is read from the forge rather than taken from the caller, the protection
# and ruleset sources are re-read, and the digest must still equal the one the
# merge decision was recorded under. An unreadable source, a branch with no
# protection left, and a changed digest each hold with their own reason.
reverify_github_branch_protection() {  # <pr-url> <expected-protection-scope>
  local pr_url=$1 expected=$2 pr_json base base_encoded protected scope
  pr_json=$(gh pr view "$pr_url" --json baseRefName 2>/dev/null) || { hold_protection base-branch-unreadable; return 0; }
  base=$(printf '%s' "$pr_json" | jq -er '.baseRefName | select(type == "string" and length > 0)' 2>/dev/null) || {
    hold_protection base-branch-unreadable
    return 0
  }
  base_encoded=$(jq -rn --arg value "$base" '$value | @uri') || { hold_protection base-encode-failed; return 0; }
  read_github_branch_protection "$FM_PR_OWNER" "$FM_PR_REPO" "$base_encoded" || {
    hold_protection "$GH_PROTECTION_HOLD"
    return 0
  }
  # A plan-unavailable repository has no protection and no branch rule the plan
  # could express, so there is no gate whose weakening this re-verification could
  # catch; the decision's own digest is still the binding, so protection that
  # appeared since (a plan change, or a repository made public) digests
  # differently and holds as changed rather than riding on the earlier verdict.
  if [ "$GH_PROTECTION_PLAN_UNAVAILABLE" = true ]; then
    scope=$(github_protection_scope "$GH_PROTECTION_JSON" "$GH_RULESETS_JSON") || {
      hold_protection branch-protection-incomplete
      return 0
    }
    [ "$scope" = "$expected" ] || { hold_protection branch-protection-changed; return 0; }
    jq -cn --arg scope "$scope" \
      '{status:"PASS",protection:false,protection_scope:$scope,protection_source:"unavailable-by-plan",reasons:[]}'
    return 0
  fi
  protected=$(github_branch_protected "$GH_PROTECTION_JSON" "$GH_RULESETS_JSON") || {
    hold_protection branch-protection-incomplete
    return 0
  }
  [ "$protected" = true ] || { hold_protection branch-protection-missing; return 0; }
  scope=$(github_protection_scope "$GH_PROTECTION_JSON" "$GH_RULESETS_JSON") || {
    hold_protection branch-protection-incomplete
    return 0
  }
  [ "$scope" = "$expected" ] || { hold_protection branch-protection-changed; return 0; }
  jq -cn --arg scope "$scope" \
    '{status:"PASS",protection:true,protection_scope:$scope,reasons:[]}'
}

collect_github() {
  local task_id=$1 expected=$2 pr_json reviews protection rulesets check_runs statuses check_runs_json statuses_json captain
  local author base owner repo number review_ok=false findings run_status path
  local approval_ok=false scope paths risk changed_files files_json observed_files
  local -a changed_paths=()
  owner=$FM_PR_OWNER repo=$FM_PR_REPO number=$FM_PR_NUMBER
  pr_json=$(gh pr view "$FM_PR_URL" --json author,headRefOid,baseRefName,changedFiles 2>/dev/null) \
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
  read_github_branch_protection "$owner" "$repo" "$base_encoded" || { hold "$GH_PROTECTION_HOLD"; return 0; }
  protection=$GH_PROTECTION_JSON
  rulesets=$GH_RULESETS_JSON
  local protection_scope protected protection_source=''
  # A repository whose plan cannot expose branch protection or branch rules at
  # all has no classic protection and no ruleset rule, so its required set is
  # provably empty: there is nothing to enforce and nothing to re-verify. That is
  # resolved as "no enforceable required check" rather than held as a missing
  # gate - exactly as bin/fm-pr-merge.sh already resolves the same plan-gated 403
  # for its own required-context and merge-queue reads - and the verdict records
  # protection_source so the relaxation is traceable instead of being inferred
  # from an empty source. Only the plan refusal reaches this branch: every other
  # unreadable read, and every repository that does carry protection, falls to
  # the ordinary gate below and still holds.
  if [ "$GH_PROTECTION_PLAN_UNAVAILABLE" = true ]; then
    protection_source='unavailable-by-plan'
    protection_scope=$(github_protection_scope "$protection" "$rulesets") || { hold branch-protection-incomplete; return 0; }
  else
    protected=$(github_branch_protected "$protection" "$rulesets") || { hold branch-protection-incomplete; return 0; }
    # A base branch with no protection at all is named as its own gap rather than
    # folded into the unconfigured-required-check refusal, because the two mean
    # different things to an operator: one has no gate, the other has a gate with
    # nothing in it.
    [ "$protected" = true ] || { hold branch-protection-missing; return 0; }
    protection_scope=$(github_protection_scope "$protection" "$rulesets") || { hold branch-protection-incomplete; return 0; }
    check_runs_json=$(gh api --paginate --slurp "repos/$owner/$repo/commits/$LIVE_HEAD/check-runs?per_page=100" 2>/dev/null) \
      || { hold required-checks-unreadable; return 0; }
    check_runs=$(printf '%s' "$check_runs_json" | jq -ce '[.[] | .check_runs[]?]') \
      || { hold required-checks-invalid; return 0; }
    statuses_json=$(gh api --paginate --slurp "repos/$owner/$repo/commits/$LIVE_HEAD/statuses?per_page=100" 2>/dev/null) \
      || { hold required-statuses-unreadable; return 0; }
    statuses=$(printf '%s' "$statuses_json" | jq -ce '[.[] | .[]?]') \
      || { hold required-statuses-invalid; return 0; }
    github_required_checks_ok "$protection" "$rulesets" "$check_runs" "$statuses" "$LIVE_HEAD" "$WAIVED_CHECK" \
      || { hold required-checks-not-green-or-unconfigured; return 0; }
  fi
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
  approval_ok=$(printf '%s' "$reviews" | jq -r --arg captain "$captain" --arg head "$LIVE_HEAD" '
    (map(select(.user.login == $captain)) | sort_by(.submitted_at // "") | last) as $r |
    $r != null and $r.state == "APPROVED" and $r.commit_id == $head') || approval_ok=false
  [ -f "$STATE/$task_id.status" ] && [ -r "$STATE/$task_id.status" ] && [ ! -L "$STATE/$task_id.status" ] \
    || { hold task-ledger-unreadable; return 0; }
  findings=$(status_open_decisions "$STATE/$task_id.status" 2>/dev/null) || { hold task-ledger-unreadable; return 0; }
  [ -z "$findings" ] || { hold task-open-decisions; return 0; }
  run_status=''
  if command -v no-mistakes >/dev/null 2>&1; then
    local wt
    wt=$(task_worktree "$task_id") || { hold test-evidence-missing-or-stale; return 0; }
    run_status=$(cd "$wt" && no-mistakes axi status 2>/dev/null) || run_status=''
  fi
  test_evidence_ok "$LIVE_HEAD" "$FM_PR_URL" "$run_status" || { hold test-evidence-missing-or-stale; return 0; }
  changed_files=$(printf '%s' "$pr_json" | jq -er '.changedFiles | select(type == "number")' 2>/dev/null) \
    || { hold changed-files-count-unreadable; return 0; }
  # `gh pr view --json files` silently caps at files(first:100), so the complete
  # set must come from the paginated REST endpoint and be reconciled against the
  # PR's own changedFiles count; a short list hides protected paths.
  files_json=$(gh api --paginate --slurp "repos/$owner/$repo/pulls/$number/files?per_page=100" 2>/dev/null) \
    || { hold changed-files-unreadable; return 0; }
  paths=$(printf '%s' "$files_json" | jq -r '
    if type == "array" and all(.[]; type == "array") then
      [.[][] | .filename | select(type == "string" and length > 0)] | unique | .[]
    else error("invalid changed-file pages") end' 2>/dev/null) \
    || { hold changed-files-invalid; return 0; }
  [ -n "$paths" ] || { hold changed-files-unreadable; return 0; }
  observed_files=$(printf '%s\n' "$paths" | grep -c .)
  [ "$observed_files" -eq "$changed_files" ] || { hold changed-files-truncated; return 0; }
  scope=$(printf '%s\n' "$paths" | LC_ALL=C sort -u | shasum -a 256 | awk '{print $1}') || { hold scope-unreadable; return 0; }
  while IFS= read -r path; do changed_paths+=("$path"); done <<< "$paths"
  # A rename changes both sides, so the risk set must carry the source path too:
  # classifying only the destination lets a protected executable be moved out of
  # its protected location and read as LOW.
  risk_paths=$(printf '%s' "$files_json" | jq -r '
    if type == "array" and all(.[]; type == "array") then
      [.[][] | (.filename, .previous_filename) | select(type == "string" and length > 0)] | unique | .[]
    else error("invalid changed-file pages") end' 2>/dev/null) \
    || { hold changed-files-invalid; return 0; }
  [ -n "$risk_paths" ] || { hold changed-files-unreadable; return 0; }
  risk_changed_paths=()
  while IFS= read -r path; do risk_changed_paths+=("$path"); done <<< "$risk_paths"
  risk=$("$SCRIPT_DIR/fm-merge-policy.sh" classify-risk "${risk_changed_paths[@]}" 2>/dev/null) || { hold risk-unknown; return 0; }
  [ -n "$risk" ] || { hold risk-unknown; return 0; }
  if [ "$risk" = HIGH ]; then
    [ "$approval_ok" = true ] || { hold high-risk-captain-approval-missing-or-stale; return 0; }
  fi
  jq -cn --arg head "$LIVE_HEAD" --arg risk "$risk" --arg scope "$scope" \
    --arg protection_scope "$protection_scope" --arg protection_source "$protection_source" \
    '{status:"PASS",head_sha:$head,risk:$risk,scope:$scope,protection:($protection_source == ""),protection_scope:$protection_scope,reasons:[]}
     + (if $protection_source == "" then {} else {protection_source:$protection_source} end)'
}

collect_gitlab() {
  local task_id=$1 expected=$2 encoded pr_json pipeline_id pipeline_jobs approvals approval_settings
  local author review_ok=false findings run_status changes paths scope risk path changes_count observed_files
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
  author=$(printf '%s' "$pr_json" | jq -er '.author.username | select(type == "string" and length > 0)' 2>/dev/null) \
    || { hold forge-author-unreadable; return 0; }
  approvals=$(GITLAB_HOST="$FM_PR_HOST" glab api "projects/$encoded/merge_requests/$FM_PR_NUMBER/approvals" 2>/dev/null) \
    || { hold forge-approvals-unreadable; return 0; }
  local target_branch
  target_branch=$(printf '%s' "$pr_json" | jq -r '.target_branch // empty')
  gitlab_required_checks_ok "$protected" "$pipeline_jobs" "$approvals" "$LIVE_HEAD" "$target_branch" \
    || { hold required-checks-not-green-or-unconfigured; return 0; }
  approval_settings=$(GITLAB_HOST="$FM_PR_HOST" glab api "projects/$encoded" 2>/dev/null) \
    || { hold approval-policy-unreadable; return 0; }
  printf '%s' "$approval_settings" | jq -e '.reset_approvals_on_push == true' >/dev/null 2>&1 \
    || { hold approval-head-binding-unverified; return 0; }
  review_ok=$(printf '%s' "$approvals" | jq -r --arg author "$author" \
    '.approvals_left == 0 and (.approved_by | type == "array") and any(.approved_by[]; .user.username != $author)') || review_ok=false
  [ "$review_ok" = true ] || { hold independent-review-missing-or-stale; return 0; }
  [ -f "$STATE/$task_id.status" ] && [ -r "$STATE/$task_id.status" ] && [ ! -L "$STATE/$task_id.status" ] \
    || { hold task-ledger-unreadable; return 0; }
  findings=$(status_open_decisions "$STATE/$task_id.status" 2>/dev/null) || { hold task-ledger-unreadable; return 0; }
  [ -z "$findings" ] || { hold task-open-decisions; return 0; }
  run_status=''
  if command -v no-mistakes >/dev/null 2>&1; then
    local wt
    wt=$(task_worktree "$task_id") || { hold test-evidence-missing-or-stale; return 0; }
    run_status=$(cd "$wt" && no-mistakes axi status 2>/dev/null) || run_status=''
  fi
  test_evidence_ok "$LIVE_HEAD" "$FM_PR_URL" "$run_status" || { hold test-evidence-missing-or-stale; return 0; }
  changes=$(GITLAB_HOST="$FM_PR_HOST" glab api "projects/$encoded/merge_requests/$FM_PR_NUMBER/changes" 2>/dev/null) \
    || { hold changed-files-unreadable; return 0; }
  # GitLab reports its own truncation with `overflow`; when the diff overflows,
  # `.changes` is a partial list, so any overflow or a length that disagrees with
  # `changes_count` must hold rather than classify risk on an incomplete set.
  printf '%s' "$changes" | jq -e 'type == "object" and (.overflow | type == "boolean")' >/dev/null 2>&1 \
    || { hold changed-files-overflow-unknown; return 0; }
  [ "$(printf '%s' "$changes" | jq -r '.overflow')" = false ] || { hold changed-files-truncated; return 0; }
  changes_count=$(printf '%s' "$changes" | jq -er \
    '.changes_count | if type == "number" then tostring elif (type == "string" and test("^[0-9]+$")) then . else error("invalid changes count") end' 2>/dev/null) \
    || { hold changed-files-count-unreadable; return 0; }
  paths=$(printf '%s' "$changes" | jq -r '
    if (.changes | type) == "array" then
      [.changes[] | .new_path | select(type == "string" and length > 0)] | unique | .[]
    else error("invalid changes") end' 2>/dev/null) \
    || { hold changed-files-invalid; return 0; }
  [ -n "$paths" ] || { hold changed-files-unreadable; return 0; }
  observed_files=$(printf '%s\n' "$paths" | grep -c .)
  [ "$observed_files" -eq "$changes_count" ] || { hold changed-files-truncated; return 0; }
  scope=$(printf '%s\n' "$paths" | LC_ALL=C sort -u | shasum -a 256 | awk '{print $1}') || { hold scope-unreadable; return 0; }
  while IFS= read -r path; do changed_paths+=("$path"); done <<< "$paths"
  # Same rename rule as GitHub: the source path belongs in the risk set.
  risk_paths=$(printf '%s' "$changes" | jq -r '
    if (.changes | type) == "array" then
      [.changes[] | (.new_path, .old_path) | select(type == "string" and length > 0)] | unique | .[]
    else error("invalid changes") end' 2>/dev/null) \
    || { hold changed-files-invalid; return 0; }
  [ -n "$risk_paths" ] || { hold changed-files-unreadable; return 0; }
  risk_changed_paths=()
  while IFS= read -r path; do risk_changed_paths+=("$path"); done <<< "$risk_paths"
  risk=$("$SCRIPT_DIR/fm-merge-policy.sh" classify-risk "${risk_changed_paths[@]}" 2>/dev/null) || { hold risk-unknown; return 0; }
  [ -n "$risk" ] || { hold risk-unknown; return 0; }
  if [ "$risk" = HIGH ]; then
    hold high-risk-captain-approval-missing-or-stale
    return 0
  fi
  jq -cn --arg head "$LIVE_HEAD" --arg risk "$risk" --arg scope "$scope" \
    '{status:"PASS",head_sha:$head,risk:$risk,scope:$scope,reasons:[]}'
}

FM_EVIDENCE_USAGE='usage: fm-merge-evidence.sh collect <task-id> <pr-url> <expected-head> [--waived-check <check-name>]
usage: fm-merge-evidence.sh branch-protection <pr-url> <expected-protection-scope>'

# Re-verify the base branch's protection immediately before a merge. This is a
# distinct entry point from `collect` because it answers one question - has the
# protection evidence moved since the decision was made - and reads only the two
# sources that question needs, so a caller can re-check it cheaply at the merge
# boundary itself rather than trusting the verdict it read earlier.
if [ "${1:-}" = branch-protection ]; then
  if [ "$#" -ne 3 ] || ! fm_pr_url_parse "$2" || ! valid_protection_scope "$3"; then
    printf '%s\n' "$FM_EVIDENCE_USAGE" >&2
    exit 2
  fi
  if [ "$FM_PR_PROVIDER" != github ]; then
    echo 'error: branch-protection re-verification is implemented for GitHub only' >&2
    exit 2
  fi
  reverify_github_branch_protection "$2" "$3"
  exit 0
fi

if [ "$#" -ge 5 ]; then
  if [ "$#" -ne 6 ] || [ "$5" != "--waived-check" ] || [ -z "${6:-}" ]; then
    printf '%s\n' "$FM_EVIDENCE_USAGE" >&2
    exit 2
  fi
  WAIVED_CHECK=$6
else
  WAIVED_CHECK=''
fi
if [ "$#" -lt 4 ] || [ "$1" != collect ] || ! fm_pr_task_id_valid "$2" || ! fm_pr_url_parse "$3" || ! valid_sha "$4"; then
  printf '%s\n' "$FM_EVIDENCE_USAGE" >&2
  exit 2
fi
case "$FM_PR_PROVIDER" in
  github) collect_github "$2" "$4" ;;
  gitlab) collect_gitlab "$2" "$4" ;;
  *) hold unsupported-provider ;;
esac
