#!/usr/bin/env bash
# guard.test.sh - Executor Evidence Guard. The guard must detect a claimed value
# that disagrees with machine-derived canonical evidence BEFORE the auditor is
# dispatched, and must fail closed on any un-evaluable claim. Read-only:
# it never mutates the report.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$UCX/fm-unattended-guard.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/uc-guard.XXXXXX")
WD="$W/wd"; mkdir -p "$WD"
C="$W/contract.json"; R="$W/report.md"; G="$W/guard.json"

# guard_rc <contract> <report> -> exit code; verdict() reads $G
guard_rc() { "$GUARD" check --contract "$1" --report "$2" --workdir "$WD" --out "$G" >/dev/null 2>&1; echo $?; }
verdict() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["verdict"])' "$G" 2>/dev/null; }
reasons() { python3 -c 'import json,sys;print(";".join(json.load(open(sys.argv[1]))["reasons"]))' "$G" 2>/dev/null; }

w_contract() { printf '%s\n' "$1" > "$C"; }
w_report()   { printf '%s' "$1" > "$R"; }

# 1. exact count vs canonical -> PASS
w_contract '{"executor":{"claims":[{"id":"families","kind":"count","report_pattern":"families = ([0-9]+)","source":{"type":"cmd","cmd":"seq 1 15","reduce":"lines"}}]}}'
w_report 'families = 15
'
{ [ "$(guard_rc "$C" "$R")" = 0 ] && [ "$(verdict)" = PASS ]; } \
  && ok "count exact (15==15) => PASS" || no "count exact (rc=$(guard_rc "$C" "$R") v=$(verdict))"

# 2. 15 vs 14 -> MISMATCH (the real-canary off-by-one)
w_report 'families = 14
'
{ [ "$(guard_rc "$C" "$R")" = 1 ] && [ "$(verdict)" = MISMATCH ] && reasons | grep -q 'families:value-mismatch(14!=15)'; } \
  && ok "count 14 vs canonical 15 => MISMATCH" || no "count 14 vs 15 (rc=$(guard_rc "$C" "$R") r=$(reasons))"

# 3. 25 vs 26 against the report's OWN capture (self-contradiction, report source)
w_contract '{"executor":{"claims":[{"id":"assertions","kind":"count","report_pattern":"assertions = ([0-9]+)","source":{"type":"report","reduce":"count_re:^ok -"}}]}}'
w_report 'assertions = 26
ok - a
ok - b
ok - c
ok - d
ok - e
'
{ [ "$(guard_rc "$C" "$R")" = 1 ] && reasons | grep -q 'assertions:value-mismatch(26!=5)'; } \
  && ok "assertion 26 vs 5 ok-lines (self-contradiction) => MISMATCH" || no "assertion self (rc=$(guard_rc "$C" "$R") r=$(reasons))"
w_report 'assertions = 5
ok - a
ok - b
ok - c
ok - d
ok - e
'
[ "$(guard_rc "$C" "$R")" = 0 ] && ok "assertion 5 vs 5 ok-lines => PASS" || no "assertion exact (r=$(reasons))"

# 4. file list set: exact -> PASS
w_contract '{"executor":{"claims":[{"id":"files","kind":"set","report_pattern":"(?m)^- (tests/[A-Za-z0-9._-]+\\.test\\.sh)$","source":{"type":"cmd","cmd":"printf %s\\\\n tests/a.test.sh tests/b.test.sh","reduce":"lines"}}]}}'
w_report '- tests/a.test.sh
- tests/b.test.sh
'
[ "$(guard_rc "$C" "$R")" = 0 ] && ok "set exact list => PASS" || no "set exact (r=$(reasons))"

# 5. file missing -> MISMATCH
w_report '- tests/a.test.sh
'
{ [ "$(guard_rc "$C" "$R")" = 1 ] && reasons | grep -q 'files:set-mismatch(missing=1,extra=0)'; } \
  && ok "set missing file => MISMATCH" || no "set missing (r=$(reasons))"

# 6. duplicate file -> MISMATCH
w_report '- tests/a.test.sh
- tests/a.test.sh
- tests/b.test.sh
'
{ [ "$(guard_rc "$C" "$R")" = 1 ] && reasons | grep -q 'files:duplicate-items'; } \
  && ok "set duplicate item => MISMATCH" || no "set duplicate (r=$(reasons))"

# 7. list order difference, same set -> PASS (semantic equality)
w_report '- tests/b.test.sh
- tests/a.test.sh
'
[ "$(guard_rc "$C" "$R")" = 0 ] && ok "set order difference => PASS" || no "set order (r=$(reasons))"

# 8. raw evidence missing (report absent) -> fail-closed
w_contract '{"executor":{"claims":[{"id":"families","kind":"count","source":{"type":"cmd","cmd":"seq 1 15","reduce":"lines"}}]}}'
{ [ "$(guard_rc "$C" "$W/does-not-exist.md")" = 1 ] && reasons | grep -q 'report-missing'; } \
  && ok "missing report => fail-closed (report-missing)" || no "missing report (r=$(reasons))"

# 9. malformed contract -> clear nonzero error (exit 2), no false pass
printf '{ this is not json' > "$C"
[ "$(guard_rc "$C" "$R")" = 2 ] && ok "malformed contract => exit 2 error" || no "malformed contract (rc=$(guard_rc "$C" "$R"))"

# 10. legacy contract with no claims -> no-op PASS (compat)
w_contract '{"mode":"production","tasks":[{"task_id":"t","executor":{"command":["true"]}}]}'
w_report 'anything
'
{ [ "$(guard_rc "$C" "$R")" = 0 ] && python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["note"]=="no-claims-declared"' "$G"; } \
  && ok "no claims declared => PASS (no-claims-declared)" || no "no claims (rc=$(guard_rc "$C" "$R"))"

# 11. default structured claim form 'StructClaim: <id> = <n>'
w_contract '{"executor":{"claims":[{"id":"families","kind":"count","source":{"type":"cmd","cmd":"seq 1 15","reduce":"lines"}}]}}'
w_report 'StructClaim: families = 15
'
[ "$(guard_rc "$C" "$R")" = 0 ] && ok "default StructClaim form => PASS" || no "struct claim (r=$(reasons))"
w_report 'StructClaim: families = 14
'
[ "$(guard_rc "$C" "$R")" = 1 ] && ok "default StructClaim mismatch => MISMATCH" || no "struct mismatch"

# 12. non-numeric claim -> MISMATCH
w_contract '{"executor":{"claims":[{"id":"families","kind":"count","report_pattern":"families = (\\S+)","source":{"type":"cmd","cmd":"seq 1 15","reduce":"lines"}}]}}'
w_report 'families = many
'
{ [ "$(guard_rc "$C" "$R")" = 1 ] && reasons | grep -q 'non-numeric-claim'; } \
  && ok "non-numeric claim => MISMATCH" || no "non-numeric (r=$(reasons))"

# 13. canonical command fails -> fail-closed
w_contract '{"executor":{"claims":[{"id":"families","kind":"count","report_pattern":"families = ([0-9]+)","source":{"type":"cmd","cmd":"exit 3","reduce":"lines"}}]}}'
w_report 'families = 15
'
{ [ "$(guard_rc "$C" "$R")" = 1 ] && reasons | grep -q 'canonical-cmd-failed'; } \
  && ok "canonical cmd failure => fail-closed" || no "canonical fail (r=$(reasons))"

# 14. required=false claim absent -> PASS (optional)
w_contract '{"executor":{"claims":[{"id":"opt","kind":"count","required":false,"report_pattern":"opt = ([0-9]+)","source":{"type":"cmd","cmd":"seq 1 15","reduce":"lines"}}]}}'
w_report 'no optional claim here
'
[ "$(guard_rc "$C" "$R")" = 0 ] && ok "optional absent claim => PASS" || no "optional absent (r=$(reasons))"

# 15. read-only: the guard never mutates the report
w_contract '{"executor":{"claims":[{"id":"families","kind":"count","report_pattern":"families = ([0-9]+)","source":{"type":"cmd","cmd":"seq 1 15","reduce":"lines"}}]}}'
w_report 'families = 14
'
h1=$(shasum -a 256 "$R" | awk '{print $1}'); guard_rc "$C" "$R" >/dev/null; h2=$(shasum -a 256 "$R" | awk '{print $1}')
[ "$h1" = "$h2" ] && ok "guard is read-only on the report" || no "guard mutated report"

rm -rf "$W"
echo "# guard.test.sh PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
