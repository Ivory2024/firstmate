#!/usr/bin/env bash
# Behavior tests for bin/fm-blocker-classify-lib.sh and its status-line reader.
#
# Exercises the classifier's PUBLIC function interface with real inputs and
# asserts the emitted (TYPE, subcause, retry_policy) rows, plus the backward
# compatibility of the status-line key parsing. No live provider, no network.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
. "$ROOT/bin/fm-blocker-classify-lib.sh"

fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; fails=$((fails + 1)); }

# assert_row <label> <expected-TYPE> <expected-subcause> <expected-policy> <args...>
assert_row() {
  local label=$1 et=$2 es=$3 ep=$4; shift 4
  local row t s p
  row=$(fm_blocker_classify "$@")
  t=${row%%$'\t'*}; row=${row#*$'\t'}; s=${row%%$'\t'*}; p=${row#*$'\t'}
  if [ "$t" = "$et" ] && [ "$s" = "$es" ] && [ "$p" = "$ep" ]; then
    pass "$label"
  else
    fail "$label (got '$t/$s/$p', want '$et/$es/$ep')"
  fi
}

# 1. real assertion failure -> CODE_BLOCKED
assert_row "1 assertion failure -> CODE_BLOCKED" CODE_BLOCKED test_assertion none \
  test 'not ok - expected 200 but got 401'
assert_row "1b structured test_assertion -> CODE_BLOCKED" CODE_BLOCKED test_assertion none \
  test 'x' test_assertion

# 2. CI runner failure -> INFRA_BLOCKED
assert_row "2 runner shutdown -> INFRA_BLOCKED" INFRA_BLOCKED infra limited \
  ci 'the runner has received a shutdown signal'
assert_row "2b structured ci_runner -> INFRA_BLOCKED" INFRA_BLOCKED runner limited \
  ci 'x' ci_runner
# 2c disk quota exhaustion is INFRASTRUCTURE, not a provider quota hit, even
# though its message carries the word "quota".
assert_row "2c disk quota -> INFRA_BLOCKED (not PROVIDER)" INFRA_BLOCKED disk limited \
  ci 'disk quota exceeded while fetching the cache'
assert_row "2c2 disk space -> INFRA_BLOCKED" INFRA_BLOCKED disk limited \
  ci 'the build failed: no disk space on the workspace volume'

# 3. codex quota -> PROVIDER_BLOCKED
assert_row "3 codex quota -> PROVIDER_BLOCKED" PROVIDER_BLOCKED quota_exhausted wait \
  review "You've hit your usage limit. try again at 2:08 PM"

# 4. quota during the review STAGE is still PROVIDER_BLOCKED (not REVIEW_BLOCKED)
assert_row "4 review-stage quota -> PROVIDER_BLOCKED" PROVIDER_BLOCKED quota_exhausted wait \
  review 'step review failed: agent review: usage limit exceeded'

# 5. reviewer change request -> REVIEW_BLOCKED
assert_row "5 reviewer request -> REVIEW_BLOCKED" REVIEW_BLOCKED changes_requested none \
  review 'x' review_changes_requested
assert_row "5b text changes requested -> REVIEW_BLOCKED" REVIEW_BLOCKED changes_requested none \
  review 'the reviewer said changes requested on two files'

# 6. unknown cause -> UNKNOWN_BLOCKED
assert_row "6 unknown cause -> UNKNOWN_BLOCKED" UNKNOWN_BLOCKED no_evidence none \
  ci 'something odd happened'

# 7. PROVIDER quota waits (no unnecessary retry before reset)
assert_row "7 quota policy = wait (no retry)" PROVIDER_BLOCKED quota_exhausted wait \
  review 'you have hit your usage limit'

# 8. provider recovery uses the official pipeline: rate_limit is bounded, quota waits
assert_row "8a transient rate limit -> limited" PROVIDER_BLOCKED rate_limit limited \
  test 'provider rate limit hit'
assert_row "8b quota -> wait (recovery via official pipeline)" PROVIDER_BLOCKED quota_exhausted wait \
  ci 'quota exhausted'

# 9. deterministic / idempotent (no duplicate classification drift)
r1=$(fm_blocker_classify review 'usage limit'); r2=$(fm_blocker_classify review 'usage limit')
if [ "$r1" = "$r2" ]; then pass "9 deterministic classification (no duplicate run drift)"
else fail "9 classification is not deterministic ('$r1' vs '$r2')"; fi

# 10. pure library: sourcing + classifying creates no state and touches no lane.
# Fingerprint the ENTIRE state tree (path + content hash), not just a count, so an
# edit or a silent rewrite of an existing file is caught, not only an addition.
state_signature() {
  ( cd "$ROOT" && find state -type f -exec cksum {} + 2>/dev/null | LC_ALL=C sort )
}
before=$(state_signature)
fm_blocker_classify test 'not ok' >/dev/null
fm_blocker_classify review 'usage limit' 'provider_quota' >/dev/null
fm_blocker_retry_after 'reset at 2026-10-08T05:08:05Z' >/dev/null
after=$(state_signature)
if [ "$before" = "$after" ]; then pass "10 classifier is side-effect free (state tree unchanged)"
else fail "10 classifier changed state ('$before' -> '$after')"; fi

# --- required extra validations -------------------------------------------

# auth failure is NOT quota
assert_row "E1 provider auth failure is NOT quota" UNKNOWN_BLOCKED provider_auth manual \
  review 'auth error: invalid api key for provider' provider_auth_failed

# the word 'review' alone is not a review finding
assert_row "E2 bare word 'review' -> UNKNOWN" UNKNOWN_BLOCKED no_evidence none \
  ci 'please review the logs before continuing'

# unknown blocker value handling in the status-line reader
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
assert_blocker() {
  local label=$1 want=$2 line=$3 got
  got=$(fm_status_line_blocker "$line")
  if [ "$got" = "$want" ]; then pass "$label"; else fail "$label (got '$got', want '$want')"; fi
}
assert_blocker "E3 known blocker key parsed" PROVIDER_BLOCKED \
  'blocked [blocker=PROVIDER_BLOCKED] [stage=review]: usage limit'
assert_blocker "E4 unknown blocker value -> UNKNOWN_BLOCKED" UNKNOWN_BLOCKED \
  'blocked [blocker=WAT] [stage=review]: odd'
assert_blocker "E5 absent blocker key -> empty (legacy record)" '' \
  'blocked: daemon socket down'
assert_blocker "E6 review-stage quota key is PROVIDER" PROVIDER_BLOCKED \
  'blocked [blocker=PROVIDER_BLOCKED] [stage=review] [retry-after=2026-10-08T05:08:05Z]: quota'

# E6b: a documented [retry-after=<ISO>] header contains colons. It must not be
# mistaken for the head/note separator, which used to hand back "08:05Z]: quota".
assert_note() {
  local label=$1 want=$2 line=$3 got
  got=$(status_line_note "$line")
  if [ "$got" = "$want" ]; then pass "$label"; else fail "$label (got '$got', want '$want')"; fi
}
assert_note "E6b retry-after header leaves the note intact" quota \
  'blocked [blocker=PROVIDER_BLOCKED] [stage=review] [retry-after=2026-10-08T05:08:05Z]: quota'

# structured vs text conflict -> safe UNKNOWN
assert_row "E7 conflicting evidence -> UNKNOWN" UNKNOWN_BLOCKED conflicting_evidence none \
  ci 'the runner has received a shutdown signal' provider_quota

# retry_after extraction: the contract promises an ISO-8601 UTC reset time, so
# the exact value is asserted, not merely "nonempty".
ra=$(fm_blocker_retry_after "quota exhausted; reset at 2026-10-08T05:08:05Z")
if [ "$ra" = '2026-10-08T05:08:05Z' ]; then
  pass "E8 retry_after extracts ISO-8601 UTC ('$ra')"
else
  fail "E8 retry_after = '$ra', want 2026-10-08T05:08:05Z"
fi
# A bare clock carries no timezone; guessing UTC would schedule the wrong
# instant, so it must yield empty rather than a fake reset time.
ra_clock=$(fm_blocker_retry_after "You've hit your usage limit. try again at 14:08 KST")
if [ -z "$ra_clock" ]; then
  pass "E8b bare clock is not a UTC reset time"
else
  fail "E8b guessed a UTC reset from a bare clock: '$ra_clock'"
fi

printf '\n'
if [ "$fails" -eq 0 ]; then
  echo "# all fm-blocker-classify tests passed"
  exit 0
fi
echo "# fm-blocker-classify: $fails failure(s)"
exit 1
