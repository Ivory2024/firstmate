#!/usr/bin/env bash
# fm-unattended.sh - mounted captain entrypoint for the unattended crew
# orchestrator.
#
# This is the ONLY captain-facing way to drive a batch. It is a thin wrapper: it
# resolves the implementation directory, records the config/evidence-root
# choice, enforces role separation, and execs the coordinator with the unchanged
# call contract:
#
#   fm-unattended.sh init|run|resume|status|next|handoff --batch B [--contract C]
#
# Role separation (never a watcher/scheduler):
#   - It never reads or writes state/.afk (the /afk posture) and never drains or
#     acks the durable wake queue. It only creates its own batch tree.
#   - It refuses to run when UC_ENTRYPOINT_ROLE is anything but `captain`.
#   - The firstmate watcher/scheduler stays the supervisor; this controller is a
#     producer of durable task state.
#
# Mounting: this repository ships the whole suite in place, so there is no
# install step; bin/fm-unattended-install.sh is not part of this tree. The
# implementation directory resolves in this order: $UC_IMPL_DIR, then the
# coordinator shipped beside this wrapper in bin/, then ../implementation for an
# externally mounted copy. UC_HOME is mandatory (the batch root); UC_CONFIG_FILE
# points at a config file outside the implied locations.
set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Role separation: only the captain entrypoint may run.
if [ "${UC_ENTRYPOINT_ROLE:-captain}" != captain ]; then
  echo "fm-unattended: refusing to run with UC_ENTRYPOINT_ROLE=${UC_ENTRYPOINT_ROLE} (not the captain entrypoint)" >&2
  exit 2
fi

# Resolve the coordinator (installed sibling first, then the repo implementation).
if [ -n "${UC_IMPL_DIR:-}" ]; then
  IMPL=$UC_IMPL_DIR
elif [ -x "$SELF_DIR/fm-unattended-coordinator.sh" ]; then
  IMPL=$SELF_DIR
else
  IMPL=$(cd "$SELF_DIR/../implementation" 2>/dev/null && pwd) || {
    echo "fm-unattended: cannot locate implementation dir from $SELF_DIR" >&2; exit 2; }
fi

COORD="$IMPL/fm-unattended-coordinator.sh"
[ -x "$COORD" ] || COORD="$IMPL/fm-unattended.sh"
[ -x "$COORD" ] || { echo "fm-unattended: no coordinator in $IMPL" >&2; exit 2; }

: "${UC_HOME:?fm-unattended: set UC_HOME to the batch root}"
export UC_IMPL_DIR="$IMPL"
export UC_CONFIG_FILE="${UC_CONFIG_FILE:-}"
exec "$COORD" "$@"
