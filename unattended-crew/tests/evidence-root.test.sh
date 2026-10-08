#!/usr/bin/env bash
# evidence-root.test.sh - durable, configurable evidence root: explicit config,
# canary-path compatibility, creation/permissions/collision, path-escape
# prevention, re-read after restart, and fail-closed on missing/unreadable.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CFG="$UCX/fm-unattended-config.sh"
FIX="$TESTS_DIR/fixtures"
mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }

# 1. no config => canary-compatible default path; evidence persists across resume
new_home
run_uc init --batch b --contract "$FIX/normal.contract.json" >/dev/null
run_uc run --batch b >/dev/null
{ [ "$(sed -n 's/^evidence_root=//p' "$UC_HOME/batches/b/batch.meta")" = "" ] \
  && [ -f "$UC_HOME/batches/b/evidence/runs/t1/executor/rc" ]; } \
  && ok "no config: default canary path used and recorded empty" \
  || no "default evidence root (meta=$(sed -n 's/^evidence_root=//p' "$UC_HOME/batches/b/batch.meta"))"
n1=$(wc -l < "$UC_HOME/batches/b/state.jsonl")
run_uc resume --batch b >/dev/null
n2=$(wc -l < "$UC_HOME/batches/b/state.jsonl")
[ "$n1" = "$n2" ] && ok "restart re-reads the same evidence, no re-run" || no "resume changed a finished batch ($n1->$n2)"
cleanup_home

# 2. explicit durable root: created, 0700, stamped, evidence lands there
new_home
ER=$(mktemp -d "${TMPDIR:-/tmp}/uc-ev.XXXXXX")/evroot
UC_EVIDENCE_ROOT="$ER" run_uc init --batch b --contract "$FIX/normal.contract.json" >/dev/null
UC_EVIDENCE_ROOT="$ER" run_uc run --batch b >/dev/null
{ [ "$(sed -n 's/^evidence_root=//p' "$UC_HOME/batches/b/batch.meta")" = "$ER/b" ] \
  && [ -f "$ER/b/runs/t1/executor/rc" ] \
  && [ "$(cat "$ER/b/.batch")" = b ]; } \
  && ok "explicit root: per-batch dir, marker, evidence recorded" \
  || no "explicit root (per=$ER/b meta=$(sed -n 's/^evidence_root=//p' "$UC_HOME/batches/b/batch.meta"))"
[ "$(mode_of "$ER/b")" = 700 ] && ok "explicit root: per-batch dir mode 0700" || no "mode=$(mode_of "$ER/b")"
# restart re-reads the SAME recorded root even if the env var is now unset
n1=$(wc -l < "$UC_HOME/batches/b/state.jsonl")
run_uc resume --batch b >/dev/null
{ [ "$(wc -l < "$UC_HOME/batches/b/state.jsonl")" = "$n1" ] && [ -f "$ER/b/runs/t1/executor/rc" ]; } \
  && ok "restart: recorded root re-read with env unset" || no "root not re-read after restart"
rm -rf "$(dirname "$ER")"; cleanup_home

# 3. config-file evidence_root is honored (home-local config)
new_home
ER2=$(mktemp -d "${TMPDIR:-/tmp}/uc-ev2.XXXXXX")/dur
mkdir -p "$UC_HOME/config"
printf '{"evidence_root":"%s"}\n' "$ER2" > "$UC_HOME/config/unattended-crew.json"
run_uc init --batch b --contract "$FIX/normal.contract.json" >/dev/null
run_uc run --batch b >/dev/null
[ "$(sed -n 's/^evidence_root=//p' "$UC_HOME/batches/b/batch.meta")" = "$ER2/b" ] \
  && ok "config evidence_root: honored and recorded" \
  || no "config root (meta=$(sed -n 's/^evidence_root=//p' "$UC_HOME/batches/b/batch.meta"))"
rm -rf "$(dirname "$ER2")"; cleanup_home

# 4. path escape refused (a `..` segment)
W=$(mktemp -d "${TMPDIR:-/tmp}/uc-esc.XXXXXX")
UC_HOME="$W/home" UC_EVIDENCE_ROOT="$W/a/../b" "$CFG" evidence-root --batch b --home "$W/home" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "path escape ('..' segment) refused" || no "escape not refused"
# 4b. collision: existing per-batch dir stamped for another batch
mkdir -p "$W/root/b"; printf 'other\n' > "$W/root/b/.batch"
UC_HOME="$W/home" UC_EVIDENCE_ROOT="$W/root" "$CFG" evidence-root --batch b --home "$W/home" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "collision with a different batch refused" || no "collision not refused"
# 4c. root that is a file refused
printf 'x\n' > "$W/afile"
UC_HOME="$W/home" UC_EVIDENCE_ROOT="$W/afile" "$CFG" evidence-root --batch b --home "$W/home" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "file-as-root refused" || no "file-as-root not refused"
# 4d. missing with --no-create refused (fail-closed)
UC_HOME="$W/home" UC_EVIDENCE_ROOT="$W/never" "$CFG" evidence-root --batch b --home "$W/home" --no-create >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "missing evidence root with --no-create refused" || no "no-create not fail-closed"
# 4e. bad batch id refused
UC_HOME="$W/home" "$CFG" evidence-root --batch '../evil' --home "$W/home" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "bad batch id ('..') refused" || no "bad batch id not refused"
rm -rf "$W"

echo "# evidence-root.test.sh PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
