#!/usr/bin/env bash
# fm-recovery.sh - the recovery state machine's thin CLI and durable store.
#
# Usage:
#   fm-recovery.sh status <task-id> | --fingerprint <fp>
#   fm-recovery.sh classify <task-id>
#   fm-recovery.sh begin <task-id> [--class <c>] [--signature <s>] [--target <t>]
#                                  [--exec-class simulation|isolated]
#   fm-recovery.sh advance --fingerprint <fp> <state> [--reason <r>]
#   fm-recovery.sh attempt --fingerprint <fp> --cause <c> --result ok|fail
#   fm-recovery.sh alternative --fingerprint <fp> --name <a>
#   fm-recovery.sh validate --fingerprint <fp> --result pass|fail [--evidence <e>]
#   fm-recovery.sh escalate --fingerprint <fp> [--approval] --reason <r>
#   fm-recovery.sh resume --fingerprint <fp>
#   fm-recovery.sh retire --fingerprint <fp>
#   fm-recovery.sh archive-all --reason <r>
#   fm-recovery.sh apply --fingerprint <fp> --action <a> [--approval-token <t>]
#   fm-recovery.sh check --fingerprint <fp>
#   fm-recovery.sh export-events
#   fm-recovery.sh playbook list [--scope <s>]
#   fm-recovery.sh playbook add <fp> <class> <status> <alternative> <scope> <evidence>
#   fm-recovery.sh playbook verify <fp> <alternative> <scope> <evidence>
#   fm-recovery.sh playbook retire <fp> <alternative>
#
# What this is. A deterministic adjunct, not an agent: the contract lives in
# bin/fm-recovery-lib.sh and this script owns only the durable store, the
# bounds enforcement, and the authority gate. It starts no watcher, daemon,
# poll, goal, or loop, and it never writes a worker's state/<id>.status log.
#
# Durable store, under $STATE/recovery/:
#   <fingerprint>.rec     one atomically-replaced line: the current recovery
#                         state and its counters (format owned by the library)
#   <fingerprint>.ledger  append-only attempt/alternative/transition history,
#                         each line carrying the resulting stage
#   .claim-<fingerprint>.lock
#                         the short-lived claim that makes two concurrent
#                         recoveries of one failure impossible
# The claim lock is the existing per-task lock primitive
# (fm_lock_try_acquire/fm_lock_release in bin/fm-wake-lib.sh), so a crashed
# holder is reclaimed by the same stale-owner proof every other lock uses.
#
# Checkpoint. The record is durable and the fingerprint deliberately excludes
# the spawn incarnation, so a recovery interrupted by a worker death is
# resumed from the same record instead of restarted: `begin` on an existing
# record with a stale lease prints `resumed`, keeps the state and counters, and
# appends a `resume` ledger line. It never re-enters RETRYABLE.
#
# Evidence is never deleted. A terminal recovery is retained live until
# `retire` archives its record and ledger, byte for byte, into
# data/recovery-archive/<fingerprint>/; a second retire inside the same epoch
# second is refused rather than allowed to overwrite the first archived
# incident. `archive-all` is the evidence-preserving rollback step, moving every
# live record and ledger into data/recovery-archive/rollback-<UTC>/ and writing
# a ROLLBACK.audit record that names the reason, the actor, and the sha256 of
# every preserved file; a second rollback inside the same UTC second is refused
# rather than allowed to merge into the first. Only transient claim locks, which
# carry a pid and no incident content, are ever removed, and only after their
# owner is proved gone: a lock whose owner is still alive is retained, because
# removing it would break the mutual exclusion a running `begin` depends on. See
# docs/recovery-state-machine.md.
#
# Bounds, all owned by fm_recovery_bound in the library: alternatives 3,
# same-cause retries 2, diagnosis 900s, whole recovery 1800s, concurrent
# recoveries 4 (the existing execution slot cap is retained, never raised).
# Exceeding the alternative or retry budget converges on BLOCKED_EXHAUSTED and
# the captain hold; exceeding the total budget does the same, and that bound is
# enforced on every path that would keep a recovery working, not only on
# `advance`, so no caller has to remember to call it for the bound to bite. A
# record past that window with no live lease is abandoned and is converged by
# `begin` before it counts against the concurrent cap, so an abandoned record
# can neither be starved forever nor silently exhaust the cap. Only exhausted
# alternatives, an exhausted budget, or the approved boundary escalate.
#
# Authority. `apply` asks fm_recovery_action_verdict and reports exactly what it
# answers: an automatic action is permitted, an approval-required action needs
# --approval-token, a refused action is never performed here even with a token,
# and an undecidable action stops (fail-closed). The capability ships inert, so
# `apply` performs no action itself - it prints `would-apply:` for a permitted
# action and records the decision - and nothing in this script can reach
# upstream writes, shared remotes or databases, PR create/retarget, attestation
# reuse, gate waivers, merges, deploys, launchd, or daemon restarts: those are
# `refused` by the table.
#
# The captain hold is a real write. A recovery that opens or escalates onto
# WAITING_APPROVAL raises the existing captain hold before it publishes that
# state, and an unrecorded hold is a fail-closed stop, never a wait the
# supervisor can read as recorded. A `simulation` recovery is inert: it writes
# its own record and ledger, and never mutates the real backlog.
#
# Evidence over guesswork. `classify` reads the worker's current state
# (bin/fm-crew-state.sh, overridable with FM_RECOVERY_CREW_STATE_BIN) and its
# status log, and maps them to a cause class by exact deterministic matching.
# It never asks a model.
#
# Test hooks: FM_RECOVERY_NOW (deterministic epoch), FM_RECOVERY_CREW_STATE_BIN,
# FM_RECOVERY_CAPTAIN_HOLD_BIN, FM_RECOVERY_ACTOR (lease owner label),
# FM_RECOVERY_EXEC_CLASS (default execution class).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-recovery-lib.sh
. "$SCRIPT_DIR/fm-recovery-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

REC_DIR="$STATE/recovery"
ARCHIVE_DIR="$DATA/recovery-archive"
CREW_STATE_BIN="${FM_RECOVERY_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
CAPTAIN_HOLD_BIN="${FM_RECOVERY_CAPTAIN_HOLD_BIN:-$SCRIPT_DIR/fm-captain-hold.sh}"
PLAYBOOK="$DATA/recovery-playbooks.tsv"

die() { printf 'fm-recovery: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2; }

now_epoch() {
  local now=${FM_RECOVERY_NOW:-}
  case "$now" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$now" ;;
  esac
}

valid_slug() {  # <label> <value>
  case "${2:-}" in
    ''|*[!A-Za-z0-9._-]*) die "$1 must be a non-empty slug: ${2:-}" ;;
  esac
}

one_line() {  # <label> <value>
  [ -n "${2:-}" ] || die "$1 must not be empty"
  case "$2" in
    *$'\n'*|*$'\r'*) die "$1 must be one line" ;;
  esac
}

record_path()  { printf '%s/%s.rec\n' "$REC_DIR" "$1"; }
ledger_path()  { printf '%s/%s.ledger\n' "$REC_DIR" "$1"; }
claim_path()   { printf '%s/.claim-%s.lock\n' "$REC_DIR" "$1"; }

ensure_dir() {
  [ -d "$REC_DIR" ] || mkdir -p "$REC_DIR" || die "cannot create $REC_DIR"
}

ledger_append() {  # <fp> <event> <detail>
  # The ledger line carries the resulting stage, so the KPI layer can derive
  # stage timings from the event stream alone instead of re-folding records.
  local detail=${3:-}
  if [ -n "$detail" ]; then
    printf '%s %s %s stage=%s\n' "$(now_epoch)" "$2" "$detail" "${REC_STATE:--}" >> "$(ledger_path "$1")"
  else
    printf '%s %s stage=%s\n' "$(now_epoch)" "$2" "${REC_STATE:--}" >> "$(ledger_path "$1")"
  fi
}

# Read a record into REC_TEXT. Absent and unreadable are different facts and
# must never read the same: return 1 when there is no record at all, and return
# 2 when a record exists but cannot be read (permission denied, or an empty or
# corrupt line). An unreadable record is a fail-closed error, never "there is
# no recovery": flattening it into absent would let a caller report a false
# `recovery: none`, or overwrite live incident evidence with a fresh recovery.
REC_TEXT=
read_record() {  # <fp>; 0 read, 1 absent, 2 unreadable
  local path
  path=$(record_path "$1")
  [ -e "$path" ] || return 1
  REC_TEXT=$(cat "$path" 2>/dev/null) || return 2
  [ -n "$REC_TEXT" ] || return 2
  return 0
}

# The one way a caller turns a failed read into a stop, so no call site can
# flatten unreadable back into absent.
read_record_or_die() {  # <fp>
  local rc=0
  read_record "$1" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) die "no recovery record for $1" ;;
    *) die "the recovery record for $1 exists but cannot be read (unreadable or empty); refusing to treat it as absent" ;;
  esac
}

field() {  # <key>
  fm_recovery_record_field "$REC_TEXT" "$1"
}

# Write a record from explicit fields, preserving the ones a caller does not
# change. Every writer goes through here so the line shape has one owner.
REC_STATE=''
REC_TASK=''
REC_CLASS=''
REC_FP=''
REC_TARGET=''
REC_SIGNATURE=''
REC_ATTEMPTS=''
REC_ALTERNATIVES=''
REC_RETRIES=''
REC_STARTED=''
REC_UPDATED=''
REC_LEASE_ACTOR=''
REC_LEASE_PID=''
REC_LEASE_EPOCH=''
REC_REASON=''
REC_EXEC_CLASS=''
load_fields() {
  REC_STATE=$(field state)
  REC_TASK=$(field task)
  REC_CLASS=$(field class)
  REC_FP=$(field fingerprint)
  REC_TARGET=$(field target)
  REC_SIGNATURE=$(field signature)
  REC_ATTEMPTS=$(field attempts)
  REC_ALTERNATIVES=$(field alternatives)
  REC_RETRIES=$(field same_cause_retries)
  REC_STARTED=$(field started)
  REC_UPDATED=$(field updated)
  REC_LEASE_ACTOR=$(field lease_actor)
  REC_LEASE_PID=$(field lease_pid)
  REC_LEASE_EPOCH=$(field lease_epoch)
  REC_REASON=$(field reason)
  REC_EXEC_CLASS=$(field exec_class)
}
write_record() {
  local tmp
  ensure_dir
  tmp=$(mktemp "$REC_DIR/.rec.XXXXXX") || die "cannot stage a recovery record"
  fm_recovery_record_format \
    "$REC_STATE" "$REC_TASK" "$REC_CLASS" "$REC_FP" "$REC_TARGET" "$REC_SIGNATURE" \
    "$REC_ATTEMPTS" "$REC_ALTERNATIVES" "$REC_RETRIES" "$REC_STARTED" "$REC_UPDATED" \
    "$REC_LEASE_ACTOR" "$REC_LEASE_PID" "$REC_LEASE_EPOCH" "$REC_REASON" "$REC_EXEC_CLASS" > "$tmp" \
    || { rm -f "$tmp"; die "cannot format a recovery record"; }
  mv -f "$tmp" "$(record_path "$REC_FP")" || { rm -f "$tmp"; die "cannot publish a recovery record"; }
}

refresh_lease() {
  REC_LEASE_ACTOR=${FM_RECOVERY_ACTOR:-main}
  REC_LEASE_PID=$$
  REC_LEASE_EPOCH=$(now_epoch)
  REC_UPDATED=$REC_LEASE_EPOCH
}

# The lease is a TTL heartbeat, not a process-liveness claim: every state
# change refreshes it, and the engine's own processes are short-lived by
# design, so a recorded pid that has exited proves nothing. A lease whose
# heartbeat has stopped for longer than the TTL is stale and may be taken over;
# that is what makes a worker death a checkpoint restore rather than a stuck
# recovery.
lease_stale() {  # 0 when the recorded lease no longer holds
  local now ttl
  now=$(now_epoch)
  ttl=$(fm_recovery_bound lease-ttl-secs) || ttl=300
  case "$REC_LEASE_EPOCH" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$((now - REC_LEASE_EPOCH))" -gt "$ttl" ]
}

active_recovery_count() {  # non-terminal records
  local path base fp count=0 text state
  [ -d "$REC_DIR" ] || { printf '0\n'; return 0; }
  for path in "$REC_DIR"/*.rec; do
    [ -f "$path" ] || continue
    base=${path##*/}
    fp=${base%.rec}
    text=$(cat "$path" 2>/dev/null) || continue
    state=$(fm_recovery_record_field "$text" state)
    fm_recovery_state_terminal "$state" && continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

total_budget_exhausted() {
  local now total
  now=$(now_epoch)
  total=$(fm_recovery_bound total-secs) || total=1800
  case "$REC_STARTED" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$((now - REC_STARTED))" -gt "$total" ]
}

diagnosis_budget_exhausted() {
  local now diag
  now=$(now_epoch)
  diag=$(fm_recovery_bound diagnosis-secs) || diag=900
  case "$REC_UPDATED" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$((now - REC_UPDATED))" -gt "$diag" ]
}

# The total budget bounds the whole recovery, not one command: every path that
# would otherwise keep a recovery working past the window converges here, so the
# bound does not depend on the caller happening to call `advance`. Returns 0
# when it converged, and the caller must stop rather than continue.
enforce_total_budget() {  # <fp>
  total_budget_exhausted || return 1
  REC_STATE=BLOCKED_EXHAUSTED
  REC_REASON="total recovery budget exhausted"
  refresh_lease
  write_record
  ledger_append "$1" escalate "total-budget-exhausted"
  printf 'escalated: %s state=BLOCKED_EXHAUSTED reason=%s\n' "$1" "$REC_REASON"
  return 0
}

# An abandoned recovery must not hold a concurrent slot forever. Past the
# whole-recovery window with no live lease nobody can be holding it, so the
# same escalation the total budget owes it is applied here, durably and
# announced: four abandoned records can then no longer silently and permanently
# exhaust the cap. A record whose lease is still fresh, or that is still inside
# the window, is left alone - `begin` on the same fingerprint resumes it (that
# is the checkpoint), and a recovery someone may still hold is never converged
# out from under its holder.
reap_abandoned() {
  local path base fp text state
  [ -d "$REC_DIR" ] || return 0
  for path in "$REC_DIR"/*.rec; do
    [ -f "$path" ] || continue
    base=${path##*/}
    fp=${base%.rec}
    text=$(cat "$path" 2>/dev/null) || continue
    state=$(fm_recovery_record_field "$text" state) || continue
    fm_recovery_state_terminal "$state" && continue
    read_record "$fp" || continue
    load_fields
    lease_stale || continue
    total_budget_exhausted || continue
    REC_STATE=BLOCKED_EXHAUSTED
    REC_REASON="abandoned: no live lease and the total recovery budget is exhausted"
    refresh_lease
    write_record
    ledger_append "$fp" escalate "abandoned-total-budget-exhausted"
    printf 'reaped: %s state=BLOCKED_EXHAUSTED reason=%s\n' "$fp" "$REC_REASON"
  done
  return 0
}

# --- classification ---------------------------------------------------------

# Deterministic evidence -> cause class. The status log's newest line and the
# worker's current state are the only inputs; nothing here guesses.
classify_note() {  # <note> -> class or empty
  local note
  note=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$note" in
    *"target mismatch"*|*"target differs"*|*"wrong base branch"*) printf 'pr-target-mismatch' ;;
    *"successor=none"*|*"successor none"*)                        printf 'watcher-successor-none' ;;
    *"base contamination"*|*"contaminated base"*|*"base is contaminated"*) printf 'worktree-base-contamination' ;;
    *quota*|*outage*|*"rate limit"*|*"temporarily unavailable"*|*"dependency unavailable"*) printf 'dependency-unavailable' ;;
    *"approval"*|*"attestation"*|*"gate waiver"*|*"needs captain"*) printf 'approval-boundary' ;;
    *"connection refused"*|*"socket refused"*|*"socket missing"*|*"daemon down"*|*"daemon unreachable"*) printf 'daemon-down' ;;
    *) : ;;
  esac
}

classify_task() {  # <task> -> "<class>\t<signature>\t<target>"
  local task=$1 state_out note cls sig target
  local status_file="$STATE/$task.status"
  state_out=''
  if [ -x "$CREW_STATE_BIN" ]; then
    state_out=$("$CREW_STATE_BIN" "$task" 2>/dev/null) || state_out=''
  fi
  note=$(status_line_note "$(status_current_line "$status_file" ship 2>/dev/null)")
  cls=$(classify_note "$note")
  sig=$note
  target=${FM_RECOVERY_TARGET:-}
  if [ -z "$cls" ]; then
    case "$state_out" in
      *"state: blocked"*)
        cls=$(classify_note "$state_out")
        [ -n "$cls" ] || cls=unknown
        [ -n "$sig" ] || sig=$state_out
        ;;
      *"state: failed"*)
        cls='run-failed'
        [ -n "$sig" ] || sig=$(printf '%s' "$state_out" | sed -n 's/^state: failed[^ ]* *//p')
        ;;
      *)
        cls=unknown
        [ -n "$sig" ] || sig=$state_out
        ;;
    esac
  fi
  if [ -z "$target" ]; then
    target=$(sed -n 's/^branch=//p' "$STATE/$task.meta" 2>/dev/null | tail -1)
    [ -n "$target" ] || target=$(sed -n 's/^project=//p' "$STATE/$task.meta" 2>/dev/null | tail -1)
  fi
  printf '%s\t%s\t%s\n' "$cls" "${sig:-unknown}" "${target:-unknown}"
}

# --- commands ---------------------------------------------------------------

cmd_status() {
  local task='' fp='' want_verb=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --fingerprint) shift; fp=${1:-} ;;
      --verb) want_verb=1 ;;
      -*) usage ;;
      *) task=$1 ;;
    esac
    shift
  done
  if [ -z "$fp" ]; then
    [ -n "$task" ] || die "status needs a task id or --fingerprint"
    local frc=0
    fp=$(cmd_find_fp "$task") || frc=$?
    [ "$frc" = 2 ] && die "a recovery record exists but cannot be read; refusing to report $task as having no recovery"
    [ "$frc" = 0 ] || die "no recovery record for $task"
  fi
  valid_slug fingerprint "$fp"
  read_record_or_die "$fp"
  load_fields
  if [ "$want_verb" = 1 ]; then
    fm_recovery_registry_verb "$REC_STATE"
    return 0
  fi
  printf 'recovery: %s · task: %s · class: %s · exec: %s · attempts: %s · retries: %s/%s · alternatives: %s/%s · registry: %s · age: %ss · reason: %s\n' \
    "$REC_STATE" "$REC_TASK" "$REC_CLASS" "${REC_EXEC_CLASS:--}" \
    "$REC_ATTEMPTS" \
    "$REC_RETRIES" "$(fm_recovery_bound max-same-cause-retries)" \
    "$REC_ALTERNATIVES" "$(fm_recovery_bound max-alternatives)" \
    "$(fm_recovery_registry_verb "$REC_STATE")" \
    "$(( $(now_epoch) - REC_STARTED ))" "${REC_REASON:--}"
}

# The fingerprint of the live recovery record for a task, if exactly one.
# Returns 2 when some record exists but cannot be read: the task's own record
# may be exactly the unreadable one, so a failed read can never be reported as
# "this task has no recovery".
cmd_find_fp() {
  local task=$1 path base fp text found='' count=0 unreadable=0
  [ -d "$REC_DIR" ] || return 1
  for path in "$REC_DIR"/*.rec; do
    [ -f "$path" ] || continue
    base=${path##*/}
    fp=${base%.rec}
    if ! text=$(cat "$path" 2>/dev/null); then
      unreadable=1
      continue
    fi
    [ -n "$text" ] || { unreadable=1; continue; }
    [ "$(fm_recovery_record_field "$text" task)" = "$task" ] || continue
    found=$fp
    count=$((count + 1))
  done
  [ "$unreadable" = 1 ] && return 2
  [ "$count" = 1 ] || return 1
  printf '%s\n' "$found"
}

cmd_classify() {
  local task=${1:-}
  [ -n "$task" ] || die "classify needs a task id"
  valid_slug task "$task"
  local out cls sig target fp
  out=$(classify_task "$task")
  cls=${out%%$'\t'*}
  out=${out#*$'\t'}
  sig=${out%%$'\t'*}
  target=${out#*$'\t'}
  fp=$(fm_recovery_fingerprint "$task" "$cls" "$sig" "$target") || die "cannot compute a fingerprint"
  printf 'class: %s\nfingerprint: %s\nsignature: %s\ntarget: %s\ninitial-state: %s\n' \
    "$cls" "$fp" "$sig" "$target" "$(fm_recovery_initial_state "$cls")"
}

cmd_begin() {
  local task='' class='' signature='' target='' exec_class='' out fp now
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --class) shift; class=${1:-} ;;
      --signature) shift; signature=${1:-} ;;
      --target) shift; target=${1:-} ;;
      --exec-class) shift; exec_class=${1:-} ;;
      -*) usage ;;
      *) task=$1 ;;
    esac
    shift
  done
  [ -n "$task" ] || die "begin needs a task id"
  valid_slug task "$task"
  if [ -z "$class" ] || [ -z "$signature" ]; then
    out=$(classify_task "$task")
    [ -n "$class" ] || class=${out%%$'\t'*}
    out=${out#*$'\t'}
    [ -n "$signature" ] || signature=${out%%$'\t'*}
    [ -n "$target" ] || target=${out#*$'\t'}
  fi
  fm_recovery_class_valid "$class" || die "unknown failure class: $class"
  [ -n "$exec_class" ] || exec_class=${FM_RECOVERY_EXEC_CLASS:-isolated}
  fm_recovery_exec_class_valid "$exec_class" || die "unknown execution class: $exec_class"
  fm_recovery_exec_class_recordable "$exec_class" \
    || die "this engine cannot record a '$exec_class' recovery: production classification is assigned by the separately approved control plane that activates the capability, never by an argument here"
  fp=$(fm_recovery_fingerprint "$task" "$class" "$signature" "$target") || die "cannot compute a fingerprint"
  ensure_dir

  # Claim the fingerprint so two concurrent recoveries cannot both start. A
  # failed claim is only a duplicate when a live holder is actually recorded:
  # a claim that could not be created at all (unwritable store, failed reclaim
  # guard) is an error, never a claim that someone else holds the recovery.
  fm_lock_try_acquire "$(claim_path "$fp")" >/dev/null 2>&1 || {
    [ -n "${FM_LOCK_HELD_PID:-}" ] || die "cannot claim the recovery for $fp: the claim lock could not be created and no live holder is recorded (refusing to report a duplicate)"
    printf 'duplicate: %s\n' "$fp"
    return 0
  }

  now=$(now_epoch)
  local have=0
  read_record "$fp" || have=$?
  if [ "$have" = 2 ]; then
    fm_lock_release "$(claim_path "$fp")" >/dev/null 2>&1 || true
    die "the recovery record for $fp exists but cannot be read (unreadable or empty); refusing to begin a new recovery over live incident evidence"
  fi
  if [ "$have" = 0 ]; then
    load_fields
    # Terminal first: a completed recovery is refused because it is completed,
    # never because its lease happens to look fresh. The refusal names the
    # retire path, because without it a recurring failure of the same
    # fingerprint would be blocked forever with no audited way to reopen it.
    if fm_recovery_state_terminal "$REC_STATE"; then
      fm_lock_release "$(claim_path "$fp")" >/dev/null 2>&1 || true
      printf 'duplicate: %s (terminal %s; retire it to open a new recovery)\n' "$fp" "$REC_STATE"
      return 0
    fi
    if ! lease_stale; then
      fm_lock_release "$(claim_path "$fp")" >/dev/null 2>&1 || true
      printf 'duplicate: %s (held by %s)\n' "$fp" "$REC_LEASE_ACTOR"
      return 0
    fi
    # Checkpoint restore: keep the state, the counters, and the start clock.
    refresh_lease
    REC_REASON="resumed after lease loss"
    write_record
    ledger_append "$fp" resume "lease-reclaimed"
    fm_lock_release "$(claim_path "$fp")" >/dev/null 2>&1 || true
    printf 'resumed: %s state=%s attempts=%s alternatives=%s\n' "$fp" "$REC_STATE" "$REC_ATTEMPTS" "$REC_ALTERNATIVES"
    return 0
  fi

  local active cap
  reap_abandoned
  active=$(active_recovery_count)
  cap=$(fm_recovery_bound max-concurrent) || cap=4
  if [ "$active" -ge "$cap" ]; then
    fm_lock_release "$(claim_path "$fp")" >/dev/null 2>&1 || true
    printf 'deferred: concurrent recovery cap %s reached (%s active)\n' "$cap" "$active"
    return 0
  fi

  REC_TASK=$task
  REC_CLASS=$class
  REC_FP=$fp
  REC_TARGET=$target
  REC_SIGNATURE=$(fm_recovery_normalize_signature "$signature")
  REC_ATTEMPTS=0
  REC_ALTERNATIVES=0
  REC_RETRIES=0
  REC_STARTED=$now
  REC_REASON="classified $class"
  REC_EXEC_CLASS=$exec_class
  refresh_lease
  REC_STATE=$(fm_recovery_initial_state "$class")
  # A recovery that opens on the captain's boundary owes the durable HOLD before
  # it claims to be waiting: a state that reads needs-decision with no recorded
  # hold would be a false wait. An unrecorded hold is therefore a fail-closed
  # stop that writes no record, not a state the supervisor can read as waiting.
  if [ "$REC_STATE" = WAITING_APPROVAL ] && ! raise_captain_hold "$REC_TASK" "$REC_REASON"; then
    fm_lock_release "$(claim_path "$fp")" >/dev/null 2>&1 || true
    die "the recovery for $REC_TASK would open at WAITING_APPROVAL but its captain hold was not recorded; refusing to record a false wait"
  fi
  write_record
  ledger_append "$fp" begin "class=$class state=$REC_STATE"
  fm_lock_release "$(claim_path "$fp")" >/dev/null 2>&1 || true
  printf 'begun: %s state=%s class=%s\n' "$fp" "$REC_STATE" "$class"
}

cmd_advance() {
  local fp='' target='' reason=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --fingerprint) shift; fp=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      -*) usage ;;
      *) target=$1 ;;
    esac
    shift
  done
  [ -n "$fp" ] || die "advance needs --fingerprint"
  [ -n "$target" ] || die "advance needs a target state"
  [ -z "$reason" ] || one_line reason "$reason"
  valid_slug fingerprint "$fp"
  fm_recovery_state_valid "$target" || die "unknown recovery state: $target"
  read_record_or_die "$fp"
  load_fields
  fm_recovery_state_terminal "$REC_STATE" && die "recovery $fp is already terminal: $REC_STATE"
  enforce_total_budget "$fp" && return 0
  fm_recovery_transition_allowed "$REC_STATE" "$target" \
    || die "illegal transition for $fp: $REC_STATE -> $target"
  REC_STATE=$target
  [ -n "$reason" ] && REC_REASON=$reason
  refresh_lease
  write_record
  ledger_append "$fp" transition "$target"
  printf 'advanced: %s state=%s\n' "$fp" "$REC_STATE"
}

cmd_attempt() {
  local fp='' cause='' result=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --fingerprint) shift; fp=${1:-} ;;
      --cause) shift; cause=${1:-} ;;
      --result) shift; result=${1:-} ;;
      -*) usage ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$fp" ] || die "attempt needs --fingerprint"
  [ -n "$cause" ] || die "attempt needs --cause"
  case "$result" in ok|fail) ;; *) die "attempt --result must be ok or fail" ;; esac
  valid_slug fingerprint "$fp"
  read_record_or_die "$fp"
  load_fields
  fm_recovery_state_terminal "$REC_STATE" && die "recovery $fp is already terminal: $REC_STATE"
  fm_recovery_class_valid "$cause" || die "unknown failure class: $cause"
  enforce_total_budget "$fp" && return 0
  local max
  max=$(fm_recovery_bound max-same-cause-retries) || max=2
  REC_ATTEMPTS=$((REC_ATTEMPTS + 1))
  if [ "$result" = ok ]; then
    REC_STATE=RECOVERABLE
    REC_REASON="retry succeeded"
    ledger_append "$fp" attempt "cause=$cause result=ok"
  elif [ "$cause" = "$REC_CLASS" ]; then
    if [ "$REC_RETRIES" -ge "$max" ]; then
      REC_STATE=DIAGNOSING
      REC_REASON="same-cause retry budget exhausted ($max)"
      ledger_append "$fp" attempt "cause=$cause result=fail retry-refused"
    else
      REC_RETRIES=$((REC_RETRIES + 1))
      REC_STATE=RETRYABLE
      REC_REASON="same-cause retry $REC_RETRIES/$max"
      ledger_append "$fp" attempt "cause=$cause result=fail retry=$REC_RETRIES"
    fi
  else
    REC_STATE=DIAGNOSING
    REC_REASON="new cause: $cause"
    ledger_append "$fp" attempt "cause=$cause result=fail new-cause"
  fi
  refresh_lease
  write_record
  printf 'attempted: %s state=%s attempts=%s same-cause-retries=%s\n' \
    "$fp" "$REC_STATE" "$REC_ATTEMPTS" "$REC_RETRIES"
}

cmd_alternative() {
  local fp='' name=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --fingerprint) shift; fp=${1:-} ;;
      --name) shift; name=${1:-} ;;
      -*) usage ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$fp" ] || die "alternative needs --fingerprint"
  one_line alternative-name "$name"
  valid_slug fingerprint "$fp"
  read_record_or_die "$fp"
  load_fields
  fm_recovery_state_terminal "$REC_STATE" && die "recovery $fp is already terminal: $REC_STATE"
  enforce_total_budget "$fp" && return 0
  local max
  max=$(fm_recovery_bound max-alternatives) || max=3
  if [ "$REC_ALTERNATIVES" -ge "$max" ]; then
    REC_STATE=BLOCKED_EXHAUSTED
    REC_REASON="alternative budget exhausted ($max)"
    refresh_lease
    write_record
    ledger_append "$fp" escalate "alternatives-exhausted"
    printf 'escalated: %s state=BLOCKED_EXHAUSTED reason=%s\n' "$fp" "$REC_REASON"
    return 0
  fi
  fm_recovery_transition_allowed "$REC_STATE" VALIDATING \
    || die "cannot start an alternative from $REC_STATE"
  REC_ALTERNATIVES=$((REC_ALTERNATIVES + 1))
  REC_STATE=VALIDATING
  REC_REASON="validating alternative: $name"
  refresh_lease
  write_record
  ledger_append "$fp" alternative "$name"
  printf 'validating: %s alternative=%s count=%s/%s\n' "$fp" "$name" "$REC_ALTERNATIVES" "$max"
}

cmd_validate() {
  local fp='' result='' evidence=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --fingerprint) shift; fp=${1:-} ;;
      --result) shift; result=${1:-} ;;
      --evidence) shift; evidence=${1:-} ;;
      -*) usage ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$fp" ] || die "validate needs --fingerprint"
  case "$result" in pass|fail) ;; *) die "validate --result must be pass or fail" ;; esac
  [ -z "$evidence" ] || one_line evidence "$evidence"
  valid_slug fingerprint "$fp"
  read_record_or_die "$fp"
  load_fields
  [ "$REC_STATE" = VALIDATING ] || die "recovery $fp is not VALIDATING (it is $REC_STATE)"
  enforce_total_budget "$fp" && return 0
  local max
  max=$(fm_recovery_bound max-alternatives) || max=3
  if [ "$result" = pass ]; then
    REC_STATE=RECOVERABLE
    REC_REASON="isolated verification passed"
    ledger_append "$fp" validate "pass ${evidence:-}"
  elif [ "$REC_ALTERNATIVES" -ge "$max" ]; then
    REC_STATE=BLOCKED_EXHAUSTED
    REC_REASON="all $max alternatives failed verification"
    ledger_append "$fp" escalate "verification-exhausted"
  else
    REC_STATE=ALTERNATIVE_SEARCH
    REC_REASON="verification failed; trying a different alternative"
    ledger_append "$fp" validate "fail ${evidence:-}"
  fi
  refresh_lease
  write_record
  printf 'validated: %s state=%s result=%s\n' "$fp" "$REC_STATE" "$result"
}

cmd_escalate() {
  local fp='' reason='' approval=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --fingerprint) shift; fp=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --approval) approval=1 ;;
      -*) usage ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$fp" ] || die "escalate needs --fingerprint"
  one_line reason "$reason"
  valid_slug fingerprint "$fp"
  read_record_or_die "$fp"
  load_fields
  local target
  if [ "$approval" = 1 ]; then target=WAITING_APPROVAL; else target=BLOCKED_EXHAUSTED; fi
  if [ "$REC_STATE" = "$target" ]; then
    if [ "$target" = WAITING_APPROVAL ] \
      && ! raise_captain_hold "$REC_TASK" "$REC_REASON"; then
      die "the recovery $fp is WAITING_APPROVAL but its captain hold for $REC_TASK was not recorded; refusing to report a false wait"
    fi
    printf 'escalated: %s state=%s (already)\n' "$fp" "$target"
    return 0
  fi
  fm_recovery_transition_allowed "$REC_STATE" "$target" \
    || die "cannot escalate $fp from $REC_STATE to $target"
  # The HOLD is raised before the state is published, so a boundary the captain
  # was never actually asked about can never be read as a wait on the captain.
  if [ "$target" = WAITING_APPROVAL ] \
    && ! raise_captain_hold "$REC_TASK" "$reason"; then
    die "the recovery $fp would escalate to WAITING_APPROVAL but its captain hold for $REC_TASK was not recorded; refusing to record a false wait"
  fi
  REC_STATE=$target
  REC_REASON=$reason
  refresh_lease
  write_record
  ledger_append "$fp" escalate "$target ${reason//(/) }"
  printf 'escalated: %s state=%s\n' "$fp" "$target"
}

# The HOLD is the existing captain hold, raised through its existing owner, so
# the backlog row, the parent channel, and the keyed-answer intake all behave
# exactly as they do for any other captain call. The return status is the proof:
# 0 only when the hold was really recorded, 1 when it was not, so a caller can
# refuse to publish a wait that nothing is waiting on. A `simulation` recovery
# is inert here by design: a rehearsal writes its own record and ledger, which
# carry the execution class, but it never mutates the real backlog.
raise_captain_hold() {  # <task> <reason>; 0 only when the hold is recorded
  local task=$1 reason=$2 rc=0 clean
  clean=$(printf '%s' "$reason" | tr -d '()')
  if [ "${REC_EXEC_CLASS:-}" = simulation ]; then
    printf 'simulated: captain hold for %s was not written (exec_class=simulation never mutates the real backlog)\n' "$task" >&2
    return 0
  fi
  if [ ! -x "$CAPTAIN_HOLD_BIN" ]; then
    printf 'actionable: captain hold for %s was not recorded (no hold owner at %s)\n' "$task" "$CAPTAIN_HOLD_BIN" >&2
    return 1
  fi
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$CAPTAIN_HOLD_BIN" hold "$task" --reason "recovery approval: $clean" >/dev/null 2>&1 || rc=$?
  if [ "$rc" != 0 ]; then
    printf 'actionable: captain hold for %s was not recorded (rc=%s)\n' "$task" "$rc" >&2
    return 1
  fi
  return 0
}

cmd_resume() {
  local fp=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --fingerprint) shift; fp=${1:-} ;;
      -*) usage ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$fp" ] || die "resume needs --fingerprint"
  valid_slug fingerprint "$fp"
  read_record_or_die "$fp"
  load_fields
  [ "$REC_STATE" = RECOVERABLE ] || die "recovery $fp is not RECOVERABLE (it is $REC_STATE)"
  REC_STATE=RESUMED
  REC_REASON="original work resumed"
  refresh_lease
  write_record
  ledger_append "$fp" resume "original-work"
  printf 'resumed: %s state=RESUMED\n' "$fp"
  printf 'resume-plan: bin/fm-control.sh %s relaunch --note "recovery %s applied; resume the original brief"\n' "$REC_TASK" "$fp"
}

cmd_apply() {
  local fp='' action='' token=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --fingerprint) shift; fp=${1:-} ;;
      --action) shift; action=${1:-} ;;
      --approval-token) shift; token=${1:-} ;;
      -*) usage ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$fp" ] || die "apply needs --fingerprint"
  [ -n "$action" ] || die "apply needs --action"
  one_line action "$action"
  valid_slug fingerprint "$fp"
  read_record_or_die "$fp"
  load_fields
  local verdict class
  verdict=$(fm_recovery_action_verdict "$action")
  class=$(fm_recovery_action_class "$action")
  ledger_append "$fp" apply "action=$action verdict=$verdict"
  # This engine decides authority; it does not perform the action. It ships
  # inert, so a permitted action is reported as what it is - a decision the
  # separately approved control plane would carry out - and never as `applied:`.
  case "$verdict" in
    automatic)
      printf 'would-apply: %s action=%s class=%s (automatic; this engine records the decision and performs no action)\n' "$fp" "$action" "$class"
      ;;
    approval-required)
      if [ -n "$token" ]; then
        printf 'would-apply: %s action=%s class=%s (approved; this engine records the decision and performs no action)\n' "$fp" "$action" "$class"
      else
        printf 'refused: %s action=%s class=%s needs captain approval (approval-required)\n' "$fp" "$action" "$class"
        return 4
      fi
      ;;
    refused)
      printf 'refused: %s action=%s is reserved to the captain; the recovery engine never performs it (fail-closed)\n' "$fp" "$action"
      return 5
      ;;
    *)
      printf 'refused: %s action=%s could not be classified; stopping (fail-closed)\n' "$fp" "$action"
      return 6
      ;;
  esac
}

cmd_check() {
  local fp='' rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --fingerprint) shift; fp=${1:-} ;;
      -*) usage ;;
      *) usage ;;
    esac
    shift
  done
  # The condition contract this satisfies (bin/fm-procevent-when.sh): exit 0
  # means the supervisor must act, exit 1 is a clean "keep recovering", and any
  # other status is an error rather than a false. A misuse therefore exits 2 so
  # a registered watch reports an error instead of silently reading "false".
  [ -n "$fp" ] || { printf 'fm-recovery: check needs --fingerprint\n' >&2; exit 2; }
  valid_slug fingerprint "$fp"
  # An unreadable record is an error, never a clean "there is no recovery": a
  # watch that read it as false would silently stop watching a live incident.
  read_record "$fp" || rc=$?
  case "$rc" in
    1) printf 'recovery: none\n'; return 1 ;;
    2) printf 'fm-recovery: the recovery record for %s exists but cannot be read; refusing to report it as absent\n' "$fp" >&2; exit 2 ;;
  esac
  load_fields
  case "$REC_STATE" in
    WAITING_APPROVAL|BLOCKED_EXHAUSTED)
      printf 'recovery: stop (%s) task=%s reason=%s\n' "$REC_STATE" "$REC_TASK" "$REC_REASON"
      return 0
      ;;
  esac
  if total_budget_exhausted; then
    printf 'recovery: stop (total-budget-exhausted) task=%s\n' "$REC_TASK"
    return 0
  fi
  if [ "$REC_STATE" = DIAGNOSING ] && diagnosis_budget_exhausted; then
    printf 'recovery: stop (diagnosis-budget-exhausted) task=%s\n' "$REC_TASK"
    return 0
  fi
  printf 'recovery: continue (%s) task=%s\n' "$REC_STATE" "$REC_TASK"
  return 1
}

# --- measurement export -----------------------------------------------------
#
# Read-only JSONL for the KPI/measurement layer. It writes nothing, and it
# never touches the metrics layer's own files: the measurement layer owns
# state/recovery-events.jsonl and the dashboard, this engine owns the recovery
# records and ledgers, and this command is the seam between them.
#
# Every event carries the execution class, so a simulation or an isolated
# recovery can never be aggregated into the production auto-recovery rate.
# Identity matches the measurement layer's own vocabulary: `incident_id`,
# `recovery_attempt_id`, `failure_fingerprint`, `failure_class`, `stage`,
# `actor`, `exec_class`. This engine has no run id, so `incident_id` binds the
# task, the failure fingerprint, and the opening epoch, and
# `recovery_attempt_id` is `<fingerprint>-<opened-at>`.

# `event`, `stage`, and `actor` come from a ledger line and from an operator
# label, so they are escaped before they are embedded: a quote in an actor label
# must not be able to break the event stream the contract calls valid JSON.
json_string() {  # <text> -> a JSON string body with no surrounding quotes
  printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

cmd_export_events() {
  local path base fp line ts event stage seq opened incident attempt
  [ -d "$REC_DIR" ] || return 0
  for path in "$REC_DIR"/*.rec; do
    [ -f "$path" ] || continue
    base=${path##*/}
    fp=${base%.rec}
    read_record "$fp" || continue
    load_fields
    opened=$REC_STARTED
    incident=$(fm_recovery_incident_id "$REC_TASK" "$REC_FP" "$opened") || continue
    attempt=$(fm_recovery_attempt_id "$REC_FP" "$opened")
    [ -f "$(ledger_path "$fp")" ] || continue
    seq=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      seq=$((seq + 1))
      ts=${line%% *}
      event=${line#* }
      event=${event%% *}
      stage=$(printf '%s\n' "$line" | sed -n 's/.* stage=\([^ ]*\)$/\1/p')
      printf '{"schema":"fm-recovery-event.v1","seq":%s,"ts":%s,"event":"%s","stage":"%s","incident_id":"%s","task_id":"%s","recovery_attempt_id":"%s","failure_fingerprint":"%s","failure_class":"%s","actor":"%s","exec_class":"%s"}\n' \
        "$seq" "$ts" "$(json_string "$event")" "$(json_string "${stage:--}")" \
        "$incident" "$(json_string "$REC_TASK")" "$attempt" \
        "$REC_FP" "$(json_string "$REC_CLASS")" "$(json_string "$REC_LEASE_ACTOR")" \
        "$(json_string "${REC_EXEC_CLASS:--}")"
    done < "$(ledger_path "$fp")"
  done
}

# --- evidence preservation --------------------------------------------------
#
# A recovery record and its ledger ARE incident evidence: they say what was
# classified, what was tried, what was refused, and why the captain was asked.
# Nothing here deletes them. `retire` archives one completed recovery so a
# recurring failure can open a new one, and `archive-all` is the
# evidence-preserving rollback step that moves every live record and ledger
# into a dated archive and records the rollback itself as an audit event.
#
# Checkpoint policy: terminal records are retained live until retired; retiring
# moves the record and ledger, byte for byte, into
# data/recovery-archive/<fingerprint>/<epoch>.{rec,ledger} and appends a
# `retire` event to the archived ledger, so the archived ledger is still a
# complete, self-contained event stream.
#
# Audit retention: every ledger event is evidence and is kept for the life of
# the home. Only two things are ever removed - transient claim locks, which
# hold a pid and no incident content, and nothing else.

sha256_file() {  # <path>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    printf 'unavailable\n'
  fi
}

# A claim lock may be removed only when its owner is provably gone, and the
# proof is the one the lock primitive itself uses (fm_lock_try_acquire): a live
# recorded pid, or a lock still inside its mid-acquire window, means a `begin`
# may be running right now, and deleting that lock would break the mutual
# exclusion that makes two concurrent recoveries of one failure impossible.
# 0 = the lock is live and must be kept.
claim_lock_live() {  # <lockpath>
  local lock=$1 pid
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" && return 0
  fm_lock_mid_acquire_is_fresh "$lock" "$pid"
}

cmd_retire() {
  local fp='' dest stamp
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --fingerprint) shift; fp=${1:-} ;;
      -*) usage ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$fp" ] || die "retire needs --fingerprint"
  valid_slug fingerprint "$fp"
  read_record_or_die "$fp"
  load_fields
  fm_recovery_state_terminal "$REC_STATE" \
    || die "recovery $fp is still $REC_STATE; only a terminal recovery is retired"
  dest="$ARCHIVE_DIR/$fp"
  mkdir -p "$dest" || die "cannot create the recovery archive at $dest"
  stamp=$(now_epoch)
  # Evidence is never overwritten. Two retires of one fingerprint inside the
  # same epoch second would otherwise collide on `<epoch>.{rec,ledger}` and
  # silently destroy the first archived incident, so the second is refused
  # before it writes anything.
  if [ -e "$dest/$stamp.rec" ] || [ -e "$dest/$stamp.ledger" ]; then
    die "the recovery archive at $dest already holds an entry stamped $stamp; refusing to overwrite preserved evidence"
  fi
  ledger_append "$fp" retire "state=$REC_STATE archived-to=$dest"
  mv -f "$(record_path "$fp")" "$dest/$stamp.rec" || die "cannot archive the record for $fp"
  mv -f "$(ledger_path "$fp")" "$dest/$stamp.ledger" || die "cannot archive the ledger for $fp"
  printf 'retired: %s state=%s archived=%s\n' "$fp" "$REC_STATE" "$dest"
}

cmd_archive_all() {
  local reason='' dest stamp entry base
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) shift; reason=${1:-} ;;
      -*) usage ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$reason" ] || die "archive-all needs --reason"
  one_line reason "$reason"
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  dest="$ARCHIVE_DIR/rollback-$stamp"
  mkdir -p "$ARCHIVE_DIR" || die "cannot create the recovery archive at $ARCHIVE_DIR"
  # `mkdir` without `-p`: two rollbacks inside one UTC second must never merge
  # into one directory, because the second `ROLLBACK.audit` would truncate the
  # first rollback's audit record and lose the evidence of that rollback.
  mkdir "$dest" 2>/dev/null \
    || die "the rollback archive $dest already exists; refusing to overwrite the previous rollback's audit record"
  if [ -d "$REC_DIR" ]; then
    for entry in "$REC_DIR"/*.rec "$REC_DIR"/*.ledger; do
      [ -f "$entry" ] || continue
      base=${entry##*/}
      mv -f "$entry" "$dest/$base" || die "cannot archive $base"
    done
    # Transient claim locks carry a pid and no incident content, and they are
    # the only thing this removes. Liveness is proved first: a lock whose owner
    # is still alive, or that is still inside its mid-acquire window, belongs to
    # a `begin` that may be running right now, and removing it would break the
    # mutual exclusion. A live lock is retained and named, never deleted.
    for entry in "$REC_DIR"/.claim-*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      if claim_lock_live "$entry"; then
        printf 'retained-live: %s\n' "${entry##*/}" >> "$dest/ROLLBACK.audit.tmp"
        continue
      fi
      printf 'removed-transient: %s\n' "${entry##*/}" >> "$dest/ROLLBACK.audit.tmp"
      rm -rf -- "$entry"
    done
  fi
  {
    printf 'schema=fm-recovery-rollback.v1\n'
    printf 'at=%s\n' "$stamp"
    printf 'actor=%s\n' "${FM_RECOVERY_ACTOR:-main}"
    printf 'reason=%s\n' "$reason"
    printf 'source=%s\n' "$REC_DIR"
    printf 'archive=%s\n' "$dest"
    printf 'preserved:\n'
    for entry in "$dest"/*.rec "$dest"/*.ledger; do
      [ -f "$entry" ] || continue
      printf '  %s bytes=%s sha256=%s\n' "${entry##*/}" "$(wc -c < "$entry" | tr -d ' ')" "$(sha256_file "$entry")"
    done
    if [ -f "$dest/ROLLBACK.audit.tmp" ]; then
      cat "$dest/ROLLBACK.audit.tmp"
      rm -f "$dest/ROLLBACK.audit.tmp"
    fi
    printf 'policy=recovery records and ledgers are incident evidence and are never deleted by rollback\n'
  } > "$dest/ROLLBACK.audit" || die "cannot write the rollback audit record"
  rmdir "$REC_DIR" 2>/dev/null || true
  printf 'archived: %s\n' "$dest"
}

# --- playbook ---------------------------------------------------------------

playbook_scope_current() {  # <task-or-empty>
  local task=${1:-} harness backend
  if [ -n "$task" ] && [ -f "$STATE/$task.meta" ]; then
    harness=$(sed -n 's/^harness=//p' "$STATE/$task.meta" | tail -1)
    backend=$(sed -n 's/^backend=//p' "$STATE/$task.meta" | tail -1)
  fi
  fm_recovery_playbook_scope "${harness:-unknown}" "${backend:-unknown}"
}

cmd_playbook() {
  local sub=${1:-}
  shift || true
  case "$sub" in
    list) cmd_playbook_list "$@" ;;
    add) cmd_playbook_add "$@" ;;
    verify) cmd_playbook_verify "$@" ;;
    retire) cmd_playbook_retire "$@" ;;
    *) usage ;;
  esac
}

cmd_playbook_list() {
  local scope='' fp class status alternative entry_scope verified evidence effective
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --scope) shift; scope=${1:-} ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$scope" ] || scope=$(playbook_scope_current)
  [ -f "$PLAYBOOK" ] || { printf 'playbook: empty (scope %s)\n' "$scope"; return 0; }
  printf 'playbook (scope %s):\n' "$scope"
  while IFS=$'\t' read -r fp class status alternative entry_scope verified evidence; do
    [ -n "$fp" ] || continue
    effective=$(fm_recovery_playbook_effective_status "$status" "$entry_scope" "$scope")
    printf '  %s  %s  %s  %s  verified=%s  %s\n' \
      "$fp" "$class" "$effective" "$alternative" "${verified:--}" "${evidence:--}"
  done < "$PLAYBOOK"
}

cmd_playbook_add() {
  local fp=${1:-} class=${2:-} status=${3:-} alternative=${4:-} scope=${5:-} evidence=${6:-}
  [ -n "$fp" ] || die "playbook add needs <fp> <class> <status> <alternative> <scope> <evidence>"
  fm_recovery_class_valid "$class" || die "unknown failure class: $class"
  fm_recovery_playbook_status_valid "$status" || die "unknown playbook status: $status"
  one_line alternative "$alternative"
  [ -n "$evidence" ] || die "playbook add needs evidence"
  [ -n "$scope" ] || scope=$(playbook_scope_current)
  one_line scope "$scope"
  ensure_dir
  if [ -f "$PLAYBOOK" ] && awk -F'\t' -v f="$fp" -v a="$alternative" '$1==f && $4==a { found=1 } END { exit !found }' "$PLAYBOOK"; then
    die "playbook already records $alternative for $fp; use verify to re-verify it"
  fi
  fm_recovery_playbook_format "$fp" "$class" "$status" "$alternative" "$scope" \
    "$(now_epoch)" "$evidence" >> "$PLAYBOOK"
  printf 'playbook: recorded %s %s (%s)\n' "$fp" "$alternative" "$status"
}

cmd_playbook_verify() {
  local fp=${1:-} alternative=${2:-} scope=${3:-} evidence=${4:-} tmp found=0
  [ -n "$fp" ] || die "playbook verify needs <fp> <alternative> <scope> <evidence>"
  one_line alternative "$alternative"
  [ -n "$evidence" ] || die "playbook verify needs evidence"
  [ -f "$PLAYBOOK" ] || die "no playbook to verify"
  [ -n "$scope" ] || scope=$(playbook_scope_current)
  ensure_dir
  tmp=$(mktemp "$REC_DIR/.playbook.XXXXXX") || die "cannot stage the playbook"
  while IFS=$'\t' read -r efp class status ealt escope verified eev; do
    [ -n "$efp" ] || continue
    if [ "$efp" = "$fp" ] && [ "$ealt" = "$alternative" ]; then
      fm_recovery_playbook_status_allowed "$status" verified \
        || { rm -f "$tmp"; die "playbook entry $fp/$alternative cannot move from $status to verified"; }
      fm_recovery_playbook_format "$efp" "$class" verified "$ealt" "$scope" "$(now_epoch)" "$evidence" >> "$tmp"
      found=1
    else
      fm_recovery_playbook_format "$efp" "$class" "$status" "$ealt" "$escope" "$verified" "$eev" >> "$tmp"
    fi
  done < "$PLAYBOOK"
  [ "$found" = 1 ] || { rm -f "$tmp"; die "no playbook entry $fp/$alternative"; }
  mv -f "$tmp" "$PLAYBOOK" || { rm -f "$tmp"; die "cannot publish the playbook"; }
  printf 'playbook: verified %s %s in scope %s\n' "$fp" "$alternative" "$scope"
}

cmd_playbook_retire() {
  local fp=${1:-} alternative=${2:-} tmp found=0
  [ -n "$fp" ] || die "playbook retire needs <fp> <alternative>"
  one_line alternative "$alternative"
  [ -f "$PLAYBOOK" ] || die "no playbook to retire from"
  ensure_dir
  tmp=$(mktemp "$REC_DIR/.playbook.XXXXXX") || die "cannot stage the playbook"
  while IFS=$'\t' read -r efp class status ealt escope verified eev; do
    [ -n "$efp" ] || continue
    if [ "$efp" = "$fp" ] && [ "$ealt" = "$alternative" ]; then
      found=1
      continue
    fi
    fm_recovery_playbook_format "$efp" "$class" "$status" "$ealt" "$escope" "$verified" "$eev" >> "$tmp"
  done < "$PLAYBOOK"
  [ "$found" = 1 ] || { rm -f "$tmp"; die "no playbook entry $fp/$alternative"; }
  mv -f "$tmp" "$PLAYBOOK" || { rm -f "$tmp"; die "cannot publish the playbook"; }
  printf 'playbook: retired %s %s\n' "$fp" "$alternative"
}

# --- dispatch ---------------------------------------------------------------

SUB=${1:-}
[ "$#" -gt 0 ] && shift
case "$SUB" in
  status)    cmd_status "$@" ;;
  classify)  cmd_classify "$@" ;;
  begin)     cmd_begin "$@" ;;
  advance)   cmd_advance "$@" ;;
  attempt)   cmd_attempt "$@" ;;
  alternative) cmd_alternative "$@" ;;
  validate)  cmd_validate "$@" ;;
  escalate)  cmd_escalate "$@" ;;
  resume)    cmd_resume "$@" ;;
  retire)    cmd_retire "$@" ;;
  archive-all) cmd_archive_all "$@" ;;
  apply)     cmd_apply "$@" ;;
  check)     cmd_check "$@" ;;
  export-events) cmd_export_events "$@" ;;
  playbook)  cmd_playbook "$@" ;;
  -h|--help) usage ;;
  *) usage ;;
esac
