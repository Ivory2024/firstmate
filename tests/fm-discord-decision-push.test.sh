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
TASKS_AXI_BIN=$(command -v tasks-axi 2>/dev/null) && TASKS_AXI_DIR=$(dirname "$TASKS_AXI_BIN") || TASKS_AXI_DIR=
[ -n "$TASKS_AXI_DIR" ] && BASE_PATH="$TASKS_AXI_DIR:$BASE_PATH"
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
    if (url === "https://discord.com/api/v10/users/@me") {
      if (process.env.FM_DISCORD_FAKE_PROFILE_STATUS) return new Response("failed", { status: Number(process.env.FM_DISCORD_FAKE_PROFILE_STATUS) });
      return Response.json({ id: "9000000000000000001" });
    }
    if (url.includes("/messages") && options.method === "POST") {
      const payload = JSON.parse(options.body);
      if (log) await import("node:fs/promises").then(({ appendFile }) => appendFile(log, JSON.stringify({ url, payload }) + "\n"));
      if (process.env.FM_DISCORD_FAKE_POST_STATUS) return new Response("failed", { status: Number(process.env.FM_DISCORD_FAKE_POST_STATUS) });
      return Response.json({ id: "1352000000000000999", channel_id: "1000000000000000001" });
    }
    if (url.includes("/channels/") && url.includes("/messages")) return Response.json(messages);
    return new Response("not found", { status: 404 });
  };
  await import(pathToFileURL(script).href);
' "$script" "$@"
SH
  chmod +x "$home/fake-bin/node"
  cat > "$home/fake-bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_DISCORD_FAKE_CREW_STATE:-state: done · source: fake}"
SH
  chmod +x "$home/fake-bin/fm-crew-state.sh"
}

discord_path_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

discord_path_links() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1"
  else
    stat -c %h "$1"
  fi
}
test_no_token_is_inert() {
  local home out rc
  home="$TMP_ROOT/no-token"
  mkdir -p "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_DISCORD_BOT_TOKEN='' \
    "$ROOT/bin/fm-discord-notify.sh" captain-hold task-a captain-hold-task-a-1 "Needs a decision" "Continue|Pause" "Pause")
  rc=$?
  expect_code 0 "$rc" "missing token is inert"
  [ -z "$out" ] || fail "missing token printed output: $out"
  assert_absent "$home/state/x-context" "missing token creates no notification record"
  pass "proactive Discord notification is inert without the self-hosted token"
}
test_quiet_report_posts_plain_snapshot() {
  local home log body long_report
  home="$TMP_ROOT/report"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  log="$home/posts.jsonl"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token \
    "$ROOT/bin/fm-discord-notify.sh" --report ' 1000000000000000001 ' $'현황\n진행 중: 작업 A' >/dev/null \
    || fail "plain report post failed"
  body=$(jq -r '.payload.content' "$log")
  assert_equals $'현황\n진행 중: 작업 A' "$body" "report body is sent verbatim"
  assert_equals '[]' "$(jq -c '.payload.allowed_mentions.parse' "$log")" "report disables mentions"
  long_report="$(printf '%02000d' 0)"$'\n🙂'
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token \
    "$ROOT/bin/fm-discord-notify.sh" --report 1000000000000000001 "$long_report" >/dev/null \
    || fail "long report post failed"
  assert_equals 3 "$(wc -l < "$log" | tr -d ' ')" "long report splits into valid Discord messages"
  assert_equals "$long_report" "$(tail -n 2 "$log" | jq -sr 'map(.payload.content) | join("")')" "long report preserves Unicode content"
  [ "$(jq -r '.payload.content | length' "$log" | sort -nr | head -n 1)" -le 2000 ] || fail "report chunk exceeds Discord limit"
  [ -z "$(find "$home/state/x-context" -name 'discord-notify-*.json' -print -quit)" ] || fail "plain report creates no decision binding"
  pass "Discord report sends a bounded plain message without creating a decision record"
}
test_report_requires_token() {
  local home output rc
  home="$TMP_ROOT/report-no-token"
  mkdir -p "$home"
  output=$(FM_HOME="$home" FM_DISCORD_BOT_TOKEN='' \
    "$ROOT/bin/fm-discord-notify.sh" --report 1000000000000000001 "현황" 2>&1); rc=$?
  expect_code 1 "$rc" "report requires configured token"
  assert_equals "fm-discord-notify: missing Discord bot token for report" "$output" "missing report token diagnostic"
  pass "Discord report fails clearly without the self-hosted token"
}
test_report_helper_refuses_non_quiet_mode() {
  local home output rc
  home="$TMP_ROOT/report-mode-guard"
  mkdir -p "$home/state"
  printf 'away\n' > "$home/state/.afk"
  output=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-discord-report.sh" 2>&1); rc=$?
  expect_code 4 "$rc" "report helper requires quiet mode"
  assert_equals "fm-discord-report: available only while quiet mode is active" "$output" "report mode diagnostic"
  pass "Discord report helper refuses outside quiet mode"
}
test_report_helper_sends_bearings_snapshot() {
  local home root result
  home="$TMP_ROOT/report-helper"
  root="$home/root"
  mkdir -p "$root/bin" "$home/state"
  cp "$ROOT/bin/fm-discord-report.sh" "$root/bin/fm-discord-report.sh"
  printf 'quiet\n' > "$home/state/.afk"
  cat > "$root/bin/fm-wake-lib.sh" <<'SH'
fm_afk_mode() { [ "$(head -n 1 "$1/.afk" 2>/dev/null)" = quiet ] && printf quiet || printf away; }
SH
  cat > "$root/bin/fm-discord-lib.sh" <<'SH'
fm_discord_load_config() { FM_DISCORD_CHANNELS=' 1000000000000000001 '; }
fm_discord_trim() { local value=$1; value=${value#"${value%%[![:space:]]*}"}; value=${value%"${value##*[![:space:]]}"}; printf '%s' "$value"; }
SH
  cat > "$root/bin/fm-bearings-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '현황\n진행 중: 작업 A\n'
SH
  cat > "$root/bin/fm-discord-notify.sh" <<'SH'
#!/usr/bin/env bash
printf '%s' "$2" > "$FM_HOME/channel"
printf '%s' "$3" > "$FM_HOME/body"
printf 'receipt-1\n'
SH
  chmod +x "$root/bin/fm-bearings-snapshot.sh" "$root/bin/fm-discord-notify.sh"
  result=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$root/bin/fm-discord-report.sh") \
    || fail "quiet report helper did not complete"
  assert_equals "receipt-1" "$result" "helper returns notify receipt"
  assert_equals "1000000000000000001" "$(cat "$home/channel")" "helper selects configured channel"
  assert_equals $'현황\n진행 중: 작업 A' "$(cat "$home/body")" "helper sends snapshot body unchanged"
  pass "quiet report helper passes the current Bearings snapshot to Discord notify"
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
      "Choose how to proceed" "Continue|Pause" "Pause" >/dev/null \
    || fail "notification post failed"
  record=$(find "$home/state/x-context" -maxdepth 1 -name 'discord-notify-*.json' -print -quit)
  assert_present "$record" "notification binding is persisted"
  assert_equals "task-a" "$(jq -r '.task_id' "$record")" "notification task id"
  assert_equals "captain-hold-task-a-1" "$(jq -r '.key' "$record")" "notification decision key"
  assert_equals "1352000000000000999" "$(jq -r '.message_id' "$record")" "Discord message id"
  assert_equals "true" "$(jq -r '.payload.enforce_nonce' "$log")" "Discord send enforces the event nonce"
  body=$(jq -r '.payload.content' "$log")
  assert_contains "$body" "task-a" "message includes task id"
  assert_contains "$body" "Choose how to proceed" "message includes summary"
  assert_contains "$body" "Continue" "message includes options"
  assert_contains "$body" "Pause" "message includes all options"
  assert_contains "$body" "필요한 결정: 보류된 작업을 어떻게 진행할지" "message states required decision"
  assert_contains "$body" "권장안: Pause" "message shows its recommendation"
  pass "proactive Discord post stores the task and reply binding"
}

test_recommendation_must_be_an_offered_option() {
  local home output rc
  home="$TMP_ROOT/invalid-recommendation"
  mkdir -p "$home"
  output=$(FM_HOME="$home" FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify.sh" ask-user task-a nm-run-review \
      "A decision is needed" "Approve|Decline" "Maybe" 2>&1); rc=$?
  expect_code 2 "$rc" "recommendation outside the offered choices is rejected"
  assert_equals "fm-discord-notify: recommendation must match one offered option" "$output" "recommendation validation diagnostic"
  assert_absent "$home/state/x-context" "invalid recommendation cannot create a pending decision"
  pass "recommendation must match an offered decision option"
}

test_failed_notification_retries_from_durable_outbox() {
  local home record log state
  home="$TMP_ROOT/retry-failed"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  log="$home/posts.jsonl"
  if FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" FM_DISCORD_FAKE_POST_STATUS=503 \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify.sh" ask-user task-retry nm-run42-review \
      "A decision is needed" "Approve|Decline" "Decline" >/dev/null 2>&1; then
    fail "a rejected Discord send reported success"
  fi
  record=$(find "$home/state/x-context" -maxdepth 1 -name 'discord-notify-*.json' -print -quit)
  assert_equals "failed" "$(jq -r '.state' "$record")" "failed send remains pending"
  jq '.summary = "A proposed change needs your decision." | .options = ["Approve the proposed change", "Keep the current behavior"]' \
    "$record" > "$record.tmp" && mv "$record.tmp" "$record"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" FM_DISCORD_FAKE_MESSAGES='[]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify.sh" --retry-pending >/dev/null \
    || fail "durable notification retry failed"
  state=$(jq -r '.state' "$record")
  assert_equals "sent" "$state" "retry completes the retained notification"
  assert_equals "2" "$(wc -l < "$log" | tr -d ' ')" "one initial failed POST and one retry POST"
  assert_contains "$(sed -n '2p' "$log" | jq -r '.payload.content')" "1. 제안된 변경 사항 승인" "legacy retry first option is localized and numbered"
  assert_contains "$(sed -n '2p' "$log" | jq -r '.payload.content')" "2. 현재 동작 유지" "legacy retry second option is localized and numbered"
  assert_contains "$(sed -n '2p' "$log" | jq -r '.payload.content')" "제안된 변경 사항에 대한 결정이 필요합니다." "legacy retry summary is localized"
  pass "failed decision notifications retry after their source cursor advances"
}

test_profile_failure_keeps_retryable_intent() {
  local home record log
  home="$TMP_ROOT/profile-failure"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  log="$home/posts.jsonl"
  if FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_PROFILE_STATUS=503 \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify.sh" ask-user task-profile nm-run43-review \
      "A decision is needed" "Approve|Decline" "Decline" >/dev/null 2>&1; then
    fail "a rejected profile lookup reported success"
  fi
  record=$(find "$home/state/x-context" -maxdepth 1 -name 'discord-notify-*.json' -print -quit)
  assert_present "$record" "profile failure leaves a durable notification intent"
  assert_equals "pending" "$(jq -r '.state' "$record")" "profile failure leaves intent retryable"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" FM_DISCORD_FAKE_MESSAGES='[]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify.sh" --retry-pending >/dev/null \
    || fail "profile-failed notification was not retried"
  assert_equals "sent" "$(jq -r '.state' "$record")" "profile-failed intent reaches sent state"
  assert_equals "1" "$(wc -l < "$log" | tr -d ' ')" "retry posts exactly once"
  pass "profile lookup failure preserves and retries the notification intent"
}

test_stale_sending_notification_recovers_without_duplicate_post() {
  local home record nonce
  home="$TMP_ROOT/retry-stale-sending"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  record="$home/state/x-context/discord-notify-stale.json"
  nonce=0123456789abcdef012345678
  cat > "$record" <<EOF
{"schema":"fm-discord-decision-notification.v1","kind":"decision-notification","state":"sending","task_id":"task-stale","key":"nm-stale-review","trigger":"ask-user","channel_id":"1000000000000000001","nonce":"$nonce","summary":"Review needed","options":["Approve","Decline"],"recorded_at":1700000000,"attempted_at":1700000000}
EOF
  chmod 600 "$record"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_MESSAGES="[{\"id\":\"1352000000000001200\",\"channel_id\":\"1000000000000000001\",\"author\":{\"id\":\"9000000000000000001\"},\"nonce\":\"$nonce\",\"timestamp\":\"2026-09-25T00:00:00.000Z\"}]" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify.sh" --retry-pending >/dev/null \
    || fail "stale sending notification did not reconcile from channel history"
  assert_equals "sent" "$(jq -r '.state' "$record")" "stale notification is marked sent"
  assert_equals "1352000000000001200" "$(jq -r '.message_id' "$record")" "existing message receipt is adopted"
  assert_absent "$home/posts.jsonl" "history reconciliation does not post a duplicate"
  pass "stale sending records recover from Discord history without reposting"
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
  assert_equals "Choose how the change should proceed" "$(jq -r '.summary' "$record")" \
    "hold summary carries the caller's actual reason, not generic filler"
  pass "a durable captain hold triggers a Discord decision push with the real reason text"
}

test_captain_hold_truncates_long_reason_for_discord() {
  local home record long_reason summary
  if ! command -v tasks-axi >/dev/null 2>&1; then
    pass "captain-hold Discord truncation skipped because tasks-axi is unavailable"
    return 0
  fi
  home="$TMP_ROOT/captain-hold-long-reason"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  make_fake_node "$home"
  long_reason=$(printf 'word %.0s' $(seq 1 500))
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$home/posts.jsonl" \
    PATH="$home/fake-bin:$BASE_PATH:$(dirname "$(command -v tasks-axi)")" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-captain-hold.sh" hold task-hold-long \
      --title "Choose the next step" --reason "$long_reason" \
      >/dev/null || fail "captain hold with a long reason failed"
  record=$(find "$home/state/x-context" -name 'discord-notify-*.json' -print -quit)
  summary=$(jq -r '.summary' "$record")
  [ "${#summary}" -le 1801 ] || fail "Discord summary was not truncated: ${#summary} chars"
  [ "${#summary}" -lt "${#long_reason}" ] || fail "Discord summary was not shortened from the full reason"
  pass "a captain hold with a reason near Discord's message limit gets truncated before sending"
}

test_ask_user_escalation_hold_carries_finding_text() {
  local home record reason
  if ! command -v tasks-axi >/dev/null 2>&1; then
    pass "ask-user escalation content integration skipped because tasks-axi is unavailable"
    return 0
  fi
  home="$TMP_ROOT/ask-user-escalation-hold"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  make_fake_node "$home"
  reason="allow the migration to drop the legacy column now, or keep it for one more release"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$home/posts.jsonl" \
    PATH="$home/fake-bin:$BASE_PATH:$(dirname "$(command -v tasks-axi)")" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-captain-hold.sh" hold nm-task \
      --title "ask-user gate" --reason "$reason" \
      >/dev/null || fail "captain hold for an escalated ask-user gate failed"
  record=$(find "$home/state/x-context" -name 'discord-notify-*.json' -print -quit)
  assert_equals "$reason" "$(jq -r '.summary' "$record")" \
    "escalated ask-user gate's Discord push carries the real finding text"
  pass "a genuinely escalated ask-user gate pushes a Discord decision with the real finding text"
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
    FM_DISCORD_AUTHORIZED_USER_IDS=8000000000000000001 \
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
test_perm_ask_reply_carries_the_identity_the_applier_needs() {
  local home record wake req inbox
  home="$TMP_ROOT/perm-ask-reply"
  mkdir -p "$home/state/x-context" "$home/state/x-inbox"
  chmod 700 "$home/state" "$home/state/x-context" "$home/state/x-inbox"
  make_fake_node "$home"
  record="$home/state/x-context/discord-notify-test.json"
  cat > "$record" <<'EOF'
{"schema":"fm-discord-decision-notification.v1","kind":"decision-notification","state":"sent","task_id":"oc-perm-task","key":"perm-per_abc123","trigger":"perm-ask","channel_id":"1000000000000000001","message_id":"1352000000000002000","summary":"OpenCode worker needs permission: action=external_directory resource=/tmp/x/*","options":["Approve once","Approve once and remember this","Reject the request"],"recorded_at":1790319000}
EOF
  chmod 600 "$record"
  FM_TEST_REAL_NODE=$(command -v node) \
    FM_DISCORD_FAKE_MESSAGES='[{"id":"1352000000000002001","channel_id":"1000000000000000001","guild_id":"1000000000000000000","author":{"id":"8000000000000000001","username":"captain"},"content":"Approve once","message_reference":{"message_id":"1352000000000002000","channel_id":"1000000000000000001"}}]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    FM_DISCORD_AUTHORIZED_USER_IDS=8000000000000000001 \
    "$ROOT/bin/fm-discord-poll.sh" > "$home/wake.log" || fail "poll failed"
  wake=$(cat "$home/wake.log")
  req=discord-sh-1352000000000002001
  assert_equals "x-mention $req" "$wake" "the permission reply wakes the responder"
  inbox="$home/state/x-inbox/$req.json"
  assert_present "$inbox" "the permission reply is captured in the existing inbox"
  assert_equals "discord-selfhosted-decision" "$(jq -r '.source' "$inbox")" "the permission reply is a decision reply, not fresh work"
  # Everything the applier needs is already in the captured object: the task it
  # belongs to, the request id behind the key, the exact options offered, and
  # the channel a confirmation goes back to.
  assert_equals "oc-perm-task" "$(jq -r '.decision.task_id' "$inbox")" "the owning task is carried"
  assert_equals "perm-ask" "$(jq -r '.decision.trigger' "$inbox")" "the trigger is carried"
  assert_equals "perm-per_abc123" "$(jq -r '.decision.key' "$inbox")" "the request key is carried"
  assert_equals "3" "$(jq -r '.decision.options | length' "$inbox")" "all three decisions are carried"
  assert_equals "1000000000000000001" "$(jq -r '.channel_id' "$inbox")" "the channel a confirmation posts to is carried"
  assert_equals "Approve once" "$(jq -r '.text' "$inbox")" "the captain's own words are preserved"
  # And the capture is durable even when this ingress run is not the watcher's.
  assert_equals "1" "$(awk -F '\t' -v want="discord-$req" 'NF >= 5 && $3 == "check" && $4 == want { n++ } END { print n + 0 }' "$home/state/.wake-queue")" \
    "the captured permission reply enqueued its own durable wake"
  pass "a permission reply reaches the inbox with the exact identity the applier needs"
}
test_captured_reply_without_offer_recovers_one_wake() {
  local home record req inbox offered wake
  home="$TMP_ROOT/recover-reply-wake"
  mkdir -p "$home/state/x-context" "$home/state/x-inbox"
  chmod 700 "$home/state" "$home/state/x-context" "$home/state/x-inbox"
  make_fake_node "$home"
  record="$home/state/x-context/discord-notify-test.json"
  cat > "$record" <<'EOF'
{"schema":"fm-discord-decision-notification.v1","kind":"decision-notification","state":"sent","task_id":"task-a","key":"captain-hold-task-a-1","trigger":"captain-hold","channel_id":"1000000000000000001","message_id":"1352000000000000999","summary":"Choose how to proceed","options":["Continue","Pause"],"recorded_at":1790319000}
EOF
  req=discord-sh-1352000000000001001
  inbox="$home/state/x-inbox/$req.json"
  jq -n --arg req "$req" --arg msg "1352000000000001001" \
    '{request_id:$req,text:"Continue",source:"discord-selfhosted-decision",message_id:$msg,channel_id:"1000000000000000001",decision:{task_id:"task-a",key:"captain-hold-task-a-1"}}' \
    > "$inbox"
  chmod 600 "$record" "$inbox"
  FM_TEST_REAL_NODE=$(command -v node) \
    FM_DISCORD_FAKE_MESSAGES='[{"id":"1352000000000001001","channel_id":"1000000000000000001","guild_id":"1000000000000000000","author":{"id":"8000000000000000001","username":"captain"},"content":"Continue","message_reference":{"message_id":"1352000000000000999","channel_id":"1000000000000000001"}}]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    FM_DISCORD_AUTHORIZED_USER_IDS=8000000000000000001 \
    "$ROOT/bin/fm-discord-poll.sh" > "$home/wake.log" || fail "recovery poll failed"
  wake=$(cat "$home/wake.log")
  assert_equals "x-mention $req" "$wake" "captured reply is woken after replay"
  offered="$home/state/x-context/$req.offered.json"
  assert_present "$offered" "recovery records the one-wake marker"
  assert_present "$home/state/x-context/$req.json" "recovery restores reply context"
  assert_equals "1352000000000001001" "$(jq -r '.replied_to.message_id' "$record")" "recovery completes notification binding"
  FM_TEST_REAL_NODE=$(command -v node) \
    FM_DISCORD_FAKE_MESSAGES='[{"id":"1352000000000001001","channel_id":"1000000000000000001","guild_id":"1000000000000000000","author":{"id":"8000000000000000001","username":"captain"},"content":"Continue","message_reference":{"message_id":"1352000000000000999","channel_id":"1000000000000000001"}}]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    FM_DISCORD_AUTHORIZED_USER_IDS=8000000000000000001 \
    "$ROOT/bin/fm-discord-poll.sh" > "$home/replay.log" || fail "second recovery poll failed"
  assert_equals "" "$(cat "$home/replay.log")" "an offered reply is not woken twice"
  pass "a captured decision reply recovers its missing wake once"
}
test_unauthorized_decision_reply_is_ignored() {
  local home record wake
  home="$TMP_ROOT/unauthorized-reply"
  mkdir -p "$home/state/x-context" "$home/state/x-inbox"
  chmod 700 "$home/state" "$home/state/x-context" "$home/state/x-inbox"
  make_fake_node "$home"
  record="$home/state/x-context/discord-notify-test.json"
  cat > "$record" <<'EOF'
{"schema":"fm-discord-decision-notification.v1","kind":"decision-notification","state":"sent","task_id":"task-a","key":"captain-hold-task-a-1","trigger":"captain-hold","channel_id":"1000000000000000001","message_id":"1352000000000000999","summary":"Choose how to proceed","options":["Continue","Pause"],"recorded_at":1790319000}
EOF
  chmod 600 "$record"
  FM_TEST_REAL_NODE=$(command -v node) \
    FM_DISCORD_FAKE_MESSAGES='[{"id":"1352000000000001002","channel_id":"1000000000000000001","guild_id":"1000000000000000000","author":{"id":"8000000000000000002","username":"member"},"content":"Continue","message_reference":{"message_id":"1352000000000000999","channel_id":"1000000000000000001"}}]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    FM_DISCORD_AUTHORIZED_USER_IDS=8000000000000000001 \
    "$ROOT/bin/fm-discord-poll.sh" > "$home/wake.log" || fail "poll failed"
  wake=$(cat "$home/wake.log")
  [ -z "$wake" ] || fail "unauthorized reply woke responder: $wake"
  assert_absent "$home/state/x-inbox/discord-sh-1352000000000001002.json" "unauthorized decision reply is not captured"
  assert_equals "null" "$(jq -r '.replied_to // "null"' "$record")" "unauthorized reply does not mark the notification answered"
  pass "Discord decision replies require an authorized user ID"
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

test_generic_report_refuses_a_captain_decision_ask() {
  local home log output rc
  home="$TMP_ROOT/report-refuses-decision"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  log="$home/posts.jsonl"
  # The defect this pins: a decision ask sent as a generic notification leaves the
  # captain's answer with no durable identity, so the reply lands as generic work.
  output=$(FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token \
    "$ROOT/bin/fm-discord-notify.sh" --report 1000000000000000001 \
      $'결정 필요 - 작업: task-a\n1. 계속 진행\n2. 보류' 2>&1); rc=$?
  expect_code 1 "$rc" "a decision ask cannot be delivered as a generic report"
  assert_contains "$output" "cannot be sent as a generic report" "generic report names the decision-path requirement"
  assert_absent "$home/posts.jsonl" "a refused decision ask posts nothing"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token \
    "$ROOT/bin/fm-discord-notify.sh" --report 1000000000000000001 "작업 완료 [task-a]: 끝" >/dev/null \
    || fail "an ordinary report was refused too"
  assert_equals "1" "$(wc -l < "$log" | tr -d '[:space:]')" "an ordinary report still posts exactly once"
  pass "a captain decision ask cannot leave through the generic report path"
}
test_ordinary_reply_refuses_a_captain_decision_ask() {
  local home log output rc
  home="$TMP_ROOT/reply-refuses-decision"
  mkdir -p "$home/state/x-context" "$home/state/x-inbox"
  chmod 700 "$home/state" "$home/state/x-context" "$home/state/x-inbox"
  make_fake_node "$home"
  log="$home/posts.jsonl"
  req=discord-sh-1352000000000002001
  printf '{"request_id":"%s","channel_id":"1000000000000000001","message_id":"1352000000000002000","text":"결정 필요 - proceed or hold?"}' "$req" > "$home/payload.json"
  output=$(FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token \
    "$ROOT/bin/fm-discord-reply.sh" "$req" "$home/payload.json" 2>&1); rc=$?
  expect_code 2 "$rc" "a decision ask cannot be delivered as an ordinary reply"
  assert_contains "$output" "cannot be sent as an ordinary reply" "ordinary reply names the decision path"
  assert_contains "$output" "fm-discord-notify.sh" "ordinary reply names the canonical decision command"
  assert_absent "$home/posts.jsonl" "a refused decision reply posts nothing"
  printf '{"request_id":"%s","channel_id":"1000000000000000001","message_id":"1352000000000002000","text":"작업 완료했습니다."}' "$req" > "$home/payload.json"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token \
    "$ROOT/bin/fm-discord-reply.sh" "$req" "$home/payload.json" >/dev/null \
    || fail "an ordinary reply was refused too"
  assert_equals "1" "$(wc -l < "$log" | tr -d '[:space:]')" "an ordinary reply still posts exactly once"
  pass "a captain decision ask cannot leave through the ordinary reply path"
}
test_registered_decision_correlates_in_a_fresh_process() {
  local home log wake req inbox record
  home="$TMP_ROOT/decision-restart"
  mkdir -p "$home/state/x-context" "$home/state/x-inbox"
  chmod 700 "$home/state" "$home/state/x-context" "$home/state/x-inbox"
  make_fake_node "$home"
  log="$home/posts.jsonl"
  # Send and answer in separate processes with nothing in memory between them:
  # the correlation identity has to come off disk, so a restart cannot lose it.
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify.sh" captain-hold task-restart captain-hold-task-restart-1 \
      "Choose how to proceed" "Continue|Pause" "Pause" >/dev/null \
    || fail "decision notification post failed"
  record=$(find "$home/state/x-context" -name 'discord-notify-*.json' -print -quit)
  FM_TEST_REAL_NODE=$(command -v node) \
    FM_DISCORD_FAKE_MESSAGES='[{"id":"1352000000000003001","channel_id":"1000000000000000001","guild_id":"1000000000000000000","author":{"id":"8000000000000000001","username":"captain"},"content":"Pause","message_reference":{"message_id":"1352000000000000999","channel_id":"1000000000000000001"}}]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    FM_DISCORD_AUTHORIZED_USER_IDS=8000000000000000001 \
    "$ROOT/bin/fm-discord-poll.sh" > "$home/wake.log" || fail "poll failed"
  wake=$(cat "$home/wake.log")
  req=discord-sh-1352000000000003001
  assert_equals "x-mention $req" "$wake" "a fresh poll process still wakes on the registered decision reply"
  inbox="$home/state/x-inbox/$req.json"
  assert_equals "discord-selfhosted-decision" "$(jq -r '.source' "$inbox")" "reply is a decision reply in a fresh process"
  assert_equals "captain-hold-task-restart-1" "$(jq -r '.decision.key' "$inbox")" "the decision key survives the process boundary"
  assert_equals "false" "$(jq -r '.decision.superseded' "$inbox")" "the first reply is not superseded"
  pass "a registered decision correlates its reply across a process restart"
}
test_reply_without_mention_keeps_decision_correlation() {
  local home wake req inbox
  home="$TMP_ROOT/reply-no-mention"
  mkdir -p "$home/state/x-context" "$home/state/x-inbox"
  chmod 700 "$home/state" "$home/state/x-context" "$home/state/x-inbox"
  make_fake_node "$home"
  cat > "$home/state/x-context/discord-notify-test.json" <<'EOF'
{"schema":"fm-discord-decision-notification.v1","kind":"decision-notification","state":"sent","task_id":"task-a","key":"captain-hold-task-a-1","trigger":"captain-hold","channel_id":"1000000000000000001","message_id":"1352000000000000999","summary":"Choose how to proceed","options":["Continue","Pause"],"recorded_at":1790319000}
EOF
  # Discord adds no @mention for a reply, so the decision binding - not a mention -
  # has to be what identifies this answer.
  FM_TEST_REAL_NODE=$(command -v node) \
    FM_DISCORD_FAKE_MESSAGES='[{"id":"1352000000000003100","channel_id":"1000000000000000001","guild_id":"1000000000000000000","author":{"id":"8000000000000000001","username":"captain"},"content":"Continue","mentions":[],"message_reference":{"message_id":"1352000000000000999","channel_id":"1000000000000000001"}}]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    FM_DISCORD_AUTHORIZED_USER_IDS=8000000000000000001 \
    "$ROOT/bin/fm-discord-poll.sh" > "$home/wake.log" || fail "poll failed"
  req=discord-sh-1352000000000003100
  assert_equals "x-mention $req" "$(cat "$home/wake.log")" "a mention-free decision reply still wakes"
  inbox="$home/state/x-inbox/$req.json"
  assert_equals "discord-selfhosted-decision" "$(jq -r '.source' "$inbox")" "a mention-free reply keeps the decision correlation"
  assert_equals "captain-hold-task-a-1" "$(jq -r '.decision.key' "$inbox")" "a mention-free reply carries the decision key"
  pass "a decision reply needs no @mention to stay correlated"
}
test_ordinary_command_stays_generic_while_a_decision_is_open() {
  local home wake req inbox
  home="$TMP_ROOT/command-with-open-decision"
  mkdir -p "$home/state/x-context" "$home/state/x-inbox"
  chmod 700 "$home/state" "$home/state/x-context" "$home/state/x-inbox"
  make_fake_node "$home"
  cat > "$home/state/x-context/discord-notify-test.json" <<'EOF'
{"schema":"fm-discord-decision-notification.v1","kind":"decision-notification","state":"sent","task_id":"task-a","key":"captain-hold-task-a-1","trigger":"captain-hold","channel_id":"1000000000000000001","message_id":"1352000000000000999","summary":"Choose how to proceed","options":["Continue","Pause"],"recorded_at":1790319000}
EOF
  # An open decision must not turn ordinary traffic into a decision answer.
  FM_TEST_REAL_NODE=$(command -v node) \
    FM_DISCORD_FAKE_MESSAGES='[{"id":"1352000000000003200","channel_id":"1000000000000000001","guild_id":"1000000000000000000","author":{"id":"8000000000000000001","username":"captain"},"content":"task-b 상태 알려줘"}]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    FM_DISCORD_COMMAND_CHANNELS=1000000000000000001 FM_DISCORD_AUTHORIZED_USER_IDS=8000000000000000001 \
    "$ROOT/bin/fm-discord-poll.sh" > "$home/wake.log" || fail "poll failed"
  req=discord-sh-1352000000000003200
  assert_equals "x-mention $req" "$(cat "$home/wake.log")" "an ordinary command still reaches firstmate"
  inbox="$home/state/x-inbox/$req.json"
  assert_equals "discord-selfhosted" "$(jq -r '.source' "$inbox")" "an ordinary command stays generic"
  assert_equals "null" "$(jq -r '.decision // "null"' "$inbox")" "an ordinary command carries no decision binding"
  assert_equals "null" "$(jq -r '.replied_to // "null"' "$home/state/x-context/discord-notify-test.json")" \
    "an ordinary command leaves the open decision unanswered"
  pass "an ordinary Discord command stays a generic command while a decision is open"
}
test_duplicate_reply_is_captured_once() {
  local home record wake req inbox
  home="$TMP_ROOT/duplicate-reply"
  mkdir -p "$home/state/x-context" "$home/state/x-inbox"
  chmod 700 "$home/state" "$home/state/x-context" "$home/state/x-inbox"
  make_fake_node "$home"
  record="$home/state/x-context/discord-notify-test.json"
  cat > "$record" <<'EOF'
{"schema":"fm-discord-decision-notification.v1","kind":"decision-notification","state":"sent","task_id":"task-a","key":"captain-hold-task-a-1","trigger":"captain-hold","channel_id":"1000000000000000001","message_id":"1352000000000000999","summary":"Choose how to proceed","options":["Continue","Pause"],"recorded_at":1790319000}
EOF
  messages='[{"id":"1352000000000003300","channel_id":"1000000000000000001","guild_id":"1000000000000000000","author":{"id":"8000000000000000001","username":"captain"},"content":"Continue","message_reference":{"message_id":"1352000000000000999","channel_id":"1000000000000000001"}}]'
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_MESSAGES="$messages" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    FM_DISCORD_AUTHORIZED_USER_IDS=8000000000000000001 \
    "$ROOT/bin/fm-discord-poll.sh" > "$home/first.log" || fail "first poll failed"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_MESSAGES="$messages" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    FM_DISCORD_AUTHORIZED_USER_IDS=8000000000000000001 \
    "$ROOT/bin/fm-discord-poll.sh" > "$home/second.log" || fail "second poll failed"
  req=discord-sh-1352000000000003300
  assert_equals "x-mention $req" "$(cat "$home/first.log")" "the first poll captures the reply"
  assert_equals "" "$(cat "$home/second.log")" "a replayed poll does not wake on the same reply again"
  assert_equals "1" "$(awk -F '\t' -v want="discord-$req" 'NF >= 5 && $3 == "check" && $4 == want { n++ } END { print n + 0 }' "$home/state/.wake-queue")" \
    "the durable wake queue holds the reply exactly once"
  inbox="$home/state/x-inbox/$req.json"
  assert_equals "Continue" "$(jq -r '.text' "$inbox")" "the captured reply keeps the captain's own words"
  assert_equals "1352000000000003300" "$(jq -r '.replied_to.message_id' "$record")" "the notification binds exactly one reply"
  pass "a duplicate poll of one decision reply is idempotent"
}
test_late_reply_to_answered_decision_is_superseded() {
  local home record wake first second
  home="$TMP_ROOT/late-reply"
  mkdir -p "$home/state/x-context" "$home/state/x-inbox"
  chmod 700 "$home/state" "$home/state/x-context" "$home/state/x-inbox"
  make_fake_node "$home"
  record="$home/state/x-context/discord-notify-test.json"
  cat > "$record" <<'EOF'
{"schema":"fm-discord-decision-notification.v1","kind":"decision-notification","state":"sent","task_id":"task-a","key":"captain-hold-task-a-1","trigger":"captain-hold","channel_id":"1000000000000000001","message_id":"1352000000000000999","summary":"Choose how to proceed","options":["Continue","Pause"],"recorded_at":1790319000}
EOF
  FM_TEST_REAL_NODE=$(command -v node) \
    FM_DISCORD_FAKE_MESSAGES='[{"id":"1352000000000003400","channel_id":"1000000000000000001","guild_id":"1000000000000000000","author":{"id":"8000000000000000001","username":"captain"},"content":"Continue","message_reference":{"message_id":"1352000000000000999","channel_id":"1000000000000000001"}}]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    FM_DISCORD_AUTHORIZED_USER_IDS=8000000000000000001 \
    "$ROOT/bin/fm-discord-poll.sh" > "$home/first.log" || fail "first poll failed"
  first=$home/state/x-inbox/discord-sh-1352000000000003400.json
  assert_equals "false" "$(jq -r '.decision.superseded' "$first")" "the first reply is not superseded"
  # The captain answers again after the decision was already applied. His words
  # must still reach firstmate, flagged so nothing rebinds to a settled decision.
  FM_TEST_REAL_NODE=$(command -v node) \
    FM_DISCORD_FAKE_MESSAGES='[{"id":"1352000000000003401","channel_id":"1000000000000000001","guild_id":"1000000000000000000","author":{"id":"8000000000000000001","username":"captain"},"content":"actually Pause","message_reference":{"message_id":"1352000000000000999","channel_id":"1000000000000000001"}}]' \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    FM_DISCORD_AUTHORIZED_USER_IDS=8000000000000000001 \
    "$ROOT/bin/fm-discord-poll.sh" > "$home/second.log" || fail "second poll failed"
  wake=$(cat "$home/second.log")
  assert_equals "x-mention discord-sh-1352000000000003401" "$wake" "a late decision reply is not silently dropped"
  second=$home/state/x-inbox/discord-sh-1352000000000003401.json
  assert_equals "actually Pause" "$(jq -r '.text' "$second")" "the late reply keeps the captain's own words"
  assert_equals "true" "$(jq -r '.decision.superseded' "$second")" "the late reply is flagged superseded"
  assert_equals "1352000000000003400" "$(jq -r '.decision.superseded_by' "$second")" "the late reply names the reply it supersedes"
  assert_equals "captain-hold-task-a-1" "$(jq -r '.decision.key' "$second")" "the late reply still names the decision it answers"
  assert_equals "1352000000000003400" "$(jq -r '.replied_to.message_id' "$record")" \
    "the notification keeps its first binding instead of rebinding"
  assert_equals "Continue" "$(jq -r '.text' "$first")" "the original captured reply is not overwritten"
  pass "a late reply to an already-answered decision is captured as superseded"
}

test_ask_user_gate_alone_triggers_no_push() {
  local home posts
  home="$TMP_ROOT/ask-user-decided-in-scope"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  posts="$home/posts.jsonl"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$posts" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a \
      'needs-decision [key=nm-run42-review]: ask-user findings=f1 file=/private/findings.txt' \
    >/dev/null || fail "ask-user status classification failed"
  [ ! -s "$posts" ] || fail "a raw ask-user gate alone sent a Discord notification"
  [ -z "$(find "$home/state/x-context" -name 'discord-notify-*.json' -print -quit)" ] \
    || fail "a raw ask-user gate created a notification record"
  pass "a raw ask-user gate never pushes on its own - firstmate may still decide it in-scope"
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
  assert_contains "$(jq -r '.summary' "$record")" "app" "PR summary names the repo extracted from the PR URL"
  assert_equals "1" "$(wc -l < "$posts" | tr -d '[:space:]')" "one yolo-off notification sent"
  pass "PR-ready notifications require yolo=off"
}

test_pr_push_names_gitlab_project() {
  local home record
  home="$TMP_ROOT/pr-trigger-gitlab"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$home/posts.jsonl" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a \
    'needs-decision [key=pr-ready-task-a]: task=task-a yolo=off pull request ready: https://gitlab.example.com/some-group/widgets-service/-/merge_requests/7 choose merge or leave open' >/dev/null \
    || fail "yolo-off GitLab MR status did not trigger a push"
  record=$(find "$home/state/x-context" -name 'discord-notify-*.json' -print -quit)
  assert_contains "$(jq -r '.summary' "$record")" "widgets-service" \
    "PR summary names the project extracted from the GitLab MR URL, independent of the URL substring"
  pass "PR-ready notifications name the project for an accepted GitLab merge-request URL too"
}

test_pr_ready_summary_names_the_task_title() {
  # The captain reads which piece of work is waiting for him, so the review
  # notification carries the backlog title beside the task id.
  local home record backlog
  home="$TMP_ROOT/pr-trigger-title"
  mkdir -p "$home/state/x-context" "$home/data"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  [ -n "$TASKS_AXI_BIN" ] || fail "tasks-axi is required for the task-title regression"
  backlog="$home/data/backlog.md"
  "$TASKS_AXI_BIN" add task-a 'Ship the billing endpoint' --file "$backlog" >/dev/null 2>&1 \
    || fail "could not seed the backlog fixture"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$home/posts.jsonl" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a \
    'needs-decision [key=pr-ready-task-a]: task=task-a yolo=off pull request ready: https://github.com/acme/app/pull/42 choose merge or leave open' >/dev/null \
    || fail "yolo-off PR status did not trigger a push"
  record=$(find "$home/state/x-context" -name 'discord-notify-*.json' -print -quit)
  assert_contains "$(jq -r '.summary' "$record")" "Ship the billing endpoint" \
    "PR summary names the task title from the backlog"
  assert_contains "$(jq -r '.summary' "$record")" "task-a" \
    "PR summary names the task id beside its title"
  assert_contains "$(jq -r '.summary' "$record")" "검토할 풀 리퀘스트가 준비되었습니다" \
    "PR summary is written in Korean"
  pass "a PR-ready notification names the task title and id in Korean"
}

test_done_status_sends_plain_report() {
  local home log body
  home="$TMP_ROOT/done-status"
  mkdir -p "$home/state"
  chmod 700 "$home/state"
  make_fake_node "$home"
  log="$home/posts.jsonl"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a \
      'done: wired up the new endpoint' >/dev/null \
    || fail "done status classification failed"
  assert_equals "1" "$(wc -l < "$log" | tr -d '[:space:]')" "done status sends exactly one report"
  assert_contains "$(jq -r '.url' "$log")" "1000000000000000001" "done status sends to configured channel"
  body=$(jq -r '.payload.content' "$log")
  assert_contains "$body" "task-a" "done report includes task id"
  assert_contains "$body" "wired up the new endpoint" "done report includes the note text"
  [ -n "$(find "$home/state/x-context" -name 'discord-completion-*.json' -print -quit)" ] \
    || fail "done status did not record its successful delivery"
  pass "a done status line sends a plain Discord report with the worker's note"
}

test_decision_notification_names_the_task_title() {
  # A decision ping names the work by its backlog title beside the id, so the
  # captain sees which task is waiting instead of decoding an opaque slug.
  local home posts content backlog
  home="$TMP_ROOT/decision-title"
  mkdir -p "$home/state/x-context" "$home/data"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  [ -n "$TASKS_AXI_BIN" ] || fail "tasks-axi is required for the task-title regression"
  backlog="$home/data/backlog.md"
  "$TASKS_AXI_BIN" add task-a 'Ship the billing endpoint' --file "$backlog" >/dev/null 2>&1 \
    || fail "could not seed the backlog fixture"
  posts="$home/posts.jsonl"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$posts" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify.sh" captain-hold task-a captain-hold-task-a-1 \
      "보류된 작업을 어떻게 진행할지" "요청대로 진행|보류 상태로 두기" "보류 상태로 두기" >/dev/null \
    || fail "captain-hold push failed"
  content=$(jq -r '.payload.content' "$posts")
  assert_contains "$content" "Ship the billing endpoint" "decision message names the task title"
  assert_contains "$content" "task-a" "decision message names the task id beside its title"
  assert_contains "$content" "**결정 필요**" "decision message keeps its Korean decision header"
  pass "a decision notification names the task by its backlog title and id"
}

test_done_report_names_the_task_title() {
  # A completion tells the captain which task finished: the backlog title
  # beside the id, in Korean, with the recorded outcome.
  local home log body backlog
  home="$TMP_ROOT/done-title"
  mkdir -p "$home/state" "$home/data"
  chmod 700 "$home/state"
  make_fake_node "$home"
  [ -n "$TASKS_AXI_BIN" ] || fail "tasks-axi is required for the task-title regression"
  backlog="$home/data/backlog.md"
  "$TASKS_AXI_BIN" add task-a 'Wire the billing endpoint' --file "$backlog" >/dev/null 2>&1 \
    || fail "could not seed the backlog fixture"
  log="$home/posts.jsonl"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a \
      'done: endpoint wired and tested' >/dev/null \
    || fail "done status classification failed"
  body=$(jq -r '.payload.content' "$log")
  assert_contains "$body" "작업 완료" "done report headline is Korean"
  assert_contains "$body" "Wire the billing endpoint" "done report names the task title"
  assert_contains "$body" "task-a" "done report names the task id"
  assert_contains "$body" "endpoint wired and tested" "done report states the outcome"
  pass "a done report is Korean and names the task title, the task id, and the outcome"
}

test_done_record_is_private_valid_json() {
  local home log note expected_note record
  home="$TMP_ROOT/done-private-record"
  mkdir -p "$home/state"
  make_fake_node "$home"
  log="$home/posts.jsonl"
  note='quote " slash \ line one'
  note="$note"$'\n''line two'
  expected_note='quote " slash \ line one line two'
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a "done: $note" >/dev/null \
    || fail "private done record delivery failed"
  record=$(find "$home/state/x-context" -type f -name 'discord-completion-*.json' -print -quit)
  [ -n "$record" ] && [ -f "$record" ] && [ ! -L "$record" ] \
    || fail "done record is not a regular file"
  assert_equals "700" "$(discord_path_mode "$home/state/x-context")" "done record directory is private"
  assert_equals "600" "$(discord_path_mode "$record")" "done record is private"
  assert_equals "1" "$(discord_path_links "$record")" "done record has one link"
  jq -e . "$record" >/dev/null || fail "done record is not valid JSON"
  assert_equals "sent" "$(jq -r .state "$record")" "a delivered completion is marked sent"
  assert_equals "fm-discord-completion-notification.v1" "$(jq -r .schema "$record")" "completion record schema"
  assert_contains "$(jq -r .message "$record")" "$expected_note" "done record preserves escaped note data"
  pass "a done record is private valid JSON and marked sent only after delivery"
}

test_nonterminal_done_status_sends_no_report() {
  local home log
  home="$TMP_ROOT/active-pr-monitoring-status"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  log="$home/posts.jsonl"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" \
    FM_DISCORD_FAKE_CREW_STATE='state: working · source: run-step · validating' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a \
      'done: background verification continues' >/dev/null \
    || fail "nonterminal done status classification failed"
  [ ! -s "$log" ] || fail "nonterminal done status sent a Discord notification"
  pass "a nonterminal done status sends no notification"
}

test_pr_awaiting_merge_done_status_sends_no_report() {
  local home log
  home="$TMP_ROOT/pr-awaiting-merge-status"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  log="$home/posts.jsonl"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" \
    FM_DISCORD_FAKE_CREW_STATE='state: done · source: run-step · checks green · pr: awaiting merge decision' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a \
      'done: background verification continues' >/dev/null \
    || fail "PR-awaiting-merge done status classification failed"
  [ ! -s "$log" ] || fail "PR-awaiting-merge done status sent a Discord notification"
  pass "a PR-awaiting-merge done status sends no notification"
}

test_failed_done_delivery_retries() {
  local home log
  home="$TMP_ROOT/done-delivery-retry"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  log="$home/posts.jsonl"
  if FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    FM_DISCORD_FAKE_POST_STATUS=500 PATH="$home/fake-bin:$BASE_PATH" \
    FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DISCORD_BOT_TOKEN=fake-token \
    FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a \
      'done: wired up the new endpoint' >/dev/null 2>&1; then
    fail "failed completion delivery returned success"
  fi
  assert_equals "failed" \
    "$(jq -r .state "$(find "$home/state/x-context" -name 'discord-completion-*.json' -print -quit)")" \
    "a failed completion stays retryable in the outbox"
  # Re-reading the same status line must not double-post; the retry sweep is the
  # single owner of redelivery, exactly as it is for a decision.
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a \
      'done: wired up the new endpoint' >/dev/null \
    || fail "re-reading a failed completion reported failure"
  assert_equals "1" "$(wc -l < "$log" | tr -d '[:space:]')" "re-reading a failed completion does not double-post"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token \
    "$ROOT/bin/fm-discord-notify.sh" --retry-pending >/dev/null \
    || fail "the retry sweep did not redeliver the failed completion"
  assert_equals "2" "$(wc -l < "$log" | tr -d '[:space:]')" "the retry sweep redelivers a failed completion"
  assert_equals "sent" \
    "$(jq -r .state "$(find "$home/state/x-context" -name 'discord-completion-*.json' -print -quit)")" \
    "a redelivered completion is marked sent"
  pass "a failed completion delivery is retried by the sweep, not by a re-read"
}

test_unconfigured_done_status_is_silent_and_retryable() {
  local home log
  home="$TMP_ROOT/done-unconfigured"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  log="$home/posts.jsonl"
  PATH="$BASE_PATH" FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN='' "$ROOT/bin/fm-discord-notify-status.sh" task-a \
    'done: wired up the new endpoint' >/dev/null \
    || fail "unconfigured completion returned failure"
  [ -z "$(find "$home/state/x-context" -name 'discord-completion-*.json' -print -quit 2>/dev/null)" ] \
    || fail "unconfigured completion was marked delivered"
  PATH="$BASE_PATH" FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=not-a-channel \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a \
      'done: wired up the new endpoint' >/dev/null \
    || fail "malformed Discord channel returned failure"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a \
      'done: wired up the new endpoint' >/dev/null \
    || fail "completion did not retry after Discord was configured"
  assert_equals "1" "$(wc -l < "$log" | tr -d '[:space:]')" "unconfigured completion is retried when configured"
  pass "an unconfigured completion is silent and remains retryable"
}

test_blocked_status_sends_no_report() {
  local home log
  home="$TMP_ROOT/blocked-status"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  log="$home/posts.jsonl"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-b \
      'blocked: waiting on API credentials' >/dev/null \
    || fail "blocked status classification failed"
  [ ! -s "$log" ] || fail "blocked status sent a Discord notification"
  pass "a blocked status line sends no Discord notification"
}

test_failed_status_sends_no_report() {
  local home log
  home="$TMP_ROOT/failed-status"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  log="$home/posts.jsonl"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-c \
      'failed: build script exited 1' >/dev/null \
    || fail "failed status classification failed"
  [ ! -s "$log" ] || fail "failed status sent a Discord notification"
  pass "a failed status line sends no Discord notification"
}

test_done_status_lands_once_across_concurrent_senders() {
  local home log pids=0 i
  home="$TMP_ROOT/done-concurrent"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  log="$home/posts.jsonl"
  # Two senders racing the same completion is the replay/concurrency case the
  # exclusive-create outbox record exists for: the nonce makes Discord itself
  # collapse a second POST, and only one record can exist.
  for i in 1 2 3 4; do
    FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
      PATH="$home/fake-bin:$BASE_PATH" FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" \
      FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
      "$ROOT/bin/fm-discord-notify-status.sh" task-a \
        'done: wired up the new endpoint' >/dev/null 2>&1 &
    pids=$((pids + 1))
  done
  i=0
  while [ "$i" -lt "$pids" ]; do wait -n 2>/dev/null || wait; i=$((i + 1)); done
  assert_equals "1" "$(find "$home/state/x-context" -name 'discord-completion-*.json' | wc -l | tr -d ' ')" \
    "concurrent completions share one outbox record"
  assert_equals "1" "$(wc -l < "$log" | tr -d '[:space:]')" \
    "concurrent completions post exactly one message"
  pass "a completion lands exactly once even when senders race"
}

test_done_status_recovers_from_a_crash_before_its_receipt() {
  local home log record nonce
  home="$TMP_ROOT/done-post-crash"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  log="$home/posts.jsonl"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a \
      'done: wired up the new endpoint' >/dev/null \
    || fail "completion delivery failed"
  record=$(find "$home/state/x-context" -name 'discord-completion-*.json' -print -quit)
  nonce=$(jq -r .nonce "$record")
  # Simulate the crash window: the message reached Discord, but the process died
  # before it could stamp the receipt. The record reads sending, the retry
  # read-backs by nonce, adopts the message already there, and does not repost.
  jq -c '.state="sending" | del(.message_id) | .attempted_at=1' "$record" > "$record.tmp" \
    && mv "$record.tmp" "$record"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    FM_DISCORD_FAKE_MESSAGES="[{\"id\":\"1352000000000000500\",\"channel_id\":\"1000000000000000001\",\"author\":{\"id\":\"9000000000000000001\"},\"nonce\":\"$nonce\",\"timestamp\":\"2030-01-01T00:00:00.000Z\"}]" \
    PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify.sh" --retry-pending >/dev/null \
    || fail "retry of a crashed completion failed"
  assert_equals "1" "$(wc -l < "$log" | tr -d '[:space:]')" \
    "a crashed completion is adopted from history instead of reposted"
  assert_equals "sent" "$(jq -r .state "$record")" "the adopted completion is marked sent"
  assert_equals "1352000000000000500" "$(jq -r .message_id "$record")" "the adopted completion records its real message id"
  pass "a completion that crashed before its receipt is adopted, not reposted"
}

test_done_status_deduplicates_repeated_lines() {
  local home log
  home="$TMP_ROOT/done-dedup"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  log="$home/posts.jsonl"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a \
      'done: wired up the new endpoint' >/dev/null \
    || fail "done status classification failed"
  assert_equals "1" "$(wc -l < "$log" | tr -d '[:space:]')" "first done status sends exactly one report"
  FM_TEST_REAL_NODE=$(command -v node) FM_DISCORD_FAKE_POST_LOG="$log" \
    PATH="$home/fake-bin:$BASE_PATH" FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$ROOT/bin/fm-discord-notify-status.sh" task-a \
      'done: wired up the new endpoint' >/dev/null \
    || fail "done status classification failed"
  assert_equals "1" "$(wc -l < "$log" | tr -d '[:space:]')" "duplicate done status does not send again"
  pass "a repeated done status line does not produce duplicate Discord posts"
}

test_no_token_is_inert
test_quiet_report_posts_plain_snapshot
test_report_requires_token
test_report_helper_refuses_non_quiet_mode
test_report_helper_sends_bearings_snapshot
test_notify_records_reply_binding
test_recommendation_must_be_an_offered_option
test_failed_notification_retries_from_durable_outbox
test_profile_failure_keeps_retryable_intent
test_stale_sending_notification_recovers_without_duplicate_post
test_captain_hold_triggers_push
test_captain_hold_truncates_long_reason_for_discord
test_reply_to_notification_enters_existing_inbox
test_perm_ask_reply_carries_the_identity_the_applier_needs
test_captured_reply_without_offer_recovers_one_wake
test_unauthorized_decision_reply_is_ignored
test_no_unrelated_reply_is_captured
test_generic_report_refuses_a_captain_decision_ask
test_ordinary_reply_refuses_a_captain_decision_ask
test_registered_decision_correlates_in_a_fresh_process
test_reply_without_mention_keeps_decision_correlation
test_ordinary_command_stays_generic_while_a_decision_is_open
test_duplicate_reply_is_captured_once
test_late_reply_to_answered_decision_is_superseded
test_ask_user_gate_alone_triggers_no_push
test_ask_user_escalation_hold_carries_finding_text
test_pr_push_requires_yolo_off
test_pr_push_names_gitlab_project
test_pr_ready_summary_names_the_task_title
test_decision_notification_names_the_task_title
test_done_status_sends_plain_report
test_done_report_names_the_task_title
test_done_record_is_private_valid_json
test_done_status_lands_once_across_concurrent_senders
test_done_status_recovers_from_a_crash_before_its_receipt
test_nonterminal_done_status_sends_no_report
test_pr_awaiting_merge_done_status_sends_no_report
test_failed_done_delivery_retries
test_unconfigured_done_status_is_silent_and_retryable
test_blocked_status_sends_no_report
test_failed_status_sends_no_report
test_done_status_deduplicates_repeated_lines
