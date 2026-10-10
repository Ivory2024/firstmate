#!/usr/bin/env bash
# fm-autonomous-loop.sh - Autonomous work loop for Firstmate.
# Owns: per-task lifecycle records, per-lane READY queue, bounded auto-resume,
# idempotent recovery, and lane progression without captain intervention.
#
# This is an adjunct to the existing watcher/control plane, not a duplicate.
# It reads durable state and drives fm-control.sh for lifecycle actions.
#
# Usage:
#   fm-autonomous-loop.sh reconcile [--startup]
#   fm-autonomous-loop.sh lane-next <lane>
#   fm-autonomous-loop.sh task-resume <task-id> [--reason <text>]
#   fm-autonomous-loop.sh task-reassign <task-id> --harness <name> [--model <name>] [--effort <level>] --note <text>
#   fm-autonomous-loop.sh task-hold <task-id> --reason <text> [--until <epoch>]
#   fm-autonomous-loop.sh task-done <task-id> --evidence <text>
#   fm-autonomous-loop.sh scan-stalled
#   fm-autonomous-loop.sh test-inject <scenario>
#
# All operations are read-only on durable state except where noted.
# Lifecycle actions (resume/reassign/hold/done) delegate to fm-control.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
LIFECYCLE_DIR="$STATE/task-lifecycle"
LANE_QUEUE_DIR="$STATE/lane-queues"
LIFECYCLE_LOCK_DIR="$STATE/task-lifecycle.locks"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-control.sh
# shellcheck source=bin/fm-crew-state.sh
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"

# Configuration
AUTO_RESUME_MAX_ATTEMPTS=${FM_AUTO_RESUME_MAX_ATTEMPTS:-3}
AUTO_RESUME_BASE_BACKOFF=${FM_AUTO_RESUME_BASE_BACKOFF:-30}
AUTO_RESUME_MAX_BACKOFF=${FM_AUTO_RESUME_MAX_BACKOFF:-1800}
AUTO_RESUME_JITTER_PCT=${FM_AUTO_RESUME_JITTER_PCT:-25}
QUOTA_WAIT_MAX=${FM_QUOTA_WAIT_MAX:-3600}
STALLED_THRESHOLD_SECS=${FM_STALLED_THRESHOLD_SECS:-900}
LANE_PROGRESSION_INTERVAL=${FM_LANE_PROGRESSION_INTERVAL:-60}
LIFECYCLE_LOCK_TIMEOUT=${FM_LIFECYCLE_LOCK_TIMEOUT:-10}

mkdir -p "$LIFECYCLE_DIR" "$LANE_QUEUE_DIR" "$LIFECYCLE_LOCK_DIR"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

# ============================================================================
# LIFECYCLE REGISTRY - Single canonical source of truth for task lifecycle
# ============================================================================

# Field definitions (P0-4): all required fields in one place
# owner, lane, priority, dependencies, acceptance_criteria, current_step,
# last_progress, next_action, retry_state, blocking_reason, evidence, resume_checkpoint
# Additional: state_version, created_epoch, updated_epoch, state_machine_version

LIFECYCLE_FIELDS=(
  "owner"
  "lane"
  "priority"
  "dependencies"
  "acceptance_criteria"
  "current_step"
  "last_progress"
  "next_action"
  "retry_state"
  "blocking_reason"
  "evidence"
  "resume_checkpoint"
  "state_version"
  "created_epoch"
  "updated_epoch"
  "state_machine_version"
)

# State machine (fail-closed): only these states are valid
# READY -> ASSIGNED -> RUNNING -> TESTING -> REVIEWING -> FIXING -> RETESTING
# -> READY_FOR_MERGE -> MERGE_VERIFIED -> DEPLOYMENT_GATE -> DONE
# HOLD states: WAITING_QUOTA, WAITING_APPROVAL, WAITING_EXTERNAL, RECOVERY_HOLD, ESCALATED
# Terminal: DONE, FAILED

VALID_STATES=(
  "READY" "ASSIGNED" "RUNNING" "TESTING" "REVIEWING" "FIXING" "RETESTING"
  "READY_FOR_MERGE" "MERGE_VERIFIED" "DEPLOYMENT_GATE" "DONE"
  "WAITING_QUOTA" "WAITING_APPROVAL" "WAITING_EXTERNAL" "RECOVERY_HOLD" "ESCALATED"
  "FAILED"
)

# State transitions (fail-closed): from -> allowed to
# Only these transitions are permitted; any other transition is rejected
declare -A VALID_TRANSITIONS=(
  ["READY"]="ASSIGNED WAITING_QUOTA WAITING_APPROVAL WAITING_EXTERNAL RECOVERY_HOLD ESCALATED FAILED"
  ["ASSIGNED"]="RUNNING WAITING_QUOTA WAITING_APPROVAL WAITING_EXTERNAL RECOVERY_HOLD ESCALATED FAILED"
  ["RUNNING"]="TESTING WAITING_QUOTA WAITING_EXTERNAL RECOVERY_HOLD ESCALATED FAILED"
  ["TESTING"]="REVIEWING FIXING WAITING_QUOTA WAITING_EXTERNAL RECOVERY_HOLD FAILED"
  ["REVIEWING"]="READY_FOR_MERGE FIXING WAITING_APPROVAL WAITING_QUOTA WAITING_EXTERNAL RECOVERY_HOLD FAILED"
  ["FIXING"]="RETESTING WAITING_QUOTA WAITING_EXTERNAL RECOVERY_HOLD FAILED"
  ["RETESTING"]="REVIEWING READY_FOR_MERGE WAITING_QUOTA WAITING_EXTERNAL RECOVERY_HOLD FAILED"
  ["READY_FOR_MERGE"]="MERGE_VERIFIED WAITING_APPROVAL WAITING_QUOTA WAITING_EXTERNAL RECOVERY_HOLD FAILED"
  ["MERGE_VERIFIED"]="DEPLOYMENT_GATE WAITING_APPROVAL WAITING_QUOTA RECOVERY_HOLD FAILED"
  ["DEPLOYMENT_GATE"]="DONE WAITING_APPROVAL WAITING_QUOTA RECOVERY_HOLD FAILED"
  ["DONE"]=""  # Terminal
  ["FAILED"]=""  # Terminal
  ["WAITING_QUOTA"]="RUNNING TESTING REVIEWING FIXING RETESTING READY_FOR_MERGE MERGE_VERIFIED DEPLOYMENT_GATE"
  ["WAITING_APPROVAL"]="READY_FOR_MERGE MERGE_VERIFIED DEPLOYMENT_GATE DONE"
  ["WAITING_EXTERNAL"]="RUNNING TESTING REVIEWING FIXING RETESTING READY_FOR_MERGE MERGE_VERIFIED DEPLOYMENT_GATE"
  ["RECOVERY_HOLD"]="RUNNING TESTING REVIEWING FIXING RETESTING READY_FOR_MERGE MERGE_VERIFIED DEPLOYMENT_GATE WAITING_QUOTA WAITING_APPROVAL WAITING_EXTERNAL"
  ["ESCALATED"]="RUNNING TESTING REVIEWING FIXING RETESTING READY_FOR_MERGE MERGE_VERIFIED DEPLOYMENT_GATE WAITING_QUOTA WAITING_APPROVAL WAITING_EXTERNAL RECOVERY_HOLD"
)

# Initialize the state machine version
STATE_MACHINE_VERSION=2

lifecycle_path() { printf '%s/%s.lifecycle' "$LIFECYCLE_DIR" "$1"; }
lane_queue_path() { printf '%s/%s.queue' "$LANE_QUEUE_DIR" "$1"; }
lifecycle_lock_path() { printf '%s/%s.lock' "$LIFECYCLE_LOCK_DIR" "$1"; }

# Atomic lifecycle write with locking
lifecycle_lock() {  # <task-id>
  local id=$1 lock_file
  lock_file=$(lifecycle_lock_path "$id")
  fm_lock_acquire_wait "$lock_file" || return 1
  LIFECYCLE_LOCK_HELD=1
  return 0
}

lifecycle_unlock() {  # <task-id>
  local id=$1 lock_file
  lock_file=$(lifecycle_lock_path "$id")
  fm_lock_release "$lock_file" || return 1
  LIFECYCLE_LOCK_HELD=0
  return 0
}

# Read a field from lifecycle record (no lock needed for reads)
lifecycle_read() {  # <task-id> <key>
  local file=$(lifecycle_path "$1") key=$2
  [ -f "$file" ] || return 1
  grep "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Write a field to lifecycle record (with lock)
lifecycle_write() {  # <task-id> <key> <value>
  local id=$1 key=$2 value=$3
  lifecycle_lock "$id" || return 1
  local file=$(lifecycle_path "$id") tmp
  tmp=$(mktemp "$LIFECYCLE_DIR/.lifecycle.XXXXXX") || { lifecycle_unlock "$id"; return 1; }
  if [ -f "$file" ]; then
    grep -v "^${key}=" "$file" > "$tmp" 2>/dev/null || true
  else
    : > "$tmp"
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$file" || { rm -f "$tmp"; lifecycle_unlock "$id"; return 1; }
  lifecycle_unlock "$id"
}

lifecycle_exists() { [ -f "$(lifecycle_path "$1")" ]; }

# Derive lane from task ID or backlog
derive_lane() {  # <task-id>
  local id=$1
  # Check meta for explicit lane
  local meta="$STATE/$id.meta"
  if [ -f "$meta" ]; then
    local m_lane=$(grep '^lane=' "$meta" 2>/dev/null | cut -d= -f2-)
    [ -n "$m_lane" ] && { printf '%s\n' "$m_lane"; return; }
  fi
  # Check backlog for lane info (new format: lane=<lane>)
  local backlog_entry=$(grep -E "^\- \[ \] $id " "$DATA/backlog.md" 2>/dev/null | head -1)
  if [ -n "$backlog_entry" ]; then
    local lane=$(printf '%s\n' "$backlog_entry" | sed -n 's/.*(lane=\([^)]*\)).*/\1/p')
    [ -n "$lane" ] && { printf '%s\n' "$lane"; return; }
    # Also check for (kind: X) to infer lane
    local kind=$(printf '%s\n' "$backlog_entry" | sed -n 's/.*(kind: \([^)]*\)).*/\1/p')
    case "$kind" in
      ship) printf 'platform-ops\n'; return ;;
      docs) printf 'docs\n'; return ;;
      scout) printf 'scout\n'; return ;;
      captain) printf 'captain\n'; return ;;
    esac
  fi
  # Default lane based on task prefix
  case "$id" in
    a4-*|a5-*) printf 'platform-ops\n' ;;
    imac-*) printf 'imac-ops\n' ;;
    firstmate-*|autonomous-loop-*|watcher-*|discord-*) printf 'platform-ops\n' ;;
    code-review-*|trackb-*) printf 'code-review\n' ;;
    *) printf 'default\n' ;;
  esac
}

# Validate state transition (fail-closed)
validate_transition() {  # <from> <to> [task-id]
  local from=$1 to=$2 task_id=${3:-} allowed
  allowed=${VALID_TRANSITIONS[$from]:-}
  case " $allowed " in *" $to "*) return 0 ;; *) 
    if [ -n "$task_id" ]; then
      echo "Invalid transition for $task_id: $from -> $to" >&2
    else
      echo "Invalid transition: $from -> $to" >&2
    fi
    return 1 
  ;; esac
}

# Atomic state transition with evidence requirement
lifecycle_transition() {  # <task-id> <new_state> <evidence>
  local id=$1 new_state=$2 evidence=$3
  local current_state

  # Validate new state is known
  local valid=0
  for s in "${VALID_STATES[@]}"; do
    [ "$s" = "$new_state" ] && valid=1
  done
  [ "$valid" -eq 1 ] || { echo "Invalid state: $new_state" >&2; return 1; }

  lifecycle_lock "$id" || return 1
  current_state=$(lifecycle_read "$id" current_step)
  [ -n "$current_state" ] || current_state="READY"

  # Validate transition
  if ! validate_transition "$current_state" "$new_state" "$id"; then
    lifecycle_unlock "$id"
    return 1
  fi

  # Require evidence for forward transitions (not for HOLD states)
  case "$new_state" in
    WAITING_QUOTA|WAITING_APPROVAL|WAITING_EXTERNAL|RECOVERY_HOLD|ESCALATED)
      # HOLD states can transition without external evidence
      ;;
    *)
      # Forward transitions require evidence
      [ -n "$evidence" ] || { lifecycle_unlock "$id"; echo "Evidence required for transition to $new_state" >&2; return 1; }
      ;;
  esac

  local now=$(date +%s)
  local file=$(lifecycle_path "$id") tmp
  tmp=$(mktemp "$LIFECYCLE_DIR/.lifecycle.XXXXXX") || { lifecycle_unlock "$id"; return 1; }

  # Read all current fields
  local fields=()
  if [ -f "$file" ]; then
    while IFS= read -r line; do
      fields+=("$line")
    done < "$file"
  fi

  # Update current_step, last_progress, updated_epoch, evidence
  local new_fields=()
  local found_step=0 found_progress=0 found_updated=0 found_evidence=0 found_version=0
  for line in "${fields[@]}"; do
    case "$line" in
      current_step=*) new_fields+=("current_step=$new_state"); found_step=1 ;;
      last_progress=*) new_fields+=("last_progress=$now"); found_progress=1 ;;
      updated_epoch=*) new_fields+=("updated_epoch=$now"); found_updated=1 ;;
      evidence=*) new_fields+=("evidence=${line#evidence=}${line:+$'\n'}[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $evidence"); found_evidence=1 ;;
      state_version=*) new_fields+=("state_version=$((${line#state_version=} + 1))"); found_version=1 ;;
      *) new_fields+=("$line") ;;
    esac
  done

  [ "$found_step" -eq 1 ] || new_fields+=("current_step=$new_state")
  [ "$found_progress" -eq 1 ] || new_fields+=("last_progress=$now")
  [ "$found_updated" -eq 1 ] || new_fields+=("updated_epoch=$now")
  [ "$found_evidence" -eq 1 ] || new_fields+=("evidence=[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $evidence")
  [ "$found_version" -eq 1 ] || new_fields+=("state_version=1")

  # Write atomically
  printf '%s\n' "${new_fields[@]}" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$file" || { rm -f "$tmp"; lifecycle_unlock "$id"; return 1; }

  lifecycle_unlock "$id"
  return 0
}

# Append to evidence (with lock)
append_evidence() {  # <task-id> <text>
  local id=$1 text=$2
  lifecycle_lock "$id" || return 1
  append_evidence_locked "$id" "$text"
  lifecycle_unlock "$id"
}

append_evidence_locked() {  # <task-id> <text> (must hold lock)
  local id=$1 text=$2 file=$(lifecycle_path "$id") tmp
  tmp=$(mktemp "$LIFECYCLE_DIR/.lifecycle.XXXXXX") || return 1
  local stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local now=$(date +%s)
  local found=0
  if [ -f "$file" ]; then
    while IFS= read -r line; do
      case "$line" in
        evidence=*) printf '%s\n' "${line}${line:+$'\n'}[$stamp] $text" >> "$tmp"; found=1 ;;
        updated_epoch=*) printf '%s\n' "updated_epoch=$now" >> "$tmp" ;;
        state_version=*) printf '%s\n' "state_version=$((${line#state_version=} + 1))" >> "$tmp" ;;
        *) printf '%s\n' "$line" >> "$tmp" ;;
      esac
    done < "$file"
  fi
  [ "$found" -eq 1 ] || printf 'evidence=[%s] %s\n' "$stamp" "$text" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}

# Initialize lifecycle record from meta/status if missing
ensure_lifecycle() {  # <task-id>
  local id=$1 meta="$STATE/$id.meta" status="$STATE/$id.status"
  [ -f "$meta" ] || return 1
  lifecycle_exists "$id" && return 0

  lifecycle_lock "$id" || return 1

  # Double-check after acquiring lock
  lifecycle_exists "$id" && { lifecycle_unlock "$id"; return 0; }

  local owner lane priority deps accept_criteria
  owner=$(grep '^harness=' "$meta" | cut -d= -f2-)
  lane=$(derive_lane "$id")
  priority=$(grep '^priority=' "$meta" 2>/dev/null | cut -d= -f2- || echo "normal")
  deps=$(grep '^depends_on=' "$meta" 2>/dev/null | cut -d= -f2- || echo "")
  accept_criteria=$(grep '^acceptance_criteria=' "$meta" 2>/dev/null | cut -d= -f2- || echo "")

  local now=$(date +%s)
  {
    printf 'owner=%s\n' "$owner"
    printf 'lane=%s\n' "$lane"
    printf 'priority=%s\n' "$priority"
    printf 'dependencies=%s\n' "$deps"
    printf 'acceptance_criteria=%s\n' "$accept_criteria"
    printf 'current_step=READY\n'
    printf 'last_progress=%s\n' "$now"
    printf 'next_action=awaiting_dispatch\n'
    printf 'retry_state=attempt=0,last_error=,last_retry=0\n'
    printf 'blocking_reason=\n'
    printf 'evidence=\n'
    printf 'resume_checkpoint=\n'
    printf 'state_version=1\n'
    printf 'created_epoch=%s\n' "$now"
    printf 'updated_epoch=%s\n' "$now"
    printf 'state_machine_version=%s\n' "$STATE_MACHINE_VERSION"
  } > "$(lifecycle_path "$id")"
  chmod 600 "$(lifecycle_path "$id")"
  lifecycle_unlock "$id"
}

# Migrate lifecycle record to current state machine version
migrate_lifecycle() {  # <task-id>
  local id=$1 file=$(lifecycle_path "$id") version
  [ -f "$file" ] || return 0
  version=$(lifecycle_read "$id" state_machine_version)
  [ -n "$version" ] || version=0
  [ "$version" -ge "$STATE_MACHINE_VERSION" ] && return 0

  lifecycle_lock "$id" || return 1
  # Re-read after lock
  version=$(lifecycle_read "$id" state_machine_version)
  [ -n "$version" ] || version=0
  if [ "$version" -ge "$STATE_MACHINE_VERSION" ]; then
    lifecycle_unlock "$id"
    return 0
  fi

  local tmp=$(mktemp "$LIFECYCLE_DIR/.lifecycle.XXXXXX") || { lifecycle_unlock "$id"; return 1; }
  local now=$(date +%s)
  local found_version=0 found_machine=0

  while IFS= read -r line; do
    case "$line" in
      state_version=*) printf '%s\n' "state_version=$((${line#state_version=} + 1))" >> "$tmp"; found_version=1 ;;
      state_machine_version=*) printf 'state_machine_version=%s\n' "$STATE_MACHINE_VERSION" >> "$tmp"; found_machine=1 ;;
      *) printf '%s\n' "$line" >> "$tmp" ;;
    esac
  done < "$file"

  [ "$found_version" -eq 1 ] || printf 'state_version=1\n' >> "$tmp"
  [ "$found_machine" -eq 1 ] || printf 'state_machine_version=%s\n' "$STATE_MACHINE_VERSION" >> "$tmp"

  chmod 600 "$tmp"
  mv -f "$tmp" "$file" || { rm -f "$tmp"; lifecycle_unlock "$id"; return 1; }
  lifecycle_unlock "$id"
}

# Fill missing required fields (lane, etc.) from meta/backlog
populate_missing_fields() {  # <task-id>
  local id=$1 file=$(lifecycle_path "$id")
  [ -f "$file" ] || return 0
  
  local current_lane=$(lifecycle_read "$id" lane)
  [ -n "$current_lane" ] && return 0  # Already has lane
  
  local lane=$(derive_lane "$id")
  [ -n "$lane" ] || return 0
  
  lifecycle_lock "$id" || return 1
  
  local tmp=$(mktemp "$LIFECYCLE_DIR/.lifecycle.XXXXXX") || { lifecycle_unlock "$id"; return 1; }
  local now=$(date +%s)
  
  while IFS= read -r line; do
    case "$line" in
      lane=*) printf 'lane=%s\n' "$lane" >> "$tmp" ;;
      updated_epoch=*) printf 'updated_epoch=%s\n' "$now" >> "$tmp" ;;
      state_version=*) printf 'state_version=%s\n' "$((${line#state_version=} + 1))" >> "$tmp" ;;
      *) printf '%s\n' "$line" >> "$tmp" ;;
    esac
  done < "$file"
  
  chmod 600 "$tmp"
  mv -f "$tmp" "$file" || { rm -f "$tmp"; lifecycle_unlock "$id"; return 1; }
  lifecycle_unlock "$id"
}

# Update retry state
update_retry_state() {  # <task-id> <attempt> <error>
  local id=$1 attempt=$2 error=$3
  lifecycle_lock "$id" || return 1
  local now=$(date +%s)
  local tmp=$(mktemp "$LIFECYCLE_DIR/.lifecycle.XXXXXX") || { lifecycle_unlock "$id"; return 1; }
  local found=0

  while IFS= read -r line; do
    case "$line" in
      retry_state=*) printf 'retry_state=attempt=%s,last_error=%s,last_retry=%s\n' "$attempt" "$error" "$now" >> "$tmp"; found=1 ;;
      updated_epoch=*) printf 'updated_epoch=%s\n' "$now" >> "$tmp" ;;
      state_version=*) printf 'state_version=%s\n' "$((${line#state_version=} + 1))" >> "$tmp" ;;
      *) printf '%s\n' "$line" >> "$tmp" ;;
    esac
  done < "$(lifecycle_path "$id")"

  [ "$found" -eq 1 ] || printf 'retry_state=attempt=%s,last_error=%s,last_retry=%s\n' "$attempt" "$error" "$now" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$(lifecycle_path "$id")" || { rm -f "$tmp"; lifecycle_unlock "$id"; return 1; }
  lifecycle_unlock "$id"
}

# Get retry attempt count
get_retry_attempt() {  # <task-id>
  local state=$(lifecycle_read "$1" retry_state)
  printf '%s\n' "$state" | sed -n 's/.*attempt=\([0-9]*\).*/\1/p'
}

# Get last retry time
get_last_retry() {  # <task-id>
  local state=$(lifecycle_read "$1" retry_state)
  printf '%s\n' "$state" | sed -n 's/.*last_retry=\([0-9]*\).*/\1/p'
}

# ============================================================================
# LANE QUEUE HELPERS
# ============================================================================

lane_enqueue() {  # <lane> <task-id>
  local lane=$1 id=$2 file
  file=$(lane_queue_path "$lane")
  mkdir -p "$LANE_QUEUE_DIR"
  grep -Fxq "$id" "$file" 2>/dev/null && return 0
  printf '%s\n' "$id" >> "$file"
}

lane_dequeue() {  # <lane> -> prints task-id or empty
  local lane=$1 file id
  file=$(lane_queue_path "$lane")
  [ -f "$file" ] || return 1
  id=$(head -1 "$file")
  [ -n "$id" ] || return 1
  sed -i '' '1d' "$file" 2>/dev/null || sed -i '1d' "$file"
  printf '%s\n' "$id"
}

lane_peek() {  # <lane> -> prints task-id or empty
  local lane=$1 file
  file=$(lane_queue_path "$lane")
  [ -f "$file" ] || return 1
  head -1 "$file"
}

lane_remove() {  # <lane> <task-id>
  local lane=$1 id=$2 file
  file=$(lane_queue_path "$lane")
  [ -f "$file" ] || return 0
  grep -Fxv "$id" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

lane_list() {  # <lane> -> prints all task-ids
  local lane=$1 file
  file=$(lane_queue_path "$lane")
  [ -f "$file" ] || return 0
  cat "$file"
}

# ============================================================================
# STATE CLASSIFICATION (external evidence only)
# ============================================================================

classify_task() {  # <task-id> -> prints "state source detail"
  local id=$1
  local out
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null) || { echo "unknown none fm-crew-state failed"; return; }
  # Output format: "state: <state> · source: <source> · <detail>"
  local state source detail
  state=$(printf '%s\n' "$out" | sed -n 's/^state: \([^·]*\).*/\1/p' | sed 's/[[:space:]]*$//')
  source=$(printf '%s\n' "$out" | sed -n 's/.*source: \([^·]*\).*/\1/p' | sed 's/[[:space:]]*$//')
  detail=$(printf '%s\n' "$out" | sed -n 's/.*· \(.*\)/\1/p')
  printf '%s %s %s\n' "$state" "$source" "$detail"
}

is_terminal() {  # <state>
  case "$1" in DONE|FAILED) return 0 ;; *) return 1 ;; esac
}

is_hold_state() {  # <state>
  case "$1" in WAITING_QUOTA|WAITING_APPROVAL|WAITING_EXTERNAL|RECOVERY_HOLD|ESCALATED) return 0 ;; *) return 1 ;; esac
}

is_legitimate_hold() {  # <task-id> <lifecycle_state> <external_detail>
  local id=$1 lifecycle_state=$2 detail=$3
  case "$lifecycle_state" in
    WAITING_QUOTA|WAITING_APPROVAL|WAITING_EXTERNAL|RECOVERY_HOLD) return 0 ;;
    *) return 1 ;;
  esac
}

# Check if external state indicates a legitimate hold
is_external_legitimate_hold() {  # <external_state> <detail>
  local state=$1 detail=$2
  case "$state" in
    parked)
      case "$detail" in *quota*|*exhausted*|*approval*|*HOLD*|*captain*|*merge*|*push.target*|*trust.boundary*|*review*|*finding*|*awaiting*|*external*) return 0 ;; *) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
}

# Check if task is stalled (P1-5: separate observables + hysteresis + per-step waits)
is_stalled() {  # <task-id> <external_state> <detail>
  local id=$1 external_state=$2 detail=$3
  local lifecycle_state
  lifecycle_state=$(lifecycle_read "$id" current_step)
  # Check against lifecycle states (uppercase), not external states (lowercase)
  case "$lifecycle_state" in
    RUNNING|TESTING|REVIEWING|FIXING|RETESTING) ;;
    *) return 1 ;;
  esac

  local meta="$STATE/$id.meta" status="$STATE/$id.status" turn_ended="$STATE/$id.turn-ended" progress="$STATE/$id.progress"
  local now progress_age worktree_age heartbeat_age step_age

  now=$(date +%s)

  # Observable 1: Status file age
  if [ -f "$status" ]; then
    progress_age=$(( now - $(stat -f %m "$status" 2>/dev/null || echo "$now") ))
  else
    progress_age=999999
  fi

  # Observable 2: Worktree age (file changes)
  local wt=$(grep '^worktree=' "$meta" 2>/dev/null | cut -d= -f2- | tail -1)
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    worktree_age=$(( now - $(stat -f %m "$wt" 2>/dev/null || echo "$now") ))
  else
    worktree_age=999999
  fi

  # Observable 3: Heartbeat / run-step activity (from fm-crew-state.sh)
  local crew_state=$(classify_task "$id")
  local run_detail=$(printf '%s\n' "$crew_state" | cut -d'·' -f3-)
  if printf '%s\n' "$run_detail" | grep -q "active_steps"; then
    heartbeat_age=0
  else
    heartbeat_age=$progress_age
  fi

  # Observable 4: Per-step progress file (if exists)
  if [ -f "$progress" ]; then
    step_age=$(( now - $(stat -f %m "$progress" 2>/dev/null || echo "$now") ))
  else
    step_age=$heartbeat_age
  fi
  fi

  # Hysteresis: require ALL observables to exceed threshold
  # Use separate thresholds per observable type
  local progress_thresh=$STALLED_THRESHOLD_SECS
  local worktree_thresh=$STALLED_THRESHOLD_SECS
  local heartbeat_thresh=$STALLED_THRESHOLD_SECS
  local step_thresh=$STALLED_THRESHOLD_SECS

  [ "$progress_age" -ge "$progress_thresh" ] && \
  [ "$worktree_age" -ge "$worktree_thresh" ] && \
  [ "$heartbeat_age" -ge "$heartbeat_thresh" ] && \
  [ "$step_age" -ge "$step_thresh" ]
}

# Classify interruption type
classify_interruption() {  # <task-id> <state> <detail> -> prints type
  local id=$1 state=$2 detail=$3
  case "$detail" in
    *503*|*unavailable*|*provider*) echo "provider_503" ;;
    *rate.limit*|*quota*|*exhausted*) echo "quota_exhausted" ;;
    *session*lost*|*harness*|*spawn*fail*) echo "harness_session" ;;
    *crash*|*exit*|*terminat*|*signal*) echo "process_crash" ;;
    *CI*fail*|*test*fail*) echo "ci_failure" ;;
    *review*finding*|*review*) echo "review_findings" ;;
    *approval*|*HOLD*|*captain*) echo "external_approval" ;;
    *done*|*complete*) echo "work_complete" ;;
    *) echo "unknown" ;;
  esac
}

# ============================================================================
# AUTO-RESUME LOGIC (P0-1: failure classes + bounded backoff/jitter + durable retry state + WAITING_QUOTA + recovery lease/idempotency + RECOVERY_HOLD)
# ============================================================================

calc_backoff() {  # <attempt>
  local attempt=$1 base=$AUTO_RESUME_BASE_BACKOFF max=$AUTO_RESUME_MAX_BACKOFF jitter_pct=$AUTO_RESUME_JITTER_PCT
  local backoff jitter
  backoff=$(( base * (1 << (attempt - 1)) ))
  [ "$backoff" -gt "$max" ] && backoff=$max
  jitter=$(( backoff * jitter_pct / 100 ))
  local rand=$(( RANDOM % (2 * jitter + 1) - jitter ))
  backoff=$(( backoff + rand ))
  [ "$backoff" -lt 1 ] && backoff=1
  printf '%s\n' "$backoff"
}

can_retry() {  # <task-id>
  local id=$1 last_retry backoff
  last_retry=$(get_last_retry "$id")
  [ -n "$last_retry" ] || return 0
  local attempt=$(get_retry_attempt "$id")
  backoff=$(calc_backoff "$attempt")
  [ $(( $(date +%s) - last_retry )) -ge "$backoff" ]
}

# Recovery lease for idempotency
recovery_lease_acquire() {  # <task-id> <lease_name>
  local id=${1:-} lease=${2:-} lease_file
  [ -n "$id" ] && [ -n "$lease" ] || return 1
  lease_file="$STATE/.recovery-lease-$id-$lease"
  (umask 077; set -C; printf '%s\n' "$(date +%s)" > "$lease_file") 2>/dev/null || return 1
  return 0
}

recovery_lease_release() {  # <task-id> <lease_name>
  local id=${1:-} lease=${2:-} lease_file
  [ -n "$id" ] && [ -n "$lease" ] || return 0
  lease_file="$STATE/.recovery-lease-$id-$lease"
  rm -f "$lease_file"
}

recovery_lease_held() {  # <task-id> <lease_name>
  local id=${1:-} lease=${2:-} lease_file
  [ -n "$id" ] && [ -n "$lease" ] || return 1
  lease_file="$STATE/.recovery-lease-$id-$lease"
  [ -f "$lease_file" ]
}

auto_resume_task() {  # <task-id>
  local id=$1 interruption_type lifecycle_state external_state detail attempt backoff new_harness note

  lifecycle_state=$(lifecycle_read "$id" current_step)
  external_state=$(classify_task "$id" | cut -d' ' -f1)
  detail=$(classify_task "$id" | cut -d' ' -f3-)

  # Don't resume if lifecycle is in a legitimate hold state
  if is_legitimate_hold "$id" "$lifecycle_state" "$detail"; then
    append_evidence "$id" "Auto-resume skipped: lifecycle hold ($lifecycle_state: $detail)"
    return 0
  fi

  # Don't resume if already ESCALATED (terminal)
  [ "$lifecycle_state" = "ESCALATED" ] && return 0

  # Don't resume if external state indicates legitimate hold
  if is_external_legitimate_hold "$external_state" "$detail"; then
    append_evidence "$id" "Auto-resume skipped: external hold ($external_state: $detail)"
    # Sync lifecycle to match
    sync_lifecycle_with_external "$id" "$external_state"
    return 0
  fi

  interruption_type=$(classify_interruption "$id" "$external_state" "$detail")
  attempt=$(get_retry_attempt "$id")
  attempt=$((attempt + 1))

  # Max attempts reached -> reassign or hold
  if [ "$attempt" -gt "$AUTO_RESUME_MAX_ATTEMPTS" ]; then
    case "$interruption_type" in
      provider_503|harness_session)
        new_harness=$(select_alternate_harness "$id")
        if [ -n "$new_harness" ]; then
          # Acquire recovery lease to prevent duplicate reassignment
          if recovery_lease_acquire "$id" "reassign"; then
            note="Auto-reassign after $AUTO_RESUME_MAX_ATTEMPTS failed resumes ($interruption_type). Switching to $new_harness."
            fm_control_relaunch "$id" "$new_harness" "$note"
            recovery_lease_release "$id" "reassign"
            return $?
          else
            append_evidence "$id" "Reassignment already in progress for $id"
            return 0
          fi
        fi
        ;;
      quota_exhausted)
        # Preserve as WAITING_QUOTA with evidence
        lifecycle_transition "$id" "WAITING_QUOTA" "Quota exhausted after $AUTO_RESUME_MAX_ATTEMPTS attempts. Preserved as WAITING_QUOTA."
        return 0
        ;;
    esac
    # No reassignment possible -> escalate (only if not already ESCALATED)
    if [ "$lifecycle_state" != "ESCALATED" ]; then
      append_evidence "$id" "Auto-resume exhausted ($interruption_type). Escalating to captain."
      lifecycle_transition "$id" "ESCALATED" "Auto-resume exhausted after $AUTO_RESUME_MAX_ATTEMPTS attempts for $interruption_type"
    fi
    return 1
  fi

  # Check backoff
  if ! can_retry "$id"; then
    return 0  # Not time yet
  fi

  # Acquire recovery lease for this attempt
  if ! recovery_lease_acquire "$id" "attempt-$attempt"; then
    append_evidence "$id" "Recovery attempt $attempt already in progress"
    return 0
  fi

  update_retry_state "$id" "$attempt" "$interruption_type"
  backoff=$(calc_backoff "$attempt")
  append_evidence "$id" "Auto-resume attempt $attempt/$AUTO_RESUME_MAX_ATTEMPTS ($interruption_type). Backoff: ${backoff}s."

  case "$interruption_type" in
    process_crash|provider_503|harness_session|ci_failure|review_findings)
      # Determine target state based on interruption type
      local target_state="RUNNING"
      case "$interruption_type" in
        ci_failure) target_state="FIXING" ;;
        review_findings) target_state="FIXING" ;;
      esac
      note="Auto-resume attempt $attempt after $interruption_type. Previous state: $lifecycle_state. Checkpoint: $(lifecycle_read "$id" resume_checkpoint)"
      if fm_control_relaunch "$id" "" "$note"; then
        # Transition to RECOVERY_HOLD while relaunch is in progress
        lifecycle_transition "$id" "RECOVERY_HOLD" "Auto-resume attempt $attempt initiated for $interruption_type"
      else
        append_evidence "$id" "Auto-resume attempt $attempt failed: fm_control_relaunch returned error"
        recovery_lease_release "$id" "attempt-$attempt"
        return 1
      fi
      ;;
    quota_exhausted)
      lifecycle_transition "$id" "WAITING_QUOTA" "Quota exhausted. Awaiting quota recovery."
      ;;
    external_approval)
      lifecycle_transition "$id" "WAITING_APPROVAL" "Waiting for external approval"
      ;;
    work_complete)
      # Should be handled by lane progression
      ;;
    *)
      note="Auto-resume attempt $attempt after $interruption_type. Previous state: $lifecycle_state."
      if fm_control_relaunch "$id" "" "$note"; then
        lifecycle_transition "$id" "RECOVERY_HOLD" "Auto-resume attempt $attempt initiated for $interruption_type"
      else
        append_evidence "$id" "Auto-resume attempt $attempt failed: fm_control_relaunch returned error"
        recovery_lease_release "$id" "attempt-$attempt"
        return 1
      fi
      ;;
  esac

  recovery_lease_release "$id" "attempt-$attempt"
}

select_alternate_harness() {  # <task-id>
  local id=$1 current_harness
  current_harness=$(lifecycle_read "$id" owner)
  # Placeholder - would integrate with quota-axi for model selection
  echo ""
}

fm_control_relaunch() {  # <task-id> [new_harness] <note>
  local id=$1 new_harness=$2 note=$3 args=()
  args=(relaunch --note "$note")
  [ -n "$new_harness" ] && args+=(--harness "$new_harness")
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$id" "${args[@]}"
}

# ============================================================================
# LANE PROGRESSION (P0-2: lane READY queue + dispatcher)
# ============================================================================

get_active_lanes() {
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    local lane=$(grep '^lane=' "$meta" 2>/dev/null | cut -d= -f2-)
    [ -z "$lane" ] && lane=$(derive_lane "$(basename "$meta" .meta)")
    printf '%s\n' "$lane"
  done | sort -u
}

get_lane_tasks() {  # <lane>
  local lane=$1
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    local m_lane=$(grep '^lane=' "$meta" 2>/dev/null | cut -d= -f2-)
    [ -z "$m_lane" ] && m_lane=$(derive_lane "$(basename "$meta" .meta)")
    if [ "$m_lane" = "$lane" ]; then
      basename "$meta" .meta
    fi
  done
}

is_task_ready() {  # <task-id>
  local id=$1 deps dep
  deps=$(lifecycle_read "$id" dependencies)
  [ -z "$deps" ] && return 0
  for dep in ${deps//,/ }; do
    local dep_lifecycle_state=$(lifecycle_read "$dep" current_step)
    local dep_external_state=$(classify_task "$dep" | cut -d' ' -f1)
    # Check both lifecycle state and external state
    case "$dep_lifecycle_state" in DONE|FAILED) continue ;; esac
    case "$dep_external_state" in done|failed) continue ;; esac
    return 1
  done
  return 0
}

# Diagnostic state for lane queue
lane_diagnostic() {  # <lane> -> prints diagnostic info
  local lane=$1
  echo "Lane: $lane"
  echo "  Tasks in lane:"
  for id in $(get_lane_tasks "$lane"); do
    local ls=$(lifecycle_read "$id" current_step)
    local es=$(classify_task "$id" | cut -d' ' -f1)
    local deps=$(lifecycle_read "$id" dependencies)
    local blocking=$(lifecycle_read "$id" blocking_reason)
    printf '    %s: lifecycle=%s external=%s deps=%s blocking=%s\n' "$id" "$ls" "$es" "$deps" "$blocking"
  done
  echo "  Queue:"
  for id in $(lane_list "$lane"); do
    printf '    %s\n' "$id"
  done
}

advance_lane() {  # <lane>
  local lane=$1 id state

  # Build queue from tasks in this lane that are READY and not in flight
  for id in $(get_lane_tasks "$lane"); do
    state=$(lifecycle_read "$id" current_step)
    # Only enqueue tasks in READY state (not already assigned/running)
    [ "$state" = "READY" ] || continue
    if is_task_ready "$id"; then
      lane_enqueue "$lane" "$id"
    fi
  done

  # Get next task from queue
  id=$(lane_peek "$lane")
  [ -n "$id" ] || return 0

  # Check if lane has capacity (no other task in RUNNING/TESTING/REVIEWING/FIXING/RETESTING state)
  local working_count=0
  for t in $(get_lane_tasks "$lane"); do
    local ls=$(lifecycle_read "$t" current_step)
    case "$ls" in RUNNING|TESTING|REVIEWING|FIXING|RETESTING|READY_FOR_MERGE|MERGE_VERIFIED|DEPLOYMENT_GATE)
      working_count=$((working_count + 1))
      ;;
    esac
  done

  if [ "$working_count" -eq 0 ]; then
    # Lane is free, dispatch next task
    lane_dequeue "$lane"
    lifecycle_transition "$id" "ASSIGNED" "Lane $lane free, dispatching next READY task."
    # Update next_action for dispatcher
    lifecycle_lock "$id"
    local file=$(lifecycle_path "$id") tmp
    tmp=$(mktemp "$LIFECYCLE_DIR/.lifecycle.XXXXXX")
    while IFS= read -r line; do
      case "$line" in
        next_action=*) printf 'next_action=spawning_worker\n' >> "$tmp" ;;
        updated_epoch=*) printf 'updated_epoch=%s\n' "$(date +%s)" >> "$tmp" ;;
        state_version=*) printf 'state_version=%s\n' "$((${line#state_version=} + 1))" >> "$tmp" ;;
        *) printf '%s\n' "$line" >> "$tmp" ;;
      esac
    done < "$file"
    chmod 600 "$tmp"
    mv -f "$tmp" "$file"
    lifecycle_unlock "$id"
    return 0
  fi
}

# ============================================================================
# STALE/ORPHAN RECONCILIATION (P1-3: read-only inventory + classification)
# ============================================================================

reconcile_orphans() {
  local cleaned=0 quarantined=0

  # Inventory: .subsuper-seen-status-* markers for tasks whose meta no longer exists
  echo "=== Orphan Inventory ==="
  for marker in "$STATE"/.subsuper-seen-status-*; do
    [ -f "$marker" ] || continue
    local task_id=$(basename "$marker" | sed 's/^.subsuper-seen-status-//')
    if [ ! -f "$STATE/$task_id.meta" ]; then
      echo "  ORPHAN marker: $marker (task: $task_id)"
      # Quarantine instead of delete
      local quarantine_dir="$STATE/quarantine/orphan-markers/$(date +%Y%m%d-%H%M%S)"
      mkdir -p "$quarantine_dir"
      mv "$marker" "$quarantine_dir/"
      quarantined=$((quarantined + 1))
    fi
  done

  # Inventory: worktrees without meta (treehouse pool slots)
  if [ -d "/Users/irene/.treehouse" ]; then
    echo "=== Treehouse Pool Inventory ==="
    for pool in /Users/irene/.treehouse/firstmate-*/; do
      [ -d "$pool" ] || continue
      for wt in "$pool"/*/; do
        [ -d "$wt" ] || continue
        local wt_id=$(basename "$wt")
        # Check if any meta references this worktree
        local referenced=0
        for meta in "$STATE"/*.meta; do
          [ -f "$meta" ] || continue
          local m_wt=$(grep '^worktree=' "$meta" 2>/dev/null | cut -d= -f2- | tail -1)
          [ "$m_wt" = "$wt" ] && referenced=1 && break
        done
        if [ "$referenced" -eq 0 ]; then
          echo "  UNREFERENCED worktree: $wt"
        fi
      done
    done
  fi

  if [ "$quarantined" -gt 0 ]; then
    echo "Quarantined $quarantined orphan markers (no deletion)"
  fi
}

# Sync lifecycle state with external state (fm-crew-state.sh)
sync_lifecycle_with_external() {  # <task-id> <external_state>
  local id=$1 external_state=$2
  local lifecycle_state=$(lifecycle_read "$id" current_step)

  # If lifecycle is READY but external shows a hold state, update lifecycle
  case "$external_state" in
    parked)
      # Check detail for specific hold reason
      local detail=$(classify_task "$id" | cut -d' ' -f3-)
      case "$detail" in
        *quota*|*exhausted*)
          [ "$lifecycle_state" = "READY" ] && lifecycle_transition "$id" "WAITING_QUOTA" "Synced with external: quota exhausted"
          ;;
        *approval*|*HOLD*|*captain*|*merge*|*push.target*|*trust.boundary*)
          [ "$lifecycle_state" = "READY" ] && lifecycle_transition "$id" "WAITING_APPROVAL" "Synced with external: approval wait"
          ;;
        *review*|*finding*)
          [ "$lifecycle_state" = "READY" ] && lifecycle_transition "$id" "WAITING_EXTERNAL" "Synced with external: review findings"
          ;;
        *awaiting*|*external*)
          [ "$lifecycle_state" = "READY" ] && lifecycle_transition "$id" "WAITING_EXTERNAL" "Synced with external: awaiting external"
          ;;
        *)
          # Generic parked - could be waiting for something
          [ "$lifecycle_state" = "READY" ] && lifecycle_transition "$id" "WAITING_EXTERNAL" "Synced with external: parked"
          ;;
      esac
      ;;
    failed)
      case "$lifecycle_state" in
        READY|ASSIGNED|RUNNING) lifecycle_transition "$id" "FAILED" "Synced with external: task failed" ;;
      esac
      ;;
    done)
      # If external says done, transition to DONE from appropriate states
      case "$lifecycle_state" in
        READY_FOR_MERGE|MERGE_VERIFIED|DEPLOYMENT_GATE|REVIEWING|TESTING|RUNNING)
          lifecycle_transition "$id" "DONE" "Synced with external: task done" ;;
      esac
      ;;
    unknown)
      # Don't change lifecycle state for unknown
      ;;
    working|paused)
      # If external says working/paused but lifecycle is READY, transition to ASSIGNED
      # If lifecycle is ASSIGNED or RECOVERY_HOLD, transition to RUNNING
      case "$lifecycle_state" in
        READY) lifecycle_transition "$id" "ASSIGNED" "Synced with external: task actively $external_state" ;;
        ASSIGNED|RECOVERY_HOLD) lifecycle_transition "$id" "RUNNING" "Synced with external: task actively $external_state" ;;
      esac
      ;;
  esac
}

# ============================================================================
# MAIN COMMANDS
# ============================================================================

cmd_reconcile() {  # [--startup]
  local startup=0
  [ "${1:-}" = "--startup" ] && startup=1

  echo "=== Reconcile start $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

  # Ensure lifecycle records for all tasks (with migration)
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    local id=$(basename "$meta" .meta)
    ensure_lifecycle "$id"
    migrate_lifecycle "$id"
    populate_missing_fields "$id"
  done

  # Sync all lifecycle states with external states FIRST
  echo "=== Syncing lifecycle states with external states ==="
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    local id=$(basename "$meta" .meta)
    local state detail
    state=$(classify_task "$id" | cut -d' ' -f1)
    detail=$(classify_task "$id" | cut -d' ' -f3-)
    sync_lifecycle_with_external "$id" "$state"
  done

  # Reconcile orphans (read-only inventory + quarantine)
  reconcile_orphans

  # Scan for stalled tasks (P1-5)
  cmd_scan_stalled

  # Advance all lanes (P0-2) - using updated lifecycle states
  for lane in $(get_active_lanes); do
    advance_lane "$lane"
  done

  # Auto-resume interrupted tasks (P0-1)
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    local id=$(basename "$meta" .meta)
    local state detail
    state=$(classify_task "$id" | cut -d' ' -f1)
    detail=$(classify_task "$id" | cut -d' ' -f3-)

    # Get updated lifecycle state (already synced above)
    local lifecycle_state=$(lifecycle_read "$id" current_step)

    # Skip if working normally (external state)
    [ "$state" = "working" ] && continue
    [ "$state" = "paused" ] && continue

    # Skip if lifecycle is terminal or in legitimate hold
    case "$lifecycle_state" in
      DONE|FAILED|ESCALATED) continue ;;
    esac

    # Skip if legitimate hold (check both lifecycle and external state)
    is_legitimate_hold "$id" "$lifecycle_state" "$detail" && continue
    is_legitimate_hold "$id" "$state" "$detail" && continue

    # Attempt auto-resume
    auto_resume_task "$id"
  done

  echo "=== Reconcile complete $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
}

cmd_scan_stalled() {
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    local id=$(basename "$meta" .meta)
    local kind=$(grep '^kind=' "$meta" 2>/dev/null | cut -d= -f2- || echo "ship")
    [ "$kind" = "secondmate" ] && continue

    local state detail
    state=$(classify_task "$id" | cut -d' ' -f1)
    detail=$(classify_task "$id" | cut -d' ' -f3-)

    if is_stalled "$id" "$state" "$detail"; then
      append_evidence "$id" "STALLED detected: all observables exceed threshold. State: $state, Detail: $detail"
      lifecycle_transition "$id" "RECOVERY_HOLD" "STALLED: heartbeat healthy but no progress for ${STALLED_THRESHOLD_SECS}s across all observables"
      local w=$(grep '^window=' "$meta" 2>/dev/null | cut -d= -f2-)
      [ -n "$w" ] && fm_wake_append stale "$w" "stale: $id (STALLED: all observables exceed ${STALLED_THRESHOLD_SECS}s threshold)"
    fi
  done
}

cmd_lane_next() {  # <lane>
  local lane=${1:-}
  [ -n "$lane" ] || die "lane required"
  advance_lane "$lane"
}

cmd_lane_diagnostic() {  # <lane>
  local lane=${1:-}
  [ -n "$lane" ] || die "lane required"
  lane_diagnostic "$lane"
}

cmd_task_resume() {  # <task-id> [--reason <text>]
  local id=$1 reason="Manual resume"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in --reason) reason=$2; shift 2 ;; *) shift ;; esac
  done
  lifecycle_transition "$id" "RECOVERY_HOLD" "Manual resume requested: $reason"
  append_evidence "$id" "Manual resume: $reason"
  fm_control_relaunch "$id" "" "$reason"
}

cmd_task_reassign() {  # <task-id> --harness <name> [--model <name>] [--effort <level>] --note <text>
  local id=$1 harness="" model="" effort="" note=""
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --harness) harness=$2; shift 2 ;;
      --model) model=$2; shift 2 ;;
      --effort) effort=$2; shift 2 ;;
      --note) note=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$harness" ] || die "--harness required"
  [ -n "$note" ] || die "--note required"
  lifecycle_transition "$id" "RECOVERY_HOLD" "Reassignment to $harness requested: $note"
  local args=("--harness" "$harness" "--note" "$note")
  [ -n "$model" ] && args+=("--model" "$model")
  [ -n "$effort" ] && args+=("--effort" "$effort")
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$id" relaunch "${args[@]}"
}

cmd_task_hold() {  # <task-id> --reason <text> [--until <epoch>]
  local id=$1 reason="" until=""
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) reason=$2; shift 2 ;;
      --until) until=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$reason" ] || die "--reason required"
  lifecycle_transition "$id" "WAITING_EXTERNAL" "Held: $reason"
  [ -n "$until" ] && lifecycle_lock "$id" && {
    local file=$(lifecycle_path "$id") tmp=$(mktemp "$LIFECYCLE_DIR/.lifecycle.XXXXXX")
    while IFS= read -r line; do
      case "$line" in
        hold_until=*) ;;
        *) printf '%s\n' "$line" >> "$tmp" ;;
      esac
    done < "$file"
    printf 'hold_until=%s\n' "$until" >> "$tmp"
    chmod 600 "$tmp"; mv -f "$tmp" "$file"; lifecycle_unlock "$id"
  }
  append_evidence "$id" "Held: $reason"
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-captain-hold.sh" hold "$id" --reason "$reason" ${until:+--until "$until"}
}

cmd_task_done() {  # <task-id> --evidence <text>
  local id=$1 evidence=""
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in --evidence) evidence=$2; shift 2 ;; *) shift ;; esac
  done
  [ -n "$evidence" ] || die "--evidence required"
  # Evidence-based transition to DONE
  lifecycle_transition "$id" "DONE" "DONE: $evidence"
  local lane=$(lifecycle_read "$id" lane)
  lane_remove "$lane" "$id"
}

# ============================================================================
# ENTRY POINT
# ============================================================================

case "${1:-}" in
  reconcile) shift; cmd_reconcile "$@" ;;
  lane-next) shift; cmd_lane_next "$@" ;;
  lane-diagnostic) shift; cmd_lane_diagnostic "$@" ;;
  task-resume) shift; cmd_task_resume "$@" ;;
  task-reassign) shift; cmd_task_reassign "$@" ;;
  task-hold) shift; cmd_task_hold "$@" ;;
  task-done) shift; cmd_task_done "$@" ;;
  scan-stalled) cmd_scan_stalled ;;
  -h|--help|help) usage ;;
  *) die "Unknown command: ${1:-}. Use --help for usage." ;;
esac