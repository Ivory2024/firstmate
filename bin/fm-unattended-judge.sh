#!/usr/bin/env bash
# fm-unattended-judge.sh - Deterministic Judge for the unattended batch
# coordinator.
#
# Evolved, in an isolated copy, from the prior batch's
# data/firstmate-fork-only-write-guard-20261008/evidence-system/judge.sh
# (sha256 recorded in evidence/artifact-manifest.json). It consumes STRUCTURED
# EVIDENCE only, never the coordinator report text, and emits one verdict:
# VERIFIED_PASS | REWORK | HOLD | AUDIT_UNAVAILABLE.
#
# Reuses the original floor conditions and adds the batch-required enforcements
# (AGENTS-style safety floor for the unattended controller):
#   - mode=production with a fake auditor can NEVER be VERIFIED_PASS -> HOLD
#     (a fake auditor is only valid in mode=test).
#   - missing audit -> AUDIT_UNAVAILABLE.
#   - incomplete test (no exit code / no raw logs) -> HOLD/REWORK.
#   - artifact hash mismatch -> HOLD.
#   - forbidden external write declared by the contract, or its marker -> HOLD.
#   - a reused prior PASS -> HOLD.
#   - auditor and executor sharing a workspace -> HOLD.
#   - fewer executed tests than the contract requires -> HOLD.
#
# Inputs under $EVIDENCE_ROOT/runs/<run_id>/:
#   task-contract.json, executor/{rc,command-log.jsonl,stdout/,stderr/,wd,
#   artifact-manifest.json,pid,patch-hash,test-count}, auditor/findings.json,
#   auditor/session.json, gate/forbidden_write
# Output: gate/verdict.json + gate/summary.md; exit 0 iff VERIFIED_PASS.
set -u
ROOT=${EVIDENCE_ROOT:?set EVIDENCE_ROOT}
RUNS="$ROOT/runs"

_jget() { python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d=d.get(k) if isinstance(d,dict) else None
print("" if d is None else d)' "$1" "$2" 2>/dev/null; }

judge() { # <run_id>
  local id=$1 d="$RUNS/$1"
  local c="$d/task-contract.json" e="$d/executor" a="$d/auditor/findings.json"
  local reasons=() verdict
  ck() { reasons+=("$1"); }

  [ -f "$c" ] || ck "contract-missing"
  [ -f "$e/rc" ] || ck "exit-code-missing"
  if [ -f "$e/rc" ]; then
    local rc; rc=$(cat "$e/rc")
    [ "$rc" = "0" ] || ck "test-nonzero-exit($rc)"
  fi
  [ -f "$e/stdout/cmd.out" ] || ck "stdout-missing"
  [ -f "$e/stderr/cmd.err" ] || ck "stderr-missing"
  [ -f "$e/command-log.jsonl" ] || ck "command-log-missing"
  [ -f "$e/artifact-manifest.json" ] || ck "artifact-manifest-missing"
  [ -f "$e/git-before.json" ] || ck "git-before-missing"
  [ -f "$e/git-after.json" ] || ck "git-after-missing"

  # required tests must actually have been executed
  if [ -f "$c" ] && [ -f "$e/command-log.jsonl" ]; then
    local want have
    want=$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]));print(len(d.get("required_tests") or []))' "$c" 2>/dev/null || echo 0)
    have=$(wc -l < "$e/command-log.jsonl" | tr -d ' ')
    if [ "${want:-0}" -gt 0 ] && [ "${have:-0}" -lt "$want" ]; then ck "tests-incomplete($have/$want)"; fi
    # a declared test-count that disagrees with the contract is also incomplete
    if [ -f "$e/test-count" ]; then
      local claimed; claimed=$(cat "$e/test-count")
      [ "${want:-0}" -gt 0 ] && [ "${claimed:-0}" -lt "$want" ] && ck "tests-incomplete-claimed($claimed/$want)"
    fi
  fi

  [ -f "$d/gate/forbidden_write" ] && ck "forbidden-external-write"

  # hash mismatch
  if [ -f "$e/patch-hash" ] && [ -f "$c" ]; then
    local exp got; exp=$(_jget "$c" patch_sha256); got=$(cat "$e/patch-hash")
    [ -n "$exp" ] && [ "$exp" != "$got" ] && ck "patch-hash-mismatch"
  fi
  # artifact manifest identity: every listed file must hash to its recorded value
  if [ -f "$e/artifact-manifest.json" ]; then
    local ok=1 line p h cur
    while IFS= read -r line; do
      p=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["path"])' "$line" 2>/dev/null || echo "")
      h=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["sha256"])' "$line" 2>/dev/null || echo "")
      [ -n "$p" ] || continue
      cur=$(shasum -a 256 "$d/$p" 2>/dev/null | awk '{print $1}')
      [ -n "$cur" ] && [ "$cur" != "$h" ] && ok=0
    done < "$e/artifact-manifest.json"
    [ "$ok" = 1 ] || ck "artifact-hash-mismatch"
  fi

  # running child still alive
  if [ -f "$e/pid" ]; then
    local p; p=$(cat "$e/pid")
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && ck "child-process-alive($p)"
  fi
  [ -f "$e/reused-prior-pass" ] && ck "reused-prior-pass"
  [ -f "$e/interrupted" ] && ck "suite-interrupted"

  # independent audit
  local audit_ok=0 audit_kind="" mode
  mode=$(_jget "$c" mode); [ -n "$mode" ] || mode="test"
  if [ ! -f "$a" ]; then
    ck "audit-missing"
  else
    local av; av=$(_jget "$a" verdict)
    audit_kind=$(_jget "$a" auditor_kind)
    case "$av" in
      PASS) audit_ok=1;;
      CONFLICT) ck "audit-conflict";;
      UNAVAILABLE) ck "audit-unavailable";;
      *) ck "audit-not-pass($av)";;
    esac
    # fake auditor is only admissible in test mode
    if [ "$audit_kind" = "fake" ] && [ "$mode" != "test" ]; then
      audit_ok=0; ck "fake-auditor-in-production"
    fi
    # auditor workspace must differ from the executor workspace
    local aw ew
    aw=$(_jget "$d/auditor/session.json" workdir)
    ew=$(cat "$e/wd" 2>/dev/null || echo "")
    if [ -n "$aw" ] && [ -n "$ew" ] && [ "$aw" = "$ew" ]; then ck "auditor-executor-same-workspace"; fi
  fi

  if [ "${#reasons[@]}" -eq 0 ] && [ "$audit_ok" = 1 ]; then
    verdict=VERIFIED_PASS
  elif printf '%s\n' "${reasons[@]:-}" | grep -qE "audit-missing|audit-unavailable"; then
    # only the audit is missing; the rest of the evidence is clean
    verdict=AUDIT_UNAVAILABLE
  elif printf '%s\n' "${reasons[@]:-}" | grep -qE "test-nonzero-exit|stdout-missing|stderr-missing|contract-missing"; then
    verdict=REWORK
  else
    verdict=HOLD
  fi

  mkdir -p "$d/gate"
  printf '{"run_id":"%s","verdict":"%s","reasons":[' "$id" "$verdict" > "$d/gate/verdict.json"
  local first=1 r
  for r in "${reasons[@]:-}"; do [ -n "$r" ] || continue; [ $first = 1 ] && first=0 || printf ',' >> "$d/gate/verdict.json"; printf '"%s"' "$r" >> "$d/gate/verdict.json"; done
  printf ']}\n' >> "$d/gate/verdict.json"
  { echo "# Judge verdict: $verdict"; echo; echo "run: $id"; echo "mode: $mode"; echo; echo "reasons:"; for r in "${reasons[@]:-}"; do [ -n "$r" ] && echo "- $r"; done; } > "$d/gate/summary.md"
  echo "VERDICT=$verdict reasons=${reasons[*]:-none}"
  [ "$verdict" = VERIFIED_PASS ]
}

case "${1:-}" in
  run) shift; judge "$@" ;;
  *) echo "usage: fm-unattended-judge.sh run <run_id>" >&2; exit 2 ;;
esac
