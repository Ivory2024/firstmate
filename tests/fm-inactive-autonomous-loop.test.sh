#!/usr/bin/env bash
# Behavior coverage for autonomous reconciliation on inactive scan entry points.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-inactive-autonomous-loop)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

root="$TMP_ROOT/root"
home="$TMP_ROOT/home"
mkdir -p "$root/bin" "$home/state"
for script in "$ROOT"/bin/*.sh; do
  ln -s "$script" "$root/bin/$(basename "$script")"
done
rm "$root/bin/fm-autonomous-loop.sh"
cat > "$root/bin/fm-autonomous-loop.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_AUTONOMOUS_LOG:?}"
exit "${FM_AUTONOMOUS_RC:-0}"
SH
chmod +x "$root/bin/fm-autonomous-loop.sh"

run_scan() {
  FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_AUTONOMOUS_LOG="$TMP_ROOT/reconcile.log" \
    FM_INACTIVE_RECONCILE_BUDGET_SECS=1 FM_INACTIVE_RECONCILE_SECS=60 \
    "$root/bin/fm-inactive-reconcile.sh" scan "$@"
}

run_scan --startup || fail "startup scan failed"
assert_equals "reconcile --startup" "$(cat "$TMP_ROOT/reconcile.log")" \
  "startup scan did not invoke autonomous reconciliation with startup context"

: > "$TMP_ROOT/reconcile.log"
if FM_AUTONOMOUS_RC=1 run_scan >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr"; then
  :
else
  fail "autonomous reconciliation failure aborted the scan"
fi
assert_equals "reconcile" "$(cat "$TMP_ROOT/reconcile.log")" \
  "regular scan did not invoke autonomous reconciliation"
assert_equals "" "$(cat "$TMP_ROOT/stdout" "$TMP_ROOT/stderr")" \
  "quiet scan emitted autonomous reconciliation output"

pass "fm-inactive-autonomous-loop"
