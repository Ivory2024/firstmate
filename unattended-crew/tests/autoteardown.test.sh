#!/usr/bin/env bash
# autoteardown.test.sh - the automatic-teardown eligibility rule. It must be
# disabled by default, and eligible ONLY when all six conditions hold: terminal
# state, pending inbox 0, zero captain calls, persisted evidence, verified
# session ownership, and no other active work in the batch.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AT="$UCX/fm-unattended-autoteardown.sh"
BD=$(mktemp -d "${TMPDIR:-/tmp}/uc-at.XXXXXX")
HOME_="$BD/home"; mkdir -p "$HOME_/state"

mkbatch() { # t1 and t2 both VERIFIED_PASS, evidence + sessions present
  rm -rf "$BD/batches"; BD_B="$BD/batches/b"
  mkdir -p "$BD_B/tasks" "$BD_B/evidence/runs/t1/executor" "$BD_B/evidence/runs/t1/gate" \
           "$BD_B/evidence/runs/t2/executor" "$BD_B/evidence/runs/t2/gate" "$BD_B/sessions"
  local t
  for t in t1 t2; do
    printf 'new=VERIFIED_PASS\n' > "$BD_B/tasks/$t.state"
    printf '0\n' > "$BD_B/evidence/runs/$t/executor/rc"
    printf '{}\n' > "$BD_B/evidence/runs/$t/executor/artifact-manifest.json"
    printf '{"verdict":"VERIFIED_PASS"}\n' > "$BD_B/evidence/runs/$t/gate/verdict.json"
    mkdir -p "$BD_B/sessions/${t}-exec"
    printf 'sid=%s-exec\ntask=%s\nrole=executor\nattempt=1\nspawn_id=%s\nhome=%s\n' "$t" "$t" "$t" "$HOME_" \
      > "$BD_B/sessions/${t}-exec/meta"
  done
}
run_at() { UC_AUTOTEARDOWN_ENABLE="${1:-0}" "$AT" check --batch-dir "$BD_B" --task "${2:-t1}" --home "$HOME_"; }

mkbatch
# 1. disabled by default
UC_AUTOTEARDOWN_ENABLE=0 "$AT" check --batch-dir "$BD_B" --task t1 --home "$HOME_"; rc=$?
{ [ "$rc" -eq 4 ] && UC_AUTOTEARDOWN_ENABLE=0 "$AT" enabled | grep -q disabled; } \
  && ok "autoteardown: disabled unless explicitly enabled" || no "disable guard (rc=$rc)"

# 2. all conditions hold => eligible
out=$(run_at 1 t1); rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^OK task=t1'; } \
  && ok "autoteardown: all six conditions => OK" || no "eligible case (rc=$rc out=$out)"

# 3. non-terminal state => refuse
printf 'new=RUNNING\n' > "$BD_B/tasks/t1.state"
out=$(run_at 1 t1); rc=$?
{ [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'not-terminal'; } \
  && ok "autoteardown: non-terminal state refused" || no "non-terminal (out=$out)"
mkbatch

# 4. evidence missing => refuse
rm -f "$BD_B/evidence/runs/t1/executor/rc"
out=$(run_at 1 t1); rc=$?
{ [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'evidence-missing'; } \
  && ok "autoteardown: missing evidence refused" || no "evidence-missing (out=$out)"
mkbatch

# 5. verdict not VERIFIED_PASS => refuse
printf '{"verdict":"HOLD"}\n' > "$BD_B/evidence/runs/t1/gate/verdict.json"
out=$(run_at 1 t1); rc=$?
{ [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'evidence-not-verified'; } \
  && ok "autoteardown: non-verified verdict refused" || no "verdict (out=$out)"
mkbatch

# 6. pending inbox nonzero => refuse
mkdir -p "$HOME_/state/t1.inbox"
printf 'steer\n' > "$HOME_/state/t1.inbox/001.msg"
out=$(run_at 1 t1); rc=$?
{ [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'inbox-pending'; } \
  && ok "autoteardown: pending inbox refused" || no "inbox-pending (out=$out)"
rm -rf "$HOME_/state/t1.inbox"

# 7. open captain calls => refuse
printf '1\n' > "$BD_B/tasks/t1.captain-calls"
out=$(run_at 1 t1); rc=$?
{ [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'captain-calls'; } \
  && ok "autoteardown: open captain call refused" || no "captain-calls (out=$out)"
rm -f "$BD_B/tasks/t1.captain-calls"

# 8. session ownership not verified (no spawn id) => refuse
printf 'sid=x\ntask=t1\nrole=executor\nhome=%s\n' "$HOME_" > "$BD_B/sessions/t1-exec/meta"
out=$(run_at 1 t1); rc=$?
{ [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'session-unowned'; } \
  && ok "autoteardown: unverified session ownership refused" || no "session-unowned (out=$out)"
mkbatch

# 9. session missing entirely => refuse
rm -rf "$BD_B/sessions/t1-exec"
out=$(run_at 1 t1); rc=$?
{ [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'session-missing'; } \
  && ok "autoteardown: missing session refused" || no "session-missing (out=$out)"
mkbatch

# 10. other active work in the batch => refuse
printf 'new=RUNNING\n' > "$BD_B/tasks/t2.state"
out=$(run_at 1 t1); rc=$?
{ [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'other-active-work'; } \
  && ok "autoteardown: other active work refused" || no "other-active-work (out=$out)"
mkbatch

# 11. plan reports every terminal task
out=$(UC_AUTOTEARDOWN_ENABLE=1 "$AT" plan --batch-dir "$BD_B" --home "$HOME_")
{ printf '%s' "$out" | grep -q '^OK task=t1' && printf '%s' "$out" | grep -q '^OK task=t2'; } \
  && ok "autoteardown: plan lists eligible terminal tasks" || no "plan (out=$out)"

rm -rf "$BD"
echo "# autoteardown.test.sh PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
