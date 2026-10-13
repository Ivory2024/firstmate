#!/usr/bin/env bash
# fm-unattended-faultinject.test.sh - G4 30-fault classification + safe-action gate.
# shellcheck disable=SC2015 # ok() and no() both return 0, so `A && ok || no`
# is if/else here: the `no` branch cannot run once `ok` has run.
set -u
UCX="${FM_UC_IMPL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin}"
R="$UCX/fm-unattended-recovery.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok - $1"; }
no(){ FAIL=$((FAIL+1)); echo "NOT OK - $1"; }

# fault:expected-category (30 fault types)
CASES="
transport-timeout:AUTO_RECOVERABLE
rate-limited:AUTO_RECOVERABLE
provider-unavailable:AUTO_RECOVERABLE
api-timeout:AUTO_RECOVERABLE
network:AUTO_RECOVERABLE
quota-exhausted:QUOTA_WAIT
auth-failed:CAPTAIN_APPROVAL_REQUIRED
approval-required:CAPTAIN_APPROVAL_REQUIRED
executor-timeout:REQUIRES_DIAGNOSIS
worker-interrupted:REQUIRES_DIAGNOSIS
worker-failed:REQUIRES_DIAGNOSIS
evidence-incomplete:REQUIRES_DIAGNOSIS
evidence-guard-mismatch:REQUIRES_DIAGNOSIS
completion-missing:REQUIRES_DIAGNOSIS
audit-unavailable:REQUIRES_DIAGNOSIS
auditor-start-failed:REQUIRES_DIAGNOSIS
structured-response-invalid:REQUIRES_DIAGNOSIS
session-lost:REQUIRES_DIAGNOSIS
tmux-lost:REQUIRES_DIAGNOSIS
sandbox-path:REQUIRES_DIAGNOSIS
symlink:REQUIRES_DIAGNOSIS
disk-full:REQUIRES_DIAGNOSIS
stale-generation:NON_RECOVERABLE
duplicate-dispatch:NON_RECOVERABLE
identity-mismatch:NON_RECOVERABLE
source-unresolved:NON_RECOVERABLE
generation-mismatch:NON_RECOVERABLE
lease-conflict:NON_RECOVERABLE
retry-exhausted:CAPTAIN_HOLD
task-logic-failed:CAPTAIN_HOLD
"
n=0
while IFS=: read -r fault want; do
  [ -n "$fault" ] || continue
  n=$((n+1))
  got=$("$R" classify "$fault")
  [ "$got" = "$want" ] && ok "$fault -> $want" || no "$fault -> $got (want $want)"
done <<EOF
$CASES
EOF
[ "$n" -ge 30 ] && ok ">=30 fault types covered ($n)" || no "fault count $n"

# safe-action gate: non-auto categories must never auto-retry
for cat in NON_RECOVERABLE QUOTA_WAIT CAPTAIN_APPROVAL_REQUIRED CAPTAIN_HOLD; do
  case "$cat" in
    NON_RECOVERABLE) f=stale-generation;;
    QUOTA_WAIT) f=quota-exhausted;;
    CAPTAIN_APPROVAL_REQUIRED) f=auth-failed;;
    CAPTAIN_HOLD) f=retry-exhausted;;
  esac
  a=$("$R" decide --reason "$f" --attempt 1 --same-cause 0 | sed -n 's/.*action=\([a-z-]*\).*/\1/p')
  [ "$a" != retry ] && ok "$cat never auto-retries ($f -> $a)" || no "$cat auto-retried"
done

echo "# fm-unattended-faultinject.test.sh PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
