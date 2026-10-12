#!/usr/bin/env bash
# Tests for bin/fm-merge-decision-lib.sh: the durable merge-policy decision
# record the merge boundary gates on.
#
# The record exists because a HOLD returned by bin/fm-merge-evidence.sh is a
# value that dies with the process that read it. These cases prove the record is
# bound to the full PR identity, the head SHA, and an expiry; that it survives a
# restart; and that a stale, duplicated, lapsed, or tampered decision is refused
# rather than replayed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-merge-decision-tests)
STATE="$TMP_ROOT/state"
META="$STATE/task-d1.meta"
mkdir -p "$STATE"
# The lock helpers the record publishes under live in the wake library, exactly
# as they do for the sibling merge-authority record's callers.
export FM_STATE_OVERRIDE="$STATE"
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-merge-decision-lib.sh
. "$ROOT/bin/fm-merge-decision-lib.sh"

PR=https://github.com/example/repo/pull/9
HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OTHER_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SCOPE=deadbeef
NOW=1000000000
EXPIRY=$((NOW + 3600))

write_meta() {
  fm_write_meta "$META" "pr=$PR" "$@"
}

write_meta

persist() {  # <head> <decision> <risk> <scope> <expiry>
  fm_merge_decision_persist "$STATE" task-d1 "$META" \
    github github.com example/repo 9 "$1" "$2" "$3" "$4" "$5"
}

read_decision() {  # <head> [<now>]
  fm_merge_decision_read "$STATE" task-d1 \
    github github.com example/repo 9 "$1" "${2:-$NOW}"
}

# --- a decision is recorded and read back bound to its identity ---
persist "$HEAD" PASS LOW "$SCOPE" "$EXPIRY" \
  || fail "persist: a PASS decision for the task's own PR was refused"
[ -f "$STATE/task-d1.merge-decision" ] \
  || fail "persist: no durable record was written"
[ "$(fm_pr_file_mode "$STATE/task-d1.merge-decision")" = 600 ] \
  || fail "persist: the record is not mode 0600"
read_decision "$HEAD" \
  || fail "read: the decision just recorded was refused (${FM_MERGE_DECISION_REASON})"
assert_equals PASS "$FM_MERGE_DECISION" "read: the recorded decision was not returned"
assert_equals LOW "$FM_MERGE_DECISION_RISK" "read: the recorded risk was not returned"
assert_equals "$SCOPE" "$FM_MERGE_DECISION_SCOPE" "read: the recorded artifact digest was not returned"
pass "a decision is recorded durably and read back bound to its identity"

# --- a HOLD survives a restart ---
# The whole point of the record: a HOLD must still be enforced by a process that
# did not witness it. The read below runs in a fresh interpreter that sources
# the libraries itself, so nothing is inherited but the durable file.
persist "$HEAD" HOLD HIGH "$SCOPE" "$EXPIRY" \
  || fail "hold-restart: a HOLD decision could not be recorded"
# shellcheck disable=SC2016 # $1..$4 are the child shell's own positional args.
out=$(env FM_STATE_OVERRIDE="$STATE" FM_HOME="$FM_HOME" \
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-merge-decision-lib.sh"
    if fm_merge_decision_read "$2" task-d1 github github.com example/repo 9 "$3" "$4"; then
      printf "decision=%s\n" "$FM_MERGE_DECISION"
    else
      printf "refused=%s\n" "$FM_MERGE_DECISION_REASON"
    fi
  ' _ "$ROOT" "$STATE" "$HEAD" "$NOW")
assert_equals "decision=HOLD" "$out" "hold-restart: a HOLD recorded before a restart was not enforced after it"
pass "a HOLD recorded before a restart is still enforced after it"

# --- a stale decision is refused against a moved head SHA ---
read_decision "$OTHER_HEAD" \
  && fail "stale-head: a decision for another head SHA was accepted"
assert_equals head-mismatch "$FM_MERGE_DECISION_REASON" \
  "stale-head: the refusal did not name the head mismatch"
pass "a decision recorded at one head SHA is refused at another"

# --- a decision is refused against another PR ---
fm_merge_decision_read "$STATE" task-d1 github github.com example/repo 10 "$HEAD" "$NOW" \
  && fail "other-pr: a decision for another pull request was accepted"
assert_equals identity-mismatch "$FM_MERGE_DECISION_REASON" \
  "other-pr: the refusal did not name the identity mismatch"
pass "a decision recorded for one pull request is refused for another"

# --- a lapsed decision is refused ---
read_decision "$HEAD" "$EXPIRY" \
  && fail "expired: a decision at its expiry was still accepted"
assert_equals expired "$FM_MERGE_DECISION_REASON" "expired: the refusal did not name the expiry"
read_decision "$HEAD" "$((EXPIRY - 1))" \
  || fail "expired: a decision one second before its expiry was refused"
pass "a lapsed decision is refused and a current one is not"

# --- an absent record is reported as absent, never as a PASS ---
rm -f "$STATE/task-d1.merge-decision"
read_decision "$HEAD" \
  && fail "absent: a missing record was read as a decision"
assert_equals absent "$FM_MERGE_DECISION_REASON" "absent: the refusal did not name the absence"
pass "a missing record is reported as absent"

# --- a tampered record is refused ---
persist "$HEAD" PASS LOW "$SCOPE" "$EXPIRY" || fail "tamper: the fixture record was not written"
printf '%s\n' 'extra' >> "$STATE/task-d1.merge-decision"
read_decision "$HEAD" && fail "tamper: a record with an extra field was accepted"
assert_equals malformed "$FM_MERGE_DECISION_REASON" "tamper: the refusal did not name the malformed record"
pass "a tampered record is refused"

# --- an unreadable-permission record is refused ---
persist "$HEAD" PASS LOW "$SCOPE" "$EXPIRY" || fail "mode: the fixture record was not written"
chmod 0644 "$STATE/task-d1.merge-decision"
read_decision "$HEAD" && fail "mode: a world-readable record was accepted"
assert_equals unreadable "$FM_MERGE_DECISION_REASON" "mode: the refusal did not name the unreadable record"
chmod 0600 "$STATE/task-d1.merge-decision"
pass "a record with unsafe permissions is refused"

# --- persistence refuses an identity the task is not bound to ---
fm_merge_decision_persist "$STATE" task-d1 "$META" \
  github github.com example/other 9 "$HEAD" PASS LOW "$SCOPE" "$EXPIRY" \
  && fail "identity: a decision was recorded for a PR the task is not bound to"
pass "persistence refuses an identity that disagrees with the task metadata"

# --- persistence refuses a head that disagrees with recorded pr_head ---
write_meta "pr_head=$OTHER_HEAD"
fm_merge_decision_persist "$STATE" task-d1 "$META" \
  github github.com example/repo 9 "$HEAD" PASS LOW "$SCOPE" "$EXPIRY" \
  && fail "meta-head: a decision was recorded for a head the metadata contradicts"
pass "persistence refuses a head that contradicts the recorded pr_head"

# --- persistence accepts a head that agrees with recorded pr_head ---
write_meta "pr_head=$HEAD"
fm_merge_decision_persist "$STATE" task-d1 "$META" \
  github github.com example/repo 9 "$HEAD" PASS LOW "$SCOPE" "$EXPIRY" \
  || fail "meta-head-ok: a decision agreeing with the recorded pr_head was refused"
pass "persistence accepts a head that agrees with the recorded pr_head"

# --- an invalid decision word is refused ---
fm_merge_decision_persist "$STATE" task-d1 "$META" \
  github github.com example/repo 9 "$HEAD" MAYBE LOW "$SCOPE" "$EXPIRY" \
  && fail "enum: an unknown decision word was recorded"
pass "persistence refuses an unknown decision word"
