#!/usr/bin/env bash
# Usage: fm-pr-target-guard.sh [<owner>/<repo>] [--repair]
# Fail closed unless the pull-request target repository is owned by the
# authenticated gh user, so a task can never open a pull request against an
# unowned upstream because gh's resolved default pointed there.
#
# The target is the <owner>/<repo> argument when given. When omitted it is the
# repository gh resolves for the current directory: the recorded
# `gh repo set-default --view` default first, then `gh repo view`'s own
# resolution over the worktree's remotes.
# Ownership is read live from the forge and never inferred from a remote name,
# a local path, or the caller's intent: `gh api repos/<target> --jq .owner.login`
# must equal `gh api user --jq .login`. Any command that fails, any empty
# answer, and any disagreement refuses; nothing here exits 0 on a target it did
# not verify.
#
# Output on success is one machine-readable verdict line, the exact `--repo
# <owner>/<repo>` value to pass to every pull-request command, and the gh
# default's own state: a named default that disagrees with the verified target,
# or the absence of any resolved default. Both are the conditions under which a
# bare gh command in this directory would target something other than the
# verified repository, so both are reported rather than left implicit.
#
# --repair is an explicit opt-in that pins the verified target as this
# directory's gh default with `gh repo set-default`, so a later bare gh command
# resolves to the owned repository. It runs only after ownership verified and
# refuses otherwise; without --repair this script changes nothing.
#
# Exit codes: 0 verified, 1 target is not owned by the authenticated user,
# 2 invalid request, 3 the target or the authenticated user could not be
# verified.
set -euo pipefail

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

refuse() { # <message> <exit-code>
  printf 'error: PR target guard refused: %s\n' "$1" >&2
  exit "$2"
}

TARGET=
REPAIR=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repair)
      REPAIR=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      refuse "unknown option '$1'" 2
      ;;
    *)
      [ -z "$TARGET" ] || refuse "only one <owner>/<repo> target is accepted" 2
      TARGET=$1
      shift
      ;;
  esac
done

case "$TARGET" in
  '') ;;
  /*|*/|*/*/*)
    refuse "target '$TARGET' is not an <owner>/<repo> pair" 2
    ;;
  */*) ;;
  *)
    refuse "target '$TARGET' is not an <owner>/<repo> pair" 2
    ;;
esac

command -v gh >/dev/null 2>&1 \
  || refuse "gh is not on PATH, so no target can be verified" 3

# The repository gh resolves for this directory without an explicit --repo.
# The recorded default wins because that is what a bare gh command uses; the
# remote-based resolution is only the fallback when no default is recorded.
resolve_gh_default() {
  local out
  if out=$(gh repo set-default --view 2>/dev/null) && [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  if out=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) && [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  return 1
}

if [ -z "$TARGET" ]; then
  TARGET=$(resolve_gh_default) \
    || refuse "no repository could be resolved for this directory; pass <owner>/<repo> explicitly" 3
fi

OWNER=$(gh api "repos/$TARGET" --jq .owner.login 2>/dev/null) \
  || refuse "the owner of '$TARGET' could not be read from the forge" 3
[ -n "$OWNER" ] || refuse "the owner of '$TARGET' came back empty" 3
ME=$(gh api user --jq .login 2>/dev/null) \
  || refuse "the authenticated gh user could not be read" 3
[ -n "$ME" ] || refuse "the authenticated gh user came back empty" 3
[ "$OWNER" = "$ME" ] \
  || refuse "target '$TARGET' is owned by '$OWNER', not the authenticated user '$ME'" 1

printf 'PR_TARGET_GUARD: PASS target=%s owner=%s\n' "$TARGET" "$OWNER"
printf -- '--repo %s\n' "$TARGET"

# What a bare gh command in this directory would target, and whether that is
# the repository just verified. Either answer is reported: a disagreeing
# default and no default at all are different states, and both are why the
# explicit --repo value above is the value to use.
if DEFAULT=$(gh repo set-default --view 2>/dev/null) && [ -n "$DEFAULT" ]; then
  [ "$DEFAULT" = "$TARGET" ] \
    || printf 'PR_TARGET_GUARD: default=%s disagrees with the verified target %s; pass --repo %s explicitly\n' \
      "$DEFAULT" "$TARGET" "$TARGET"
else
  printf 'PR_TARGET_GUARD: no gh default resolved for this directory; pass --repo %s explicitly\n' "$TARGET"
fi

if [ "$REPAIR" = true ]; then
  gh repo set-default "$TARGET" >/dev/null 2>&1 \
    || refuse "'$TARGET' is verified, but setting it as this directory's gh default failed" 3
  printf 'PR_TARGET_GUARD: repair set the gh default to %s\n' "$TARGET"
fi
