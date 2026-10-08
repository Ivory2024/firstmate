#!/usr/bin/env bash
# judge.test.sh - deterministic-judge floor conditions. Each case builds a run
# fixture and asserts the verdict. The judge must never emit VERIFIED_PASS when
# evidence, audit, hashes, workspace isolation, or the mode contract are unmet.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JUDGE="$UCX/fm-unattended-judge.sh"
ER="$UCX/fm-unattended-evidence.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/uc-judge.XXXXXX")

mkfixture() { # <id> <mode> <rc> <audit-verdict|none> <auditor-kind>
  local id=$1 mode=$2 rc=$3 av=$4 kind=${5:-fake}
  local d="$W/runs/$id"; rm -rf "$d"; mkdir -p "$d/auditor" "$d/gate"
  cat > "$d/task-contract.json" <<EOF
{ "mode": "$mode", "required_tests": ["x"], "patch_sha256": "deadbeef", "forbidden_operations": ["github_write"] }
EOF
  EVIDENCE_ROOT="$W" "$ER" run "$id" -- bash -c "exit $rc" >/dev/null 2>&1
  printf 'deadbeef\n' > "$d/executor/patch-hash"
  printf '1\n' > "$d/executor/test-count"
  printf '{"session_id":"exec","workdir":"/tmp/exec-ws-A"}\n' > "$d/executor/session.json"
  printf '/tmp/exec-ws-A\n' > "$d/executor/wd"
  printf '{"session_id":"aud","workdir":"/tmp/aud-ws-B","auditor_kind":"%s"}\n' "$kind" > "$d/auditor/session.json"
  case "$av" in
    none) rm -f "$d/auditor/findings.json";;
    *) printf '{"verdict":"%s","auditor_kind":"%s"}\n' "$av" "$kind" > "$d/auditor/findings.json";;
  esac
}
verdict() { EVIDENCE_ROOT="$W" "$JUDGE" run "$1" 2>/dev/null | sed 's/^VERDICT=//;s/ .*//'; }

# clean test-mode run -> VERIFIED_PASS
mkfixture cok test 0 PASS fake
[ "$(verdict cok)" = VERIFIED_PASS ] && ok "clean test-mode => VERIFIED_PASS" || no "clean (got $(verdict cok))"

# fixable failure -> REWORK
mkfixture c11 test 1 PASS fake
[ "$(verdict c11)" = REWORK ] && ok "nonzero exit => REWORK" || no "nonzero (got $(verdict c11))"

# missing exit code -> HOLD
mkfixture c3 test 0 PASS fake; rm -f "$W/runs/c3/executor/rc"
[ "$(verdict c3)" = HOLD ] && ok "missing exit code => HOLD" || no "missing exit (got $(verdict c3))"

# missing audit -> AUDIT_UNAVAILABLE
mkfixture c8 test 0 none
[ "$(verdict c8)" = AUDIT_UNAVAILABLE ] && ok "missing audit => AUDIT_UNAVAILABLE" || no "missing audit (got $(verdict c8))"

# forbidden external write -> HOLD
mkfixture c10 test 0 PASS fake; : > "$W/runs/c10/gate/forbidden_write"
[ "$(verdict c10)" = HOLD ] && ok "forbidden write => HOLD" || no "forbidden write (got $(verdict c10))"

# patch hash mismatch -> HOLD
mkfixture c7 test 0 PASS fake; echo different > "$W/runs/c7/executor/patch-hash"
[ "$(verdict c7)" = HOLD ] && ok "patch hash mismatch => HOLD" || no "hash mismatch (got $(verdict c7))"

# artifact manifest hash mismatch -> HOLD
mkfixture ch test 0 PASS fake; echo "tampered" >> "$W/runs/ch/executor/stdout/cmd.out"
[ "$(verdict ch)" = HOLD ] && ok "artifact hash mismatch => HOLD" || no "artifact tamper (got $(verdict ch))"

# auditor and executor share a workspace -> HOLD
mkfixture cws test 0 PASS fake
printf '{"session_id":"aud","workdir":"/tmp/exec-ws-A","auditor_kind":"fake"}\n' > "$W/runs/cws/auditor/session.json"
[ "$(verdict cws)" = HOLD ] && ok "same workspace => HOLD" || no "same workspace (got $(verdict cws))"

# fake auditor in production mode -> HOLD (never VERIFIED_PASS)
mkfixture cprod production 0 PASS fake
[ "$(verdict cprod)" = HOLD ] && ok "fake auditor in production => HOLD" || no "production fake (got $(verdict cprod))"

# tests incomplete (fewer executed than required) -> HOLD
mkfixture cti test 0 PASS fake
python3 - "$W/runs/cti/task-contract.json" <<'PY'
import json,sys;p=sys.argv[1];d=json.load(open(p));d["required_tests"]=["a","b","c"];json.dump(d,open(p,"w"))
PY
[ "$(verdict cti)" = HOLD ] && ok "tests incomplete => HOLD" || no "tests incomplete (got $(verdict cti))"

# reused prior PASS -> HOLD
mkfixture crp test 0 PASS fake; : > "$W/runs/crp/executor/reused-prior-pass"
[ "$(verdict crp)" = HOLD ] && ok "reused prior PASS => HOLD" || no "reused prior pass (got $(verdict crp))"

rm -rf "$W"
echo "# judge.test.sh PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
