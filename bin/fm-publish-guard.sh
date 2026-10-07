#!/usr/bin/env bash
# Usage: fm-publish-guard.sh branch <branch-name>
#        fm-publish-guard.sh check
# Create a task branch from the spawn-pinned base or refuse publication when its
# base, ancestry, changed paths, diff size, or open-PR state violates the contract.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-git-base-lib.sh
. "$SCRIPT_DIR/fm-git-base-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'PUBLISH_GUARD: FAIL: %s\n' "$*" >&2
  exit 1
}

branch_from_verified_base() { # <branch>
  local branch=$1 head
  fm_git_base_read_pin "$PWD" || exit 1
  git check-ref-format --branch "$branch" >/dev/null 2>&1 \
    || die "branch name is invalid: '$branch'"
  [ -z "$FM_GIT_BASE_BRANCH" ] \
    || die "task branch is already recorded as '$FM_GIT_BASE_BRANCH'; refusing to replace its pin"
  git symbolic-ref -q HEAD >/dev/null 2>&1 \
    && die "HEAD is already attached to '$(git symbolic-ref --short HEAD)'; expected a detached verified worktree"
  head=$(git rev-parse --verify HEAD 2>/dev/null) || die "could not resolve current HEAD"
  [ "$head" = "$FM_GIT_BASE_SHA" ] \
    || die "branch creation refused: HEAD=$head, verified base=$FM_GIT_BASE_SHA ($FM_GIT_BASE_REPOSITORY $FM_GIT_BASE_REF)"
  git show-ref --verify --quiet "refs/heads/$branch" \
    && die "branch '$branch' already exists; refusing to reuse an unverified branch"
  git checkout -b "$branch" >/dev/null \
    || die "could not create '$branch' from verified base $FM_GIT_BASE_SHA"
  fm_git_base_write_branch_pin "$PWD" "$branch" "$FM_GIT_BASE_SHA" \
    || die "created '$branch' at $FM_GIT_BASE_SHA but could not persist its base pin; do not publish"
  printf 'PUBLISH_GUARD: PASS: branch=%s head=%s verified_base=%s repository=%s ref=%s\n' \
    "$branch" "$(git rev-parse HEAD)" "$FM_GIT_BASE_SHA" "$FM_GIT_BASE_REPOSITORY" "$FM_GIT_BASE_REF"
}

scope_match() { # <path> <pattern>
  # shellcheck disable=SC2254 # The manifest supplies a pathname glob, not a literal value.
  case "$1" in
    $2) return 0 ;;
    *) return 1 ;;
  esac
}

publish_check() { #
  local scope_file git_dir path pattern limit extra total_limit='' total_bytes=0 pattern_count=0 i path_count=0
  local bytes found unexpected total_commits first_parent_commits current_branch current_base inherited_commits expected_repository verification_ref
  local pr_list pr_numbers reported_pr_count listed_pr_count
  local -a patterns=() limits=()

  [ "$#" -eq 0 ] || die "check accepts no options; its scope manifest path is fixed per worktree"
  git_dir=$(git rev-parse --absolute-git-dir 2>/dev/null) || die "could not resolve current worktree Git directory"
  scope_file="$git_dir/info/fm-publish-scope"
  [ -f "$scope_file" ] && [ ! -L "$scope_file" ] \
    || die "scope allowlist is missing or unsafe at '$scope_file'; publication is refused"
  fm_git_base_read_pin "$PWD" || exit 1
  [ -n "$FM_GIT_BASE_BRANCH" ] && [ -n "$FM_GIT_BASE_START_SHA" ] \
    || die "task branch has no recorded verified-base start; create it with fm-publish-guard.sh branch"
  current_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$current_branch" = "$FM_GIT_BASE_BRANCH" ] \
    || die "branch identity mismatch: current=${current_branch:-detached}, pinned=$FM_GIT_BASE_BRANCH"
  [ "$FM_GIT_BASE_START_SHA" = "$FM_GIT_BASE_SHA" ] \
    || die "branch start mismatch: start=$FM_GIT_BASE_START_SHA, pinned base=$FM_GIT_BASE_SHA"
  [ -z "$(git status --porcelain)" ] \
    || die "working tree is dirty; commit or preserve those changes before publication"

  found=$(git merge-base HEAD "$FM_GIT_BASE_SHA" 2>/dev/null || true)
  [ "$found" = "$FM_GIT_BASE_SHA" ] \
    || die "merge-base invariant failed: merge-base=${found:-none}, pinned verified base=$FM_GIT_BASE_SHA"

  total_commits=$(git rev-list --count "$FM_GIT_BASE_SHA..HEAD" 2>/dev/null) \
    || die "could not count commits after pinned base $FM_GIT_BASE_SHA"
  first_parent_commits=$(git rev-list --first-parent --count "$FM_GIT_BASE_SHA..HEAD" 2>/dev/null) \
    || die "could not count first-parent commits after pinned base $FM_GIT_BASE_SHA"
  unexpected=$((total_commits - first_parent_commits))
  [ "$unexpected" -eq 0 ] \
    || die "unexpected inherited commits invariant failed: total=$total_commits first_parent=$first_parent_commits unexpected=$unexpected"
  case "$FM_GIT_BASE_MODE" in
    local)
      current_base=$(git rev-parse --verify --quiet "$FM_GIT_BASE_REF^{commit}" 2>/dev/null) \
        || die "could not verify current local base '$FM_GIT_BASE_REF'"
      ;;
    remote)
      [ "$FM_GIT_BASE_REF" = refs/heads/main ] \
        || die "pinned remote base ref is not refs/heads/main: '$FM_GIT_BASE_REF'"
      expected_repository=$(fm_git_base_expected_repository "$PWD") \
        || die "could not verify expected repository identity for current fork base"
      [ "$(printf '%s' "$expected_repository" | tr '[:upper:]' '[:lower:]')" = \
        "$(printf '%s' "$FM_GIT_BASE_REPOSITORY" | tr '[:upper:]' '[:lower:]')" ] \
        || die "pinned repository '$FM_GIT_BASE_REPOSITORY' differs from configured expected repository '$expected_repository'"
      verification_ref=refs/remotes/fm-publish-verification/main
      fm_git_base_fetch_remote_ref "$PWD" "$expected_repository" refs/heads/main "$verification_ref" \
        || die "could not revalidate current refs/heads/main from verified repository '$expected_repository'"
      current_base=$(git rev-parse --verify --quiet "$verification_ref^{commit}" 2>/dev/null) \
        || die "verified fork main did not resolve to a commit"
      ;;
    *) die "verified-base pin has unsupported mode '$FM_GIT_BASE_MODE'" ;;
  esac
  found=$(git merge-base "$FM_GIT_BASE_SHA" "$current_base" 2>/dev/null || true)
  [ "$found" = "$FM_GIT_BASE_SHA" ] \
    || die "current-base ancestry invariant failed: pinned=$FM_GIT_BASE_SHA current=$current_base merge-base=${found:-none}"
  inherited_commits=$(git rev-list --count "$FM_GIT_BASE_SHA..HEAD" --not "$current_base" 2>/dev/null) \
    || die "could not distinguish task commits from commits already present on verified current base '$current_base'"
  [ "$inherited_commits" -eq "$total_commits" ] \
    || die "unexpected inherited commits invariant failed: total=$total_commits task_owned=$inherited_commits inherited=$((total_commits - inherited_commits)) verified_current_base=$current_base"

  while IFS=$'\t' read -r pattern limit extra || [ -n "${pattern:-}${limit:-}${extra:-}" ]; do
    [ -n "${pattern:-}" ] || continue
    case "$pattern" in \#*) continue ;; esac
    [ -z "${extra:-}" ] || die "scope row has more than two tab-separated fields: '$pattern'"
    case "$limit" in ''|*[!0-9]*) die "scope budget for '$pattern' must be a positive byte count" ;; esac
    [ "$limit" -gt 0 ] || die "scope budget for '$pattern' must be positive"
    if [ "$pattern" = @total ]; then
      [ -z "$total_limit" ] || die "scope allowlist repeats @total"
      total_limit=$limit
    else
      patterns[pattern_count]=$pattern
      limits[pattern_count]=$limit
      pattern_count=$((pattern_count + 1))
    fi
  done < "$scope_file"
  [ -n "$total_limit" ] || die "scope allowlist must include @total<TAB><max-diff-bytes>"
  [ "$pattern_count" -gt 0 ] || die "scope allowlist contains no path patterns"

  while IFS= read -r -d '' path; do
    path_count=$((path_count + 1))
    found=0
    limit=
    for ((i = 0; i < pattern_count; i++)); do
      if scope_match "$path" "${patterns[$i]}"; then
        found=1
        limit=${limits[$i]}
        break
      fi
    done
    [ "$found" -eq 1 ] \
      || die "scope allowlist invariant failed: changed path '$path' matches no expected task scope"
    bytes=$(git diff --binary --no-renames "$FM_GIT_BASE_SHA...HEAD" -- "$path" | wc -c | tr -d '[:space:]') \
      || die "could not measure diff bytes for '$path'"
    case "$bytes" in ''|*[!0-9]*) die "could not measure diff bytes for '$path'" ;; esac
    [ "$bytes" -le "$limit" ] \
      || die "oversized diff invariant failed: path='$path' bytes=$bytes limit=$limit"
    total_bytes=$((total_bytes + bytes))
  done < <(git diff --name-only --no-renames -z "$FM_GIT_BASE_SHA...HEAD" --) \
    || die "could not inspect changed paths against pinned base"
  [ "$path_count" -gt 0 ] || die "scope invariant failed: no committed paths differ from pinned base"
  [ "$total_bytes" -le "$total_limit" ] \
    || die "oversized diff invariant failed: total_bytes=$total_bytes limit=$total_limit"

  [ "$FM_GIT_BASE_REPOSITORY" != local ] \
    || die "verified-base pin has no repository identity; configure firstmate.expectedRepository to verify conflicting open PRs"
  command -v gh-axi >/dev/null 2>&1 || die "gh-axi is unavailable; cannot verify conflicting open PRs"
  pr_list=$(gh-axi pr list --repo "$FM_GIT_BASE_REPOSITORY" --state open --head "$FM_GIT_BASE_BRANCH" --limit 100 2>&1) \
    || die "could not verify conflicting open PRs with gh-axi: $pr_list"
  reported_pr_count=$(printf '%s\n' "$pr_list" | awk '
    $1 == "count:" {
      count++
      if ($2 !~ /^[0-9]+$/) { invalid = 1; next }
      value = $2
      if (NF == 2) next
      if (NF == 5 && $3 == "of" && $4 ~ /^[0-9]+$/ && $5 == "total" && $2 <= $4) next
      if (NF == 5 && $3 == "(showing" && $4 == "first" && $5 ~ /^[0-9]+\)$/) {
        sub(/\)$/, "", $5)
        if ($2 <= $5) next
      }
      invalid = 1
    }
    END { if (count == 1 && !invalid) print value; else exit 1 }
  ') \
    || die "gh-axi did not report a parseable open-PR count for '$FM_GIT_BASE_REPOSITORY' branch '$FM_GIT_BASE_BRANCH'"
  pr_numbers=$(printf '%s\n' "$pr_list" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p')
  listed_pr_count=$(printf '%s\n' "$pr_numbers" | awk 'NF { count++ } END { print count+0 }')
  [ "$reported_pr_count" = "$listed_pr_count" ] \
    || die "gh-axi open-PR count mismatch: reported=$reported_pr_count parsed=$listed_pr_count for '$FM_GIT_BASE_REPOSITORY' branch '$FM_GIT_BASE_BRANCH'"
  [ "$reported_pr_count" -eq 0 ] \
    || die "conflicting open PR invariant failed: matching open PR count=$reported_pr_count numbers=$(printf '%s' "$pr_numbers" | tr '\n' ',') repository=$FM_GIT_BASE_REPOSITORY branch=$FM_GIT_BASE_BRANCH"
  printf 'PUBLISH_GUARD: PASS: base=%s commits=%s unexpected=%s paths=%s diff_bytes=%s scope=%s open_prs=%s\n' \
    "$FM_GIT_BASE_SHA" "$total_commits" "$unexpected" \
    "$path_count" \
    "$total_bytes" "$scope_file" "$reported_pr_count"
}

case "${1:-}" in
  branch)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    branch_from_verified_base "$2"
    ;;
  check)
    shift
    publish_check "$@"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
