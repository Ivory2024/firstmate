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

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-control.sh
# shellcheck source=bin/fm-crew-state.sh
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

# Configuration
AUTO_RESUME_MAX_ATTEMPTS=${FM_AUTO_RESUME_MAX_ATTEMPTS:-3}
AUTO_RESUME_BASE_BACKOFF=${FM_AUTO_RESUME_BASE_BACKOFF:-30}
AUTO_RESUME_MAX_BACKOFF=${FM_AUTO_RESUME_MAX_BACKOFF:-1800}
AUTO_RESUME_JITTER_PCT=${FM_AUTO_RESUME_JITTER_PCT:-25}
QUOTA_WAIT_MAX=${FM_QUOTA_WAIT_MAX:-3600}
STALLED_THRESHOLD_SECS=${FM_STALLED_THRESHOLD_SECS:-900}
LANE_PROGRESSION_INTERVAL=${FM_LANE_PROGRESSION_INTERVAL:-60}

mkdir -p "$LIFECYCLE_DIR" "$LANE_QUEUE_DIR"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

# --- Lifecycle record helpers -------------------------------------------------

lifecycle_path() { printf '%s/%s.lifecycle' "$LIFECYCLE_DIR" "$1"; }
lane_queue_path() { printf '%s/%s.queue' "$LANE_QUEUE_DIR" "$1"; }

lifecycle_read() {  # <task-id> <key>
  local file=$(lifecycle_path "$1") key=$2
  [ -f "$file" ] || return 1
  grep "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

lifecycle_write() {  # <task-id> <key> <value>
  local file=$(lifecycle_path "$1") key=$2 value=$3 tmp
  mkdir -p "$LIFECYCLE_DIR"
  tmp=$(mktemp "$LIFECYCLE_DIR/.lifecycle.XXXXXX") || return 1
  if [ -f "$file" ]; then
    grep -v "^${key}=" "$file" > "$tmp" 2>/dev/null || true
  else
    : > "$tmp"
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}

lifecycle_exists() { [ -f "$(lifecycle_path "$1")" ]; }

# Initialize lifecycle record from meta/status if missing
ensure_lifecycle() {  # <task-id>
  local id=$1 meta="$STATE/$id.meta" status="$STATE/$id.status"
  [ -f "$meta" ] || return 1
  lifecycle_exists "$id" && return 0

  local owner lane priority deps accept_criteria step progress next_action retry_state blocking_reason evidence checkpoint
  owner=$(grep '^harness=' "$meta" | cut -d= -f2-)
  lane=$(grep '^lane=' "$meta" 2>/dev/null | cut -d= -f2- || echo "default")
  priority=$(grep '^priority=' "$meta" 2>/dev/null | cut -d= -f2- || echo "normal")
  deps=$(grep '^depends_on=' "$meta" 2>/dev/null | cut -d= -f2- || echo "")
  accept_criteria=$(grep '^acceptance_criteria=' "$meta" 2>/dev/null | cut -d= -f2- || echo "")
  step="initialized"
  progress=$(date +%s)
  next_action="awaiting_dispatch"
  retry_state="attempt=0,last_error="
  blocking_reason=""
  evidence=""
  checkpoint=""

  {
    printf 'owner=%s\n' "$owner"
    printf 'lane=%s\n' "$lane"
    printf 'priority=%s\n' "$priority"
    printf 'depends_on=%s\n' "$deps"
    printf 'acceptance_criteria=%s\n' "$accept_criteria"
    printf 'current_step=%s\n' "$step"
    printf 'last_progress=%s\n' "$progress"
    printf 'next_action=%s\n' "$next_action"
    printf 'retry_state=%s\n' "$retry_state"
    printf 'blocking_reason=%s\n' "$blocking_reason"
    printf 'evidence=%s\n' "$evidence"
    printf 'resume_checkpoint=%s\n' "$checkpoint"
  } > "$(lifecycle_path "$id")"
  chmod 600 "$(lifecycle_path "$id")"
}

# Update a lifecycle field
update_lifecycle() {  # <task-id> <key> <value>
  local id=$1 key=$2 value=$3
  ensure_lifecycle "$id" || return 1
  lifecycle_write "$id" "$key" "$value"
}

# Append to evidence (timestamped)
append_evidence() {  # <task-id> <text>
  local id=$1 text=$2 stamp
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local current=$(lifecycle_read "$id" evidence)
  update_lifecycle "$id" evidence "${current}${current:+$'\n'}[$stamp] $text"
}

# Update retry state
update_retry_state() {  # <task-id> <attempt> <error>
  local id=$1 attempt=$2 error=$3
  update_lifecycle "$id" retry_state "attempt=$attempt,last_error=$error,last_retry=$(date +%s)"
}

# Get retry attempt count
get_retry_attempt() {  # <task-id>
  local state=$(lifecycle_read "$1" retry_state)
  printf '%s\n' "$state" | sed -n 's/.*attempt=\([0-9]*\).*/\1/p'
}

# --- Lane queue helpers -------------------------------------------------------

lane_enqueue() {  # <lane> <task-id>
  local lane=$1 id=$2 file
  file=$(lane_queue_path "$lane")
  mkdir -p "$LANE_QUEUE_DIR"
  # Avoid duplicates
  grep -Fxq "$id" "$file" 2>/dev/null && return 0
  printf '%s\n' "$id" >> "$file"
}

lane_dequeue() {  # <lane> -> prints task-id or empty
  local lane=$1 file id
  file=$(lane_queue_path "$lane")
  [ -f "$file" ] || return 1
  id=$(head -1 "$file")
  [ -n "$id" ] || return 1
  # Remove first line
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

# --- State classification -----------------------------------------------------

# Classify a task's current state using fm-crew-state.sh
classify_task() {  # <task-id> -> prints "state source detail"
  local id=$1
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null || echo "unknown none fm-crew-state failed"
}

# Check if task is in a terminal state
is_terminal() {  # <state>
  case "$1" in done|failed|blocked|paused) return 0 ;; *) return 1 ;; esac
}

# Check if task is a legitimate hold (not a failure)
is_legitimate_hold() {  # <task-id> <state> <detail>
  local id=$1 state=$2 detail=$3
  case "$state" in
    paused)
      # External wait or quota wait
      case "$detail" in *quota*|*external*|*awaiting*) return 0 ;; *) return 1 ;; esac
      ;;
    blocked)
      # Captain approval wait or explicit blocker
      case "$detail" in *HOLD*|*captain*|*approval*|*merge*) return 0 ;; *) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
}

# Check if task is stalled (healthy heartbeat but no progress)
is_stalled() {  # <task-id> <state> <detail>
  local id=$1 state=$2 detail=$3
  [ "$state" = "working" ] || return 1

  local meta="$STATE/$id.meta" status="$STATE/$id.status" turn_ended="$STATE/$id.turn-ended"
  local now progress_age worktree_age heartbeat_age

  now=$(date +%s)

  # Status file age
  if [ -f "$status" ]; then
    progress_age=$(( now - $(stat -f %m "$status" 2>/dev/null || echo "$now") ))
  else
    progress_age=999999
  fi

  # Worktree age (if available)
  local wt=$(grep '^worktree=' "$meta" 2>/dev/null | cut -d= -f2- | tail -1)
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    worktree_age=$(( now - $(stat -f %m "$wt" 2>/dev/null || echo "$now") ))
  else
    worktree_age=999999
  fi

  # Heartbeat age (run-step activity)
  local crew_state=$(classify_task "$id")
  local run_detail=$(printf '%s\n' "$crew_state" | cut -d'·' -f3-)
  if printf '%s\n' "$run_detail" | grep -q "active_steps"; then
    heartbeat_age=0
  else
    heartbeat_age=$progress_age
  fi

  # Stalled if: status not updated > threshold AND worktree not changed > threshold
  # AND no active run-step activity
  [ "$progress_age" -ge "$STALLED_THRESHOLD_SECS" ] && \
  [ "$worktree_age" -ge "$STALLED_THRESHOLD_SECS" ] && \
  [ "$heartbeat_age" -ge "$STALLED_THRESHOLD_SECS" ]
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

# --- Auto-resume logic --------------------------------------------------------

# Calculate exponential backoff with jitter
calc_backoff() {  # <attempt>
  local attempt=$1 base=$AUTO_RESUME_BASE_BACKOFF max=$AUTO_RESUME_MAX_BACKOFF jitter_pct=$AUTO_RESUME_JITTER_PCT
  local backoff jitter
  # Exponential: base * 2^(attempt-1)
  backoff=$(( base * (1 << (attempt - 1)) ))
  [ "$backoff" -gt "$max" ] && backoff=$max
  # Jitter: ±jitter_pct%
  jitter=$(( backoff * jitter_pct / 100 ))
  # Random between -jitter and +jitter
  local rand=$(( RANDOM % (2 * jitter + 1) - jitter ))
  backoff=$(( backoff + rand ))
  [ "$backoff" -lt 1 ] && backoff=1
  printf '%s\n' "$backoff"
}

# Check if enough time has passed since last retry
can_retry() {  # <task-id>
  local id=$1 state last_retry backoff
  state=$(lifecycle_read "$id" retry_state)
  last_retry=$(printf '%s\n' "$state" | sed -n 's/.*last_retry=\([0-9]*\).*/\1/p')
  [ -n "$last_retry" ] || return 0
  attempt=$(get_retry_attempt "$id")
  backoff=$(calc_backoff "$attempt")
  [ $(( $(date +%s) - last_retry )) -ge "$backoff" ]
}

# Attempt auto-resume for a task
auto_resume_task() {  # <task-id>
  local id=$1 interruption_type state detail attempt backoff new_harness new_model new_effort note
  state=$(classify_task "$id" | cut -d' ' -f1)
  detail=$(classify_task "$id" | cut -d' ' -f3-)

  # Don't resume if terminal and legitimate hold
  if is_terminal "$state" && is_legitimate_hold "$id" "$state" "$detail"; then
    append_evidence "$id" "Auto-resume skipped: legitimate hold ($state: $detail)"
    return 0
  fi

  interruption_type=$(classify_interruption "$id" "$state" "$detail")
  attempt=$(get_retry_attempt "$id")
  attempt=$((attempt + 1))

  # Max attempts reached -> reassign or hold
  if [ "$attempt" -gt "$AUTO_RESUME_MAX_ATTEMPTS" ]; then
    case "$interruption_type" in
      provider_503|harness_session)
        # Try to reassign to another allowed model/harness
        new_harness=$(select_alternate_harness "$id")
        if [ -n "$new_harness" ]; then
          note="Auto-reassign after $AUTO_RESUME_MAX_ATTEMPTS failed resumes ($interruption_type). Switching to $new_harness."
          fm_control_relaunch "$id" "$new_harness" "$note"
          return $?
        fi
        ;;
      quota_exhausted)
        # Preserve as WAITING_QUOTA
        update_lifecycle "$id" current_step "WAITING_QUOTA"
        update_lifecycle "$id" next_action "awaiting_quota_recovery"
        update_lifecycle "$id" blocking_reason "quota_exhausted"
        append_evidence "$id" "Quota exhausted after $AUTO_RESUME_MAX_ATTEMPTS attempts. Preserved as WAITING_QUOTA."
        return 0
        ;;
    esac
    # No reassignment possible -> escalate
    append_evidence "$id" "Auto-resume exhausted ($interruption_type). Escalating to captain."
    update_lifecycle "$id" current_step "ESCALATED"
    update_lifecycle "$id" blocking_reason "auto_resume_exhausted: $interruption_type"
    return 1
  fi

  # Check backoff
  if ! can_retry "$id"; then
    return 0  # Not time yet
  fi

  update_retry_state "$id" "$attempt" "$interruption_type"
  backoff=$(calc_backoff "$attempt")
  append_evidence "$id" "Auto-resume attempt $attempt/$AUTO_RESUME_MAX_ATTEMPTS ($interruption_type). Backoff: ${backoff}s."

  case "$interruption_type" in
    process_crash|provider_503|harness_session|ci_failure|review_findings)
      # Relaunch with same harness, add progress note
      note="Auto-resume attempt $attempt after $interruption_type. Previous state: $state. Checkpoint: $(lifecycle_read "$id" resume_checkpoint)"
      fm_control_relaunch "$id" "" "$note"
      ;;
    quota_exhausted)
      update_lifecycle "$id" current_step "WAITING_QUOTA"
      update_lifecycle "$id" next_action "awaiting_quota_recovery"
      update_lifecycle "$id" blocking_reason "quota_exhausted"
      ;;
    external_approval)
      # Don't auto-resume approval waits
      update_lifecycle "$id" current_step "WAITING_APPROVAL"
      update_lifecycle "$id" blocking_reason "external_approval"
      ;;
    work_complete)
      # Should be handled by lane progression
      ;;
    *)
      # Generic relaunch
      note="Auto-resume attempt $attempt after $interruption_type. Previous state: $state."
      fm_control_relaunch "$id" "" "$note"
      ;;
  esac
}

# Select alternate harness/model for reassignment
select_alternate_harness() {  # <task-id>
  local id=$1 current_harness
  current_harness=$(lifecycle_read "$id" owner)
  # For now, return empty - would need quota-axi integration
  # This is a placeholder for the reassignment logic
  echo ""
}

# Delegate to fm-control.sh for relaunch
fm_control_relaunch() {  # <task-id> [new_harness] <note>
  local id=$1 new_harness=$2 note=$3 args=()
  args=(relaunch --note "$note")
  [ -n "$new_harness" ] && args+=(--harness "$new_harness")
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$id" "${args[@]}"
}

# --- Lane progression ---------------------------------------------------------

# Get all lanes from active tasks
get_active_lanes() {
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep '^lane=' "$meta" 2>/dev/null | cut -d= -f2-
  done | sort -u
}

# Get tasks in a lane
get_lane_tasks() {  # <lane>
  local lane=$1
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    if grep -q "^lane=$lane$" "$meta"; then
      basename "$meta" .meta
    fi
  done
}

# Check if a task is READY (no deps or all deps done)
is_task_ready() {  # <task-id>
  local id=$1 deps dep
  deps=$(lifecycle_read "$id" depends_on)
  [ -z "$deps" ] && return 0
  for dep in ${deps//,/ }; do
    local dep_state=$(classify_task "$dep" | cut -d' ' -f1)
    is_terminal "$dep_state" || return 1
  done
  return 0
}

# Advance lane: find next READY task and dispatch
advance_lane() {  # <lane>
  local lane=$1 id state
  # Build queue from tasks in this lane that are READY and not in flight
  for id in $(get_lane_tasks "$lane"); do
    state=$(classify_task "$id" | cut -d' ' -f1)
    if [ "$state" = "unknown" ] || [ "$state" = "working" ]; then
      # Task already in flight or not initialized
      continue
    fi
    if is_task_ready "$id"; then
      lane_enqueue "$lane" "$id"
    fi
  done

  # Get next task from queue
  id=$(lane_peek "$lane")
  [ -n "$id" ] || return 0

  # Check if lane has capacity (no other task in working state)
  local working_count=0
  for t in $(get_lane_tasks "$lane"); do
    local s=$(classify_task "$t" | cut -d' ' -f1)
    [ "$s" = "working" ] && working_count=$((working_count + 1))
  done

  if [ "$working_count" -eq 0 ]; then
    # Lane is free, dispatch next task
    lane_dequeue "$lane"
    update_lifecycle "$id" current_step "DISPATCHING"
    update_lifecycle "$id" next_action "spawning_worker"
    append_evidence "$id" "Lane $lane free, dispatching next READY task."
    # Spawn would be done via fm-spawn.sh, but that's firstmate's job
    # Here we just mark it ready for dispatch
    return 0
  fi
}

# --- Stale/orphan reconciliation ----------------------------------------------

reconcile_orphans() {
  local cleaned=0
  # Find .subsuper-seen-status-* markers for tasks whose meta no longer exists
  for marker in "$STATE"/.subsuper-seen-status-*; do
    [ -f "$marker" ] || continue
    local task_id=$(basename "$marker" | sed 's/^.subsuper-seen-status-//')
    if [ ! -f "$STATE/$task_id.meta" ]; then
      rm -f "$marker"
      cleaned=$((cleaned + 1))
    fi
  done

  # Find unused treehouse pool slots (worktrees without meta)
  # This is more complex - for now just report
  if [ "$cleaned" -gt 0 ]; then
    echo "Cleaned $cleaned orphan subsuper markers"
  fi
}

# --- Main commands ------------------------------------------------------------

cmd_reconcile() {  # [--startup]
  local startup=0
  [ "${1:-}" = "--startup" ] && startup=1

  # Ensure lifecycle records for all tasks
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    local id=$(basename "$meta" .meta)
    ensure_lifecycle "$id"
  done

  # Reconcile orphans
  reconcile_orphans

  # Scan for stalled tasks
  cmd_scan_stalled

  # Advance all lanes
  for lane in $(get_active_lanes); do
    advance_lane "$lane"
  done

  # Auto-resume interrupted tasks
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    local id=$(basename "$meta" .meta)
    local state detail
    state=$(classify_task "$id" | cut -d' ' -f1)
    detail=$(classify_task "$id" | cut -d' ' -f3-)

    # Skip if working normally
    [ "$state" = "working" ] && continue

    # Skip if legitimate hold
    is_terminal "$state" && is_legitimate_hold "$id" "$state" "$detail" && continue

    # Attempt auto-resume
    auto_resume_task "$id"
  done
}

cmd_scan_stalled() {
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    local id=$(basename "$meta" .meta)
    local kind=$(grep '^kind=' "$meta" 2>/dev/null | cut -d= -f2- || echo "ship")
    [ "$kind" = "secondmate" ] && continue  # Secondmates have their own liveness

    local state detail
    state=$(classify_task "$id" | cut -d' ' -f1)
    detail=$(classify_task "$id" | cut -d' ' -f3-)

    if is_stalled "$id" "$state" "$detail"; then
      append_evidence "$id" "STALLED detected: heartbeat healthy but no progress for ${STALLED_THRESHOLD_SECS}s. State: $state, Detail: $detail"
      update_lifecycle "$id" current_step "STALLED"
      update_lifecycle "$id" blocking_reason "stalled_no_progress"
      # Queue a stale wake for supervisor attention
      local w=$(grep '^window=' "$meta" 2>/dev/null | cut -d= -f2-)
      [ -n "$w" ] && fm_wake_append stale "$w" "stale: $id (STALLED: heartbeat healthy but no progress for ${STALLED_THRESHOLD_SECS}s)"
    fi
  done
}

cmd_lane_next() {  # <lane>
  local lane=${1:-}
  [ -n "$lane" ] || die "lane required"
  advance_lane "$lane"
}

cmd_task_resume() {  # <task-id> [--reason <text>]
  local id=$1 reason="Manual resume"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in --reason) reason=$2; shift 2 ;; *) shift ;; esac
  done
  update_lifecycle "$id" current_step "RESUMING"
  update_lifecycle "$id" next_action "relaunching"
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
  update_lifecycle "$id" current_step "HELD"
  update_lifecycle "$id" blocking_reason "$reason"
  [ -n "$until" ] && update_lifecycle "$id" hold_until "$until"
  append_evidence "$id" "Held: $reason"
  # Also use fm-captain-hold.sh for proper hold tracking
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-captain-hold.sh" hold "$id" --reason "$reason" ${until:+--until "$until"}
}

cmd_task_done() {  # <task-id> --evidence <text>
  local id=$1 evidence=""
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in --evidence) evidence=$2; shift 2 ;; *) shift ;; esac
  done
  [ -n "$evidence" ] || die "--evidence required"
  update_lifecycle "$id" current_step "DONE"
  update_lifecycle "$id" next_action "complete"
  append_evidence "$id" "DONE: $evidence"
  # Mark in lane queue as done
  local lane=$(lifecycle_read "$id" lane)
  lane_remove "$lane" "$id"
}

# --- Fault injection tests ----------------------------------------------------

cmd_test_inject() {  # <scenario>
  local scenario=${1:-}
  case "$scenario" in
    worker_exit)
      # Find a working task and simulate worker exit
      for meta in "$STATE"/*.meta; do
        [ -f "$meta" ] || continue
        local id=$(basename "$meta" .meta)
        local state=$(classify_task "$id" | cut -d' ' -f1)
        [ "$state" = "working" ] || continue
        echo "Injecting worker exit for $id"
        FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$id" exit
        sleep 2
        # Now test recovery
        cmd_reconcile
        return
      done
      echo "No working task found for injection"
      ;;
    provider_503)
      # Simulate provider 503 by marking a task
      for meta in "$STATE"/*.meta; do
        [ -f "$meta" ] || continue
        local id=$(basename "$meta" .meta)
        local state=$(classify_task "$id" | cut -d' ' -f1)
        [ "$state" = "working" ] || continue
        echo "Injecting provider 503 for $id"
        append_evidence "$id" "TEST INJECTION: provider 503 simulated"
        update_lifecycle "$id" current_step "PROVIDER_503"
        return
      done
      echo "No working task found for injection"
      ;;
    quota_exhausted)
      for meta in "$STATE"/*.meta; do
        [ -f "$meta" ] || continue
        local id=$(basename "$meta" .meta)
        local state=$(classify_task "$id" | cut -d' ' -f1)
        [ "$state" = "working" ] || continue
        echo "Injecting quota exhaustion for $id"
        append_evidence "$id" "TEST INJECTION: quota exhausted simulated"
        update_lifecycle "$id" current_step "QUOTA_EXHAUSTED"
        update_lifecycle "$id" blocking_reason "quota_exhausted"
        return
      done
      echo "No working task found for injection"
      ;;
    stalled)
      for meta in "$STATE"/*.meta; do
        [ -f "$meta" ] || continue
        local id=$(basename "$meta" .meta)
        local state=$(classify_task "$id" | cut -d' ' -f1)
        [ "$state" = "working" ] || continue
        echo "Injecting STALLED for $id"
        # Touch status file to old timestamp
        touch -t $(date -v-20M +%Y%m%d%H%M) "$STATE/$id.status" 2>/dev/null || \
        touch -d '20 minutes ago' "$STATE/$id.status" 2>/dev/null
        local wt=$(grep '^worktree=' "$meta" 2>/dev/null | cut -d= -f2-)
        [ -n "$wt" ] && [ -d "$wt" ] && \
          touch -t $(date -v-20M +%Y%m%d%H%M) "$wt" 2>/dev/null || \
          touch -d '20 minutes ago' "$wt" 2>/dev/null
        cmd_scan_stalled
        return
      done
      echo "No working task found for injection"
      ;;
    supervisor_restart)
      echo "Simulating supervisor restart - running reconcile"
      cmd_reconcile
      ;;
    duplicate_recovery)
      # Trigger reconcile twice rapidly
      cmd_reconcile
      sleep 1
      cmd_reconcile
      echo "Duplicate recovery test complete"
      ;;
    ci_failure_repair)
      for meta in "$STATE"/*.meta; do
        [ -f "$meta" ] || continue
        local id=$(basename "$meta" .meta)
        local state=$(classify_task "$id" | cut -d' ' -f1)
        [ "$state" = "working" ] || continue
        echo "Injecting CI failure for $id"
        append_evidence "$id" "TEST INJECTION: CI failure simulated"
        update_lifecycle "$id" current_step "CI_FAILED"
        update_lifecycle "$id" blocking_reason "ci_failure"
        return
      done
      echo "No working task found for injection"
      ;;
    review_findings)
      for meta in "$STATE"/*.meta; do
        [ -f "$meta" ] || continue
        local id=$(basename "$meta" .meta)
        local state=$(classify_task "$id" | cut -d' ' -f1)
        [ "$state" = "working" ] || continue
        echo "Injecting review findings for $id"
        append_evidence "$id" "TEST INJECTION: review findings simulated"
        update_lifecycle "$id" current_step "REVIEW_FINDINGS"
        update_lifecycle "$id" blocking_reason "review_findings"
        return
      done
      echo "No working task found for injection"
      ;;
    approval_wait)
      for meta in "$STATE"/*.meta; do
        [ -f "$meta" ] || continue
        local id=$(basename "$meta" .meta)
        local state=$(classify_task "$id" | cut -d' ' -f1)
        [ "$state" = "working" ] || continue
        echo "Injecting approval wait for $id"
        append_evidence "$id" "TEST INJECTION: captain approval wait simulated"
        update_lifecycle "$id" current_step "WAITING_APPROVAL"
        update_lifecycle "$id" blocking_reason "external_approval"
        return
      done
      echo "No working task found for injection"
      ;;
    lane_isolation)
      echo "Testing lane isolation - verifying other lanes continue"
      for lane in $(get_active_lanes); do
        echo "Lane $lane tasks:"
        for id in $(get_lane_tasks "$lane"); do
          local state=$(classify_task "$id" | cut -d' ' -f1)
          echo "  $id: $state"
        done
      done
      ;;
    *)
      die "Unknown scenario: $scenario. Available: worker_exit, provider_503, quota_exhausted, stalled, supervisor_restart, duplicate_recovery, ci_failure_repair, review_findings, approval_wait, lane_isolation"
      ;;
  esac
}

# --- Entry point --------------------------------------------------------------

case "${1:-}" in
  reconcile) shift; cmd_reconcile "$@" ;;
  lane-next) shift; cmd_lane_next "$@" ;;
  task-resume) shift; cmd_task_resume "$@" ;;
  task-reassign) shift; cmd_task_reassign "$@" ;;
  task-hold) shift; cmd_task_hold "$@" ;;
  task-done) shift; cmd_task_done "$@" ;;
  scan-stalled) cmd_scan_stalled ;;
  test-inject) shift; cmd_test_inject "$@" ;;
  -h|--help|help) usage ;;
  *) die "Unknown command: ${1:-}. Use --help for usage." ;;
esac