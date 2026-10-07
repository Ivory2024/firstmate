#!/usr/bin/env bash
# Shared source identity and pinned-base contract for spawn and publish guards.
# Source this file; bin/fm-spawn.sh and bin/fm-publish-guard.sh own the call sites.

fm_git_base_repo_identity_from_url() { # <url>
  local url=$1 path owner repo
  case "$url" in
    https://github.com/*) path=${url#https://github.com/} ;;
    ssh://git@github.com/*) path=${url#ssh://git@github.com/} ;;
    git@github.com:*) path=${url#git@github.com:} ;;
    *) return 1 ;;
  esac
  path=${path%/}
  path=${path%.git}
  case "$path" in
    */*) owner=${path%%/*}; repo=${path#*/} ;;
    *) return 1 ;;
  esac
  case "$repo" in */*|'') return 1 ;; esac
  case "$owner" in ''|.*|*[^A-Za-z0-9_.-]*) return 1 ;; esac
  case "$repo" in .*|*[^A-Za-z0-9_.-]*) return 1 ;; esac
  printf '%s/%s\n' "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" \
    "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')"
}

fm_git_base_expected_repository() { # <source-repository>
  local repo=$1 expected
  expected=$(git -C "$repo" config --get firstmate.expectedRepository 2>/dev/null || true)
  if [ -z "$expected" ] && [ -f "$repo/bin/fm-spawn.sh" ] \
    && [ -f "$repo/.agents/skills/firstmate-coding-guidelines/SKILL.md" ]; then
    expected=Ivory2024/firstmate
  fi
  case "$expected" in
    */*) ;;
    *)
      echo "error: no expected repository identity is configured for '$repo'; set firstmate.expectedRepository to owner/repository or use the explicit local-base contract" >&2
      return 1
      ;;
  esac
  case "$expected" in
    *[!A-Za-z0-9_./-]*|*/*/*|/*|*/)
      echo "error: invalid firstmate.expectedRepository value '$expected'; expected owner/repository" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$expected"
}

fm_git_base_ref() { # <source-repository>
  local repo=$1 ref
  ref=$(git -C "$repo" config --get firstmate.baseRef 2>/dev/null || true)
  [ -n "$ref" ] || ref=refs/heads/main
  case "$ref" in
    refs/heads/*) ;;
    *)
      echo "error: firstmate.baseRef must name a local branch ref under refs/heads/ (got '$ref')" >&2
      return 1
      ;;
  esac
  git check-ref-format "$ref" >/dev/null 2>&1 || {
    echo "error: invalid firstmate.baseRef '$ref'" >&2
    return 1
  }
  printf '%s\n' "$ref"
}

fm_git_base_pin_path() { # <worktree>
  local git_dir
  git_dir=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  printf '%s/info/fm-verified-base\n' "$git_dir"
}

fm_git_base_write_pin() { # <worktree> <mode> <repository> <ref> <sha>
  local worktree=$1 mode=$2 repository=$3 ref=$4 sha=$5 path tmp
  path=$(fm_git_base_pin_path "$worktree") || return 1
  mkdir -p "$(dirname "$path")" || return 1
  tmp="$path.tmp.${BASHPID:-$$}"
  (umask 077; {
    printf 'schema=firstmate-verified-base.v1\n'
    printf 'mode=%s\nrepository=%s\nref=%s\nsha=%s\n' "$mode" "$repository" "$ref" "$sha"
  } > "$tmp") || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

fm_git_base_verified_source_url() { # <worktree> <expected-repository>
  local worktree=$1 expected_repository=$2 expected_normalized remote urls url identity source_url effective_url effective_identity
  expected_normalized=$(printf '%s' "$expected_repository" | tr '[:upper:]' '[:lower:]')
  source_url=
  while IFS= read -r remote; do
    [ -n "$remote" ] || continue
    urls=$(git -C "$worktree" config --get-all "remote.$remote.url" 2>/dev/null || true)
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      identity=$(fm_git_base_repo_identity_from_url "$url" 2>/dev/null || true)
      if [ "$identity" = "$expected_normalized" ]; then
        source_url=$url
        break
      fi
    done <<EOF
$urls
EOF
    [ -n "$source_url" ] && break
  done <<EOF
$(git -C "$worktree" remote 2>/dev/null || true)
EOF
  if [ -z "$source_url" ]; then
    echo "error: no configured remote URL resolves to expected repository '$expected_repository'; refusing to trust a remote name such as origin" >&2
    return 1
  fi
  effective_url=$(git -C "$worktree" ls-remote --get-url "$source_url" 2>/dev/null) || {
    echo "error: could not resolve the effective fetch URL for verified repository '$expected_repository'; refusing to fetch an unverified source" >&2
    return 1
  }
  if [ "$effective_url" != "$source_url" ]; then
    effective_identity=$(fm_git_base_repo_identity_from_url "$effective_url" 2>/dev/null || true)
    if [ "$effective_identity" != "$expected_normalized" ]; then
      echo "error: Git URL rewrite changes verified repository '$expected_repository' to an unverified fetch destination '$effective_url'; refusing to fetch" >&2
      return 1
    fi
  fi
  printf '%s\n' "$source_url"
}

fm_git_base_fetch_remote_ref() { # <worktree> <expected-repository> <source-ref> <target-ref>
  local worktree=$1 repository=$2 source_ref=$3 target_ref=$4 source_url
  source_url=$(fm_git_base_verified_source_url "$worktree" "$repository") || return 1
  git -C "$worktree" fetch --quiet --no-tags "$source_url" "+$source_ref:$target_ref"
}

fm_git_base_has_verifiable_remote_identity() { # <worktree>
  local worktree=$1 remote urls url identity
  while IFS= read -r remote; do
    [ -n "$remote" ] || continue
    urls=$(git -C "$worktree" config --get-all "remote.$remote.url" 2>/dev/null || true)
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      identity=$(fm_git_base_repo_identity_from_url "$url" 2>/dev/null || true)
      [ -n "$identity" ] && return 0
    done <<EOF
$urls
EOF
  done <<EOF
$(git -C "$worktree" remote 2>/dev/null || true)
EOF
  return 1
}

fm_git_base_refresh_worktree() { # <worktree> <source-repository>
  local worktree=$1 source_repo=$2 mode expected_repository expected_ref
  local target_ref expected actual source_common worktree_common
  mode=$(git -C "$source_repo" config --get firstmate.baseMode 2>/dev/null || true)
  [ -n "$mode" ] || mode=remote
  expected_ref=$(fm_git_base_ref "$source_repo") || return 1
  if [ "$mode" = remote ] && [ "$expected_ref" != refs/heads/main ]; then
    echo "error: verified remote base must be refs/heads/main (configured '$expected_ref'); refusing to use a remote default branch or another ref" >&2
    return 1
  fi
  # No configured repository identity and not a firstmate source checkout: this
  # project cannot name an expected fork, so fall back to the explicit local-base
  # contract instead of refusing to launch. A project that configures
  # firstmate.expectedRepository, or that carries a verifiable GitHub remote, stays
  # strict, so a wrong or upstream remote is still rejected.
  if [ "$mode" = remote ] && ! fm_git_base_expected_repository "$source_repo" >/dev/null 2>&1; then
    if ! fm_git_base_has_verifiable_remote_identity "$worktree"; then
      mode=local
    fi
  fi

  case "$mode" in
    local)
      expected_repository=$(fm_git_base_expected_repository "$source_repo" 2>/dev/null || true)
      [ -n "$expected_repository" ] || expected_repository=local
      source_common=$(git -C "$source_repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
        echo "error: could not resolve the explicit local-base source repository '$source_repo'" >&2
        return 1
      }
      worktree_common=$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
        echo "error: could not resolve the pooled worktree's Git repository" >&2
        return 1
      }
      [ "$source_common" = "$worktree_common" ] || {
        echo "error: explicit local-base mode requires the source checkout and pooled worktree to share one Git repository; source='$source_common' worktree='$worktree_common'" >&2
        return 1
      }
      expected=$(git -C "$source_repo" rev-parse --verify --quiet "$expected_ref^{commit}" 2>/dev/null) || {
        echo "error: local base ref '$expected_ref' is not a commit in source checkout '$source_repo'; configure an explicit local base ref or a verified repository identity" >&2
        return 1
      }
      git -C "$worktree" cat-file -e "$expected^{commit}" 2>/dev/null || {
        echo "error: local base commit '$expected' from '$source_repo' is unavailable in pooled worktree '$worktree'; refusing to launch from an unverified base" >&2
        return 1
      }
      ;;
    remote)
      expected_repository=$(fm_git_base_expected_repository "$source_repo") || return 1
      expected_ref=$(fm_git_base_ref "$source_repo") || return 1
      target_ref="refs/remotes/fm-verified-fork/${expected_ref#refs/heads/}"
      if ! fm_git_base_fetch_remote_ref "$worktree" "$expected_repository" "$expected_ref" "$target_ref"; then
        echo "error: could not fetch '$expected_ref' from verified repository '$expected_repository'; refusing to launch from an unverified base" >&2
        return 1
      fi
      expected=$(git -C "$worktree" rev-parse --verify --quiet "$target_ref^{commit}" 2>/dev/null) || {
        echo "error: fetched '$expected_ref' from '$expected_repository' did not resolve to a commit; refusing to launch" >&2
        return 1
      }
      ;;
    *)
      echo "error: unsupported firstmate.baseMode '$mode'; expected remote or the explicit local contract" >&2
      return 1
      ;;
  esac

  actual=$(git -C "$worktree" rev-parse --verify --quiet HEAD 2>/dev/null) || {
    echo "error: could not resolve pooled worktree HEAD before base refresh" >&2
    return 1
  }
  if [ "$actual" != "$expected" ] && ! git -C "$worktree" merge-base --is-ancestor "$actual" "$expected" 2>/dev/null; then
    echo "error: pooled worktree HEAD '$actual' is not an ancestor of verified base '$expected'; refusing to discard or rewrite inherited commits" >&2
    return 1
  fi
  if [ "$actual" != "$expected" ]; then
    if ! git -C "$worktree" reset --hard "$expected" >/dev/null; then
      echo "error: could not fast-forward clean pooled worktree to verified base '$expected'; refusing to launch" >&2
      return 1
    fi
  fi
  actual=$(git -C "$worktree" rev-parse --verify --quiet HEAD 2>/dev/null || true)
  if [ "$actual" != "$expected" ]; then
    echo "error: pooled worktree HEAD '$actual' does not equal verified base '$expected'; refusing to launch" >&2
    return 1
  fi
  fm_git_base_write_pin "$worktree" "$mode" "$expected_repository" "$expected_ref" "$expected" || {
    echo "error: verified base '$expected' but could not persist its private worktree pin; refusing to launch" >&2
    return 1
  }
  FM_GIT_BASE_SHA=$expected
  FM_GIT_BASE_REPOSITORY=$expected_repository
  FM_GIT_BASE_REF=$expected_ref
}

fm_git_base_read_pin() { # <worktree>
  local worktree=$1 path key value
  local schema='' repository='' ref='' sha='' mode='' count_schema=0 count_repository=0 count_ref=0 count_sha=0 count_mode=0
  FM_GIT_BASE_BRANCH=
  FM_GIT_BASE_START_SHA=
  path=$(fm_git_base_pin_path "$worktree") || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || {
    echo "error: verified-base pin is missing or unsafe at '$path'" >&2
    return 1
  }
  while IFS='=' read -r key value; do
    case "$key" in
      schema) schema=$value; count_schema=$((count_schema + 1)) ;;
      mode) mode=$value; count_mode=$((count_mode + 1)) ;;
      repository) repository=$value; count_repository=$((count_repository + 1)) ;;
      ref) ref=$value; count_ref=$((count_ref + 1)) ;;
      sha) sha=$value; count_sha=$((count_sha + 1)) ;;
      branch)
        # Consumed by fm-publish-guard.sh after this library call returns.
        # shellcheck disable=SC2034
        FM_GIT_BASE_BRANCH=$value
        ;;
      start_sha)
        # Consumed by fm-publish-guard.sh after this library call returns.
        # shellcheck disable=SC2034
        FM_GIT_BASE_START_SHA=$value
        ;;
      *) echo "error: verified-base pin contains unknown field '$key'" >&2; return 1 ;;
    esac
  done < "$path"
  [ "$schema" = firstmate-verified-base.v1 ] && [ "$count_schema" = 1 ] \
    && [ "$count_mode" = 1 ] && [ "$count_repository" = 1 ] \
    && [ "$count_ref" = 1 ] && [ "$count_sha" = 1 ] || {
    echo "error: verified-base pin is incomplete or duplicated at '$path'" >&2
    return 1
  }
  case "$mode" in remote|local) ;; *) echo "error: verified-base pin has invalid mode '$mode'" >&2; return 1 ;; esac
  git -C "$worktree" cat-file -e "$sha^{commit}" 2>/dev/null || {
    echo "error: pinned base '$sha' is not an available commit" >&2
    return 1
  }
  FM_GIT_BASE_MODE=$mode
  FM_GIT_BASE_REPOSITORY=$repository
  FM_GIT_BASE_REF=$ref
  FM_GIT_BASE_SHA=$sha
}

fm_git_base_write_branch_pin() { # <worktree> <branch> <start-sha>
  local worktree=$1 branch=$2 start_sha=$3 path tmp
  path=$(fm_git_base_pin_path "$worktree") || return 1
  tmp="$path.tmp.${BASHPID:-$$}"
  (umask 077; {
    printf 'schema=firstmate-verified-base.v1\n'
    printf 'mode=%s\nrepository=%s\nref=%s\nsha=%s\n' \
      "$FM_GIT_BASE_MODE" "$FM_GIT_BASE_REPOSITORY" "$FM_GIT_BASE_REF" "$FM_GIT_BASE_SHA"
    printf 'branch=%s\nstart_sha=%s\n' "$branch" "$start_sha"
  } > "$tmp") || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}
