#!/usr/bin/env bash
# fm-unattended-recovery-state.sh - durable G4 recovery metadata (self-healing).
#
# Persists per-task recovery bookkeeping OUTSIDE the 12-state lifecycle, so the
# existing state machine is unchanged: recovery progress is expressed as durable
# metadata, not new lifecycle states (RECOVERING/VERIFYING/ROLLBACK).
#
# Record: <UC_HOME>/recovery/<task>.recovery  (key=value lines)
#   attempt_id=NNN        monotonic recovery attempt id
#   same_cause=N          consecutive same-reason recovery attempts
#   last_reason=<r>
#   last_action=<a>
#   status=<recovering|resumed|held|quota-wait|approval|isolated>
#   updated_at=<epoch>
#
# Atomic (mkdir lock) and restart-safe: a fresh process reads the same record and
# never re-runs an already-terminal recovery.
#
# Usage:
#   fm-unattended-recovery-state.sh get    <home> <task>
#   fm-unattended-recovery-state.sh bump   <home> <task> <reason> <action> <status>
#   fm-unattended-recovery-state.sh set-status <home> <task> <status>
#   fm-unattended-recovery-state.sh reset  <home> <task>
set -u
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
POLICY="$SCRIPT_DIR/fm-unattended-recovery.sh"
_dir(){ printf '%s/recovery' "$1"; }
_file(){ printf '%s/recovery/%s.recovery' "$1" "$2"; }
_get(){ sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }

_lock(){ # <home> -> echo lock path, acquire
  local l; l="$(_dir "$1").lock"; local n=0
  while [ "$n" -lt 100 ]; do mkdir "$l" 2>/dev/null && { echo "$l"; return 0; }; n=$((n+1)); sleep 0.02; done
  return 1
}

cmd=${1:-}; home=${2:-}; task=${3:-}
case "$cmd" in
  get)
    [ -n "$home" ] && [ -n "$task" ] || { echo "usage: get <home> <task>" >&2; exit 2; }
    f=$(_file "$home" "$task"); [ -f "$f" ] && cat "$f" || true;;
  bump)
    reason=${4:-}; action=${5:-}; status=${6:-recovering}
    [ -n "$home" ] && [ -n "$task" ] && [ -n "$reason" ] || { echo "usage: bump <home> <task> <reason> <action> <status>" >&2; exit 2; }
    mkdir -p "$(_dir "$home")"
    l=$(_lock "$home") || { echo "recovery-state=unavailable reason=lock-timeout" >&2; exit 3; }
    f=$(_file "$home" "$task")
    prev_reason=$(_get "$f" last_reason); prev_same=$(_get "$f" same_cause); prev_attempt=$(_get "$f" attempt_id)
    [ -n "$prev_same" ] || prev_same=0
    [ -n "$prev_attempt" ] || prev_attempt=0
    if [ "$prev_reason" = "$reason" ]; then same=$((prev_same+1)); else same=1; fi
    attempt=$((prev_attempt+1))
    { printf 'attempt_id=%s\n' "$attempt"
      printf 'same_cause=%s\n' "$same"
      printf 'last_reason=%s\n' "$reason"
      printf 'last_action=%s\n' "$action"
      printf 'status=%s\n' "$status"
      printf 'updated_at=%s\n' "$(date +%s)"; } > "$f"
    rmdir "$l" 2>/dev/null
    cat "$f";;
  set-status)
    status=${4:-}; [ -n "$home" ] && [ -n "$task" ] && [ -n "$status" ] || exit 2
    l=$(_lock "$home") || exit 3
    f=$(_file "$home" "$task"); [ -f "$f" ] || { rmdir "$l" 2>/dev/null; echo "recovery-state=absent" >&2; exit 1; }
    sed -i.bak "s/^status=.*/status=$status/;s/^updated_at=.*/updated_at=$(date +%s)/" "$f" && rm -f "$f.bak"
    rmdir "$l" 2>/dev/null; cat "$f";;
  decide)
    # atomic read-decide-write: the whole critical section runs under one lock, so
    # two concurrent calls for the same task cannot both read the same same_cause
    # and both pass the circuit breaker (TOCTOU fix). A lock failure is fail-closed.
    reason=${4:-}; gen=${5:-}; curgen=${6:-}
    [ -n "$home" ] && [ -n "$task" ] && [ -n "$reason" ] || { echo "usage: decide <home> <task> <reason> [gen] [current-gen]" >&2; exit 2; }
    mkdir -p "$(_dir "$home")"
    l=$(_lock "$home") || { echo "recovery-state=unavailable reason=lock-timeout action=hold category=UNKNOWN"; exit 3; }
    f=$(_file "$home" "$task")
    st=$(_get "$f" status)
    case "$st" in
      held|resumed|approval|isolated) printf 'category=terminal action=hold status=%s\n' "$st"; rmdir "$l" 2>/dev/null; exit 0;;
    esac
    # re-dispatch fence: a recovery for a superseded generation is not allowed.
    if [ -n "$gen" ] && [ -n "$curgen" ] && [ "$gen" != "$curgen" ]; then
      printf 'category=NON_RECOVERABLE action=hold reason=stale-generation\n'; rmdir "$l" 2>/dev/null; exit 0
    fi
    prev_reason=$(_get "$f" last_reason); prev_same=$(_get "$f" same_cause); [ -n "$prev_same" ] || prev_same=0
    if [ "$prev_reason" = "$reason" ]; then same=$((prev_same+1)); else same=1; fi
    # delegate the pure decision to the policy module with the durable same_cause.
    out=$("$POLICY" decide --reason "$reason" --same-cause "$((same-1))" 2>/dev/null)
    action=$(printf '%s' "$out" | sed -n 's/.*action=\([a-z-]*\).*/\1/p'); [ -n "$action" ] || action=hold
    status="$action"; [ "$action" = retry ] && status=recovering; [ "$action" = diagnose ] && status=recovering
    [ "$action" = hold ] && status=held   # a terminal hold must be caught by the guard next call
    attempt=$(( $(_get "$f" attempt_id || echo 0) + 1 )); [ -n "$attempt" ] || attempt=1
    { printf 'attempt_id=%s\n' "$attempt"; printf 'same_cause=%s\n' "$same"
      printf 'last_reason=%s\n' "$reason"; printf 'last_action=%s\n' "$action"
      printf 'status=%s\n' "$status"; printf 'updated_at=%s\n' "$(date +%s)"; } > "$f"
    rmdir "$l" 2>/dev/null
    printf '%s\n' "$out";;
  reset)
    [ -n "$home" ] && [ -n "$task" ] || exit 2
    rm -f "$(_file "$home" "$task")"; echo "reset";;
  *) echo "usage: fm-unattended-recovery-state.sh get|bump|set-status|reset <home> <task> ..." >&2; exit 2;;
esac
