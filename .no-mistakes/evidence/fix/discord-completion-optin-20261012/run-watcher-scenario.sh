#!/usr/bin/env bash
# Live end-to-end watcher scenario for fix/discord-completion-optin-20261012.
#
# The user-visible symptom in the intent is that bin/fm-watch.sh logs a triage
# failure on every non-zero completion-bridge exit. This drives the REAL
# fm-watch.sh (not a stub) over a disposable credential-free home and asserts:
#   Case A (token + malformed channel): the watcher DOES log the bridge failure,
#           which proves the notification path really runs.
#   Case B (no token): the watcher does NOT log any Discord failure.
set -u
ROOT=${ROOT:?ROOT must point at the gate worktree}
export ROOT
# shellcheck source=/dev/null
. "$ROOT/tests/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-discord-optin-watch)

PASS_COUNT=0
FAIL_COUNT=0
ok()  { PASS_COUNT=$((PASS_COUNT + 1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '  FAIL: %s\n' "$1"; }

# Run the real watcher once against a disposable home holding one done: status.
# Echoes nothing; leaves the triage log at $dir/state/.watch-triage.log.
run_watch_case() { # <name> [extra env assignments...]
  local name=$1; shift
  local dir state fakebin out pid
  dir=$(make_case "$name")
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  printf 'done: wired up the new endpoint\n' > "$state/task.status"
  export FM_FAKE_CREW_STATE='state: done · source: fake'
  env -u FM_DISCORD_TOKEN -u FM_DISCORD_EXCLUDE_CHANNELS -u FMX_ENV_FILE \
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$@" "$WATCH" > "$out" 2>"$dir/watch.err" &
  pid=$!
  if ! wait_for_exit "$pid" 200; then
    printf '  (watcher did not exit; out=%s)\n' "$(cat "$out")" >&2
  fi
  printf '%s\n' "$dir"
}

printf '=====================================================================\n'
printf 'Watcher case A: token + unusable channel -> failure IS logged (proves path)\n'
printf '=====================================================================\n'
dirA=$(run_watch_case disc-a FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=not-a-channel)
logA="$dirA/state/.watch-triage.log"
if [ -f "$logA" ] && grep -Fq 'Discord status notification failed for task' "$logA"; then
  ok "the watcher logged the completion-bridge failure for a misconfigured home"
else
  bad "the watcher did not log the bridge failure; watcher out=[$(cat "$dirA/watch.out")] triage=[$(cat "$logA" 2>/dev/null)]"
fi
printf '  triage log A: %s\n' "$(tr '\n' '|' < "$logA" 2>/dev/null)"

printf '\n=====================================================================\n'
printf 'Watcher case B: no token -> silent opt-out, NO failure logged\n'
printf '=====================================================================\n'
dirB=$(run_watch_case disc-b FM_DISCORD_BOT_TOKEN='' FM_DISCORD_CHANNEL_ID='')
logB="$dirB/state/.watch-triage.log"
if grep -Fq 'Discord status notification failed' "$logB" 2>/dev/null; then
  bad "the watcher logged a Discord failure for an unconfigured home; triage=[$(cat "$logB")]"
else
  ok "the watcher logged no Discord failure for an unconfigured home"
fi
# The done: status itself is still surfaced, so the watcher ran the same path.
if grep -Fq 'signal:' "$dirB/watch.out"; then
  ok "the watcher still surfaced the done: wake it always did"
else
  bad "the watcher did not surface the done: wake; out=[$(cat "$dirB/watch.out")]"
fi
printf '  watcher out B: %s\n' "$(tr '\n' '|' < "$dirB/watch.out")"
if [ -f "$logB" ]; then
  printf '  triage log B: %s\n' "$(tr '\n' '|' < "$logB")"
else
  printf '  triage log B: <absent, as expected for a silent opt-out>\n'
fi

printf '\n=====================================================================\n'
printf 'RESULT: %s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
printf '=====================================================================\n'
[ "$FAIL_COUNT" -eq 0 ]
