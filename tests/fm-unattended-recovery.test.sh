#!/usr/bin/env bash
# fm-unattended-recovery.test.sh - G4 self-healing recovery policy fixtures.
# shellcheck disable=SC2015 # ok() and no() both return 0, so `A && ok || no`
# is if/else here: the `no` branch cannot run once `ok` has run.
set -u
UCX="${FM_UC_IMPL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin}"
R="$UCX/fm-unattended-recovery.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok - $1"; }
no(){ FAIL=$((FAIL+1)); echo "NOT OK - $1"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || no "$1 (got '$2' want '$3')"; }
cat_of(){ "$R" classify "$1"; }

# --- §4 classification (fault-injection coverage) ---
eq "executor timeout -> diagnosis"      "$(cat_of executor-timeout)" REQUIRES_DIAGNOSIS
eq "worker interrupted -> diagnosis"    "$(cat_of worker-interrupted)" REQUIRES_DIAGNOSIS
eq "worker failed -> diagnosis"         "$(cat_of worker-failed)" REQUIRES_DIAGNOSIS
eq "auditor start failed -> diagnosis"  "$(cat_of auditor-start-failed)" REQUIRES_DIAGNOSIS
eq "structured response -> diagnosis"   "$(cat_of structured-response-invalid)" REQUIRES_DIAGNOSIS
eq "audit unavailable -> diagnosis"     "$(cat_of audit-unavailable)" REQUIRES_DIAGNOSIS
eq "tmux lost -> diagnosis"             "$(cat_of tmux-lost)" REQUIRES_DIAGNOSIS
eq "sandbox path -> diagnosis"          "$(cat_of sandbox-path)" REQUIRES_DIAGNOSIS
eq "symlink -> diagnosis"               "$(cat_of symlink)" REQUIRES_DIAGNOSIS
eq "disk full -> diagnosis"             "$(cat_of disk-full)" REQUIRES_DIAGNOSIS
eq "stale generation -> non-recoverable" "$(cat_of stale-generation)" NON_RECOVERABLE
eq "duplicate dispatch -> non-recoverable" "$(cat_of duplicate-dispatch)" NON_RECOVERABLE
eq "identity mismatch -> non-recoverable" "$(cat_of identity-mismatch)" NON_RECOVERABLE
eq "source unresolved -> non-recoverable" "$(cat_of source-unresolved)" NON_RECOVERABLE
eq "quota blocked -> quota wait"        "$(cat_of quota-blocked)" QUOTA_WAIT
eq "model quota -> quota wait"          "$(cat_of MODEL_QUOTA_EXHAUSTED)" QUOTA_WAIT
eq "transport timeout -> auto"          "$(cat_of MODEL_TRANSPORT_TIMEOUT)" AUTO_RECOVERABLE
eq "rate limited -> auto"               "$(cat_of MODEL_RATE_LIMITED)" AUTO_RECOVERABLE
eq "provider unavailable -> auto"       "$(cat_of MODEL_PROVIDER_UNAVAILABLE)" AUTO_RECOVERABLE
eq "auth failed -> approval"            "$(cat_of MODEL_AUTH_FAILED)" CAPTAIN_APPROVAL_REQUIRED
eq "approval required -> approval"      "$(cat_of approval-required)" CAPTAIN_APPROVAL_REQUIRED
eq "retry exhausted -> captain hold"    "$(cat_of retry-exhausted)" CAPTAIN_HOLD
eq "unknown reason -> UNKNOWN"          "$(cat_of something-weird)" UNKNOWN

# --- §6 bounded retry + circuit breaker ---
eq "auto retry (1st)"   "$("$R" decide --reason transport --attempt 1 --same-cause 0 | sed -n 's/.*action=\([a-z-]*\).*/\1/p')" retry
eq "auto retry (2nd)"   "$("$R" decide --reason transport --attempt 2 --same-cause 1 | sed -n 's/.*action=\([a-z-]*\).*/\1/p')" retry
eq "circuit breaker at max" "$("$R" decide --reason transport --attempt 3 --same-cause 2 | sed -n 's/.*action=\([a-z-]*\).*/\1/p')" hold
eq "diagnosis retry once" "$("$R" decide --reason worker-failed --attempt 1 --same-cause 0 | sed -n 's/.*action=\([a-z-]*\).*/\1/p')" diagnose
eq "diagnosis circuit breaker" "$("$R" decide --reason worker-failed --attempt 2 --same-cause 1 | sed -n 's/.*action=\([a-z-]*\).*/\1/p')" hold
eq "quota -> quota-wait (no retry burn)" "$("$R" decide --reason quota-blocked --attempt 1 --same-cause 0 | sed -n 's/.*action=\([a-z-]*\).*/\1/p')" quota-wait
eq "non-recoverable -> hold" "$("$R" decide --reason stale-generation --attempt 1 --same-cause 0 | sed -n 's/.*action=\([a-z-]*\).*/\1/p')" hold
eq "approval -> approval" "$("$R" decide --reason approval-required --attempt 1 --same-cause 0 | sed -n 's/.*action=\([a-z-]*\).*/\1/p')" approval
eq "unknown -> hold (fail-closed)" "$("$R" decide --reason mystery --attempt 1 --same-cause 0 | sed -n 's/.*action=\([a-z-]*\).*/\1/p')" hold

echo "# fm-unattended-recovery.test.sh PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
