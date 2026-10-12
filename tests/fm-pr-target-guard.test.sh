#!/usr/bin/env bash
# Regression tests for bin/fm-pr-target-guard.sh: the fail-closed check that a
# pull-request target repository is owned by the authenticated gh user.
# A stubbed gh on PATH answers every forge read, so no live API is used.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-target-guard)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_TEST_GH_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
fi
case "${1:-} ${2:-}" in
  "repo set-default")
    if [ "${3:-}" = --view ]; then
      [ -n "${FM_TEST_GH_DEFAULT:-}" ] || { echo 'no default repository set' >&2; exit 1; }
      printf '%s\n' "$FM_TEST_GH_DEFAULT"
      exit 0
    fi
    if [ "${FM_TEST_GH_SET_DEFAULT_RC:-0}" -ne 0 ]; then
      echo 'could not set the default repository' >&2
      exit "${FM_TEST_GH_SET_DEFAULT_RC}"
    fi
    printf 'set %s as the default repository\n' "${3:-}"
    exit 0
    ;;
  "repo view")
    [ -n "${FM_TEST_GH_VIEW:-}" ] || { echo 'unable to determine current repository' >&2; exit 1; }
    printf '%s\n' "$FM_TEST_GH_VIEW"
    exit 0
    ;;
  "api repos/"*)
    [ "${FM_TEST_GH_API_FAIL:-0}" -eq 0 ] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
    printf '%s\n' "${FM_TEST_GH_OWNER:-Ivory2024}"
    exit 0
    ;;
  "api user")
    [ "${FM_TEST_GH_USER_FAIL:-0}" -eq 0 ] || { echo 'gh: authentication required' >&2; exit 1; }
    printf '%s\n' "${FM_TEST_GH_USER:-Ivory2024}"
    exit 0
    ;;
  *)
    echo "unexpected gh request: $*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$FAKEBIN/gh"

export FM_TEST_GH_LOG="$TMP_ROOT/gh.log"
export FM_TEST_GH_DEFAULT=''
export FM_TEST_GH_VIEW=''
export FM_TEST_GH_OWNER='Ivory2024'
export FM_TEST_GH_USER='Ivory2024'
export FM_TEST_GH_API_FAIL=0
export FM_TEST_GH_USER_FAIL=0
export FM_TEST_GH_SET_DEFAULT_RC=0

GH_LOG="$FM_TEST_GH_LOG"
STDERR_FILE="$TMP_ROOT/stderr"
CASE_OUT=
CASE_STATUS=
CASE_ERR=

# Run the guard with the stubbed gh first on PATH, capturing its stdout,
# stderr, and exit status for the assertions that follow.
run_guard() {
  CASE_OUT=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-pr-target-guard.sh" "$@" 2>"$STDERR_FILE")
  CASE_STATUS=$?
  CASE_ERR=$(cat "$STDERR_FILE")
}

reset_gh() {
  : > "$GH_LOG"
  FM_TEST_GH_DEFAULT=''
  FM_TEST_GH_VIEW=''
  FM_TEST_GH_OWNER='Ivory2024'
  FM_TEST_GH_USER='Ivory2024'
  FM_TEST_GH_API_FAIL=0
  FM_TEST_GH_USER_FAIL=0
  FM_TEST_GH_SET_DEFAULT_RC=0
}

test_owned_target_passes() {
  reset_gh
  FM_TEST_GH_DEFAULT='Ivory2024/firstmate'
  run_guard Ivory2024/firstmate
  expect_code 0 "$CASE_STATUS" "an owned target must pass"
  assert_contains "$CASE_OUT" 'PR_TARGET_GUARD: PASS target=Ivory2024/firstmate owner=Ivory2024' \
    "the pass verdict must name the verified target and owner"
  assert_contains "$CASE_OUT" '--repo Ivory2024/firstmate' \
    "the pass must print the exact --repo value to use"
  pass "an owned target passes and prints its --repo value"
}

test_unowned_target_fails_closed() {
  reset_gh
  FM_TEST_GH_OWNER='kunchenguid'
  run_guard Ivory2024/firstmate
  expect_code 1 "$CASE_STATUS" "a target owned by another account must be refused"
  assert_contains "$CASE_ERR" "target 'Ivory2024/firstmate' is owned by 'kunchenguid', not the authenticated user 'Ivory2024'" \
    "the refusal must name the real owner and the authenticated user"
  assert_not_contains "$CASE_OUT" '--repo' \
    "a refused target must not print a --repo value to use"
  pass "an unowned target fails closed"
}

test_authenticated_user_mismatch_fails_closed() {
  reset_gh
  FM_TEST_GH_USER='someone-else'
  run_guard Ivory2024/firstmate
  expect_code 1 "$CASE_STATUS" "a target not owned by the authenticated user must be refused"
  assert_contains "$CASE_ERR" "not the authenticated user 'someone-else'" \
    "the refusal must name the authenticated user"
  pass "an authenticated user that does not own the target fails closed"
}

test_unreadable_owner_fails_closed() {
  reset_gh
  FM_TEST_GH_API_FAIL=1
  run_guard Ivory2024/firstmate
  expect_code 3 "$CASE_STATUS" "an unreadable owner must refuse rather than pass"
  assert_contains "$CASE_ERR" "the owner of 'Ivory2024/firstmate' could not be read from the forge" \
    "the refusal must name the failed ownership read"
  assert_not_contains "$CASE_OUT" 'PASS' \
    "an unverified target must never print a pass verdict"
  pass "an unreadable target fails closed"
}

test_unreadable_user_fails_closed() {
  reset_gh
  FM_TEST_GH_USER_FAIL=1
  run_guard Ivory2024/firstmate
  expect_code 3 "$CASE_STATUS" "an unreadable authenticated user must refuse"
  assert_contains "$CASE_ERR" "the authenticated gh user could not be read" \
    "the refusal must name the failed user read"
  pass "an unreadable authenticated user fails closed"
}

test_unresolvable_target_fails_closed() {
  reset_gh
  run_guard
  expect_code 3 "$CASE_STATUS" "an omitted target that gh cannot resolve must refuse"
  assert_contains "$CASE_ERR" "no repository could be resolved for this directory" \
    "the refusal must say the target could not be resolved"
  pass "an unresolvable omitted target fails closed"
}

test_omitted_target_uses_gh_default() {
  reset_gh
  FM_TEST_GH_DEFAULT='Ivory2024/firstmate'
  run_guard
  expect_code 0 "$CASE_STATUS" "an omitted target must resolve through the gh default"
  assert_contains "$CASE_OUT" '--repo Ivory2024/firstmate' \
    "the resolved owned target must print its --repo value"
  pass "an omitted target resolves through the gh default"
}

test_omitted_target_falls_back_to_gh_repo_view() {
  reset_gh
  FM_TEST_GH_VIEW='Ivory2024/firstmate'
  run_guard
  expect_code 0 "$CASE_STATUS" "an omitted target must fall back to gh repo view's resolution"
  assert_contains "$CASE_OUT" '--repo Ivory2024/firstmate' \
    "the resolved owned target must print its --repo value"
  pass "an omitted target falls back to gh repo view when no default is recorded"
}

test_disagreeing_default_is_reported() {
  reset_gh
  FM_TEST_GH_DEFAULT='kunchenguid/firstmate'
  run_guard Ivory2024/firstmate
  expect_code 0 "$CASE_STATUS" "a verified explicit target must still pass with a disagreeing default"
  assert_contains "$CASE_OUT" 'PR_TARGET_GUARD: default=kunchenguid/firstmate disagrees with the verified target Ivory2024/firstmate' \
    "a disagreeing gh default must be reported"
  assert_contains "$CASE_OUT" 'pass --repo Ivory2024/firstmate explicitly' \
    "the disagreement must point at the explicit --repo value"
  pass "a gh default that disagrees with the verified target is reported"
}

test_missing_default_is_reported() {
  reset_gh
  run_guard Ivory2024/firstmate
  expect_code 0 "$CASE_STATUS" "a verified explicit target must pass with no recorded default"
  assert_contains "$CASE_OUT" 'no gh default resolved for this directory; pass --repo Ivory2024/firstmate explicitly' \
    "the absence of a resolved default must be reported"
  pass "the absence of a resolved gh default is reported"
}

test_repair_refuses_on_unverified_owner() {
  reset_gh
  FM_TEST_GH_OWNER='kunchenguid'
  run_guard Ivory2024/firstmate --repair
  expect_code 1 "$CASE_STATUS" "repair must refuse an unowned target"
  assert_no_grep 'repo set-default Ivory2024/firstmate' "$GH_LOG" \
    "repair must not set a default for an unverified owner"
  assert_not_contains "$CASE_OUT" 'repair set the gh default' \
    "repair must not report a repair it did not perform"
  pass "the repair path refuses on an unverified owner"
}

test_repair_refuses_when_owner_unreadable() {
  reset_gh
  FM_TEST_GH_API_FAIL=1
  run_guard Ivory2024/firstmate --repair
  expect_code 3 "$CASE_STATUS" "repair must refuse when ownership cannot be read"
  assert_no_grep 'repo set-default Ivory2024/firstmate' "$GH_LOG" \
    "repair must not set a default when ownership could not be verified"
  pass "the repair path refuses when ownership cannot be verified"
}

test_repair_pins_verified_target() {
  reset_gh
  run_guard Ivory2024/firstmate --repair
  expect_code 0 "$CASE_STATUS" "repair must succeed on a verified owned target"
  assert_contains "$CASE_OUT" 'PR_TARGET_GUARD: repair set the gh default to Ivory2024/firstmate' \
    "repair must report the default it set"
  assert_grep 'repo set-default Ivory2024/firstmate' "$GH_LOG" \
    "repair must set the verified target as the gh default"
  pass "the repair path pins a verified owned target as the gh default"
}

test_repair_failure_fails_closed() {
  reset_gh
  FM_TEST_GH_SET_DEFAULT_RC=1
  run_guard Ivory2024/firstmate --repair
  expect_code 3 "$CASE_STATUS" "a failed default write must refuse"
  assert_contains "$CASE_ERR" "setting it as this directory's gh default failed" \
    "the refusal must name the failed default write"
  pass "a failed repair fails closed"
}

test_invalid_request_is_refused() {
  reset_gh
  run_guard firstmate
  expect_code 2 "$CASE_STATUS" "a target that is not <owner>/<repo> must be a request error"
  assert_contains "$CASE_ERR" "is not an <owner>/<repo> pair" \
    "the refusal must name the malformed target"
  run_guard Ivory2024/firstmate --nonsense
  expect_code 2 "$CASE_STATUS" "an unknown option must be a request error"
  assert_contains "$CASE_ERR" "unknown option '--nonsense'" \
    "the refusal must name the unknown option"
  pass "a malformed target and an unknown option are refused"
}

test_owned_target_passes
test_unowned_target_fails_closed
test_authenticated_user_mismatch_fails_closed
test_unreadable_owner_fails_closed
test_unreadable_user_fails_closed
test_unresolvable_target_fails_closed
test_omitted_target_uses_gh_default
test_omitted_target_falls_back_to_gh_repo_view
test_disagreeing_default_is_reported
test_missing_default_is_reported
test_repair_refuses_on_unverified_owner
test_repair_refuses_when_owner_unreadable
test_repair_pins_verified_target
test_repair_failure_fails_closed
test_invalid_request_is_refused

echo '# all fm-pr-target-guard tests passed'
