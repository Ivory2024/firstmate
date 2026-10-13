#!/usr/bin/env bash
# fm-unattended-recovery.sh - G4 autonomous self-healing recovery policy.
#
# Data-only decision layer over the EXISTING coordinator: it maps a detected
# failure (a coordinator HOLD reason or a failover failure class) to a recovery
# category and a bounded action. It never dispatches; it never rebuilds the state
# machine. The coordinator owns transitions; this owns the retry/rollback policy.
#
# Categories (§4):
#   AUTO_RECOVERABLE          approved-scope auto retry
#   REQUIRES_DIAGNOSIS        collect evidence, then decide (may retry once)
#   NON_RECOVERABLE           never auto-retry (integrity/identity broken)
#   QUOTA_WAIT                wait for real quota re-check (never estimate reset)
#   CAPTAIN_APPROVAL_REQUIRED needs approval (cost/permission/data)
#
# Usage:
#   fm-unattended-recovery.sh classify <reason-or-class>
#   fm-unattended-recovery.sh decide --reason R --attempt N --same-cause C
set -u

classify() { # <reason-or-failure-class>
  local r; r=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$r" in
    # integrity / identity / duplicate: never auto-retry
    stale-generation|duplicate-dispatch|identity-mismatch|generation-mismatch|lease-conflict)
      echo NON_RECOVERABLE;;
    source-unresolved|source-identity-unknown|data-corruption|unsafe-rollback)
      echo NON_RECOVERABLE;;
    # approval / cost / credential
    approval-required|model_auth_failed|auth-failed|paid-api|permission|credential)
      echo CAPTAIN_APPROVAL_REQUIRED;;
    # quota
    quota-blocked|model_quota_exhausted|quota-exhausted|quota_wait)
      echo QUOTA_WAIT;;
    # transient / transport: safe to retry
    model_transport_timeout|model_rate_limited|model_provider_unavailable|network|api-timeout|transport|transport-timeout|rate-limit|rate-limited|provider-unavailable|provider_unavailable)
      echo AUTO_RECOVERABLE;;
    # executor/auditor mid-failure: diagnose then decide
    worker-interrupted|worker-failed|executor-timeout|evidence-incomplete|evidence-guard-mismatch|completion-missing|audit-unavailable|auditor-start-failed|structured-response-invalid|retry-audit|session-lost|tmux-lost|sandbox-path|symlink|disk-full)
      echo REQUIRES_DIAGNOSIS;;
    # exhausted / logic: escalate, do not loop
    retry-exhausted|task_logic_failed|task-logic-failed|logic-failed)
      echo CAPTAIN_HOLD;;
    *) echo UNKNOWN;;
  esac
}

# policy <category> -> "<action> same_cause_max=N"
policy() {
  case "${1:-}" in
    AUTO_RECOVERABLE)          echo "retry same_cause_max=2";;
    REQUIRES_DIAGNOSIS)        echo "diagnose same_cause_max=1";;
    NON_RECOVERABLE)           echo "hold same_cause_max=0";;
    QUOTA_WAIT)                echo "quota-wait same_cause_max=0";;
    CAPTAIN_APPROVAL_REQUIRED) echo "approval same_cause_max=0";;
    CAPTAIN_HOLD)              echo "hold same_cause_max=0";;
    *)                         echo "hold same_cause_max=0";;
  esac
}

# decide: pure bounded-retry + circuit-breaker decision. State persistence is
# owned atomically by fm-unattended-recovery-state.sh decide (no TOCTOU here).
decide() {
  local reason='' attempt=0 same=0
  while [ $# -gt 0 ]; do case "$1" in
    --reason) reason=$2; shift 2;; --attempt) attempt=$2; shift 2;;
    --same-cause) same=$2; shift 2;; *) shift;; esac; done
  local cat action max
  cat=$(classify "$reason")
  action=$(policy "$cat"); max=${action#*same_cause_max=}; action=${action%% *}
  local out="$action"
  case "$cat" in
    AUTO_RECOVERABLE)  [ "$same" -ge "$max" ] && out="hold";;
    REQUIRES_DIAGNOSIS) [ "$same" -ge "$max" ] && out="hold";;
    QUOTA_WAIT) out="quota-wait";;
    CAPTAIN_APPROVAL_REQUIRED) out="approval";;
    NON_RECOVERABLE|CAPTAIN_HOLD) out="hold";;
    *) out="hold";;
  esac
  printf 'category=%s action=%s same_cause_max=%s attempt=%s same_cause=%s\n' \
    "$cat" "$out" "$max" "$attempt" "$same"
}

case "${1:-}" in
  classify) shift; classify "${1:-}";;
  policy) shift; policy "${1:-}";;
  decide) shift; decide "$@";;
  *) echo "usage: fm-unattended-recovery.sh classify|policy|decide ..." >&2; exit 2;;
esac
