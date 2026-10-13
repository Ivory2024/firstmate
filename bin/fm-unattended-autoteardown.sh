#!/usr/bin/env bash
# fm-unattended-autoteardown.sh - automatic-teardown eligibility rule for the
# unattended crew orchestrator.
#
# This is a POLICY + DECISION helper only. It never tears anything down itself;
# it answers one question: may this completed task's crews/resources be cleaned
# up automatically? Actual cleanup stays with the firstmate teardown owner
# (bin/fm-teardown.sh) and is a separate, explicitly approved action.
#
# It is DISABLED unless UC_AUTOTEARDOWN_ENABLE=1. Production must not enable it
# yet (G4): the rule is designed and tested but not switched on.
#
# A task is eligible ONLY when ALL six conditions hold:
#   C1 terminal state            - tasks/<task>.state == VERIFIED_PASS
#   C2 pending inbox == 0        - no unhandled worker inbox records
#   C3 zero captain calls        - no open captain decision on the task
#   C4 evidence persisted        - executor rc=0 + artifact manifest + gate
#                                  verdict == VERIFIED_PASS (re-readable)
#   C5 session ownership verified- every session bound to the task owns it, and
#                                  its identity is recorded (no orphan/foreign)
#   C6 no other active work      - no other task in the batch is non-terminal
# Any failed condition is a refusal with the exact reason; anything unevaluable
# is a refusal (fail-closed).
#
# Usage:
#   fm-unattended-autoteardown.sh enabled
#   fm-unattended-autoteardown.sh check --batch-dir D --task T [--home H]
#   fm-unattended-autoteardown.sh plan  --batch-dir D [--home H]
set -u

TERMINAL_RE='VERIFIED_PASS|HOLD|CANCELLED|AUDIT_UNAVAILABLE'

_disabled() { [ "${UC_AUTOTEARDOWN_ENABLE:-0}" = 1 ] && return 1 || return 0; }

_pending_inbox() { # <home> <spawn> -> count of unhandled inbox records (files)
  local home=$1 spawn=$2 d
  d="$home/state/$spawn.inbox"
  [ -d "$d" ] || { echo 0; return 0; }
  find "$d" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' '
}

_captain_calls() { # <batch-dir> <task> -> open captain calls
  local bd=$1 t=$2 f="$1/tasks/$2.captain-calls"
  if [ -f "$f" ]; then cat "$f"; else echo 0; fi
}

check_one() { # <batch-dir> <task> <home>
  local bd=$1 t=$2 home=$3
  local st; st=$(sed -n 's/^new=//p' "$bd/tasks/$t.state" 2>/dev/null | tail -1)
  [ "$st" = VERIFIED_PASS ] || { echo "REFUSE task=$t reason=not-terminal($st)"; return 3; }

  # C4 evidence persisted and re-readable
  local ev="$bd/evidence/runs/$t" rc
  rc=$(cat "$ev/executor/rc" 2>/dev/null || echo "")
  [ -n "$rc" ] && [ "$rc" = 0 ] || { echo "REFUSE task=$t reason=evidence-missing"; return 3; }
  [ -f "$ev/executor/artifact-manifest.json" ] || { echo "REFUSE task=$t reason=evidence-manifest-missing"; return 3; }
  local v; v=$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("verdict",""))
except Exception: print("")' "$ev/gate/verdict.json" 2>/dev/null)
  [ "$v" = VERIFIED_PASS ] || { echo "REFUSE task=$t reason=evidence-not-verified($v)"; return 3; }

  # C2/C5 sessions: ownership + pending inbox
  local pending=0 saw_session=0 mismatched=0 d spawn sh
  for d in "$bd"/sessions/*/; do
    [ -f "${d}meta" ] || continue
    [ "$(sed -n 's/^task=//p' "${d}meta" | tail -1)" = "$t" ] || continue
    saw_session=1
    spawn=$(sed -n 's/^spawn_id=//p' "${d}meta" | tail -1)
    [ -n "$spawn" ] || mismatched=1
    sh=$(sed -n 's/^home=//p' "${d}meta" | tail -1); [ -n "$sh" ] || sh=$home
    if [ -n "$sh" ] && [ -n "$spawn" ]; then
      pending=$((pending + $(_pending_inbox "$sh" "$spawn")))
    else
      # no home to read: fall back to the batch-local count, default 0
      pending=$((pending + $(_captain_calls "$bd" "$t")))
    fi
  done
  [ "$mismatched" = 0 ] || { echo "REFUSE task=$t reason=session-unowned"; return 3; }
  [ "$saw_session" = 1 ] || { echo "REFUSE task=$t reason=session-missing"; return 3; }
  # batch-local pending inbox count (authoritative when present)
  if [ -f "$bd/tasks/$t.inbox_pending" ]; then pending=$(cat "$bd/tasks/$t.inbox_pending"); fi
  [ "$pending" = 0 ] || { echo "REFUSE task=$t reason=inbox-pending($pending)"; return 3; }

  # C3 zero captain calls
  local cc; cc=$(_captain_calls "$bd" "$t")
  [ "$cc" = 0 ] || { echo "REFUSE task=$t reason=captain-calls($cc)"; return 3; }

  # C6 no other active work in the batch
  local f other
  for f in "$bd"/tasks/*.state; do
    [ -f "$f" ] || continue
    other=$(basename "$f" .state)
    [ "$other" = "$t" ] && continue
    local ost; ost=$(sed -n 's/^new=//p' "$f" | tail -1)
    if ! printf '%s' "$ost" | grep -Eq "^($TERMINAL_RE)$"; then
      echo "REFUSE task=$t reason=other-active-work($other=$ost)"; return 3
    fi
  done

  echo "OK task=$t"
  return 0
}

cmd_check() {
  local bd='' t='' home=''
  while [ $# -gt 0 ]; do case "$1" in
    --batch-dir) bd=$2; shift 2;; --task) t=$2; shift 2;; --home) home=$2; shift 2;;
    *) echo "check: bad arg $1" >&2; exit 2;;
  esac; done
  [ -d "$bd" ] || { echo "check: no batch dir $bd" >&2; exit 2; }
  [ -n "$t" ] || { echo "check: need --task" >&2; exit 2; }
  if _disabled; then echo "DISABLED reason=autoteardown-not-enabled"; exit 4; fi
  check_one "$bd" "$t" "$home"
  return $?
}

cmd_plan() {
  local bd='' home='' f t
  while [ $# -gt 0 ]; do case "$1" in --batch-dir) bd=$2; shift 2;; --home) home=$2; shift 2;; *) echo "plan: bad arg $1" >&2; exit 2;; esac; done
  [ -d "$bd" ] || { echo "plan: no batch dir $bd" >&2; exit 2; }
  if _disabled; then echo "DISABLED reason=autoteardown-not-enabled"; exit 4; fi
  local rc=0
  for f in "$bd"/tasks/*.state; do
    [ -f "$f" ] || continue
    t=$(basename "$f" .state)
    check_one "$bd" "$t" "$home" || rc=3
  done
  return "$rc"
}

case "${1:-}" in
  enabled)
    if _disabled; then echo disabled; exit 4; else echo enabled; exit 0; fi;;
  check) shift; cmd_check "$@";;
  plan) shift; cmd_plan "$@";;
  *) echo "usage: fm-unattended-autoteardown.sh enabled|check|plan ..." >&2; exit 2;;
esac
