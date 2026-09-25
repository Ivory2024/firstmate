#!/usr/bin/env bash
# Regression tests for proactive Discord decisions and their reply inbox route.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
NODE_DIR=$(command -v node 2>/dev/null) && NODE_DIR=$(dirname "$NODE_DIR") || NODE_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
[ -n "$NODE_DIR" ] && BASE_PATH="$NODE_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-discord-decision-push)
make_fake_node() {
  local home=$1
  mkdir -p "$home/fake-bin"
  cat > "$home/fake-bin/node" <<'SH'
#!/usr/bin/env bash
set -u
script=$1
shift
exec "$FM_TEST_REAL_NODE" --input-type=module -e '
  import { pathToFileURL } from "node:url";
  const [script, ...args] = process.argv.slice(1);
  process.argv = [process.argv[0], script, ...args];
  const messages = JSON.parse(process.env.FM_DISCORD_FAKE_MESSAGES || "[]");
  const log = process.env.FM_DISCORD_FAKE_POST_LOG;
  globalThis.fetch = async (url, options = {}) => {
    if (url === "https://discord.com/api/v10/users/@me") return Response.json({ id: "9000000000000000001" });
    if (url.includes("/messages") && options.method === "POST") {
      const payload = JSON.parse(options.body);
      if (log) await import("node:fs/promises").then(({ appendFile }) => appendFile(log, JSON.stringify({ url, payload }) + "\n"));
      return Response.json({ id: "1352000000000000999", channel_id: "1000000000000000001" });
    }
    if (url.includes("/channels/") && url.includes("/messages")) return Response.json(messages);
    return new Response("not found", { status: 404 });
  };
  await import(pathToFileURL(script).href);
' "$script" "$@"
SH
  chmod +x "$home/fake-bin/node"
}
test_no_token_is_inert() {
  local home out rc
  home="$TMP_ROOT/no-token"
  mkdir -p "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_DISCORD_BOT_TOKEN='' \
    "$ROOT/bin/fm-discord-notify.sh" captain-hold task-a captain-hold-task-a-1 "Needs a decision" "Continue|Pause")
  rc=$?
  expect_code 0 "$rc" "missing token is inert"
  [ -z "$out" ] || fail "missing token printed output: $out"
  assert_absent "$home/state/x-context" "missing token creates no notification record"
  pass "proactive Discord notification is inert without the self-hosted token"
}
test_notify_records_reply_binding() {
  local home log record body
  home="$TMP_ROOT/notify"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  log="$home/posts.jsonl"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify.sh" captain-hold task-a captain-hold-task-a-1 \
      "Choose how to proceed" "Continue|Pause" >/dev/null \
    || fail "notification post failed"
  record=$(find "$home/state/x-context" -maxdepth 1 -name 'discord-notify-*.json' -print -quit)
  assert_present "$record" "notification binding is persisted"
  assert_equals "task-a" "$(jq -r '.task_id' "$record")" "notification task id"
  assert_equals "captain-hold-task-a-1" "$(jq -r '.key' "$record")" "notification decision key"
  assert_equals "1352000000000000999" "$(jq -r '.message_id' "$record")" "Discord message id"
  body=$(jq -r '.payload.content' "$log")
  assert_contains "$body" "task-a" "message includes task id"
  assert_contains "$body" "Choose how to proceed" "message includes summary"
  assert_contains "$body" "Continue" "message includes options"
  assert_contains "$body" "Pause" "message includes all options"
  pass "proactive Discord post stores the task and reply binding"
}

test_captain_hold_triggers_push() {
  local home record
  if ! command -v tasks-axi >/dev/null 2>&1; then
    pass "captain-hold trigger integration skipped because tasks-axi is unavailable"
    return 0
  fi
  home="$TMP_ROOT/captain-hold-trigger"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  make_fake_node "$home"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$home/posts.jsonl" \
    PATH="$home/fake-bin:$BASE_PATH:$(dirname "$(command -v tasks-axi)")" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-captain-hold.sh" hold task-hold \
      --title "Choose the next step" --reason "Choose how the change should proceed" \
      >/dev/null || fail "captain hold failed"
  record=$(find "$home/state/x-context" -name 'discord-notify-*.json' -print -quit)
  assert_equals "captain-hold" "$(jq -r '.trigger' "$record")" "captain-hold trigger type"
  assert_equals "task-hold" "$(jq -r '.task_id' "$record")" "captain-hold task id"
  assert_equals "A task is waiting for your decision." "$(jq -r '.summary' "$record")" "hold summary uses plain language"
  pass "a durable captain hold triggers a Discord decision push"
}
test_reply_to_notification_enters_existing_inbox() {
  local home record wake req inbox
  home="$TMP_ROOT/reply"
  mkdir -p "$home/state/x-context" "$home/state/x-inbox"
  chmod 700 "$home/state" "$home/state/x-context" "$home/state/x-inbox"
  make_fake_node "$home"
  record="$home/state/x-context/discord-notify-test.json"
  cat > "$record" <<'EOF'
{"schema":"fm-discord-decision-notification.v1","kind":"decision-notification","state":"sent","task_id":"task-a","key":"captain-hold-task-a-1","trigger":"captain-hold","channel_id":"1000000000000000001","message_id":"1352000000000000999","summary":"Choose how to proceed","options":["Continue","Pause"],"recorded_at":1790319000}
EOF
  chmod 600 "$record"
  FM_TEST_REAL_NODE=$(command -v node) \
    FM_DISCORD_FAKE_MESSAGES='[{"id":"1352000000000001000","channel_id":"1000000000000000001","guild_id":"1000000000000000000","author":{"id":"8000000000000000001","username":"captain"},"content":"Continue","message_reference":{"message_id":"1352000000000000999","channel_id":"1000000000000000001"}}]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-poll.sh" > "$home/wake.log" || fail "poll failed"
  wake=$(cat "$home/wake.log")
  req=discord-sh-1352000000000001000
  assert_equals "x-mention $req" "$wake" "reply wakes existing responder"
  inbox="$home/state/x-inbox/$req.json"
  assert_present "$inbox" "reply is captured in existing inbox"
  assert_equals "discord-selfhosted-decision" "$(jq -r '.source' "$inbox")" "decision reply source"
  assert_equals "task-a" "$(jq -r '.decision.task_id' "$inbox")" "decision task id routed"
  assert_equals "captain-hold-task-a-1" "$(jq -r '.decision.key' "$inbox")" "decision key routed"
  assert_equals "Continue" "$(jq -r '.text' "$inbox")" "captain reply preserved"
  assert_equals "1352000000000001000" "$(jq -r '.replied_to.message_id' "$record")" "notification accepts only one reply"
  pass "reply to a pushed decision enters x-inbox with keyed answer context"
}
test_no_unrelated_reply_is_captured() {
  local home wake
  home="$TMP_ROOT/unrelated"
  mkdir -p "$home/state/x-context" "$home/state/x-inbox"
  chmod 700 "$home/state" "$home/state/x-context" "$home/state/x-inbox"
  make_fake_node "$home"
  FM_TEST_REAL_NODE=$(command -v node) \
    FM_DISCORD_FAKE_MESSAGES='[{"id":"1352000000000001100","channel_id":"1000000000000000001","guild_id":"1000000000000000000","author":{"id":"8000000000000000001","username":"captain"},"content":"ordinary chat","message_reference":{"message_id":"1352000000000000999","channel_id":"1000000000000000001"}}]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-poll.sh" > "$home/wake.log" || fail "poll failed"
  wake=$(cat "$home/wake.log")
  [ -z "$wake" ] || fail "unbound reply woke responder: $wake"
  assert_absent "$home/state/x-inbox/discord-sh-1352000000000001100.json" "unrelated reply is not captured"
  pass "ordinary Discord replies do not enter the decision inbox"
}

test_ask_user_gate_triggers_push() {
  local home record
  home="$TMP_ROOT/ask-user-trigger"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$home/posts.jsonl" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a \
      'needs-decision [key=nm-run42-review]: ask-user findings=f1 file=/private/findings.txt' \
    >/dev/null || fail "ask-user status did not trigger a push"
  record=$(find "$home/state/x-context" -name 'discord-notify-*.json' -print -quit)
  assert_equals "ask-user" "$(jq -r '.trigger' "$record")" "ask-user trigger type"
  assert_equals "nm-run42-review" "$(jq -r '.key' "$record")" "ask-user key"
  assert_equals "task-a" "$(jq -r '.task_id' "$record")" "ask-user task id"
  pass "only an nm-keyed ask-user status triggers a decision push"
}

test_pr_push_requires_yolo_off() {
  local home record posts
  home="$TMP_ROOT/pr-trigger"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  posts="$home/posts.jsonl"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$posts" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a \
      'needs-decision [key=pr-ready-task-a]: task=task-a pull request ready yolo=on' >/dev/null \
    || fail "yolo-on PR status classification failed"
  [ ! -s "$posts" ] || fail "yolo-on PR status sent a notification"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$posts" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a \
    'needs-decision [key=pr-ready-task-a]: task=task-a yolo=off pull request ready: https://github.com/acme/app/pull/42 choose merge or leave open' >/dev/null \
    || fail "yolo-off PR status did not trigger a push"
  record=$(find "$home/state/x-context" -name 'discord-notify-*.json' -print -quit)
  assert_equals "pr-ready" "$(jq -r '.trigger' "$record")" "PR-ready trigger type"
  assert_equals "task-a" "$(jq -r '.task_id' "$record")" "PR-ready task id"
  assert_contains "$(jq -r '.summary' "$record")" "https://github.com/acme/app/pull/42" "PR summary includes review link"
  assert_equals "1" "$(wc -l < "$posts" | tr -d '[:space:]')" "one yolo-off notification sent"
  pass "PR-ready notifications require yolo=off"
}

test_no_token_is_inert
test_notify_records_reply_binding
test_captain_hold_triggers_push
test_reply_to_notification_enters_existing_inbox
test_no_unrelated_reply_is_captured
test_ask_user_gate_triggers_push
test_pr_push_requires_yolo_off
