#!/usr/bin/env bash
# Pins Agenttrail Kitchen's 12-worktree selection and active-state priority.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-agenttrail-kitchen.sh
. "$ROOT/bin/fm-agenttrail-kitchen.sh"

snapshot=$(jq -n '
  ([{id:"unknown",state:"unknown"},{id:"failed",state:"failed"},{id:"done",state:"done"}]
   + [range(0;6) | {id:("working-" + tostring),state:"working"}]
   + [range(0;6) | {id:("validating-" + tostring),state:"validating"}]) as $tasks
  | {in_flight:$tasks,paths:[$tasks[] | {id,worktree:("/fixture/" + .id)}]}
') || fail "could not build in-flight fixture"

selection=$(fm_agenttrail_select_json "$snapshot" 12) || fail "selection failed"
[ "$(jq '.selected | length' <<<"$selection")" -eq 12 ] \
  || fail "selection did not enforce the 12-project cap"
[ "$(jq -r '.selected[0].id' <<<"$selection")" = working-0 ] \
  || fail "working tasks did not precede earlier terminal rows"
[ "$(jq -r '.selected[1].id' <<<"$selection")" = working-1 ] \
  || fail "working task snapshot order was not stable"
[ "$(jq '[.selected[] | select(.state == "working" or .state == "validating")] | length' <<<"$selection")" -eq 12 ] \
  || fail "unknown, failed, or done tasks displaced active tasks"
[ "$(jq -r '[.omitted[].id] | sort | join(",")' <<<"$selection")" = "done,failed,unknown" ] \
  || fail "overflow did not identify every lower-priority task"
pass "Agenttrail Kitchen selection caps at 12 and prioritizes working/validating tasks"
