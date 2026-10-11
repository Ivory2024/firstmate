#!/usr/bin/env bash
# Regression tests for bin/fm-nm-gate-guard.sh and the gate mode of
# bin/fm-pr-target-guard.sh: the fail-closed push boundary of a no-mistakes
# gate. The lab is a real bare gate repository and a real clone that pushes
# into it, so every rejection below is git's own pre-receive rejection and not
# a simulation; a stubbed gh on PATH answers the forge reads, so no live API is
# used and nothing is pushed anywhere.
#
# The lab gate is deliberately UNBORN: it has a symbolic HEAD of refs/heads/main
# and no commit on it, which is the shape of every real firstmate gate. A gate
# whose base branch had been planted would hide the defect this file guards
# against - a boundary that refuses every push into a gate whose base the run
# start has not fetched yet.
#
# The lab gate also carries the no-mistakes `repos` row the daemon reads, so the
# boundary's destination source is exercised, not the gate's own git remotes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-gate-guard)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

# The stub answers `gh api user`, an owner lookup per slug, a push-permission
# lookup, and the gh default read/write. Owner and permission come from files so
# one case can move a single field without touching the others.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TEST_GH_LOG:-/dev/null}"
owner_for() { # <slug>
  local line slug want
  want=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    slug=$(printf '%s' "${line%%=*}" | tr '[:upper:]' '[:lower:]')
    [ "$slug" = "$want" ] && { printf '%s\n' "${line#*=}"; return 0; }
  done < "${FM_TEST_GH_OWNERS:-/dev/null}"
  return 1
}
case "${1:-} ${2:-}" in
  "api user")
    [ "${FM_TEST_GH_USER_FAIL:-0}" -eq 0 ] || { echo 'gh: authentication required' >&2; exit 1; }
    printf '%s\n' "${FM_TEST_GH_USER:-Ivory2024}"
    ;;
  "api repos/"*)
    [ "${FM_TEST_GH_API_FAIL:-0}" -eq 0 ] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
    case "${4:-}" in
      .owner.login)
        owner_for "${2#repos/}" || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
        ;;
      .permissions.push)
        cat "${FM_TEST_GH_PUSH:-/dev/null}" 2>/dev/null || printf 'false\n'
        ;;
      *)
        echo "unexpected gh jq expression: ${4:-}" >&2
        exit 2
        ;;
    esac
    ;;
  "repo set-default")
    if [ "${3:-}" = --view ]; then
      [ -n "${FM_TEST_GH_DEFAULT:-}" ] || { echo 'no default repository set' >&2; exit 1; }
      printf '%s\n' "$FM_TEST_GH_DEFAULT"
      exit 0
    fi
    printf 'set %s as the default repository\n' "${3:-}"
    ;;
  "repo view")
    [ -n "${FM_TEST_GH_VIEW:-}" ] || { echo 'unable to determine current repository' >&2; exit 1; }
    printf '%s\n' "$FM_TEST_GH_VIEW"
    ;;
  *)
    echo "unexpected gh request: $*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$FAKEBIN/gh"

export FM_TEST_GH_LOG="$TMP_ROOT/gh.log"
: > "$FM_TEST_GH_LOG"
export FM_TEST_GH_USER=Ivory2024
export FM_TEST_GH_DEFAULT=''
export FM_TEST_GH_VIEW=''
export FM_TEST_GH_API_FAIL=0
export FM_TEST_GH_USER_FAIL=0
export FM_TEST_GH_OWNERS="$TMP_ROOT/owners"
export FM_TEST_GH_PUSH="$TMP_ROOT/push-permission"
printf 'ivory2024/firstmate=Ivory2024\nkunchenguid/firstmate=kunchenguid\n' > "$FM_TEST_GH_OWNERS"
printf 'true\n' > "$FM_TEST_GH_PUSH"

PATH="$FAKEBIN:$PATH"
export PATH

GUARD="$ROOT/bin/fm-pr-target-guard.sh"
INSTALLER="$ROOT/bin/fm-nm-gate-guard.sh"

LAB="$TMP_ROOT/lab"
SEED="$LAB/seed"
GATE_ID=0123456789ab
GATE="$LAB/$GATE_ID.git"
PUSH_CLONE="$LAB/push"
DB="$TMP_ROOT/state.sqlite"
mkdir -p "$LAB"

# The no-mistakes `repos` row the daemon reads. The guard must read this and not
# the gate's own remotes, so the lab carries the real schema and one row.
write_row() { # <upstream_url> <fork_url|-> <default_branch>
  local fork_sql
  if [ "$2" = '-' ]; then fork_sql=NULL; else fork_sql="'$2'"; fi
  rm -f "$DB"
  sqlite3 "$DB" "CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE, upstream_url TEXT NOT NULL, fork_url TEXT, default_branch TEXT NOT NULL DEFAULT 'main', created_at INTEGER NOT NULL);"
  sqlite3 "$DB" "INSERT INTO repos (id, working_path, upstream_url, fork_url, default_branch, created_at) VALUES ('$GATE_ID', '$LAB/work', '$1', $fork_sql, '$3', 0);"
}
export FM_NM_STATE_DB="$DB"

UP=https://github.com/kunchenguid/firstmate.git
FORK=https://github.com/Ivory2024/firstmate.git

git init -q -b main "$SEED"
git -C "$SEED" config user.email lab@example.invalid
git -C "$SEED" config user.name lab
printf 'lab\n' > "$SEED/a.txt"
git -C "$SEED" add a.txt
git -C "$SEED" commit -qm init

# The gate is a real bare repository whose HEAD is unborn: no refs/heads/main
# commit exists, exactly as on a live firstmate gate before its first run.
git init -q --bare "$GATE"
git -C "$GATE" symbolic-ref HEAD refs/heads/main
git -C "$GATE" config remote.origin.url "$FORK"
git -C "$GATE" config remote.fork.url "$FORK"

# The vendor seam. Real no-mistakes owns hooks/pre-receive, runs its daemon
# admit-push there, and execs hooks/pre-receive.no-mistakes-user when it is
# executable. This lab has no daemon, so the stub models only the documented
# chain, which is the part the boundary depends on.
write_vendor_hook() {
  cat > "$GATE/hooks/pre-receive" <<'SH'
#!/bin/sh
GATE_DIR=$(git rev-parse --absolute-git-dir 2>/dev/null || :)
USER_HOOK="$GATE_DIR/hooks/pre-receive.no-mistakes-user"
if [ -x "$USER_HOOK" ]; then
  exec "$USER_HOOK"
fi
exit 0
SH
  chmod 755 "$GATE/hooks/pre-receive"
}

git clone -q "$SEED" "$PUSH_CLONE"
git -C "$PUSH_CLONE" config user.email lab@example.invalid
git -C "$PUSH_CLONE" config user.name lab
git -C "$PUSH_CLONE" checkout -q -b fm/lab-task
printf 'work\n' > "$PUSH_CLONE/b.txt"
git -C "$PUSH_CLONE" add b.txt
git -C "$PUSH_CLONE" commit -qm work

STDERR_FILE="$TMP_ROOT/stderr"
CASE_OUT=
CASE_STATUS=
CASE_ERR=
PUSH_STATUS=
PUSH_ERR=

run_guard() { # <args...>; sets CASE_STATUS, CASE_OUT, CASE_ERR
  CASE_OUT=$("$GUARD" "$@" 2>"$STDERR_FILE")
  CASE_STATUS=$?
  CASE_ERR=$(cat "$STDERR_FILE")
}

run_installer() { # <args...>
  CASE_OUT=$("$INSTALLER" "$@" 2>"$STDERR_FILE")
  CASE_STATUS=$?
  CASE_ERR=$(cat "$STDERR_FILE")
}

push_branch() { # <refspec>; sets PUSH_STATUS, PUSH_ERR
  PUSH_ERR=$(git -C "$PUSH_CLONE" push "$GATE" "$1" 2>&1 >/dev/null)
  PUSH_STATUS=$?
}

# expect_true <label> <command...>: report the label as passed when the command
# succeeds and failed when it does not.
expect_true() {
  local label=$1
  shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

gate_head() { # <ref>
  git -C "$GATE" rev-parse "$1"
}

# --- install / status ----------------------------------------------------------

run_installer install "$GATE" Ivory2024/firstmate
expect_code 2 "$CASE_STATUS" "install without the vendor pre-receive seam must refuse"
assert_contains "$CASE_ERR" "no executable no-mistakes pre-receive hook" \
  "the refusal must say the seam a user hook would run from is absent"
expect_true "an install with no seam writes no hook" test ! -e "$GATE/hooks/pre-receive.no-mistakes-user"

write_vendor_hook

run_installer install "$GATE"
expect_code 2 "$CASE_STATUS" "install without an explicit target must be a request error"
assert_contains "$CASE_ERR" "requires the approved <owner>/<repo> target" \
  "the refusal must say the target is required"
expect_true "a refused install writes no hook" test ! -e "$GATE/hooks/pre-receive.no-mistakes-user"

run_installer install "$GATE" kunchenguid/firstmate
expect_code 3 "$CASE_STATUS" "install must refuse a target the authenticated user does not own"
expect_true "an unowned target installs no hook" test ! -e "$GATE/hooks/pre-receive.no-mistakes-user"

run_installer install "$GATE" Ivory2024/firstmate
expect_code 0 "$CASE_STATUS" "install on a gate whose row is not yet written must still record the target"
assert_contains "$CASE_OUT" "FM_NM_GATE_GUARD: installed gate=$GATE target=Ivory2024/firstmate" \
  "install must report the gate and the recorded target"
expect_true "install writes an executable user hook on the vendor seam" \
  test -x "$GATE/hooks/pre-receive.no-mistakes-user"

run_installer status "$GATE"
expect_code 0 "$CASE_STATUS" "status must succeed"
assert_contains "$CASE_OUT" "FM_NM_GATE_GUARD: installed gate=$GATE target=Ivory2024/firstmate" \
  "status must report the installed target"

# --- the unborn-HEAD gate still accepts a task branch --------------------------
# This is the regression the previous lab hid by planting refs/heads/main in the
# gate. A live firstmate gate has an unborn HEAD, so a boundary that demanded a
# base commit would refuse every push.

write_row "$FORK" "$FORK" main
GATE_BASE_SHA=$(git -C "$GATE" rev-parse --verify --quiet 'refs/heads/main^{commit}' || true)
expect_true "the lab gate has no refs/heads/main commit" test -z "$GATE_BASE_SHA"
push_branch fm/lab-task:refs/heads/fm/lab-task
expect_code 0 "$PUSH_STATUS" "a task branch pushed into an unborn-HEAD gate whose row names the approved repository must be accepted"
expect_true "the accepted push lands the exact pushed commit" \
  test "$(gate_head refs/heads/fm/lab-task)" = "$(git -C "$PUSH_CLONE" rev-parse HEAD)"

# --- the boundary reads the row, not the gate's own remotes --------------------

write_row "$UP" - main
push_branch fm/lab-task:refs/heads/fm/lab-task-unowned-push
expect_true "a push whose row names an unowned push destination is rejected" test "$PUSH_STATUS" -ne 0
assert_contains "$PUSH_ERR" "PR target guard refused" \
  "the rejection must come from the guard"
assert_contains "$PUSH_ERR" "kunchenguid/firstmate" \
  "the rejection must name the unowned repository"

write_row "$UP" "$FORK" main
push_branch fm/lab-task:refs/heads/fm/lab-task-unowned-base
expect_true "a push whose row names an unowned pull-request base is rejected" test "$PUSH_STATUS" -ne 0
assert_contains "$PUSH_ERR" "pull-request base" \
  "the rejection must name the pull-request base clause"
assert_contains "$PUSH_ERR" "kunchenguid/firstmate" \
  "the rejection must name the unowned repository"

# The gate's own remotes are the *other* source; moving only those must not move
# the boundary's verdict, which is what keeps guard and daemon from diverging.
git -C "$GATE" config remote.origin.url "$FORK"
git -C "$GATE" config remote.fork.url "$FORK"
push_branch fm/lab-task:refs/heads/fm/lab-task-gate-remotes-only
expect_true "gate remotes alone cannot make an unowned row pass" test "$PUSH_STATUS" -ne 0

# From here the row names the approved repository, so the remaining clauses are
# the only reason a case can be refused.
write_row "$FORK" "$FORK" main

# --- clause bite: recorded target disagrees with the row -----------------------

git -C "$GATE" config no-mistakes.prTarget kunchenguid/firstmate
run_guard --gate "$GATE" --ref refs/heads/fm/lab-task --old "$(gate_head refs/heads/fm/lab-task)" \
  --new "$(gate_head refs/heads/fm/lab-task)"
expect_code 1 "$CASE_STATUS" "a row destination that disagrees with the recorded approved repository must be refused"
assert_contains "$CASE_ERR" "is not the approved repository" \
  "the refusal must name the approved-repository mismatch"
git -C "$GATE" config no-mistakes.prTarget Ivory2024/firstmate

# --- clause bite: an unowned remote URL ---------------------------------------

git -C "$GATE" config remote.extra.url https://github.com/kunchenguid/firstmate.git
run_guard --gate "$GATE" --ref refs/heads/fm/lab-task --old "$(gate_head refs/heads/fm/lab-task)" \
  --new "$(gate_head refs/heads/fm/lab-task)"
expect_code 1 "$CASE_STATUS" "an unowned remote URL in the gate must be refused"
assert_contains "$CASE_ERR" "gate remote 'extra'" "the refusal must name the offending remote"
git -C "$GATE" config --unset remote.extra.url

git -C "$GATE" config remote.extra.url 'ext::sh -c "echo pwned"'
run_guard --gate "$GATE" --ref refs/heads/fm/lab-task --old "$(gate_head refs/heads/fm/lab-task)" \
  --new "$(gate_head refs/heads/fm/lab-task)"
expect_code 3 "$CASE_STATUS" "a remote-helper URL in the gate must be refused as unverifiable"
assert_contains "$CASE_ERR" "unaccepted URL" "the refusal must name the unaccepted URL"
git -C "$GATE" config --unset remote.extra.url

# --- clause bite: base/head ----------------------------------------------------

run_guard --gate "$GATE" --ref refs/heads/main --old "$(gate_head refs/heads/fm/lab-task)" \
  --new "$(gate_head refs/heads/fm/lab-task)"
expect_code 1 "$CASE_STATUS" "a push to the default branch must be refused"
assert_contains "$CASE_ERR" "task branch" "the refusal must explain the branch rule"

run_guard --gate "$GATE" --ref refs/tags/fm-lab --old "$(gate_head refs/heads/fm/lab-task)" \
  --new "$(gate_head refs/heads/fm/lab-task)"
expect_code 1 "$CASE_STATUS" "a non-branch push must be refused"
assert_contains "$CASE_ERR" "non-branch push" "the refusal must name the non-branch push"

run_guard --gate "$GATE" --ref refs/heads/fm/lab-task --old "$(gate_head refs/heads/fm/lab-task)" \
  --new 0000000000000000000000000000000000000000
expect_code 3 "$CASE_STATUS" "a pushed object that is not a commit in the gate must be refused"
assert_contains "$CASE_ERR" "is not a commit in the gate" "the refusal must name the missing commit"

run_guard --gate "$GATE" --ref refs/heads/fm/lab-task --old "$(gate_head refs/heads/fm/lab-task)"
expect_code 2 "$CASE_STATUS" "gate mode without --new must be a request error"
assert_contains "$CASE_ERR" "requires --new" "the refusal must name the missing --new"

# --- clause bite: the destination source --------------------------------------

export FM_NM_STATE_DB="$TMP_ROOT/absent.sqlite"
run_guard --gate "$GATE" --ref refs/heads/fm/lab-task --old "$(gate_head refs/heads/fm/lab-task)" \
  --new "$(gate_head refs/heads/fm/lab-task)"
expect_code 3 "$CASE_STATUS" "a gate whose repos row cannot be read must refuse rather than guess"
assert_contains "$CASE_ERR" "does not exist" "the refusal must name the unreadable state database"

rm -f "$TMP_ROOT/empty.sqlite"
sqlite3 "$TMP_ROOT/empty.sqlite" "CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE, upstream_url TEXT NOT NULL, fork_url TEXT, default_branch TEXT NOT NULL DEFAULT 'main', created_at INTEGER NOT NULL);"
export FM_NM_STATE_DB="$TMP_ROOT/empty.sqlite"
run_guard --gate "$GATE" --ref refs/heads/fm/lab-task --old "$(gate_head refs/heads/fm/lab-task)" \
  --new "$(gate_head refs/heads/fm/lab-task)"
expect_code 3 "$CASE_STATUS" "a gate with no repos row must refuse rather than guess"
assert_contains "$CASE_ERR" "records no push destination" "the refusal must name the missing row"
export FM_NM_STATE_DB="$DB"

# --- clause bite: push permission ---------------------------------------------

printf 'false\n' > "$FM_TEST_GH_PUSH"
run_guard --gate "$GATE" --ref refs/heads/fm/lab-task --old "$(gate_head refs/heads/fm/lab-task)" \
  --new "$(gate_head refs/heads/fm/lab-task)"
expect_code 1 "$CASE_STATUS" "a target the authenticated user cannot push to must be refused"
assert_contains "$CASE_ERR" "cannot push to 'ivory2024/firstmate'" \
  "the refusal must name the missing push permission"
printf 'true\n' > "$FM_TEST_GH_PUSH"

# --- the failure path: no forge answer at all ---------------------------------

export FM_TEST_GH_USER_FAIL=1
run_guard --gate "$GATE" --ref refs/heads/fm/lab-task --old "$(gate_head refs/heads/fm/lab-task)" \
  --new "$(gate_head refs/heads/fm/lab-task)"
expect_code 3 "$CASE_STATUS" "an unreadable authenticated user must refuse"
assert_not_contains "$CASE_OUT" "PASS" "an unverifiable gate must never print a pass verdict"
export FM_TEST_GH_USER_FAIL=0

export FM_TEST_GH_API_FAIL=1
push_branch fm/lab-task:refs/heads/fm/lab-task2
expect_true "an unreadable forge makes the boundary reject the push" test "$PUSH_STATUS" -ne 0
export FM_TEST_GH_API_FAIL=0

# --- the boundary survives the vendor hook's own refresh ----------------------
# no-mistakes owns and reinstalls hooks/pre-receive, so the boundary must live on
# the seam that hook execs and be untouched when the vendor hook is rewritten. A
# real accepted push runs the vendor hook, and the boundary must be
# byte-identical afterwards.

cp "$GATE/hooks/pre-receive.no-mistakes-user" "$TMP_ROOT/hook.before"
cp "$GATE/hooks/pre-receive" "$TMP_ROOT/vendor.before"
write_vendor_hook
expect_true "the lab's vendor hook rewrite is byte-identical, so this case isolates the boundary" \
  cmp -s "$TMP_ROOT/vendor.before" "$GATE/hooks/pre-receive"
push_branch fm/lab-task:refs/heads/fm/lab-task4
expect_code 0 "$PUSH_STATUS" "the accepted push must run the vendor hook chain"
expect_true "the boundary hook is unchanged after the vendor hook was refreshed and ran" \
  cmp -s "$TMP_ROOT/hook.before" "$GATE/hooks/pre-receive.no-mistakes-user"

# --- remove -------------------------------------------------------------------

run_installer remove "$GATE"
expect_code 0 "$CASE_STATUS" "remove must succeed"
expect_true "remove deletes the boundary hook" test ! -e "$GATE/hooks/pre-receive.no-mistakes-user"
expect_true "remove leaves the vendor hook in place" test -x "$GATE/hooks/pre-receive"
expect_true "remove clears the recorded approved target" \
  test -z "$(git -C "$GATE" config --get no-mistakes.prTarget 2>/dev/null || true)"

write_row "$UP" - main
push_branch fm/lab-task:refs/heads/fm/lab-task3
expect_code 0 "$PUSH_STATUS" "with the boundary removed the unowned row no longer refuses the push"

# --- install refuses to clobber a foreign user hook ---------------------------

printf '#!/bin/sh\nexit 0\n' > "$GATE/hooks/pre-receive.no-mistakes-user"
chmod 755 "$GATE/hooks/pre-receive.no-mistakes-user"
run_installer install "$GATE" Ivory2024/firstmate
expect_code 2 "$CASE_STATUS" "install must refuse a user hook it did not write"
assert_contains "$CASE_ERR" "refusing to overwrite" "the refusal must say the hook is foreign"
rm -f "$GATE/hooks/pre-receive.no-mistakes-user"

echo '# all fm-nm-gate-guard tests passed'
