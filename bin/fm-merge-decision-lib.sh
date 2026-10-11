#!/usr/bin/env bash
# Durable ownership of the merge-policy decision a task's PR was judged under.
#
# bin/fm-merge-evidence.sh returns the decision as a value, and a return value
# does not survive the process that read it: after a restart nothing records
# that this PR was held, so a later run cannot tell a re-verified PASS from one
# that was never produced. bin/fm-pr-merge.sh therefore persists the verdict it
# gated on as:
#   state/<task-id>.merge-decision
#   fm-merge-decision-v1
#   <provider>
#   <host>
#   <path>
#   <number>
#   <head-sha>
#   <decision>                  PASS | HOLD | REJECT
#   <risk>
#   <scope>                     artifact digest of the classified change set
#   <expiry>                    epoch seconds the decision stops being current
# The record is bound to the full PR identity, the head SHA it was judged at,
# and an expiry, so the same decision cannot be replayed against a different
# PR, a different head SHA, or after it has lapsed. Identity comes from the
# merge run's immutable canonical URL parse and the record revalidates the
# task's own pr= (and, when present, pr_head=) metadata under its lock before
# publishing; a mismatch refuses rather than recording a decision for a PR the
# task is not bound to.
#
# The file is atomically published, mode 0600, single-link, and on the state
# filesystem, exactly like the sibling merge-authority record. Missing,
# malformed, unreadable, expired, or mismatched state is reported as its own
# reason and never resolved to a decision, so the merge gate can refuse on the
# concrete cause instead of treating "no decision" as an implicit PASS.
#
# Sourced by bin/fm-pr-merge.sh and by tests. Callers must already have
# bin/fm-wake-lib.sh sourced for the shared lock helpers, as
# bin/fm-merge-authority-lib.sh's callers do. No side effects on source beyond
# its sourced libraries.

_FM_MERGE_DECISION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_MERGE_DECISION_LIB_DIR/fm-pr-lib.sh"

# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_DECISION=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_DECISION_REASON=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_DECISION_RISK=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_DECISION_SCOPE=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_DECISION_EXPIRY=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
FM_MERGE_DECISION_RECORD_IDENTITY=

fm_merge_decision_valid() {
  case "${1:-}" in PASS|HOLD|REJECT) return 0 ;; *) return 1 ;; esac
}

# Clear every public result. Callers read FM_MERGE_DECISION_REASON after a
# refusal, so a stale value from a previous call would be worse than none.
fm_merge_decision_clear() {
  FM_MERGE_DECISION=
  FM_MERGE_DECISION_REASON=
  FM_MERGE_DECISION_RISK=
  FM_MERGE_DECISION_SCOPE=
  FM_MERGE_DECISION_EXPIRY=
  FM_MERGE_DECISION_RECORD_IDENTITY=
}

# <record> <device> <provider> <host> <path> <number> <head-sha> <now>
# Sets the public results and returns 0 only when the record is well formed, is
# on the expected device, carries the expected identity and head SHA, and has
# not expired. Every other case returns 1 with FM_MERGE_DECISION_REASON naming
# which one it was.
fm_merge_decision_record_matches() {
  local record=$1 device=$2 expected_provider=$3 expected_host=$4 expected_path=$5
  local expected_number=$6 expected_head=$7 now=$8
  local version provider host path number head decision risk scope expiry
  fm_merge_decision_clear
  if ! fm_pr_private_file_valid "$record" 600 "$device"; then
    if [ -e "$record" ] || [ -L "$record" ]; then
      FM_MERGE_DECISION_REASON=unreadable
    else
      FM_MERGE_DECISION_REASON=absent
    fi
    return 1
  fi
  exec 8< "$record" || { FM_MERGE_DECISION_REASON=unreadable; return 1; }
  IFS= read -r version <&8 || { exec 8<&-; FM_MERGE_DECISION_REASON=malformed; return 1; }
  IFS= read -r provider <&8 || { exec 8<&-; FM_MERGE_DECISION_REASON=malformed; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; FM_MERGE_DECISION_REASON=malformed; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; FM_MERGE_DECISION_REASON=malformed; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; FM_MERGE_DECISION_REASON=malformed; return 1; }
  IFS= read -r head <&8 || { exec 8<&-; FM_MERGE_DECISION_REASON=malformed; return 1; }
  IFS= read -r decision <&8 || { exec 8<&-; FM_MERGE_DECISION_REASON=malformed; return 1; }
  IFS= read -r risk <&8 || { exec 8<&-; FM_MERGE_DECISION_REASON=malformed; return 1; }
  IFS= read -r scope <&8 || { exec 8<&-; FM_MERGE_DECISION_REASON=malformed; return 1; }
  IFS= read -r expiry <&8 || { exec 8<&-; FM_MERGE_DECISION_REASON=malformed; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    FM_MERGE_DECISION_REASON=malformed
    return 1
  fi
  exec 8<&-
  [ "$version" = fm-merge-decision-v1 ] || { FM_MERGE_DECISION_REASON=malformed; return 1; }
  fm_merge_decision_valid "$decision" || { FM_MERGE_DECISION_REASON=malformed; return 1; }
  case "$expiry" in
    ''|*[!0-9]*) FM_MERGE_DECISION_REASON=malformed; return 1 ;;
  esac
  if [ "$provider" != "$expected_provider" ] || [ "$host" != "$expected_host" ] \
    || [ "$path" != "$expected_path" ] || [ "$number" != "$expected_number" ]; then
    FM_MERGE_DECISION_REASON='identity-mismatch'
    return 1
  fi
  if [ "$head" != "$expected_head" ]; then
    FM_MERGE_DECISION_REASON='head-mismatch'
    return 1
  fi
  if [ "$expiry" -le "$now" ]; then
    FM_MERGE_DECISION_REASON='expired'
    return 1
  fi
  # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
  FM_MERGE_DECISION=$decision
  # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
  FM_MERGE_DECISION_RISK=$risk
  # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
  FM_MERGE_DECISION_SCOPE=$scope
  # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
  FM_MERGE_DECISION_EXPIRY=$expiry
  return 0
}

# <state> <task-id> <meta> <provider> <host> <path> <number> <head-sha>
#   <decision> <risk> <scope> <expiry>
# Validates the identity against the task's own metadata before publishing, so a
# decision is never recorded for a PR this task is not bound to. Returns
# non-zero without writing anything when validation or the atomic publish fails.
fm_merge_decision_persist() {
  local state=$1 id=$2 meta=$3 provider=$4 host=$5 path=$6 number=$7
  local head=$8 decision=$9 risk=${10} scope=${11} expiry=${12}
  local record tmp='' state_device lock meta_head status=0
  fm_pr_task_id_valid "$id" || return 1
  fm_merge_decision_valid "$decision" || return 1
  case "$expiry" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_metadata_identity_parse "$meta" || return 1
  [ "$FM_PR_META_PROVIDER" = "$provider" ] \
    && [ "$FM_PR_META_HOST" = "$host" ] \
    && [ "$FM_PR_META_PATH" = "$path" ] \
    && [ "$FM_PR_META_NUMBER" = "$number" ] || return 1
  # A recorded pr_head is the head the metadata itself claims; a decision for
  # any other head would contradict it, so the disagreement refuses here rather
  # than leaving two durable records that disagree about the same PR.
  meta_head=$(grep '^pr_head=' "$meta" | tail -1 | cut -d= -f2- || true)
  [ -z "$meta_head" ] || [ "$meta_head" = "$head" ] || return 1
  record="$state/$id.merge-decision"
  lock="$record.lock"
  fm_lock_acquire_wait "$lock" || return 1
  fm_pr_regular_destination_on_device_or_absent "$record" "$state_device" || status=1
  if [ "$status" -eq 0 ]; then
    umask 077
    tmp=$(mktemp "$state/.fm-merge-decision.XXXXXX") || status=1
  fi
  if [ "$status" -eq 0 ]; then
    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
      fm-merge-decision-v1 "$provider" "$host" "$path" "$number" \
      "$head" "$decision" "$risk" "$scope" "$expiry" > "$tmp" \
      || status=1
  fi
  if [ "$status" -eq 0 ]; then
    chmod 0600 "$tmp" \
      && fm_merge_decision_record_matches "$tmp" "$state_device" \
        "$provider" "$host" "$path" "$number" "$head" "$((expiry - 1))" \
      && fm_pr_regular_destination_on_device_or_absent "$record" "$state_device" \
      && mv -f -- "$tmp" "$record" \
      && fm_merge_decision_record_matches "$record" "$state_device" \
        "$provider" "$host" "$path" "$number" "$head" "$((expiry - 1))" \
      || status=1
  fi
  [ "$status" -eq 0 ] || rm -f -- "$tmp"
  fm_lock_release "$lock" || status=1
  return "$status"
}

# <state> <task-id> <provider> <host> <path> <number> <head-sha> [<now>]
# The read the merge gate enforces on. Returns 0 only for a currently valid
# decision bound to exactly this PR identity and head SHA; anything else returns
# 1 with FM_MERGE_DECISION_REASON naming the concrete cause.
fm_merge_decision_read() {
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6 head=$7
  local now=${8:-$(date +%s)}
  local record state_device lock status=0
  fm_merge_decision_clear
  fm_pr_task_id_valid "$id" || { FM_MERGE_DECISION_REASON='invalid-task-id'; return 1; }
  [ -d "$state" ] && [ ! -L "$state" ] || { FM_MERGE_DECISION_REASON=unreadable; return 1; }
  state_device=$(fm_pr_file_device "$state") || { FM_MERGE_DECISION_REASON=unreadable; return 1; }
  record="$state/$id.merge-decision"
  lock="$record.lock"
  fm_lock_acquire_wait "$lock" || {
    # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
    FM_MERGE_DECISION_REASON=unreadable
    return 1
  }
  if fm_merge_decision_record_matches "$record" "$state_device" \
      "$provider" "$host" "$path" "$number" "$head" "$now"; then
    # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
    FM_MERGE_DECISION_RECORD_IDENTITY=$(fm_pr_file_identity "$record") || status=1
  else
    status=1
  fi
  fm_lock_release "$lock" || status=1
  return "$status"
}
