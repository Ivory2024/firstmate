#!/usr/bin/env bash
# fm-recovery-lib.sh - the ONE owner of the FirstCrew recovery state machine.
#
# WHY. A worker that fails at an execution path currently reports a failure and
# asks the captain for the fix. That conflates "the path failed" with "the
# objective failed". This library is the contract that separates them: a failure
# is classified, an alternative is searched and verified in isolation, the
# authority needed to apply it is decided, and only then is the original work
# resumed - escalating to the captain only when the alternatives are exhausted
# or the approved boundary is reached.
#
# NOT A NEW AGENT. This is a deterministic contract library plus one thin CLI
# (bin/fm-recovery.sh), the same shape as bin/fm-inactive-reconcile.sh: an
# adjunct that reuses the existing registry (data/backlog.md), the existing
# current-state read (bin/fm-crew-state.sh), the existing approval boundary
# (bin/fm-captain-hold.sh), the existing per-task lock/stale-reclaim primitive
# (fm_lock_try_acquire in bin/fm-wake-lib.sh), and the existing status-log verb
# vocabulary (bin/fm-classify-lib.sh). It starts no watcher, daemon, poll, or
# goal loop of its own.
#
# It never writes a worker's state/<id>.status log: that log has one owner and
# a second writer would corrupt the open-decision fold. It projects the state
# machine onto the existing registry verbs instead, and the HOLD it raises is
# the existing captain hold, raised through its existing owner.
#
# STATE VOCABULARY. The recovery state is internal to a recovery record; the
# registry projection is what the rest of Firstmate already understands.
#
#   recovery state        registry projection   authority
#   RETRYABLE             working               automatic: re-run the same step,
#                                               bounded to MAX_SAME_CAUSE_RETRIES
#   DIAGNOSING            working               automatic, read-only
#   ALTERNATIVE_SEARCH    working               automatic, read-only
#   VALIDATING            working               automatic, isolated worktree only
#   RECOVERABLE           working               automatic only for an automatic-
#                                               verdict action; else WAITING_APPROVAL
#   WAITING_DEPENDENCY    paused                automatic wait on an external cause
#   WAITING_APPROVAL      needs-decision        none: the captain owns the call
#   BLOCKED_EXHAUSTED     blocked               none: escalated, work preserved
#   RESUMED               none                  handed back to the ordinary path
#
# The projection is printed by `fm-recovery.sh status`, never written into the
# status log.
#
# SAFETY. Two hard boundaries live here and nowhere else:
#   1. Search and isolated verification are separate from operational apply.
#      `fm_recovery_action_verdict` decides which of automatic /
#      approval-required / refused / undecidable an action is, and anything it
#      cannot classify reads `undecidable`, which every caller must treat as a
#      stop (fail-closed) - never as a permission.
#   2. The actions the captain reserved to themselves are `refused`: the engine
#      does not perform them even with an approval token. It escalates instead.
#
# Source with:  . "$SCRIPT_DIR/fm-recovery-lib.sh"
# No side effects on source. set -u and set -e safe. Pure functions only; every
# filesystem read and write belongs to bin/fm-recovery.sh.

# --- state vocabulary -------------------------------------------------------

FM_RECOVERY_STATES_DEFAULT='RETRYABLE DIAGNOSING ALTERNATIVE_SEARCH VALIDATING RECOVERABLE WAITING_DEPENDENCY WAITING_APPROVAL BLOCKED_EXHAUSTED RESUMED'
FM_RECOVERY_TERMINAL_STATES_DEFAULT='BLOCKED_EXHAUSTED RESUMED'

fm_recovery_states() { printf '%s\n' "$FM_RECOVERY_STATES_DEFAULT"; }

fm_recovery_terminal_states() { printf '%s\n' "$FM_RECOVERY_TERMINAL_STATES_DEFAULT"; }

fm_recovery_state_valid() {  # <state>
  local want=${1:-} s
  [ -n "$want" ] || return 1
  for s in $FM_RECOVERY_STATES_DEFAULT; do
    [ "$s" = "$want" ] && return 0
  done
  return 1
}

fm_recovery_state_terminal() {  # <state>
  local want=${1:-} s
  [ -n "$want" ] || return 1
  for s in $FM_RECOVERY_TERMINAL_STATES_DEFAULT; do
    [ "$s" = "$want" ] && return 0
  done
  return 1
}

# The registry verb this recovery state projects onto. `none` means the recovery
# record no longer speaks for the task: the original work path owns it again.
fm_recovery_registry_verb() {  # <state>
  case "${1:-}" in
    RETRYABLE|DIAGNOSING|ALTERNATIVE_SEARCH|VALIDATING|RECOVERABLE) printf 'working\n' ;;
    WAITING_DEPENDENCY) printf 'paused\n' ;;
    WAITING_APPROVAL)   printf 'needs-decision\n' ;;
    BLOCKED_EXHAUSTED)  printf 'blocked\n' ;;
    RESUMED)            printf 'none\n' ;;
    *) return 1 ;;
  esac
}

# --- transitions ------------------------------------------------------------
#
# Encoded once, as FROM<TAB>TO lines. A transition not listed here is illegal
# and every caller must refuse it rather than invent a path.

fm_recovery_transitions() {
  cat <<'EOF'
RETRYABLE	RETRYABLE
RETRYABLE	DIAGNOSING
RETRYABLE	ALTERNATIVE_SEARCH
RETRYABLE	WAITING_APPROVAL
RETRYABLE	WAITING_DEPENDENCY
RETRYABLE	BLOCKED_EXHAUSTED
DIAGNOSING	ALTERNATIVE_SEARCH
DIAGNOSING	WAITING_DEPENDENCY
DIAGNOSING	WAITING_APPROVAL
DIAGNOSING	BLOCKED_EXHAUSTED
ALTERNATIVE_SEARCH	VALIDATING
ALTERNATIVE_SEARCH	WAITING_APPROVAL
ALTERNATIVE_SEARCH	WAITING_DEPENDENCY
ALTERNATIVE_SEARCH	BLOCKED_EXHAUSTED
VALIDATING	RECOVERABLE
VALIDATING	ALTERNATIVE_SEARCH
VALIDATING	BLOCKED_EXHAUSTED
RECOVERABLE	WAITING_APPROVAL
RECOVERABLE	RESUMED
RECOVERABLE	BLOCKED_EXHAUSTED
WAITING_DEPENDENCY	DIAGNOSING
WAITING_DEPENDENCY	BLOCKED_EXHAUSTED
WAITING_APPROVAL	RECOVERABLE
WAITING_APPROVAL	BLOCKED_EXHAUSTED
EOF
}

fm_recovery_transition_allowed() {  # <from> <to>
  local from=${1:-} to=${2:-}
  fm_recovery_state_valid "$from" || return 1
  fm_recovery_state_valid "$to" || return 1
  fm_recovery_transitions | awk -F'\t' -v f="$from" -v t="$to" '$1==f && $2==t { found=1 } END { exit !found }'
}

# --- action authority -------------------------------------------------------
#
# The captain's reserved actions are `denied`: the engine escalates instead of
# performing them, with or without an approval token. Anything unrecognized is
# `unknown` and fails closed.

fm_recovery_action_class() {  # <action> -> L0|L1|L2|L3|denied|unknown
  case "${1:-}" in
    read-only-probe|retry-same-step|cache-refresh|reattach-run|refresh-clone-read)
      printf 'L0\n' ;;
    isolated-branch-edit|isolated-test-run|isolated-worktree-reset|revert-isolated-commit)
      printf 'L1\n' ;;
    config-reload|queue-requeue|external-draft-notify)
      printf 'L2\n' ;;
    discard-unlanded|force-terminate|credential-change|external-publish|rollback-destructive)
      printf 'L3\n' ;;
    upstream-write|shared-remote-change|shared-db-change|pr-create|pr-retarget|\
attestation-reuse|attestation-fabricate|gate-waiver|merge|production-deploy|\
launchd-change|auto-recovery-activate|daemon-restart)
      printf 'denied\n' ;;
    *)
      printf 'unknown\n' ;;
  esac
}

# The verdict every caller must gate on. `undecidable` is a stop, never a
# permission.
fm_recovery_action_verdict() {  # <action> -> automatic|approval-required|refused|undecidable
  local class
  class=$(fm_recovery_action_class "$1")
  case "$class" in
    L0|L1) printf 'automatic\n' ;;
    L2|L3) printf 'approval-required\n' ;;
    denied) printf 'refused\n' ;;
    *) printf 'undecidable\n' ;;
  esac
}

fm_recovery_action_permitted() {  # <action> <approval-token>
  local verdict
  verdict=$(fm_recovery_action_verdict "$1")
  case "$verdict" in
    automatic) return 0 ;;
    approval-required) [ -n "${2:-}" ] && return 0; return 1 ;;
    *) return 1 ;;
  esac
}

# --- failure classification -------------------------------------------------

# The failure classes the pilot recognizes. A class is a *cause category*, not a
# verdict on the objective: it never by itself means the work failed.
fm_recovery_classes() {
  cat <<'EOF'
daemon-down
run-failed
pr-target-mismatch
watcher-successor-none
worktree-base-contamination
dependency-unavailable
approval-boundary
unknown
EOF
}

fm_recovery_class_valid() {  # <class>
  local want=${1:-} c
  [ -n "$want" ] || return 1
  while IFS= read -r c; do
    [ "$c" = "$want" ] && return 0
  done < <(fm_recovery_classes)
  return 1
}

# Classes whose cause is outside this home's control, so the correct first state
# is a declared external wait rather than a repair attempt.
fm_recovery_class_waits_on_dependency() {  # <class>
  case "${1:-}" in
    dependency-unavailable) return 0 ;;
    *) return 1 ;;
  esac
}

# Classes whose cause is an authority boundary, so the correct first state is
# the captain's call rather than a repair attempt.
fm_recovery_class_needs_approval() {  # <class>
  case "${1:-}" in
    approval-boundary) return 0 ;;
    *) return 1 ;;
  esac
}

# The state a freshly classified failure enters.
fm_recovery_initial_state() {  # <class>
  local class=${1:-unknown}
  fm_recovery_class_valid "$class" || class=unknown
  if fm_recovery_class_waits_on_dependency "$class"; then
    printf 'WAITING_DEPENDENCY\n'
  elif fm_recovery_class_needs_approval "$class"; then
    printf 'WAITING_APPROVAL\n'
  else
    printf 'RETRYABLE\n'
  fi
}

# --- signature and fingerprint ----------------------------------------------
#
# A signature is the normalized, environment-independent text of a failure; a
# fingerprint binds the task, the cause class, the signature, and the target.
# The fingerprint deliberately does NOT bind the spawn incarnation: a worker
# that dies mid-recovery and comes back must land on the SAME record (that is
# the checkpoint), while a genuinely new failure after a completed recovery
# gets a new record because the old one was retired.

fm_recovery_normalize_signature() {  # <text> -> one normalized line
  local text=${1:-}
  printf '%s' "$text" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E \
        -e 's/[0-9a-f]{7,}/<sha>/g' \
        -e 's#([[:alnum:]_.@-]*/)+[[:alnum:]_.@-]+#<path>#g' \
        -e 's/[0-9]+/<n>/g' \
    | tr -s '[:space:]' ' ' \
    | sed -e 's/^ //' -e 's/ $//' \
    | cut -c1-160
}

fm_recovery_sha256() {  # <text> -> hex digest, or empty when no digest tool
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

fm_recovery_fingerprint() {  # <task> <class> <signature> <target> -> 16-hex
  local task=${1:-} class=${2:-} signature=${3:-} target=${4:-} digest
  [ -n "$task" ] || return 1
  fm_recovery_class_valid "$class" || class=unknown
  digest=$(fm_recovery_sha256 "$task|$class|$(fm_recovery_normalize_signature "$signature")|$(fm_recovery_normalize_signature "$target")") || return 1
  printf '%s\n' "${digest:0:16}"
}

# --- bounds (pilot initial values) ------------------------------------------
#
# Every bound has one owner: this function. A caller reads it, never a literal.
# A malformed value falls back to the pilot default rather than opening the
# bound, so a typo can only ever make recovery more conservative.

fm_recovery_bound() {  # <name>
  local name=${1:-} value
  case "$name" in
    max-alternatives)          value=${FM_RECOVERY_MAX_ALTERNATIVES:-3} ;;
    max-same-cause-retries)    value=${FM_RECOVERY_MAX_SAME_CAUSE_RETRIES:-2} ;;
    diagnosis-secs)            value=${FM_RECOVERY_DIAGNOSIS_SECS:-900} ;;
    total-secs)                value=${FM_RECOVERY_TOTAL_SECS:-1800} ;;
    max-concurrent)            value=${FM_RECOVERY_MAX_CONCURRENT:-4} ;;
    lease-ttl-secs)            value=${FM_RECOVERY_LEASE_TTL_SECS:-300} ;;
    *) return 1 ;;
  esac
  case "$value" in
    ''|*[!0-9]*|0) return 1 ;;
  esac
  printf '%s\n' "$value"
}

# --- recovery record --------------------------------------------------------
#
# One line, atomically replaced, one file per fingerprint:
#   state/recovery/<fingerprint>.rec
# Fields are space-separated key=value, so a reader is a field lookup rather
# than a positional parse. The append-only ledger beside it is
# state/recovery/<fingerprint>.ledger.

fm_recovery_record_keys() { printf '%s\n' 'state task class fingerprint target signature attempts alternatives same_cause_retries started updated lease_actor lease_pid lease_epoch reason exec_class'; }

fm_recovery_record_field() {  # <record-text> <key>
  local text=${1:-} key=${2:-} token
  for token in $text; do
    case "$token" in
      "$key"=*) printf '%s\n' "${token#*=}"; return 0 ;;
    esac
  done
  return 1
}

fm_recovery_record_format() {  # <state> <task> <class> <fingerprint> <target> <signature> <attempts> <alternatives> <same_cause_retries> <started> <updated> <lease_actor> <lease_pid> <lease_epoch> <reason> <exec_class>
  printf 'state=%s task=%s class=%s fingerprint=%s target=%s signature=%s attempts=%s alternatives=%s same_cause_retries=%s started=%s updated=%s lease_actor=%s lease_pid=%s lease_epoch=%s reason=%s exec_class=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" "${13}" "${14}" "${15}" "${16}"
}

# --- execution class --------------------------------------------------------
#
# The measurement layer must never present an isolated or simulated recovery as
# a production one, so every recovery record carries the class of execution it
# is. This engine only ever produces `simulation` or `isolated`; `production`
# is refused here and is assigned by the separately approved control plane that
# activates the capability, so no argument to this script can relabel test
# output as operational output.

fm_recovery_exec_classes() { printf '%s\n' 'simulation isolated production'; }

fm_recovery_exec_class_valid() {  # <class>
  local want=${1:-} c
  [ -n "$want" ] || return 1
  for c in $(fm_recovery_exec_classes); do
    [ "$c" = "$want" ] && return 0
  done
  return 1
}

# 0 only when this engine may record an event under this class.
fm_recovery_exec_class_recordable() {  # <class>
  case "${1:-}" in
    simulation|isolated) return 0 ;;
    *) return 1 ;;
  esac
}

# The measurement identity the KPI layer consumes. `incident_id` follows the
# same shape as the metrics layer's own derivation, `inc:<hex>[:16]`, over this
# engine's own binding. Two deliberate differences from that layer's derivation
# are worth knowing at integration time: this engine uses sha256 rather than
# sha1, and it has no run id, so it binds the task, the failure fingerprint, and
# the opening epoch. A consumer should therefore take the exported
# `failure_fingerprint` and `incident_id` as this engine's authoritative values
# for engine-produced events instead of re-deriving them, so a cross-source join
# cannot silently miss.
fm_recovery_incident_id() {  # <task> <fingerprint> <opened-at>
  local digest
  digest=$(fm_recovery_sha256 "${1:-}|${2:-}|${3:-}") || return 1
  printf 'inc:%s\n' "${digest:0:16}"
}

fm_recovery_attempt_id() {  # <fingerprint> <n>
  printf '%s-%s\n' "${1:-}" "${2:-0}"
}

# --- playbook ---------------------------------------------------------------
#
# data/recovery-playbooks.tsv, one TAB-separated line per entry:
#   fingerprint  class  status  alternative  scope  verified_at  evidence
#
# status is hypothesis | validating | verified. Only `verified` may inform an
# apply decision, and only while its recorded scope still matches the current
# environment; a verified entry whose scope has moved reads `stale` and must be
# re-verified before it counts again. An entry that names an action the
# authority table refuses can never be applied, whatever its status.

fm_recovery_playbook_statuses() { printf '%s\n' 'hypothesis validating verified'; }

fm_recovery_playbook_status_valid() {  # <status>
  local want=${1:-} s
  [ -n "$want" ] || return 1
  for s in $(fm_recovery_playbook_statuses); do
    [ "$s" = "$want" ] && return 0
  done
  return 1
}

fm_recovery_playbook_status_allowed() {  # <from> <to>
  local from=${1:-} to=${2:-}
  fm_recovery_playbook_status_valid "$from" || return 1
  fm_recovery_playbook_status_valid "$to" || return 1
  case "$from:$to" in
    hypothesis:hypothesis|hypothesis:validating|hypothesis:verified) return 0 ;;
    validating:validating|validating:verified) return 0 ;;
    verified:verified) return 0 ;;
    *) return 1 ;;
  esac
}

# The status an entry effectively has right now: a `verified` entry whose scope
# no longer matches the current environment is `stale` (re-verification owed).
fm_recovery_playbook_effective_status() {  # <recorded-status> <recorded-scope> <current-scope>
  local status=${1:-} recorded=${2:-} current=${3:-}
  fm_recovery_playbook_status_valid "$status" || { printf 'invalid\n'; return 0; }
  if [ "$status" = verified ] && [ "$recorded" != "$current" ]; then
    printf 'stale\n'
    return 0
  fi
  printf '%s\n' "$status"
}

# 0 only when an entry may inform an apply decision right now: verified, in the
# current scope, and naming an action the authority table does not refuse.
fm_recovery_playbook_applicable() {  # <recorded-status> <recorded-scope> <current-scope> <alternative>
  local effective
  effective=$(fm_recovery_playbook_effective_status "$1" "$2" "$3")
  [ "$effective" = verified ] || return 1
  fm_recovery_action_permitted "$4" ''
}

fm_recovery_playbook_scope() {  # <harness> <backend>
  printf '%s/%s\n' "${1:-unknown}" "${2:-unknown}"
}

fm_recovery_playbook_format() {  # <fingerprint> <class> <status> <alternative> <scope> <verified-at> <evidence>
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}
