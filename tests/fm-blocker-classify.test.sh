#!/usr/bin/env bash
# Behavior tests for bin/fm-blocker-classify-lib.sh and its status-line reader.
#
# Exercises the classifier's PUBLIC function interface with real inputs and
# asserts the emitted (TYPE, subcause) rows, plus the backward
# compatibility of the status-line key parsing. No live provider, no network.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
. "$ROOT/bin/fm-blocker-classify-lib.sh"

fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; fails=$((fails + 1)); }

# assert_row <label> <expected-TYPE> <expected-subcause> <args...>
assert_row() {
  local label=$1 et=$2 es=$3; shift 3
  local row t s
  row=$(fm_blocker_classify "$@")
  t=${row%%$'\t'*}; s=${row#*$'\t'}
  if [ "$t" = "$et" ] && [ "$s" = "$es" ]; then
    pass "$label"
  else
    fail "$label (got '$t/$s', want '$et/$es')"
  fi
}

# 1. real assertion failure -> CODE_BLOCKED
assert_row "1 assertion failure -> CODE_BLOCKED" CODE_BLOCKED test_assertion \
  test 'not ok - expected 200 but got 401'
assert_row "1b structured test_assertion -> CODE_BLOCKED" CODE_BLOCKED test_assertion \
  test 'x' test_assertion

# 2. CI runner failure -> INFRA_BLOCKED
assert_row "2 runner shutdown -> INFRA_BLOCKED" INFRA_BLOCKED infra \
  ci 'the runner has received a shutdown signal'
assert_row "2b structured ci_runner -> INFRA_BLOCKED" INFRA_BLOCKED runner \
  ci 'x' ci_runner
# 2c disk quota exhaustion is INFRASTRUCTURE, not a provider quota hit, even
# though its message carries the word "quota".
assert_row "2c disk quota -> INFRA_BLOCKED (not PROVIDER)" INFRA_BLOCKED disk \
  ci 'disk quota exceeded while fetching the cache'
assert_row "2c2 disk space -> INFRA_BLOCKED" INFRA_BLOCKED disk \
  ci 'the build failed: no disk space on the workspace volume'

# 3. codex quota -> PROVIDER_BLOCKED
assert_row "3 codex quota -> PROVIDER_BLOCKED" PROVIDER_BLOCKED quota_exhausted \
  review "You've hit your usage limit. try again at 2:08 PM"

# 4. quota during the review STAGE is still PROVIDER_BLOCKED (not REVIEW_BLOCKED)
assert_row "4 review-stage quota -> PROVIDER_BLOCKED" PROVIDER_BLOCKED quota_exhausted \
  review 'step review failed: agent review: usage limit exceeded'

# 5. reviewer change request -> REVIEW_BLOCKED
assert_row "5 reviewer request -> REVIEW_BLOCKED" REVIEW_BLOCKED changes_requested \
  review 'x' review_changes_requested
assert_row "5b text changes requested -> REVIEW_BLOCKED" REVIEW_BLOCKED changes_requested \
  review 'the reviewer said changes requested on two files'

# 6. unknown cause -> UNKNOWN_BLOCKED
assert_row "6 unknown cause -> UNKNOWN_BLOCKED" UNKNOWN_BLOCKED no_evidence \
  ci 'something odd happened'

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
after=$(state_signature)
if [ "$before" = "$after" ]; then pass "10 classifier is side-effect free (state tree unchanged)"
else fail "10 classifier changed state ('$before' -> '$after')"; fi

# --- required extra validations -------------------------------------------

# auth failure is NOT quota
assert_row "E1 provider auth failure is NOT quota" UNKNOWN_BLOCKED provider_auth \
  review 'auth error: invalid api key for provider' provider_auth_failed

# the word 'review' alone is not a review finding
assert_row "E2 bare word 'review' -> UNKNOWN" UNKNOWN_BLOCKED no_evidence \
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

# structured vs text conflict -> safe UNKNOWN
assert_row "E7 conflicting evidence -> UNKNOWN" UNKNOWN_BLOCKED conflicting_evidence \
  ci 'the runner has received a shutdown signal' provider_quota

# --- independent-review regressions (captain, 2026-10-10) ---------------------

# F1 provider outage / unavailable text is a PROVIDER failure, not quota.
assert_row "F1 provider outage text -> PROVIDER_BLOCKED" PROVIDER_BLOCKED provider_outage \
  run 'the provider outage began mid-step and every call failed'
assert_row "F1b provider unavailable text -> PROVIDER_BLOCKED" PROVIDER_BLOCKED provider_outage \
  run 'provider unavailable: 503 returned for every retry'
assert_row "F1c structured provider_outage agrees with its text -> PROVIDER_BLOCKED" PROVIDER_BLOCKED provider_outage \
  run 'provider outage' provider_outage
# an outage message that also reports a quota hit stays a quota hit: quota is
# checked first, so the shared outage word cannot steal it.
assert_row "F1d outage plus quota text -> quota_exhausted" PROVIDER_BLOCKED quota_exhausted \
  run 'usage limit reached while the provider outage was still reported'

# F2 a structured code and conflicting text stay UNKNOWN in both directions.
assert_row "F2 structured CODE code vs INFRA text -> UNKNOWN" UNKNOWN_BLOCKED conflicting_evidence \
  test 'the runner has received a shutdown signal' test_assertion
assert_row "F2b structured REVIEW code vs PROVIDER outage text -> UNKNOWN" UNKNOWN_BLOCKED conflicting_evidence \
  review 'provider outage reported by the API' review_changes_requested
assert_row "F2c structured PROVIDER code vs REVIEW text -> UNKNOWN" UNKNOWN_BLOCKED conflicting_evidence \
  review 'the reviewer said changes requested' provider_quota

# F3 every other evidence gap still lands on an UNKNOWN fallback.
assert_row "F3 unrecognized structured code -> UNKNOWN" UNKNOWN_BLOCKED unknown_code \
  ci 'x' some_new_code
assert_row "F3b no matching evidence -> UNKNOWN" UNKNOWN_BLOCKED no_evidence \
  ci 'nothing here matches anything'
# the caller-supplied stage never changes the verdict.
assert_row "F3c stage alone decides nothing" UNKNOWN_BLOCKED no_evidence \
  review 'please review the logs before continuing'

# F4 no function local leaks into the caller's scope. This is the independent
# review's regression: `code_type` was assigned without `local`, and the lib is
# sourced by fm-crew-state.sh, the watcher and teardown, so a leaked value would
# corrupt their own variables.
FM_BLOCKER_LOCALS='stage cause code text_code from_text from_code type sub text_type code_type'
for _v in $FM_BLOCKER_LOCALS; do
  eval "$_v=LEAK_SENTINEL_$_v"
done
leak_row=$(fm_blocker_classify ci 'the runner has received a shutdown signal' provider_quota)
leak_leaked=''
for _v in $FM_BLOCKER_LOCALS; do
  if [ "$(eval "printf '%s' \"\$$_v\"")" != "LEAK_SENTINEL_$_v" ]; then
    leak_leaked="$leak_leaked $_v"
  fi
done
# shellcheck disable=SC2086  # deliberate word splitting over the local-name list
unset $FM_BLOCKER_LOCALS 2>/dev/null || true
if [ -z "$leak_leaked" ]; then
  pass "F4 fm_blocker_classify leaves every local out of the caller scope"
else
  fail "F4 fm_blocker_classify leaked:$leak_leaked"
fi
# the conflict row is still produced through the very call that probes for leaks.
case "${leak_row%%$'\t'*}" in
  UNKNOWN_BLOCKED) pass "F4b the conflict row survives the leak probe" ;;
  *) fail "F4b the conflict row changed ('$leak_row')" ;;
esac

# F5 Bash 3.2 compatibility. The CI lane that pins stock macOS Bash only parses
# these files with `/bin/bash -n`, so this regression must prove the classifier
# also RUNS there.
if [ -x /bin/bash ]; then
  if /bin/bash -n "$ROOT/bin/fm-blocker-classify-lib.sh"; then
    pass "F5 fm-blocker-classify-lib.sh parses under /bin/bash"
  else
    fail "F5 fm-blocker-classify-lib.sh does not parse under /bin/bash"
  fi
  stock_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-blocker-stock.XXXXXX")
  cat > "$stock_dir/probe.sh" <<'SH'
# Runs under the stock interpreter. Exit 3 proves a leaked local, exit 4 proves
# the conflict row itself broke.
. "$1"
code_type=STOCK_SENTINEL
row=$(fm_blocker_classify "$2" "$3" "$4")
[ "$code_type" = STOCK_SENTINEL ] || exit 3
case "${row%%$'\t'*}" in
  UNKNOWN_BLOCKED) exit 0 ;;
esac
exit 4
SH
  if /bin/bash -c 'printf "%s" "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"' | grep -q '^3\.2$'; then
    if /bin/bash "$stock_dir/probe.sh" "$ROOT/bin/fm-blocker-classify-lib.sh" \
      ci 'the runner has received a shutdown signal' provider_quota; then
      pass "F5c stock Bash 3.2 runs the conflict path with no leaked code_type"
    else
      fail "F5c stock Bash 3.2 conflict path broken (rc=$?)"
    fi
  else
    pass "F5c stock Bash 3.2 absent on this host; the parse sweep above is the portable check"
  fi
  rm -rf "$stock_dir"
else
  pass "F5 no /bin/bash on this host; skipped"
fi

printf '\n'
if [ "$fails" -eq 0 ]; then
  echo "# all fm-blocker-classify tests passed"
  exit 0
fi
echo "# fm-blocker-classify: $fails failure(s)"
exit 1
