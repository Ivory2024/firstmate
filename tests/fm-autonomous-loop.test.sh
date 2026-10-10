#!/usr/bin/env bash
# Executable coverage for autonomous lane dispatch and dependency gating.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-autonomous-loop)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

root="$TMP_ROOT/root"
home="$TMP_ROOT/home"
mkdir -p "$root/bin" "$home/state/task-lifecycle" "$home/data"
for script in "$ROOT"/bin/*.sh; do
  ln -s "$script" "$root/bin/$(basename "$script")"
done
rm "$root/bin/fm-spawn.sh" "$root/bin/fm-crew-state.sh"
cat > "$root/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_DISPATCH_LOG:?}"
meta="${FM_HOME:?}/state/${1:?}.meta"
sed '/^spawn_gen=/d' "$meta" > "$meta.tmp"
printf 'spawn_gen=test\n' >> "$meta.tmp"
mv "$meta.tmp" "$meta"
touch "$FM_HOME/state/.fake-working-$1"
SH
cat > "$root/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
if [ -e "${FM_STATE_OVERRIDE:?}/.fake-working-${1:-}" ]; then
  printf 'state: working · source: fake · active\n'
else
  case "${1:-}" in
    *-done) printf 'state: done · source: fake · complete\n' ;;
    *-failed) printf 'state: failed · source: fake · failed\n' ;;
    *) printf 'state: unknown · source: fake · no external result\n' ;;
  esac
fi
SH
chmod +x "$root/bin/fm-spawn.sh" "$root/bin/fm-crew-state.sh"

write_task() {
  local id=$1 lane=$2 step=$3 deps=${4:-}
  mkdir -p "$home/data/$id"
  cat > "$home/state/$id.meta" <<EOF
lane=$lane
kind=ship
project=$home/project
mode=local-only
yolo=off
branch=fm/$id
base_branch=main
spawn_gen=old
EOF
  cat > "$home/state/task-lifecycle/$id.lifecycle" <<EOF
current_step=$step
lane=$lane
dependencies=$deps
next_action=awaiting_dispatch
state_version=1
EOF
}

mkdir -p "$home/project"
write_task failed-dep other FAILED
write_task blocked-task lane-a READY failed-dep
write_task missing-brief lane-a READY
write_task ready-task lane-a READY
cat > "$home/data/ready-task/brief.md" <<'EOF'
# Task
Dispatch this task.

Delivery contract: mode=local-only
Ship branch: fm/ready-task
EOF

FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_DISPATCH_LOG="$TMP_ROOT/spawn.log" \
  "$root/bin/fm-autonomous-loop.sh" lane-next lane-a >/dev/null

assert_equals "WAITING_EXTERNAL" "$(sed -n 's/^current_step=//p' "$home/state/task-lifecycle/blocked-task.lifecycle")" \
  "failed dependency did not hold the dependent"
assert_equals "failed_dependency:failed-dep" "$(sed -n 's/^blocking_reason=//p' "$home/state/task-lifecycle/blocked-task.lifecycle")" \
  "failed dependency was not named in the hold reason"
assert_equals "WAITING_EXTERNAL" "$(sed -n 's/^current_step=//p' "$home/state/task-lifecycle/missing-brief.lifecycle")" \
  "task without a brief was not held"
assert_equals "missing_brief:brief" "$(sed -n 's/^blocking_reason=//p' "$home/state/task-lifecycle/missing-brief.lifecycle")" \
  "missing brief was not named in the hold reason"
assert_equals "ASSIGNED" "$(sed -n 's/^current_step=//p' "$home/state/task-lifecycle/ready-task.lifecycle")" \
  "ready task was not assigned after spawn"
assert_equals "worker_started" "$(sed -n 's/^next_action=//p' "$home/state/task-lifecycle/ready-task.lifecycle")" \
  "dispatch intent was recorded without a completed spawn"
assert_equals "lane-dispatch:ready-task:old" "$(sed -n 's/^dispatch_key=//p' "$home/state/task-lifecycle/ready-task.lifecycle")" \
  "dispatch idempotency key was not persisted"
assert_contains "$(cat "$TMP_ROOT/spawn.log")" \
  "ready-task $home/project --mode local-only --yolo off --branch-prefix fm/ --base-branch main" \
  "lane progression did not invoke fm-spawn with the durable task contract"
assert_absent "$home/state/task-lifecycle.locks/ready-task.lane-dispatch.lock" \
  "successful dispatch left its task lease behind"
FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_DISPATCH_LOG="$TMP_ROOT/spawn.log" \
  "$root/bin/fm-autonomous-loop.sh" lane-next lane-a >/dev/null
assert_equals 1 "$(wc -l < "$TMP_ROOT/spawn.log" | tr -d '[:space:]')" \
  "a duplicate lane reconciliation spawned the task twice"

for lifecycle_state in READY ASSIGNED RUNNING TESTING REVIEWING FIXING RETESTING READY_FOR_MERGE MERGE_VERIFIED DEPLOYMENT_GATE WAITING_QUOTA WAITING_APPROVAL WAITING_EXTERNAL RECOVERY_HOLD ESCALATED; do
  for external_state in done failed; do
    id="${lifecycle_state,,}-$external_state"
    write_task "$id" "terminal-$id" "$lifecycle_state"
  done
done
marker="$home/state/.subsuper-seen-status-orphan-task"
touch "$marker"
FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-autonomous-loop.sh" reconcile >/dev/null
for lifecycle_state in READY ASSIGNED RUNNING TESTING REVIEWING FIXING RETESTING READY_FOR_MERGE MERGE_VERIFIED DEPLOYMENT_GATE WAITING_QUOTA WAITING_APPROVAL WAITING_EXTERNAL RECOVERY_HOLD ESCALATED; do
  assert_equals DONE "$(sed -n 's/^current_step=//p' "$home/state/task-lifecycle/${lifecycle_state,,}-done.lifecycle")" \
    "$lifecycle_state did not sync external done"
  assert_equals FAILED "$(sed -n 's/^current_step=//p' "$home/state/task-lifecycle/${lifecycle_state,,}-failed.lifecycle")" \
    "$lifecycle_state did not sync external failed"
done
assert_equals 1 "$([ -f "$marker" ] && echo 1 || echo 0)" "orphan inventory moved or deleted its marker"
assert_absent "$home/state/quarantine/orphan-markers" "reconcile created a quarantine for orphan markers"

pass "fm-autonomous-loop"
