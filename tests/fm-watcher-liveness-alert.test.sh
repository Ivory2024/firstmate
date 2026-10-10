#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ALERT="$ROOT/bin/fm-watcher-liveness-alert.sh"
TMP_ROOT=$(fm_test_tmproot fm-watcher-liveness-alert)
DIR="$TMP_ROOT/case"
HOME_CASE="$DIR/home"
STATE="$HOME_CASE/custom-state"
consumer=
queue_before=
mkdir -p "$STATE" "$HOME_CASE/config"
mkdir -p "$DIR/fakebin"
cat > "$HOME_CASE/.env" <<'ENV'
FM_DISCORD_BOT_TOKEN=test-token
FM_DISCORD_CHANNEL_ID=1234567890
ENV

record_consumer() {
  local pid=$1 identity
  identity=$(FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid") \
    || fail "could not identify consumer process"
  mkdir -p "$STATE/.watch.lock"
  printf '%s\n' "$pid" > "$STATE/.watch.lock/pid"
  printf '%s\n' "$HOME_CASE" > "$STATE/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$STATE/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$STATE/.watch.lock/pid-identity"
}

cleanup() {
  [ -n "$consumer" ] || return 0
  kill "$consumer" 2>/dev/null || true
  wait "$consumer" 2>/dev/null || true
}
trap cleanup EXIT

cat > "$DIR/fake-discord.mjs" <<'JS'
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
cat > "$DIR/fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Darwin\n'
SH
cat > "$DIR/fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_LAUNCHCTL_LOG"
SH
chmod +x "$DIR/fakebin/uname" "$DIR/fakebin/launchctl"

FM_HOME="$HOME_CASE" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE" FM_GUARD_GRACE=30 HOME="$HOME_CASE" \
  "$ALERT" render > "$DIR/agent.plist" || fail "could not render LaunchAgent contract"
FM_HOME="$HOME_CASE" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE" FM_GUARD_GRACE=30 HOME="$HOME_CASE" \
  FM_TEST_LAUNCHCTL_LOG="$DIR/launchctl.log" PATH="$DIR/fakebin:$PATH" \
  "$ALERT" install || fail "could not install the alert LaunchAgent"
[ -f "$HOME_CASE/Library/LaunchAgents/dev.firstmate.watcher-liveness-alert.plist" ] \
  || fail "install did not publish the LaunchAgent plist"
[ "$(wc -l < "$DIR/launchctl.log" | tr -d '[:space:]')" = 2 ] \
  || fail "install did not bootstrap the alert LaunchAgent"

run_agent() {
  local plist=${1:-$DIR/agent.plist} expected_grace=${2:-30} fail_post=${3:-0}
  FM_HOME="$HOME_CASE" FM_ROOT_OVERRIDE="$ROOT" HOME="$HOME_CASE" \
    FM_WATCHER_ALERT_COOLDOWN="${cooldown:-2}" FM_TEST_EXPECT_STATE="$STATE" FM_TEST_EXPECT_GRACE="$expected_grace" \
    FM_TEST_DISCORD_POSTS="$DIR/posts.jsonl" FM_TEST_DISCORD_FAIL="$fail_post" \
    NODE_OPTIONS="--import=$DIR/fake-discord.mjs" \
    python3 - "$plist" <<'PY'
import os, plistlib, subprocess, sys
with open(sys.argv[1], "rb") as stream:
    agent = plistlib.load(stream)
assert agent["StartInterval"] == 60 and agent["RunAtLoad"] is True
assert agent["ProgramArguments"][1] == "check"
assert agent["EnvironmentVariables"]["FM_STATE_OVERRIDE"] == os.environ["FM_TEST_EXPECT_STATE"]
assert agent["EnvironmentVariables"]["FM_WATCHER_STALE_GRACE"] == os.environ["FM_TEST_EXPECT_GRACE"]
env = os.environ.copy()
env.update(agent["EnvironmentVariables"])
subprocess.run(agent["ProgramArguments"], env=env, check=True)
PY
}

sleep 60 &
consumer=$!
record_consumer "$consumer"
touch "$STATE/.last-watcher-beat"
run_agent || fail "LaunchAgent failed to classify healthy consumer"
[ "$(cut -f1 "$STATE/.watcher-liveness-alert-state")" = healthy ] || fail "healthy consumer class missing"
[ ! -e "$DIR/posts.jsonl" ] || fail "healthy empty queue emitted an alert"

touch -t 201901010000 "$STATE/.last-watcher-beat"
run_agent || fail "LaunchAgent failed to classify stale heartbeat"
[ "$(cut -f1 "$STATE/.watcher-liveness-alert-state")" = stale-heartbeat ] || fail "stale-heartbeat class missing"
kill "$consumer" 2>/dev/null || true
wait "$consumer" 2>/dev/null || true
consumer=
rm -rf "$STATE/.watch.lock"
run_agent || fail "LaunchAgent failed to classify absent consumer"
[ "$(cut -f1 "$STATE/.watcher-liveness-alert-state")" = no-consumer ] || fail "no-consumer class missing"

printf '1\t1\tcheck\ttest\tcheck: pending\n' > "$STATE/.wake-queue"
queue_before=$(cat "$STATE/.wake-queue")
run_agent "$DIR/agent.plist" 30 1 || fail "LaunchAgent failed during simulated Discord outage"
[ "$(cat "$STATE/.wake-queue")" = "$queue_before" ] || fail "failed alert changed pending wake"
[ ! -e "$STATE/.watch.lock" ] || fail "failed alert re-armed a missing watcher"
[ "$(cut -f2 "$STATE/.watcher-liveness-alert-state")" = 0 ] || fail "failed delivery recorded a sent alert"
run_agent || fail "LaunchAgent failed to send HIGH alert after delivery recovered"
[ "$(cut -f1 "$STATE/.watcher-liveness-alert-state")" = pending-wake-no-consumer-high ] || fail "pending wake did not classify HIGH"
[ ! -e "$STATE/.watch.lock" ] || fail "alert check re-armed a missing watcher"
[ "$(cat "$STATE/.wake-queue")" = "$queue_before" ] || fail "alert check changed the pending wake"
posts=$(wc -l < "$DIR/posts.jsonl" | tr -d '[:space:]')
[ "$posts" = 1 ] || fail "no-consumer HIGH alert did not reach Discord"
cooldown=3600 run_agent || fail "LaunchAgent cooldown invocation failed"
posts_after=$(wc -l < "$DIR/posts.jsonl" | tr -d '[:space:]')
[ "$posts_after" = "$posts" ] || fail "cooldown allowed duplicate HIGH alert"
sleep 2.1
cooldown=2 run_agent || fail "LaunchAgent cooldown expiry invocation failed"
[ "$(wc -l < "$DIR/posts.jsonl" | tr -d '[:space:]')" = 2 ] || fail "HIGH alert did not repeat after cooldown"
[ "$(cat "$STATE/.wake-queue")" = "$queue_before" ] || fail "cooldown check changed the pending wake"

sleep 60 &
consumer=$!
record_consumer "$consumer"
touch -t 201901010000 "$STATE/.last-watcher-beat"
run_agent || fail "LaunchAgent failed to alert for stale heartbeat with pending wake"
[ "$(cut -f1 "$STATE/.watcher-liveness-alert-state")" = pending-wake-stale-heartbeat-high ] \
  || fail "stale heartbeat plus pending wake did not classify HIGH"
[ "$(cat "$STATE/.watch.lock/pid")" = "$consumer" ] || fail "alert check restarted the stale watcher"
[ "$(wc -l < "$DIR/posts.jsonl" | tr -d '[:space:]')" = 3 ] || fail "stale-heartbeat HIGH alert did not reach Discord"

touch "$STATE/.last-watcher-beat"
run_agent || fail "LaunchAgent recovery invocation failed"
[ "$(cut -f1 "$STATE/.watcher-liveness-alert-state")" = healthy ] || fail "healthy recovery state missing"
[ "$(wc -l < "$DIR/posts.jsonl" | tr -d '[:space:]')" = 4 ] || fail "recovery did not reach Discord"

FM_HOME="$HOME_CASE" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE" FM_POLL=300 HOME="$HOME_CASE" \
  "$ALERT" render > "$DIR/poll-agent.plist" || fail "could not render poll-derived grace contract"
touch -t "$(date -v-330S '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '330 seconds ago' '+%Y%m%d%H%M.%S')" \
  "$STATE/.last-watcher-beat"
run_agent "$DIR/poll-agent.plist" 360 || fail "LaunchAgent failed to use poll-derived grace"
[ "$(cut -f1 "$STATE/.watcher-liveness-alert-state")" = healthy ] \
  || fail "fresh poll-interval heartbeat was classified stale"
[ "$(wc -l < "$DIR/posts.jsonl" | tr -d '[:space:]')" = 4 ] \
  || fail "poll-derived grace emitted a false alert"
[ "$(cat "$STATE/.watch.lock/pid")" = "$consumer" ] || fail "poll-derived check changed watcher lock"
python3 - "$STATE/x-context" <<'PY' || fail "durable Discord outbox lacks sent HIGH or recovery records"
import glob, json, sys
rows = [json.load(open(path)) for path in glob.glob(sys.argv[1] + "/discord-completion-*.json")]
messages = [row["message"] for row in rows]
assert len(rows) == 4 and all(row["state"] == "sent" and row.get("message_id") for row in rows)
assert sum("HIGH reliability alert" in message for message in messages) == 3
assert sum("Recovered:" in message for message in messages) == 1
PY


kill "$consumer" 2>/dev/null || true
wait "$consumer" 2>/dev/null || true
consumer=
pass "watcher liveness LaunchAgent classifies, deduplicates, alerts, and surfaces recovery"
