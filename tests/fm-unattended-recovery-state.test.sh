#!/usr/bin/env bash
# fm-unattended-recovery-state.test.sh - durable recovery metadata fixtures.
# shellcheck disable=SC2015 # ok() and no() both return 0, so `A && ok || no`
# is if/else here: the `no` branch cannot run once `ok` has run.
set -u
UCX="${FM_UC_IMPL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin}"
S="$UCX/fm-unattended-recovery-state.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok - $1"; }
no(){ FAIL=$((FAIL+1)); echo "NOT OK - $1"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || no "$1 (got '$2' want '$3')"; }
H=$(mktemp -d "${TMPDIR:-/tmp}/rec.XXXXXX"); T=t1
g(){ "$S" get "$H" "$T" | sed -n "s/^$1=//p"; }

# 1. first bump
"$S" bump "$H" "$T" transport retry recovering >/dev/null
eq "attempt_id=1" "$(g attempt_id)" 1
eq "same_cause=1" "$(g same_cause)" 1

# 2. same reason -> increment
"$S" bump "$H" "$T" transport retry recovering >/dev/null
eq "attempt_id=2" "$(g attempt_id)" 2
eq "same_cause=2" "$(g same_cause)" 2

# 3. different reason -> reset same_cause
"$S" bump "$H" "$T" worker-failed diagnose recovering >/dev/null
eq "same_cause resets to 1" "$(g same_cause)" 1
eq "attempt_id monotonic=3" "$(g attempt_id)" 3

# 4. restart persistence: a fresh process reads the same record
eq "restart keeps attempt_id" "$("$S" get "$H" "$T" | sed -n 's/^attempt_id=//p')" 3

# 5. durable terminal guard: an already-held recovery is not re-run
"$S" set-status "$H" "$T" held >/dev/null
eq "terminal guard blocks re-recovery" "$("$S" decide "$H" "$T" transport | sed -n 's/.*action=\([a-z-]*\).*/\1/p')" hold

# 6. reset clears
"$S" reset "$H" "$T" >/dev/null
eq "reset clears record" "$("$S" get "$H" "$T" | wc -l | tr -d ' ')" 0

# 7. atomic decide persists same_cause + circuit-breaks across calls
T2=t2
a1=$("$S" decide "$H" "$T2" transport | sed -n 's/.*action=\([a-z-]*\).*/\1/p')
a2=$("$S" decide "$H" "$T2" transport | sed -n 's/.*action=\([a-z-]*\).*/\1/p')
a3=$("$S" decide "$H" "$T2" transport | sed -n 's/.*action=\([a-z-]*\).*/\1/p')
{ [ "$a1" = retry ] && [ "$a2" = retry ] && [ "$a3" = hold ]; } && ok "bounded retry then circuit breaker (atomic)" || no "bounded retry ($a1/$a2/$a3)"
# 7a. decide()'s own hold is terminal: status=held and the next call is a no-op
eq "decide hold writes status=held" "$("$S" get "$H" "$T2" | sed -n 's/^status=//p')" held
before=$("$S" get "$H" "$T2" | sed -n 's/^attempt_id=//p')
"$S" decide "$H" "$T2" transport >/dev/null
after=$("$S" get "$H" "$T2" | sed -n 's/^attempt_id=//p')
eq "terminal hold not re-run (attempt_id frozen)" "$after" "$before"

# 7b. re-dispatch fence: a superseded generation is not recovered
eq "stale gen -> hold (fence)" "$("$S" decide "$H" t9 transport 1 2 | sed -n 's/.*action=\([a-z-]*\).*/\1/p')" hold

# 8. concurrency: 10 concurrent bumps -> attempt_id consistent, no corruption
T3=t3
for i in $(seq 1 10); do "$S" bump "$H" "$T3" transport retry recovering >/dev/null 2>&1 & done; wait
eq "10 concurrent bumps -> attempt_id=10" "$("$S" get "$H" "$T3" | sed -n 's/^attempt_id=//p')" 10
eq "record has 6 fields" "$("$S" get "$H" "$T3" | wc -l | tr -d ' ')" 6

# 9. TOCTOU: concurrent decide() must not over-pass the circuit breaker.
# Serialized correctly, only 2 of N concurrent calls may return retry (max=2).
T4=t4
tmpd=$(mktemp -d "${TMPDIR:-/tmp}/rec9.XXXXXX")
for i in $(seq 1 8); do
  ( "$S" decide "$H" "$T4" transport | sed -n 's/.*action=\([a-z-]*\).*/\1/p' > "$tmpd/$i" ) &
done; wait
retries=$(grep -l '^retry$' "$tmpd"/* 2>/dev/null | wc -l | tr -d ' ')
eq "concurrent decide: exactly 2 retries (no over-pass)" "$retries" 2
rm -rf "$tmpd"

rm -rf "$H"
echo "# fm-unattended-recovery-state.test.sh PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
