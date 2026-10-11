#!/usr/bin/env bash
# Usage:
#   fm-pr-target-guard.sh [<owner>/<repo>] [--repair]
#   fm-pr-target-guard.sh --pin <worktree> [--optional]
#   fm-pr-target-guard.sh --gate <gate-dir> --ref <refname> --old <sha> --new <sha>
#
# The single owner of the fail-closed rule that a pull-request branch may only
# be pushed to, and a pull request only opened against, a repository owned by
# the authenticated forge user. It exists because no-mistakes derives its push
# and pull-request target from data this repository does not own - the
# `upstream_url` / `fork_url` columns of its own `repos` row, which a run start
# re-fills from the `origin` of whichever checkout pushed - so a checkout whose
# `origin` is a third-party upstream silently routes the pipeline's push and PR
# there. Ownership is therefore read live from the forge and never inferred
# from a remote name, a local path, the caller's intent, or any recorded row.
#
# Three modes, one rule:
#
#   check (default) - the target is the <owner>/<repo> argument when given, and
#     otherwise the repository the forge CLI resolves for the current
#     directory: the recorded default first, then its own remote-based
#     resolution. The verified target must also equal the approved repository
#     when one is known: `$FM_PR_TARGET`, else the current directory's
#     `firstmate.expectedRepository` through the same owner the spawn base
#     contract uses. On success it prints one machine-readable verdict line and
#     the exact `--repo <owner>/<repo>` value to pass to every pull-request
#     command, because a bare forge command in this directory can still resolve
#     somewhere else. `--repair` additionally pins the verified target as this
#     directory's forge default; without it nothing is changed.
#
#   --pin <worktree> - repoint <worktree>'s `origin` at the approved repository.
#     This is the routing fix: a run start re-derives its target from the
#     pushing checkout's `origin`, so an `origin` that already names the
#     approved repository makes that re-derivation idempotent instead of
#     origin-dependent. The approved repository is the worktree's
#     `firstmate.expectedRepository`, and the URL written is the configured
#     remote URL that resolves to that identity, so no remote name is trusted.
#     A worktree with no approved identity refuses unless `--optional` is given,
#     which turns exactly that absence into a documented no-op for a caller that
#     must not require one.
#
#   --gate <gate-dir> - a no-mistakes gate's pre-receive boundary, run from the
#     gate's `hooks/pre-receive.no-mistakes-user` seam, which the vendor
#     `hooks/pre-receive` execs. It validates, before the push is accepted, that
#       target     the effective push target and the effective pull-request
#                  base are each a repository owned by the authenticated user,
#                  and each equals the gate's recorded `no-mistakes.prTarget`
#                  when one is set. Both are read from the no-mistakes state
#                  database's `repos` row for the gate's own repository id -
#                  the single source the daemon's push and pull-request steps
#                  read (`fork_url` when set, else `upstream_url`, for the push;
#                  `upstream_url` for the pull-request base) - because a
#                  boundary that read the gate's own `remote.fork.url` and
#                  `remote.origin.url` instead would accept a push the daemon
#                  then sends somewhere else;
#       remote     every configured remote URL in the gate is an accepted clone
#                  URL that names a forge repository owned by the
#                  authenticated user;
#       base/head  the pushed ref is a `refs/heads/fm/...` task branch and never
#                  the default branch named by that same `repos` row, and both
#                  object ids are commits present in the gate;
#       permission the target repository reports push permission for the
#                  authenticated user.
#     The base branch name comes from the `repos` row and its commit is
#     deliberately not required to exist in the gate: a pre-receive hook runs
#     before the run start that fetches the base, so demanding the commit would
#     refuse every push into a gate that has never had the base fetched - every
#     firstmate gate, whose `HEAD` is unborn.
#     Any mismatch or unverifiable answer exits non-zero, and git then rejects
#     the push, so the pipeline's own push and the pull request that follows it
#     cannot reach an unowned repository even though the run start re-derived
#     its target. bin/fm-nm-gate-guard.sh installs this hook.
#
# Only github.com remote URLs are resolvable here, because the identity owner
# this guard reuses and the forge CLI's `repos/<owner>/<repo>` API path are both
# github.com forms; a remote on any other host is refused as unverifiable rather
# than guessed at.
#
# Exit codes: 0 verified, 1 a target is not owned by the authenticated user or
# disagrees with the approved repository, 2 invalid request, 3 the target, the
# remote, the objects, or the authenticated user could not be verified.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-git-base-lib.sh
. "$SCRIPT_DIR/fm-git-base-lib.sh"
# shellcheck source=bin/fm-project-origin-lib.sh
. "$SCRIPT_DIR/fm-project-origin-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

refuse() { # <message> <exit-code>
  printf 'error: PR target guard refused: %s\n' "$1" >&2
  exit "$2"
}

MODE=check
TARGET=
REPAIR=false
WORKTREE=
GATE=
GATE_REF=
GATE_OLD=
GATE_NEW=
PIN_OPTIONAL=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repair)
      REPAIR=true
      shift
      ;;
    --optional)
      PIN_OPTIONAL=true
      shift
      ;;
    --pin)
      [ "$MODE" = check ] || refuse "only one mode may be requested" 2
      [ "$#" -ge 2 ] || refuse "--pin requires a worktree path" 2
      MODE=pin
      WORKTREE=$2
      shift 2
      ;;
    --gate)
      [ "$MODE" = check ] || refuse "only one mode may be requested" 2
      [ "$#" -ge 2 ] || refuse "--gate requires a gate directory" 2
      MODE=gate
      GATE=$2
      shift 2
      ;;
    --ref)
      [ "$#" -ge 2 ] || refuse "--ref requires a refname" 2
      GATE_REF=$2
      shift 2
      ;;
    --old)
      [ "$#" -ge 2 ] || refuse "--old requires an object id" 2
      GATE_OLD=$2
      shift 2
      ;;
    --new)
      [ "$#" -ge 2 ] || refuse "--new requires an object id" 2
      GATE_NEW=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      refuse "unknown option '$1'" 2
      ;;
    *)
      [ "$MODE" = check ] || refuse "a target argument is only accepted in check mode" 2
      [ -z "$TARGET" ] || refuse "only one <owner>/<repo> target is accepted" 2
      TARGET=$1
      shift
      ;;
  esac
done

command -v gh >/dev/null 2>&1 \
  || refuse "gh is not on PATH, so no target can be verified" 3

# owner/repo in the identity owner's normalized form, from either a remote URL
# or an already-written <owner>/<repo>.
normalize_identity() { # <owner>/<repo>|<url>
  local value=$1
  case $value in
    *://*|*@*) fm_git_base_repo_identity_from_url "$value" || return 1 ;;
    *) printf '%s\n' "$value" | tr '[:upper:]' '[:lower:]' ;;
  esac
}

# The authenticated forge user every ownership answer is compared against.
authenticated_user() {
  local me
  me=$(gh api user --jq .login 2>/dev/null) || return 1
  [ -n "$me" ] || return 1
  printf '%s\n' "$me"
}

require_owned() { # <owner>/<repo> <label> <me>; refuses on failure, prints nothing
  local slug=$1 label=$2 me=$3 owner
  owner=$(gh api "repos/$slug" --jq .owner.login 2>/dev/null) \
    || refuse "the owner of '$slug' could not be read from the forge" 3
  [ -n "$owner" ] || refuse "the owner of '$slug' came back empty" 3
  [ "$owner" = "$me" ] \
    || refuse "$label '$slug' is owned by '$owner', not the authenticated user '$me'" 1
}

# The approved repository identity this directory is bound to, or failure when
# none is known. `$FM_PR_TARGET` is an explicit caller override; otherwise the
# spawn base contract's own identity owner answers, so there is exactly one
# place that says which repository a checkout belongs to.
approved_repository() { # <directory>
  local dir=$1 value
  value=${FM_PR_TARGET:-}
  if [ -z "$value" ]; then
    value=$(fm_git_base_expected_repository "$dir" 2>/dev/null || true)
  fi
  [ -n "$value" ] || return 1
  normalize_identity "$value"
}

# ---------------------------------------------------------------- check mode

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

run_check() {
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

  if [ -z "$TARGET" ]; then
    TARGET=$(resolve_gh_default) \
      || refuse "no repository could be resolved for this directory; pass <owner>/<repo> explicitly" 3
  fi

  local me approved
  me=$(authenticated_user) || refuse "the authenticated gh user could not be read" 3
  require_owned "$TARGET" "target" "$me"

  approved=$(approved_repository "$PWD" || true)
  if [ -n "$approved" ] && [ "$approved" != "$(normalize_identity "$TARGET")" ]; then
    refuse "target '$TARGET' disagrees with the approved repository '$approved'" 1
  fi

  printf 'PR_TARGET_GUARD: PASS target=%s owner=%s\n' "$TARGET" "$me"
  printf -- '--repo %s\n' "$TARGET"

  local default
  if default=$(gh repo set-default --view 2>/dev/null) && [ -n "$default" ]; then
    [ "$default" = "$TARGET" ] \
      || printf 'PR_TARGET_GUARD: default=%s disagrees with the verified target %s; pass --repo %s explicitly\n' \
        "$default" "$TARGET" "$TARGET"
  else
    printf 'PR_TARGET_GUARD: no gh default resolved for this directory; pass --repo %s explicitly\n' "$TARGET"
  fi

  if [ "$REPAIR" = true ]; then
    gh repo set-default "$TARGET" >/dev/null 2>&1 \
      || refuse "'$TARGET' is verified, but setting it as this directory's gh default failed" 3
    printf 'PR_TARGET_GUARD: repair set the gh default to %s\n' "$TARGET"
  fi
}

# ------------------------------------------------------------------ pin mode

run_pin() {
  [ -d "$WORKTREE" ] || refuse "worktree '$WORKTREE' does not exist" 2
  git -C "$WORKTREE" rev-parse --git-dir >/dev/null 2>&1 \
    || refuse "worktree '$WORKTREE' is not a git checkout" 2

  local slug url me current
  slug=$(approved_repository "$WORKTREE" || true)
  if [ -z "$slug" ]; then
    [ "$PIN_OPTIONAL" = true ] \
      || refuse "worktree '$WORKTREE' has no approved repository identity (set firstmate.expectedRepository); refusing to guess one" 3
    printf 'PR_TARGET_GUARD: PINNED skipped=no-expected-repository worktree=%s\n' "$WORKTREE"
    return 0
  fi

  url=$(fm_git_base_verified_source_url "$WORKTREE" "$slug" 2>/dev/null) \
    || refuse "no configured remote URL in '$WORKTREE' resolves to the approved repository '$slug'; refusing to trust a remote name such as origin" 3

  me=$(authenticated_user) || refuse "the authenticated gh user could not be read" 3
  require_owned "$slug" "approved repository" "$me"

  current=$(git -C "$WORKTREE" remote get-url origin 2>/dev/null || true)
  if [ "$current" = "$url" ]; then
    printf 'PR_TARGET_GUARD: PINNED origin=%s target=%s (unchanged)\n' "$url" "$slug"
    return 0
  fi
  if [ -n "$current" ]; then
    git -C "$WORKTREE" remote set-url origin "$url" >/dev/null 2>&1 \
      || refuse "could not repoint '$WORKTREE' origin from '$current' to '$url'" 3
  else
    git -C "$WORKTREE" remote add origin "$url" >/dev/null 2>&1 \
      || refuse "could not add origin '$url' to '$WORKTREE'" 3
  fi
  printf 'PR_TARGET_GUARD: PINNED origin=%s target=%s (was %s)\n' "$url" "$slug" "${current:-none}"
}

# ----------------------------------------------------------------- gate mode

# The no-mistakes state database that holds the repos row the daemon reads. A
# gate lives at <state-dir>/repos/<repo-id>.git, so the database is that
# directory's grandparent. FM_NM_STATE_DB overrides it so a lab can point at
# its own database.
gate_state_db() { # <gate-dir>
  if [ -n "${FM_NM_STATE_DB:-}" ]; then
    printf '%s\n' "$FM_NM_STATE_DB"
    return 0
  fi
  local state_dir
  state_dir=$(cd "$1/../.." 2>/dev/null && pwd -P) || return 1
  printf '%s\n' "$state_dir/state.sqlite"
}

# The repository id the gate belongs to, taken from the gate's own directory
# name so the guard cannot be pointed at another repository's row.
gate_repo_id() { # <gate-dir>
  local base
  base=$(basename "$1")
  base=${base%.git}
  case $base in
    ''|*[!0-9a-fA-F]*) return 1 ;;
  esac
  printf '%s\n' "$base"
}

# One column of the gate's repos row, or nothing when it cannot be read. The
# id is validated hex by gate_repo_id before it reaches the query, so it cannot
# carry SQL.
gate_row_field() { # <db> <id> <select-expression>
  sqlite3 -noheader "$1" "SELECT $3 FROM repos WHERE id = '$2';" 2>/dev/null
}

run_gate() {
  [ -d "$GATE" ] || refuse "gate '$GATE' does not exist" 2
  git -C "$GATE" rev-parse --git-dir >/dev/null 2>&1 \
    || refuse "gate '$GATE' is not a git repository" 2
  case $GATE_REF in
    refs/heads/*) ;;
    '') refuse "gate mode requires --ref" 2 ;;
    *) refuse "refusing a non-branch push to '$GATE_REF'; only refs/heads/fm/* task branches are accepted" 1 ;;
  esac

  local me approved push_url base_url push_slug base_slug
  me=$(authenticated_user) || refuse "the authenticated gh user could not be read" 3

  # remote: every configured forge remote in the gate must be accepted and owned.
  local name url slug
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    url=$(git -C "$GATE" remote get-url "$name" 2>/dev/null || true)
    [ -n "$url" ] || continue
    case $url in
      /*) continue ;;  # the gate's own local path remote is not a forge target
    esac
    fm_project_origin_safe "$url" \
      || refuse "the gate remote '$name' has an unaccepted URL '$url'" 3
    slug=$(fm_git_base_repo_identity_from_url "$url") \
      || refuse "the gate remote '$name' does not name a github.com repository ('$url')" 3
    require_owned "$slug" "gate remote '$name' target" "$me"
  done < <(git -C "$GATE" remote 2>/dev/null || true)

  # target: read the destination from the row the daemon reads, never from the
  # gate's own remotes, so the boundary and the daemon cannot disagree.
  local db id row_default
  db=$(gate_state_db "$GATE") \
    || refuse "the gate's no-mistakes state database path could not be resolved" 3
  id=$(gate_repo_id "$GATE") \
    || refuse "the gate directory name does not name a no-mistakes repository id" 3
  command -v sqlite3 >/dev/null 2>&1 \
    || refuse "sqlite3 is not on PATH, so the gate's repository row cannot be read" 3
  [ -f "$db" ] \
    || refuse "the no-mistakes state database '$db' does not exist, so the destination cannot be verified" 3
  push_url=$(gate_row_field "$db" "$id" "COALESCE(NULLIF(TRIM(fork_url), ''), upstream_url)" || true)
  base_url=$(gate_row_field "$db" "$id" "upstream_url" || true)
  row_default=$(gate_row_field "$db" "$id" "default_branch" || true)
  [ -n "$push_url" ] \
    || refuse "the no-mistakes repos row for '$id' records no push destination, so no target can be verified" 3
  [ -n "$base_url" ] \
    || refuse "the no-mistakes repos row for '$id' records no pull-request base, so no target can be verified" 3
  push_slug=$(fm_git_base_repo_identity_from_url "$push_url") \
    || refuse "the row's push destination '$push_url' is not a github.com repository" 3
  base_slug=$(fm_git_base_repo_identity_from_url "$base_url") \
    || refuse "the row's pull-request base '$base_url' is not a github.com repository" 3

  approved=$(git -C "$GATE" config --get no-mistakes.prTarget 2>/dev/null || true)
  if [ -n "$approved" ]; then
    approved=$(normalize_identity "$approved") \
      || refuse "the gate's recorded approved repository '$approved' is not an <owner>/<repo> pair" 3
    [ "$push_slug" = "$approved" ] \
      || refuse "the row's push destination '$push_slug' is not the approved repository '$approved'" 1
    [ "$base_slug" = "$approved" ] \
      || refuse "the row's pull-request base '$base_slug' is not the approved repository '$approved'" 1
  fi

  # base/head: a task branch, never the default branch, both ids present. The
  # default branch name comes from the same row; its commit is not required to
  # exist in the gate because the run start that fetches it has not run yet.
  local branch default
  branch=${GATE_REF#refs/heads/}
  case $branch in
    fm/*) ;;
    *) refuse "refusing to accept '$GATE_REF'; a pull-request branch must be a refs/heads/fm/* task branch" 1 ;;
  esac
  default=$row_default
  [ -n "$default" ] || default=$(git -C "$GATE" symbolic-ref --short HEAD 2>/dev/null || true)
  [ -n "$default" ] || default=main
  [ "$branch" != "$default" ] || refuse "refusing a push to the default branch '$default'" 1
  [ -n "$GATE_NEW" ] || refuse "gate mode requires --new" 2
  git -C "$GATE" rev-parse --verify --quiet "$GATE_NEW^{commit}" >/dev/null \
    || refuse "the pushed object '$GATE_NEW' is not a commit in the gate" 3
  if [ -n "$GATE_OLD" ] && [ "$GATE_OLD" != "0000000000000000000000000000000000000000" ]; then
    git -C "$GATE" rev-parse --verify --quiet "$GATE_OLD^{commit}" >/dev/null \
      || refuse "the previous object '$GATE_OLD' is not a commit in the gate" 3
  fi

  # permission: the target must accept a push from the authenticated user.
  local can_push
  can_push=$(gh api "repos/$push_slug" --jq .permissions.push 2>/dev/null) \
    || refuse "push permission on '$push_slug' could not be read from the forge" 3
  [ "$can_push" = true ] \
    || refuse "the authenticated user '$me' cannot push to '$push_slug' (permissions.push=$can_push)" 1

  printf 'PR_TARGET_GUARD: PASS gate=%s ref=%s push=%s base=%s permission=true\n' \
    "$GATE" "$GATE_REF" "$push_slug" "$base_slug"
}

case $MODE in
  check) run_check ;;
  pin) run_pin ;;
  gate) run_gate ;;
  *) refuse "unknown mode '$MODE'" 2 ;;
esac
