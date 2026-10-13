#!/usr/bin/env bash
# fm-unattended-failover.sh - data-only failover policy for the G4 executor.
#
# Scope: classify a failure and decide the next route within a bounded budget.
# It NEVER calls a paid API; free models first, subscription CLI is only ever
# returned as an approval-hold candidate. It performs no dispatch itself.
#
# Usage:
#   fm-unattended-failover.sh classify <raw-error-text>
#   fm-unattended-failover.sh next --model M --attempt N --failures "m1,m1,m2"
#   fm-unattended-failover.sh budget
set -u

# --- free-first model allow-list (route type is explicit) --------------------
# Only genuinely free routes; paid-api aliases are never listed.
FREE_MODELS_DEFAULT="opencode/ling-3.1-flash-free opencode/nemotron-3.5-lightning-free opencode/step-5-preview-free opencode/mimo-v2.6-flash-free"

# --- retry budget (per class, not one global counter) ------------------------
budget() {
  cat <<'EOF'
transport_timeout same_model_retry=1 alt_free=2 subscription=1 total=4
provider_unavailable alt_free=2 subscription=1 total=3
rate_limited backoff=30 alt_free=2 subscription=1 total=3
quota_exhausted cooldown=3600 alt_free=2 subscription=1 total=3
auth_failed total=0
context_exceeded total=0
unsupported_capability total=0
executor_spawn_failed same_model_retry=1 total=1
completion_missing total=0
task_logic_failed total=0
task_test_failed total=0
EOF
}

# --- failure classification --------------------------------------------------
classify() { # <raw error text>
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$s" in
    *"transport"*"timeout"*|*"operation timed out"*) echo MODEL_TRANSPORT_TIMEOUT;;
    # "insufficient_quota" and "exceeded your current quota" both contain
    # "quota", so the single alternative below already covers them (SC2221/2222).
    *"quota"*) echo MODEL_QUOTA_EXHAUSTED;;
    *"rate"*"limit"*|*"429"*|*"too many requests"*) echo MODEL_RATE_LIMITED;;
    *"401"*|*"403"*|*"unauthorized"*|*"authentication"*|*"invalid api key"*) echo MODEL_AUTH_FAILED;;
    *"context"*"length"*|*"maximum context"*) echo MODEL_CONTEXT_EXCEEDED;;
    # "does not support tool" contains "not support"; the first alternative
    # already covers it (SC2221/2222).
    *"not support"*|*"unsupported"*) echo MODEL_UNSUPPORTED_CAPABILITY;;
    *"provider"*"unavailable"*|*"503"*|*"502"*|*"service unavailable"*) echo MODEL_PROVIDER_UNAVAILABLE;;
    *"spawn failed"*|*"spawn_failed"*) echo EXECUTOR_SPAWN_FAILED;;
    *"completion"*"missing"*|*"turn-end"*"missing"*) echo EXECUTOR_COMPLETION_MISSING;;
    *) echo TASK_LOGIC_FAILED;;
  esac
}

# Normalize a classify() class to its budget() key. A budget() key is the class
# lowercased with a leading MODEL_ dropped; the EXECUTOR_/TASK_ families keep
# their prefix (executor_spawn_failed, task_logic_failed, task_test_failed), and
# completion_missing is the one key budget() declares without its EXECUTOR_ prefix.
class_key() { # <class>
  local c
  c=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$c" in
    model_*) printf '%s' "${c#model_}";;
    executor_completion_missing) printf '%s' completion_missing;;
    *) printf '%s' "$c";;
  esac
}

# budget_for <class>: the per-class retry budget line, FAIL-CLOSED on an unknown
# class (total=0) so a classify/budget key mismatch can never yield unlimited retry.
budget_for() {
  local k line; k=$(class_key "${1:-}")
  line=$(budget | awk -v k="$k" '$1==k')
  [ -n "$line" ] || line="$k total=0"
  printf '%s\n' "$line"
}

# --- next route decision -----------------------------------------------------
# Prints "route <free-model>" | "subscription <claude|codex>" | "hold <reason>".
next() { # --model M --attempt N --failures csv
  local model='' failures=''
  while [ $# -gt 0 ]; do case "$1" in
    --model) model=$2; shift 2;; --attempt) shift 2;;
    --failures) failures=$2; shift 2;; *) shift;; esac; done
  local free="${FM_FREE_MODELS:-$FREE_MODELS_DEFAULT}"
  # pick the first free model that has not already failed this task
  local m
  for m in $free; do
    case ",$failures," in *",$m,"*) continue;; esac
    [ "$m" = "$model" ] && continue
    echo "route $m"; return 0
  done
  # all free candidates exhausted -> subscription escalation candidate (approval)
  local codex_floor=${FM_CODEX_QUOTA_FLOOR:-5}
  local codex_remaining=${FM_CODEX_QUOTA_REMAINING:-0}
  if [ "$codex_remaining" -ge "$codex_floor" ] 2>/dev/null; then
    echo "subscription codex"
  else
    echo "subscription claude"
  fi
}

# --- paid-api alias guard ----------------------------------------------------
# A route is eligible only if it is in the free allow-list or a subscription CLI.
route_eligible() { # <route>
  local r=$1 free="${FM_FREE_MODELS:-$FREE_MODELS_DEFAULT}"
  case " $free " in *" $r "*) return 0;; esac
  case "$r" in claude|codex) return 0;; esac
  return 1
}

case "${1:-}" in
  classify) shift; classify "${1:-}";;
  class_key) shift; class_key "${1:-}";;
  budget_for) shift; budget_for "${1:-}";;
  next) shift; next "$@";;
  budget) budget;;
  route_eligible) shift; route_eligible "${1:-}" && echo eligible || echo blocked;;
  *) echo "usage: fm-unattended-failover.sh classify|class_key|budget_for|next|budget|route_eligible ..." >&2; exit 2;;
esac
