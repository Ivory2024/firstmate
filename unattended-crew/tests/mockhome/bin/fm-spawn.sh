#!/usr/bin/env bash
# mock fm-spawn.sh - stands in for bin/fm-spawn.sh in the offline real-E2E test.
# It creates the same durable records a real scout spawn produces (state/<id>.meta,
# state/<id>.status, data/<id>/report.md) from the recorded canary fixture, and
# runs a background writer that appends the completion event. It makes NO
# provider call. Failure injection is by environment variable.
#
# This is a TEST DOUBLE for the real firstmate home; production never uses it.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
id=$1; shift || true
[ -n "$id" ] || { echo "mock fm-spawn: need id" >&2; exit 2; }
mkdir -p "$ROOT/state" "$ROOT/data/$id" "$ROOT/worktrees/$id"

is_audit=0; case "$id" in *-audit) is_audit=1;; esac

if [ "$is_audit" = 1 ]; then
  if [ "${MOCK_AUDIT_SPAWN_FAIL:-0}" = 1 ]; then echo "mock: auditor spawn refused" >&2; exit 1; fi
elif [ "${MOCK_SPAWN_FAIL:-0}" = 1 ]; then
  echo "mock: spawn refused" >&2; exit 1
fi

# A distinct worktree per session: the auditor must never share the executor's.
if [ "$is_audit" = 1 ] && [ "${MOCK_SAME_WORKSPACE:-0}" = 1 ]; then
  wt="$ROOT/worktrees/${id%-audit}"
else
  wt="$ROOT/worktrees/$id"
fi
window="firstmate:fm-$id"

cat > "$ROOT/state/$id.meta" <<EOF
window=$window
endpoint_task_id=$id
worktree=$wt
project=$ROOT/project
harness=opencode
kind=scout
model=opencode/mock-fixture
spawn_gen=s$(date +%s)
EOF
printf 'working [at=%s]: spawned\n' "$(date +%s)" > "$ROOT/state/$id.status"

# the worker's durable report (recorded canary fixture)
if [ "$is_audit" = 1 ]; then
  src="$ROOT/fixture/auditor-report.md"
else
  src="$ROOT/fixture/executor-report.md"
fi
if [ "${MOCK_NO_REPORT:-0}" = 1 ]; then
  :
elif [ "$is_audit" = 1 ] && [ -n "${MOCK_AUDIT_VERDICT:-}" ]; then
  printf '# Mock audit report\n\nTask: audit the executor evidence.\n\n**Verdict: %s**\n' "$MOCK_AUDIT_VERDICT" > "$ROOT/data/$id/report.md"
elif [ "$is_audit" = 1 ] && [ "${MOCK_NO_VERDICT:-0}" = 1 ]; then
  printf '# Mock audit report\n\nTask: audit the executor evidence.\n\nNo verdict line was produced.\n' > "$ROOT/data/$id/report.md"
else
  cp "$src" "$ROOT/data/$id/report.md"
fi

echo "window=$window"
echo "endpoint_task_id=$id"
echo "worktree=$wt"
echo "spawned $id harness=opencode kind=scout window=$window worktree=$wt"

status="$ROOT/state/$id.status"
if [ "${MOCK_DEAD:-0}" = 1 ]; then
  printf 'failed [at=%s]: endpoint died during spawn\n' "$(date +%s)" >> "$status"
  exit 0
fi
if [ "${MOCK_FAIL:-0}" = 1 ]; then
  ( sleep "${MOCK_DONE_DELAY:-1}"; printf 'failed [at=%s]: mock executor failure\n' "$(date +%s)" >> "$status" ) >/dev/null 2>&1 &
  exit 0
fi
if [ "${MOCK_NO_DONE:-0}" = 1 ]; then exit 0; fi

line_msg="mock executor complete"
[ "$is_audit" = 1 ] && line_msg="audit complete - verdict ${MOCK_AUDIT_VERDICT:-PASS}"
( sleep "${MOCK_DONE_DELAY:-1}"; printf 'done [at=%s]: %s\n' "$(date +%s)" "$line_msg" >> "$status" ) >/dev/null 2>&1 &
exit 0
