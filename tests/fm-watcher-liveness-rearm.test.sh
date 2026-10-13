#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Behavior coverage for the session-independent re-arm stage of
# bin/fm-watcher-liveness-alert.sh. Every case drives the real `check` entry
# point with a stubbed arm binary and stubbed Discord, so no live watcher and no
# launchctl ever run. The stub arm stands in for bin/fm-watch-arm.sh and does
# only what the re-arm layer observes: record the invocation, and (unless told
# to fail) publish a live identity-matched watcher lock with a fresh beacon.

ALERT="$ROOT/bin/fm-watcher-liveness-alert.sh"
WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"
WATCH_PATH="$ROOT/bin/fm-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-watcher-liveness-rearm)
ARM_PIDS="$TMP_ROOT/arm-pids"
FAKE_DISCORD="$TMP_ROOT/fake-discord.mjs"
: > "$ARM_PIDS"

cleanup_fixtures() {
  if [ -f "$ARM_PIDS" ]; then
    while IFS= read -r pid; do
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      kill "$pid" 2>/dev/null || true
    done < "$ARM_PIDS"
  fi
  fm_test_cleanup
}
trap cleanup_fixtures EXIT INT TERM HUP

cat > "$FAKE_DISCORD" <<'JS'
import { appendFileSync, readFileSync } from "node:fs";
globalThis.fetch = async (url, options = {}) => {
  if (String(url).endsWith("/users/@me")) return { ok: true, json: async () => ({ id: "bot" }) };
  if (String(url).includes("/messages") && !options.method) return { ok: true, json: async () => [] };
  if (options.method === "POST") {
    const channelId = String(url).match(/channels\/(\d+)\/messages/)?.[1];
    if (process.env.FM_TEST_DISCORD_FAIL === "1") return { ok: false, status: 503, text: async () => "unavailable" };
    const rows = (() => { try { return readFileSync(process.env.FM_TEST_DISCORD_POSTS, "utf8").trim().split("\n").filter(Boolean); } catch { return []; } })();
    const body = JSON.parse(options.body);
    appendFileSync(process.env.FM_TEST_DISCORD_POSTS, `${JSON.stringify({ channelId, body })}\n`);
    return { ok: true, json: async () => ({ id: String(100 + rows.length), channel_id: channelId }) };
  }
  throw new Error(`unexpected Discord request ${url}`);
};
JS

# --- fixture -----------------------------------------------------------------

new_case() { # <name>
  CASE="$TMP_ROOT/$1"
  HOME_CASE="$CASE/home"
  STATE="$HOME_CASE/custom-state"
  ARM_LOG="$CASE/arm.log"
  POSTS="$CASE/posts.jsonl"
  ARM_BIN="$CASE/stub-arm.sh"
  FAKE_WATCHER_PID=
  rm -rf "$CASE"
  mkdir -p "$STATE" "$HOME_CASE/config"
  : > "$ARM_LOG"
  : > "$POSTS"
  cat > "$HOME_CASE/.env" <<'ENV'
FM_DISCORD_BOT_TOKEN=test-token
FM_DISCORD_CHANNEL_ID=1234567890
ENV
  # Per-scenario knobs, reset so no case inherits another's stub behavior.
  ARM_FAIL=0
  ARM_DELAY=0
  ARM_REPORT_STARTED=0
  CONFIRM_TIMEOUT=3
  BACKOFF_BASE=60
  BACKOFF_MAX=60
  ALERT_AFTER=3
  COOLDOWN_OVERRIDE=1
  DISCORD_FAIL=0
  # Supervision is needed: one in-flight task record.
  : > "$STATE/task-a.meta"
  write_stub_arm
}

write_stub_arm() {
  cat > "$ARM_BIN" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" >> "$FM_TEST_ARM_PIDS"
printf 'arm-invoked\n' >> "$FM_TEST_ARM_LOG"
if [ "${FM_TEST_ARM_FAIL:-0}" = 1 ]; then
  printf 'watcher: FAILED - stub arm forced failure\n'
  exit 1
fi
if [ "${FM_TEST_ARM_REPORT_STARTED:-0}" = 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  exit 0
fi
sleep "${FM_TEST_ARM_DELAY:-0}"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_TEST_WAKE_LIB"
identity=$(fm_pid_identity "$$") || exit 1
mkdir -p "$FM_TEST_STATE/.watch.lock"
printf '%s\n' "$$" > "$FM_TEST_STATE/.watch.lock/pid"
printf '%s\n' "$FM_TEST_HOME" > "$FM_TEST_STATE/.watch.lock/fm-home"
printf '%s\n' "$FM_TEST_WATCH_PATH" > "$FM_TEST_STATE/.watch.lock/watcher-path"
printf '%s\n' "$identity" > "$FM_TEST_STATE/.watch.lock/pid-identity"
touch "$FM_TEST_STATE/.last-watcher-beat"
while :; do sleep 1; done
SH
  chmod +x "$ARM_BIN"
}

# start_fake_watcher: a live identity-matched watcher lock owner (a plain sleep
# process, never bin/fm-watch.sh), recorded for cleanup.
start_fake_watcher() {
  local identity
  sleep 300 &
  FAKE_WATCHER_PID=$!
  printf '%s\n' "$FAKE_WATCHER_PID" >> "$ARM_PIDS"
  identity=$(FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_pid_identity "$2"' _ "$WAKE_LIB" "$FAKE_WATCHER_PID") \
    || fail "could not identify the fake watcher process"
  mkdir -p "$STATE/.watch.lock"
  printf '%s\n' "$FAKE_WATCHER_PID" > "$STATE/.watch.lock/pid"
  printf '%s\n' "$HOME_CASE" > "$STATE/.watch.lock/fm-home"
  printf '%s\n' "$WATCH_PATH" > "$STATE/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$STATE/.watch.lock/pid-identity"
}

stale_beacon() {
  fm_touch_epoch $(( $(date +%s) - 1000 )) "$STATE/.last-watcher-beat"
}

fresh_beacon() {
  touch "$STATE/.last-watcher-beat"
}

# write_cycle <reason> <successor> <arm_pid> <watcher_pid> <exit_code>
write_cycle() {
  local now
  now=$(date +%s)
  printf 'arm_pid=%s\twatcher_pid=%s\torigin=started\tstarted_at=%s\tended_at=%s\texit_code=%s\tsignal=none\treason=%s\tbeacon_age=999\tlock_before=pid:none|identity:none\tlock_after=pid:none|identity:none\tsuccessor=%s\n' \
    "$3" "$4" "$now" "$now" "$5" "$1" "$2" >> "$STATE/.watch-cycle-exits.log"
}

run_check() {
  FM_HOME="$HOME_CASE" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE" \
    HOME="$HOME_CASE" \
    FM_WATCH_ARM_BIN="$ARM_BIN" \
    FM_TEST_ARM_LOG="$ARM_LOG" FM_TEST_ARM_PIDS="$ARM_PIDS" \
    FM_TEST_ARM_FAIL="${ARM_FAIL:-0}" FM_TEST_ARM_DELAY="${ARM_DELAY:-0}" \
    FM_TEST_ARM_REPORT_STARTED="${ARM_REPORT_STARTED:-0}" \
    FM_TEST_STATE="$STATE" FM_TEST_HOME="$HOME_CASE" FM_TEST_WATCH_PATH="$WATCH_PATH" \
    FM_TEST_WAKE_LIB="$WAKE_LIB" \
    FM_SUPERVISION_MODEL=persistent \
    FM_WATCHER_STALE_GRACE="${GRACE_OVERRIDE:-5}" \
    FM_WATCH_REARM_CONFIRM_TIMEOUT="${CONFIRM_TIMEOUT:-3}" \
    FM_WATCH_REARM_BACKOFF_BASE="${BACKOFF_BASE:-60}" \
    FM_WATCH_REARM_BACKOFF_MAX="${BACKOFF_MAX:-60}" \
    FM_WATCH_REARM_ALERT_AFTER="${ALERT_AFTER:-3}" \
    FM_WATCHER_ALERT_COOLDOWN="${COOLDOWN_OVERRIDE:-1}" \
    FM_TEST_DISCORD_POSTS="$POSTS" FM_TEST_DISCORD_FAIL="${DISCORD_FAIL:-0}" \
    NODE_OPTIONS="--import=$FAKE_DISCORD" \
    "$ALERT" check
}

arm_count() {
  if [ -s "$ARM_LOG" ]; then
    grep -c '^arm-invoked$' "$ARM_LOG" || true
  else
    printf '0\n'
  fi
}

lock_pid() {
  cat "$STATE/.watch.lock/pid" 2>/dev/null || true
}

lock_present_count() {
  if [ -e "$STATE/.watch.lock" ]; then printf '1\n'; else printf '0\n'; fi
}

inbox_entry_count() { # <basename>
  local n=0 entry
  for entry in "$STATE"/task-a.inbox/*; do
    [ -e "$entry" ] || continue
    [ "${entry##*/}" = "$1" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

is_alive() {
  kill -0 "$1" 2>/dev/null
}

post_count() {
  if [ -s "$POSTS" ]; then
    wc -l < "$POSTS" | tr -d '[:space:]'
  else
    printf '0\n'
  fi
}

posts_containing() { # <needle>
  [ -s "$POSTS" ] || { printf '0\n'; return 0; }
  grep -c -- "$1" "$POSTS" || true
}

# --- 1. healthy running watcher: zero duplicate re-arm -----------------------

new_case rearm-healthy
start_fake_watcher
fresh_beacon
write_cycle actionable-signal none none none 0
run_check || fail "check failed with a healthy watcher"
assert_equals 0 "$(arm_count)" "a healthy running watcher must never be re-armed"
assert_equals "$FAKE_WATCHER_PID" "$(lock_pid)" "a healthy watcher lock must be left untouched"
pass "1. healthy running watcher produces zero duplicate re-arm"

# --- 2. normal cycle exit with no successor: exactly one re-arm --------------

new_case rearm-cycle-exit
stale_beacon
write_cycle actionable-signal none none none 0
run_check || fail "check failed on a dead chain"
assert_equals 1 "$(arm_count)" "a chain that ended with no successor must be re-armed exactly once"
is_alive "$(lock_pid)" || fail "re-arm did not leave a live watcher lock owner"
pass "2. normal cycle exit with no successor re-arms exactly once"

# --- 3. continuously active session: re-arm still happens --------------------

new_case rearm-session-active
sleep 300 &
SESSION_PID=$!
printf '%s\n' "$SESSION_PID" >> "$ARM_PIDS"
printf '%s\n' "$SESSION_PID" > "$STATE/.lock"
stale_beacon
write_cycle actionable-signal none none none 0
run_check || fail "check failed while a session stayed active"
assert_equals 1 "$(arm_count)" "an active session that never goes idle must still be re-armed"
is_alive "$(lock_pid)" || fail "active-session re-arm did not leave a live watcher"
assert_absent "$STATE/task-a.turn-ended" "fixture must carry no idle/turn-end event"
pass "3. a continuously active session does not block re-arm"

# --- 4. no idle event at all: re-arm still happens ---------------------------

new_case rearm-no-idle
stale_beacon
write_cycle actionable-signal none none none 0
assert_absent "$STATE/.lock" "fixture must carry no session lock"
assert_absent "$STATE/task-a.turn-ended" "fixture must carry no idle event"
run_check || fail "check failed with no idle event present"
assert_equals 1 "$(arm_count)" "re-arm must not depend on any idle event"
is_alive "$(lock_pid)" || fail "idle-free re-arm did not leave a live watcher"
pass "4. no idle event at all still re-arms"

# --- 5. watcher process killed: recovered ------------------------------------

new_case rearm-killed
start_fake_watcher
fresh_beacon
killed_pid=$FAKE_WATCHER_PID
kill "$killed_pid" 2>/dev/null || true
wait "$killed_pid" 2>/dev/null || true
stale_beacon
write_cycle signal-exit none none "$killed_pid" 143
run_check || fail "check failed after a killed watcher"
assert_equals 1 "$(arm_count)" "a killed watcher must be recovered exactly once"
new_pid=$(lock_pid)
is_alive "$new_pid" || fail "killed-watcher recovery did not leave a live watcher"
assert_not_equals "$killed_pid" "$new_pid" "recovery must replace the killed watcher pid"
pass "5. a killed watcher process is recovered"

# --- 6. existing lock with a live owner: verified, never stolen --------------

new_case rearm-live-owner
start_fake_watcher
stale_beacon
write_cycle actionable-signal none none none 0
run_check || fail "check failed with a live lock owner"
assert_equals 0 "$(arm_count)" "a live lock owner must never be re-armed or stolen from"
assert_equals "$FAKE_WATCHER_PID" "$(lock_pid)" "a live lock owner's pid must be preserved"
pass "6. an existing lock with a live owner is verified and never stolen"

# --- 7. concurrent recovery requests: one watcher instance -------------------

new_case rearm-concurrent
stale_beacon
write_cycle actionable-signal none none none 0
ARM_DELAY=1
CONFIRM_TIMEOUT=6
run_check & p1=$!
run_check & p2=$!
wait "$p1" || fail "first concurrent check failed"
wait "$p2" || fail "second concurrent check failed"
assert_equals 1 "$(arm_count)" "concurrent recovery requests must start exactly one watcher"
is_alive "$(lock_pid)" || fail "concurrent recovery left no live watcher"
assert_equals 1 "$(lock_present_count)" "exactly one watcher lock must remain"
pass "7. concurrent recovery requests maintain a single watcher instance"

# --- 8. intentional HOLD / deliberate stop: no re-arm ------------------------

new_case rearm-hold
stale_beacon
write_cycle actionable-signal none none none 0
printf 'maintenance window\n' > "$STATE/.watch-hold"
run_check || fail "check failed during a maintenance HOLD"
assert_equals 0 "$(arm_count)" "a maintenance HOLD must suppress re-arm"
assert_absent "$STATE/.watch.lock" "a maintenance HOLD must not start a watcher"

new_case rearm-interrupted
stale_beacon
write_cycle arm-interrupted none none none 143
run_check || fail "check failed after a deliberate stop"
assert_equals 0 "$(arm_count)" "a deliberate stop (arm-interrupted) must never be re-armed"
assert_absent "$STATE/.watch.lock" "a deliberate stop must not start a watcher"

new_case rearm-afk
stale_beacon
write_cycle actionable-signal none none none 0
printf 'away\n' > "$STATE/.afk"
run_check || fail "check failed in away posture"
assert_equals 0 "$(arm_count)" "away posture must suppress re-arm"
assert_absent "$STATE/.watch.lock" "away posture must not start a watcher"
pass "8. an intentional HOLD, a deliberate stop, and away posture never re-arm"

# --- 9. repeated re-arm failure: bounded backoff plus alert ------------------

new_case rearm-failure
stale_beacon
write_cycle actionable-signal none none none 0
ARM_FAIL=1
ALERT_AFTER=1
CONFIRM_TIMEOUT=2
BACKOFF_BASE=30
BACKOFF_MAX=30
run_check || fail "first failing check errored"
run_check || fail "second (backed-off) check errored"
run_check || fail "third (backed-off) check errored"
assert_equals 1 "$(arm_count)" "repeated failure must stop re-arming inside the backoff window"
failures=$(cut -f1 "$STATE/.watch-rearm-state")
assert_equals 1 "$failures" "one failure must be recorded"
next_attempt=$(cut -f3 "$STATE/.watch-rearm-state")
now=$(date +%s)
[ "$next_attempt" -gt "$now" ] || fail "backoff must schedule the next attempt in the future"
[ "$((next_attempt - now))" -le 30 ] || fail "backoff must stay within the configured bound"
assert_equals 1 "$(posts_containing 're-arm failed')" "one re-arm failure alert must be emitted"
assert_equals 1 "$(post_count)" "no duplicate re-arm failure alert may be emitted"
# A bounded delay must expire rather than wedge: rewind the window and prove the
# next attempt runs, advances the counter, and does not repeat the alert.
printf '1\t%s\t0\t%s\t1\n' "$now" "$now" > "$STATE/.watch-rearm-state"
run_check || fail "post-backoff check errored"
assert_equals 2 "$(arm_count)" "a bounded backoff must expire and allow the next attempt"
assert_equals 2 "$(cut -f1 "$STATE/.watch-rearm-state")" "the failure counter must advance"
assert_equals 1 "$(post_count)" "the failure alert must stay deduplicated per episode"
pass "9. repeated re-arm failure backs off, stops looping, and still alerts"

# --- 10. pending instruction preserved across recovery -----------------------

new_case rearm-pending
stale_beacon
write_cycle actionable-signal none none none 0
printf '1\t1\tcheck\ttest\tcheck: pending\n' > "$STATE/.wake-queue"
mkdir -p "$STATE/task-a.inbox/handled"
printf 'instruction-1\n' > "$STATE/task-a.inbox/0001-steer"
queue_before=$(cat "$STATE/.wake-queue")
inbox_before=$(cat "$STATE/task-a.inbox/0001-steer")
run_check || fail "check failed with a pending instruction present"
assert_equals 1 "$(arm_count)" "a pending instruction must still allow recovery"
assert_equals "$queue_before" "$(cat "$STATE/.wake-queue")" "re-arm must not consume or duplicate the durable wake queue"
assert_equals "$inbox_before" "$(cat "$STATE/task-a.inbox/0001-steer")" "re-arm must not consume or duplicate the steering inbox"
assert_equals 1 "$(inbox_entry_count 0001-steer)" "the pending instruction must remain exactly once"
pass "10. a pending instruction survives recovery exactly once"

# --- 11. alerting stays intact alongside re-arm (flap/dedup) -----------------

new_case rearm-alert-intact
stale_beacon
write_cycle actionable-signal none none none 0
printf '1\t1\tcheck\ttest\tcheck: pending\n' > "$STATE/.wake-queue"
ARM_FAIL=1
ALERT_AFTER=99
CONFIRM_TIMEOUT=2
COOLDOWN_OVERRIDE=3600
run_check || fail "first alert-intact check errored"
run_check || fail "second alert-intact check errored"
run_check || fail "third alert-intact check errored"
assert_equals 1 "$(posts_containing 'HIGH reliability alert')" "the HIGH alert must fire exactly once"
assert_equals 1 "$(post_count)" "the alert cooldown must dedupe repeated HIGH alerts"
assert_equals 1 "$(arm_count)" "the bounded re-arm failure must not loop while alerting"
pass "11. HIGH alert dedup still holds while re-arm is active"

# --- 12. a delivered-wake cycle is a successful re-arm, not a failure --------

new_case rearm-delivered-wake
stale_beacon
write_cycle actionable-signal none none none 0
ARM_REPORT_STARTED=1
CONFIRM_TIMEOUT=2
run_check || fail "delivered-wake check errored"
assert_equals 0 "$(cut -f1 "$STATE/.watch-rearm-state")" "an arm that verified a watcher must not record a failure"
assert_equals 0 "$(post_count)" "a delivered-wake cycle must not alert as a re-arm failure"
run_check || fail "second delivered-wake check errored"
assert_equals 2 "$(arm_count)" "a delivered-wake cycle must not wedge the chain behind a backoff"
pass "12. a re-armed watcher that surfaced a wake and exited counts as success"

pass "session-independent watcher re-arm: all scenarios passed"
