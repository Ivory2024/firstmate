#!/usr/bin/env bash
# Executable coverage for the reconcile loops' kind=secondmate exclusion.
#
# The reconcile owns the TASK lifecycle registry. A persistent secondmate meta
# records a provisioned firstmate home, not a backlog task (AGENTS.md "Backlog
# contract": "It tracks work items only, never agents; persistent secondmates
# never appear as backlog items"), and its state read is a remote round trip
# that must never ride the poll budget the inactive scan and this reconcile
# share. These cases pin both halves of that contract:
#
#   * the exclusion holds (no lifecycle record, no state read for a mate), and
#   * the exclusion hides nothing (orphan inventory, other task kinds, the
#     failure path, and the resume/restart path all still run).
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-autonomous-loop-secondmate)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

root="$TMP_ROOT/root"
home="$TMP_ROOT/home"
pool="$TMP_ROOT/treehouse/firstmate-pool"
mkdir -p "$root/bin" "$home/state" "$home/data" "$home/project" \
  "$pool/ref-wt" "$pool/mate-wt" "$pool/unref-wt"
for script in "$ROOT"/bin/*.sh; do
  ln -s "$script" "$root/bin/$(basename "$script")"
done

# Fake crew-state: records every task it is asked about, so a reconcile that
# classifies a mate is visible even when nothing else changes.
rm "$root/bin/fm-crew-state.sh"
cat > "$root/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "${FM_CREW_STATE_LOG:?}"
case "${1:-}" in
  *-done) printf 'state: done · source: fake · complete\n' ;;
  *-failed) printf 'state: failed · source: fake · failed\n' ;;
  *) printf 'state: unknown · source: fake · no external result\n' ;;
esac
SH

# Fake control: logs the relaunch, and fails for the one task that models a
# relaunch error so the pass's failure path is exercised in the same run.
rm "$root/bin/fm-control.sh"
cat > "$root/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_CONTROL_LOG:?}"
[ "${1:-}" != "resume-fail" ]
SH

# Fake spawn: reconcile must never dispatch anything; a call here is a failure
# signal asserted at the end rather than an error that muddies other cases.
rm "$root/bin/fm-spawn.sh"
cat > "$root/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_SPAWN_LOG:?}"
SH
chmod +x "$root/bin/fm-crew-state.sh" "$root/bin/fm-control.sh" "$root/bin/fm-spawn.sh"

write_lifecycle() { # <id> <step> [retry]
  cat > "$home/state/task-lifecycle/$1.lifecycle" <<EOF
current_step=$2
lane=$1-lane
dependencies=
next_action=awaiting_dispatch
retry_state=${3:-attempt=0,last_error=,last_retry=0}
state_version=1
state_machine_version=1
EOF
}

mkdir -p "$home/state/task-lifecycle"

# The pool inventory globs "$TREEHOUSE_ROOT"/firstmate-*/ and then "$pool"/*/,
# so a slot is framed as <root>/firstmate-<x>//<slot>/ (the glob's trailing
# slash plus the pool's own). A meta records that exact string, which is what
# the comparison matches, so the fixtures use the same framing.
write_meta() { # <id> <kind> <slot-name>
  local slot='' mode=local-only
  [ -z "$3" ] || slot="$pool//$3/"
  [ "$2" = secondmate ] && mode=secondmate
  cat > "$home/state/$1.meta" <<EOF
window=remote:$1
endpoint_task_id=$1
worktree=$slot
project=$home/project
harness=codex
kind=$2
mode=$mode
yolo=off
lane=$1-lane
spawn_gen=old
EOF
}

# The subject: a persistent secondmate with NO lifecycle record.
write_meta mate secondmate mate-wt
# A legacy persistent secondmate that still carries a lifecycle record from
# before the exclusion, parked at READY. The lane dispatcher must still refuse
# to treat it as a dispatchable task.
write_meta mate-stale secondmate ""
write_lifecycle mate-stale READY
# Other task kinds that must still reconcile.
write_meta ship-done ship ref-wt
write_lifecycle ship-done ASSIGNED
write_meta scout-failed scout ""
write_lifecycle scout-failed RUNNING
# Resume path (relaunch succeeds) and its failure sibling (relaunch fails).
write_meta resume-task ship ""
write_lifecycle resume-task ASSIGNED
write_meta resume-fail ship ""
write_lifecycle resume-fail ASSIGNED

# Orphan inventory: a marker with no meta is reported whatever its kind, and a
# mate-shaped id is not exempt.
touch "$home/state/.subsuper-seen-status-orphan-task"
touch "$home/state/.subsuper-seen-status-mate-gone"

run_reconcile() {
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_CREW_STATE_LOG="$TMP_ROOT/crew-state.log" \
    FM_CONTROL_LOG="$TMP_ROOT/control.log" \
    FM_SPAWN_LOG="$TMP_ROOT/spawn.log" \
    TREEHOUSE_ROOT="$TMP_ROOT/treehouse" \
    "$root/bin/fm-autonomous-loop.sh" reconcile
}

: > "$TMP_ROOT/crew-state.log"
: > "$TMP_ROOT/control.log"
rm -f "$TMP_ROOT/spawn.log"
run_reconcile > "$TMP_ROOT/reconcile.out" 2>&1 || fail "reconcile exited non-zero"

# --- (1) the exclusion holds ------------------------------------------------
assert_absent "$home/state/task-lifecycle/mate.lifecycle" \
  "reconcile created a lifecycle record for a persistent secondmate"
assert_absent "$home/state/.recovery-lease-mate-attempt-1" \
  "reconcile started a resume attempt for a persistent secondmate"
if grep -qx mate "$TMP_ROOT/crew-state.log"; then
  fail "reconcile read a persistent secondmate's state (remote round trip on the shared budget)"
fi
if grep -qx mate-stale "$TMP_ROOT/crew-state.log"; then
  fail "reconcile read a legacy persistent secondmate's state"
fi
if [ -s "$TMP_ROOT/spawn.log" ]; then
  fail "reconcile dispatched work, which a read-only reconcile pass must never do"
fi
# A legacy mate lifecycle record parked at READY is held by the dispatcher's own
# kind guard, never assigned, so the exclusion cannot strand a mate as work.
if grep -q '^current_step=ASSIGNED$' "$home/state/task-lifecycle/mate-stale.lifecycle"; then
  fail "a legacy persistent secondmate lifecycle record was assigned as work"
fi

# --- (2) the exclusion hides no orphan --------------------------------------
out=$(cat "$TMP_ROOT/reconcile.out")
assert_contains "$out" "ORPHAN marker: $home/state/.subsuper-seen-status-orphan-task" \
  "orphan marker for an ordinary task was not reported"
assert_contains "$out" "ORPHAN marker: $home/state/.subsuper-seen-status-mate-gone" \
  "orphan marker whose id looks like a secondmate was not reported"
assert_contains "$out" "=== Treehouse Pool Inventory ===" \
  "the pool inventory did not run"
assert_contains "$out" "UNREFERENCED worktree: $pool//unref-wt/" \
  "an unreferenced pool worktree was not reported as an orphan"
if printf '%s\n' "$out" | grep -Fq "UNREFERENCED worktree: $pool//ref-wt/"; then
  fail "an ordinary task's referenced worktree was reported as unreferenced"
fi
if printf '%s\n' "$out" | grep -Fq "UNREFERENCED worktree: $pool//mate-wt/"; then
  fail "a secondmate's referenced worktree was reported as unreferenced"
fi

# --- (3) other task kinds still reconcile -----------------------------------
assert_equals DONE "$(sed -n 's/^current_step=//p' "$home/state/task-lifecycle/ship-done.lifecycle")" \
  "a ship task did not sync external done"
assert_equals FAILED "$(sed -n 's/^current_step=//p' "$home/state/task-lifecycle/scout-failed.lifecycle")" \
  "a scout task did not sync external failed"

# --- (4) the failure path ---------------------------------------------------
assert_contains "$out" "=== Reconcile complete " \
  "a failing resume aborted the reconcile pass"
assert_equals RECOVERY_HOLD "$(sed -n 's/^current_step=//p' "$home/state/task-lifecycle/resume-task.lifecycle")" \
  "a resumable task did not enter RECOVERY_HOLD after a successful relaunch"
assert_contains "$(cat "$home/state/task-lifecycle/resume-fail.lifecycle")" \
  "Auto-resume attempt 1 failed: fm_control_relaunch returned error" \
  "a failed relaunch was not recorded as evidence"
if grep -q '^current_step=RECOVERY_HOLD$' "$home/state/task-lifecycle/resume-fail.lifecycle"; then
  fail "a failed relaunch still entered RECOVERY_HOLD"
fi

# --- (5) the restart/resume path -------------------------------------------
assert_contains "$(cat "$TMP_ROOT/control.log")" "resume-task relaunch --note Auto-resume attempt 1" \
  "the resume path did not drive fm-control relaunch"
assert_contains "$(cat "$home/state/task-lifecycle/resume-task.lifecycle")" "retry_state=attempt=1" \
  "the resume attempt was not recorded durably for restart"

# A second pass is the restart: the mate stays excluded and no attempt repeats.
: > "$TMP_ROOT/crew-state.log"
run_reconcile > "$TMP_ROOT/reconcile2.out" 2>&1 || fail "second reconcile exited non-zero"
assert_absent "$home/state/task-lifecycle/mate.lifecycle" \
  "a restarted reconcile created a lifecycle record for a persistent secondmate"
if grep -qx mate "$TMP_ROOT/crew-state.log"; then
  fail "a restarted reconcile read a persistent secondmate's state"
fi
if grep -qx mate-stale "$TMP_ROOT/crew-state.log"; then
  fail "a restarted reconcile read a legacy persistent secondmate's state"
fi
assert_equals 1 "$(grep -c '^resume-task ' "$TMP_ROOT/control.log" | tr -d '[:space:]')" \
  "a restarted reconcile repeated a completed resume attempt"

pass "fm-autonomous-loop-secondmate"
