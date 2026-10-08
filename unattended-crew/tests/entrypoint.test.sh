#!/usr/bin/env bash
# entrypoint.test.sh - mounted entrypoint wrapper (call contract, role
# separation) and the install / unmount / rollback mechanics: manifest, target
# ownership, no-overwrite, per-file hashes, partial-install rollback, idempotent
# unmount, verify command, and an isolated rehearsal (never the home).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAP="$UCX/../bin/fm-unattended.sh"
INST="$UCX/../bin/fm-unattended-install.sh"
FIX="$TESTS_DIR/fixtures"

# 1. role separation: only the captain entrypoint may run
UC_HOME=$(mktemp -d "${TMPDIR:-/tmp}/uc-ep.XXXXXX") UC_ENTRYPOINT_ROLE=watcher UC_IMPL_DIR="$UCX" "$WRAP" status --batch b >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "wrapper: refuses a non-captain role" || no "wrapper role guard failed"

# 2. call contract: wrapper drives a batch through the coordinator unchanged
new_home; unset UC_IMPL_DIR
FM_UNATTENDED_ADAPTER=fake "$WRAP" init --batch b --contract "$FIX/normal.contract.json" >/dev/null 2>&1
FM_UNATTENDED_ADAPTER=fake "$WRAP" run --batch b >/dev/null 2>&1
[ "$(task_state b t1)" = VERIFIED_PASS ] && ok "wrapper: pass-through run => VERIFIED_PASS" || no "wrapper run (t1=$(task_state b t1))"
cleanup_home

# 3. explicit install/uninstall file list
list=$("$INST" file-list)
{ printf '%s' "$list" | grep -q 'implementation/fm-unattended.sh -> bin/fm-unattended-coordinator.sh' \
  && printf '%s' "$list" | grep -q 'bin/fm-unattended.sh -> bin/fm-unattended.sh'; } \
  && ok "install: explicit file list names wrapper + coordinator" || no "file list ($list)"

# 4. isolated install -> verify -> run -> unmount rehearsal
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/uc-root.XXXXXX")
"$INST" install --root "$ROOT" >/dev/null 2>&1 && "$INST" verify --root "$ROOT" >/dev/null 2>&1
{ [ "$?" -eq 0 ] && [ -x "$ROOT/bin/fm-unattended.sh" ] && [ -x "$ROOT/bin/fm-unattended-coordinator.sh" ] \
  && [ -f "$ROOT/.fm-unattended-manifest.json" ] \
  && python3 -c 'import json,sys
o=[json.loads(l) for l in open(sys.argv[1])]
assert any(x["path"]=="bin/fm-unattended.sh" and len(x.get("sha256",""))==64 for x in o)' "$ROOT/.fm-unattended-manifest.json"; } \
  && ok "install: manifest with per-file hashes; verify passes" || no "install/verify failed"
# installed entrypoint resolves the mounted coordinator + siblings and runs
H2=$(mktemp -d "${TMPDIR:-/tmp}/uc-h2.XXXXXX")
UC_HOME="$H2" FM_UNATTENDED_ADAPTER=fake "$ROOT/bin/fm-unattended.sh" init --batch b --contract "$FIX/normal.contract.json" >/dev/null 2>&1
out=$(UC_HOME="$H2" "$ROOT/bin/fm-unattended.sh" status --batch b 2>&1)
{ printf '%s' "$out" | grep -q 't1: QUEUED' \
  && [ -x "$ROOT/bin/fm-unattended-config.sh" ]; } \
  && ok "installed entrypoint: resolves mounted coordinator + siblings" || no "installed entrypoint (out=$out)"
rm -rf "$H2"
"$INST" uninstall --root "$ROOT" >/dev/null 2>&1
{ [ ! -e "$ROOT/bin/fm-unattended.sh" ] && [ ! -e "$ROOT/.fm-unattended-manifest.json" ]; } \
  && ok "uninstall: removes owned files and manifest" || no "uninstall left files"
"$INST" uninstall --root "$ROOT" >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "uninstall: idempotent second run is a no-op" || no "uninstall not idempotent"
rm -rf "$ROOT"

# 5. no-overwrite: an existing unowned target is refused and untouched
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/uc-root2.XXXXXX"); mkdir -p "$ROOT/bin"
printf 'USER CONTENT\n' > "$ROOT/bin/fm-unattended-judge.sh"
"$INST" install --root "$ROOT" >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 3 ] && [ "$(cat "$ROOT/bin/fm-unattended-judge.sh")" = "USER CONTENT" ] && [ ! -e "$ROOT/.fm-unattended-manifest.json" ]; } \
  && ok "no-overwrite: unowned existing target refused, unchanged, no manifest" || no "no-overwrite (rc=$rc)"
rm -rf "$ROOT"

# 6. idempotent install (owned targets may be re-installed)
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/uc-root3.XXXXXX")
"$INST" install --root "$ROOT" >/dev/null 2>&1; r1=$?
"$INST" install --root "$ROOT" >/dev/null 2>&1; r2=$?
"$INST" verify --root "$ROOT" >/dev/null 2>&1; r3=$?
{ [ "$r1" -eq 0 ] && [ "$r2" -eq 0 ] && [ "$r3" -eq 0 ]; } \
  && ok "install: idempotent re-install stays valid" || no "idempotent install (r1=$r1 r2=$r2 r3=$r3)"
# user-modified file is preserved on uninstall
printf '\n# local edit\n' >> "$ROOT/bin/fm-unattended-quota.sh"
"$INST" uninstall --root "$ROOT" >/dev/null 2>&1
{ [ -f "$ROOT/bin/fm-unattended-quota.sh" ] && [ ! -e "$ROOT/bin/fm-unattended-judge.sh" ]; } \
  && ok "uninstall: preserves a user-modified file, removes the rest" || no "modified-file preservation"
rm -rf "$ROOT"

# 7. partial-install failure handling: injected mid-commit failure rolls back
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/uc-root4.XXXXXX")
FM_UNATTENDED_INSTALL_FAIL_AT=3 "$INST" install --root "$ROOT" >/dev/null 2>&1; rc=$?
{ [ "$rc" -ne 0 ] && [ ! -e "$ROOT/.fm-unattended-manifest.json" ] && [ ! -e "$ROOT/bin/fm-unattended.sh" ] \
  && [ -z "$(ls -A "$ROOT/bin" 2>/dev/null)" ]; } \
  && ok "partial install: injected failure rolls back every file" || no "partial rollback (rc=$rc leftover=$(ls -A "$ROOT/bin" 2>/dev/null | tr '\n' ' '))"
rm -rf "$ROOT"

# 8. isolated rehearsal (temp dir) passes; unsafe roots refused
"$INST" rehearse >/dev/null 2>&1 && ok "rehearse: install -> verify -> unmount -> clean PASS" || no "rehearse failed"
"$INST" install --root / >/dev/null 2>&1; [ "$?" -eq 2 ] && ok "install: refuses unsafe root /" || no "unsafe root not refused"
"$INST" install >/dev/null 2>&1; [ "$?" -eq 2 ] && ok "install: requires an explicit --root" || no "missing root not refused"

echo "# entrypoint.test.sh PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
