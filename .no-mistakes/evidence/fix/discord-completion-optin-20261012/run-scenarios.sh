#!/usr/bin/env bash
# Live scenario driver for fix/discord-completion-optin-20261012.
# Drives the REAL shipped scripts against disposable homes. No source is stubbed
# except the outbound Discord transport (a local fake node) for the one scenario
# that must prove a real send still happens.
set -u
ROOT=${ROOT:?ROOT must point at the gate worktree}
EV=${EV:?EV must point at the evidence directory}
BASE_COMMIT=${BASE_COMMIT:?}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-disc-live.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0
ok()   { PASS_COUNT=$((PASS_COUNT + 1)); printf '  PASS: %s\n' "$1"; }
bad()  { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '  FAIL: %s\n' "$1"; }
check_eq() { # <expected> <actual> <label>
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected [$1], got [$2])"; fi
}

# A disposable home with a credential-free .env and a cable to a fake crew state.
make_home() { # <name>
  local home="$WORK/$1"
  mkdir -p "$home/state/x-context" "$home/fake-bin"
  chmod 700 "$home/state" "$home/state/x-context"
  : > "$home/.env"
  cat > "$home/fake-bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "state: done · source: fake"
SH
  chmod +x "$home/fake-bin/fm-crew-state.sh"
  printf '%s\n' "$home"
}

# The real product's completion bridge. Ambiguous ambient Discord settings are
# stripped so the home's own empty .env is authoritative.
run_bridge() { # <home> <name> <message> [env assignments...]
  local home=$1 name=$2 message=$3; shift 3
  env -u FM_DISCORD_BOT_TOKEN -u FM_DISCORD_CHANNEL_ID -u FM_DISCORD_ALLOWED_CHANNELS \
      -u FM_DISCORD_TOKEN -u FM_DISCORD_EXCLUDE_CHANNELS -u FM_DISCORD_ALLOW_DMS -u FMX_ENV_FILE \
      FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" \
      "$@" bash "$ROOT/bin/fm-discord-notify-status.sh" "$name" "$message" \
      >"$home/$name.stdout" 2>"$home/$name.stderr"
}

records() { find "$1/state/x-context" -name 'discord-completion-*.json' -print 2>/dev/null; }

printf '=====================================================================\n'
printf 'Scenario 1: unconfigured done: status is a silent success\n'
printf '=====================================================================\n'
h=$(make_home s1)
set +e
run_bridge "$h" task-a "done: wired up the new endpoint"
rc=$?
set -e
check_eq "0" "$rc" "completion bridge exits 0 with no token"
check_eq "" "$(cat "$h/task-a.stderr")" "completion bridge writes nothing to stderr"
check_eq "" "$(records "$h")" "completion bridge records no delivery"
printf '  rc=%s stderr=[%s]\n' "$rc" "$(cat "$h/task-a.stderr")"

printf '\n=====================================================================\n'
printf 'Scenario 2: token set but channel missing/malformed still fails closed\n'
printf '=====================================================================\n'
h=$(make_home s2)
set +e
run_bridge "$h" no-channel "done: wired up the new endpoint" FM_DISCORD_BOT_TOKEN=fake-token
rc=$?
set -e
check_eq "1" "$rc" "token without any channel exits 1"
check_eq "fm-discord-notify-status: no Discord channel configured; completion not sent" \
  "$(cat "$h/no-channel.stderr")" "token-without-channel diagnostic"
check_eq "" "$(records "$h")" "token without channel records no delivery"

set +e
run_bridge "$h" bad-channel "done: wired up the new endpoint" \
  FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=not-a-channel
rc=$?
set -e
check_eq "1" "$rc" "token with a malformed channel id exits 1"
check_eq "fm-discord-notify-status: invalid Discord channel id; completion not sent" \
  "$(cat "$h/bad-channel.stderr")" "malformed-channel diagnostic"
check_eq "" "$(records "$h")" "malformed channel records no delivery"

printf '\n=====================================================================\n'
printf 'Scenario 3: decision-push behavior in fm-discord-notify.sh is unchanged\n'
printf '=====================================================================\n'
h=$(make_home s3)
set +e
env -u FM_DISCORD_BOT_TOKEN -u FM_DISCORD_CHANNEL_ID -u FM_DISCORD_ALLOWED_CHANNELS \
    -u FM_DISCORD_TOKEN -u FMX_ENV_FILE FM_HOME="$h" FM_DISCORD_BOT_TOKEN='' \
    bash "$ROOT/bin/fm-discord-notify.sh" captain-hold task-a captain-hold-task-a-1 \
    "Needs a decision" "Continue|Pause" "Pause" >"$h/dec.stdout" 2>"$h/dec.stderr"
rc=$?
set -e
check_eq "1" "$rc" "decision push without a token still exits 1"
check_eq "fm-discord-notify: missing Discord bot token" "$(cat "$h/dec.stderr")" \
  "decision push missing-token diagnostic"
set +e
env -u FM_DISCORD_BOT_TOKEN -u FM_DISCORD_CHANNEL_ID -u FM_DISCORD_ALLOWED_CHANNELS \
    -u FM_DISCORD_TOKEN -u FMX_ENV_FILE FM_HOME="$h" FM_DISCORD_BOT_TOKEN='' \
    bash "$ROOT/bin/fm-discord-notify.sh" --retry-pending >"$h/retry.stdout" 2>"$h/retry.stderr"
rc=$?
set -e
check_eq "0" "$rc" "--retry-pending unconfigured still exits 0"
check_eq "" "$(cat "$h/retry.stderr")" "--retry-pending unconfigured is silent"

printf '\n=====================================================================\n'
printf 'Scenario 4: a configured completion still posts exactly once\n'
printf '=====================================================================\n'
h=$(make_home s4)
# Fake transport: a real node process whose fetch never reaches Discord.
cat > "$h/fake-bin/node" <<'SH'
#!/usr/bin/env bash
set -u
script=$1
shift
exec "$FM_TEST_REAL_NODE" --input-type=module -e '
  import { pathToFileURL } from "node:url";
  const [script, ...args] = process.argv.slice(1);
  process.argv = [process.argv[0], script, ...args];
  globalThis.fetch = async (url, options = {}) => {
    if (url === "https://discord.com/api/v10/users/@me") {
      return Response.json({ id: "9000000000000000001" });
    }
    if (url.includes("/messages") && options.method === "POST") {
      const payload = JSON.parse(options.body);
      if (process.env.FM_DISCORD_FAKE_POST_LOG) {
        await import("node:fs/promises").then(({ appendFile }) =>
          appendFile(process.env.FM_DISCORD_FAKE_POST_LOG, JSON.stringify({ url, payload }) + "\n"));
      }
      return Response.json({ id: "1352000000000000999", channel_id: "1000000000000000001" });
    }
    if (url.includes("/channels/") && url.includes("/messages")) return Response.json([]);
    return new Response("not found", { status: 404 });
  };
  await import(pathToFileURL(script).href);
' "$script" "$@"
SH
chmod +x "$h/fake-bin/node"
: > "$h/posts.jsonl"
set +e
env -u FM_DISCORD_BOT_TOKEN -u FM_DISCORD_CHANNEL_ID -u FM_DISCORD_ALLOWED_CHANNELS \
    -u FM_DISCORD_TOKEN -u FMX_ENV_FILE \
    FM_TEST_REAL_NODE="$(command -v node)" FM_DISCORD_FAKE_POST_LOG="$h/posts.jsonl" \
    PATH="$h/fake-bin:$PATH" FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" \
    FM_CREW_STATE_BIN="$h/fake-bin/fm-crew-state.sh" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    bash "$ROOT/bin/fm-discord-notify-status.sh" task-a 'done: wired up the new endpoint' \
    >"$h/send.stdout" 2>"$h/send.stderr"
rc=$?
set -e
check_eq "0" "$rc" "a configured completion exits 0"
check_eq "1" "$(wc -l < "$h/posts.jsonl" | tr -d '[:space:]')" "a configured completion posts exactly once"
grep -q '작업 완료' "$h/posts.jsonl" && ok "the posted completion body reaches the transport" \
  || bad "the posted completion body is missing"
# Re-reading the same status line must not double-post.
set +e
env -u FM_DISCORD_BOT_TOKEN -u FM_DISCORD_CHANNEL_ID -u FM_DISCORD_ALLOWED_CHANNELS \
    -u FM_DISCORD_TOKEN -u FMX_ENV_FILE \
    FM_TEST_REAL_NODE="$(command -v node)" FM_DISCORD_FAKE_POST_LOG="$h/posts.jsonl" \
    PATH="$h/fake-bin:$PATH" FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" \
    FM_CREW_STATE_BIN="$h/fake-bin/fm-crew-state.sh" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    bash "$ROOT/bin/fm-discord-notify-status.sh" task-a 'done: wired up the new endpoint' \
    >/dev/null 2>&1
rc=$?
set -e
check_eq "0" "$rc" "re-reading the same completion exits 0"
check_eq "1" "$(wc -l < "$h/posts.jsonl" | tr -d '[:space:]')" "the same completion is not double-posted"

printf '\n=====================================================================\n'
printf 'Scenario 5: the pre-fix bridge really did fail closed (regression proof)\n'
printf '=====================================================================\n'
basebin="$WORK/base-bin"
cp -R "$ROOT/bin" "$basebin"
git -C "$ROOT" show "$BASE_COMMIT:bin/fm-discord-notify-status.sh" > "$basebin/fm-discord-notify-status.sh"
chmod +x "$basebin/fm-discord-notify-status.sh"
h=$(make_home s5)
set +e
env -u FM_DISCORD_BOT_TOKEN -u FM_DISCORD_CHANNEL_ID -u FM_DISCORD_ALLOWED_CHANNELS \
    -u FM_DISCORD_TOKEN -u FM_DISCORD_EXCLUDE_CHANNELS -u FM_DISCORD_ALLOW_DMS -u FMX_ENV_FILE \
    FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" \
    FM_CREW_STATE_BIN="$h/fake-bin/fm-crew-state.sh" \
    bash "$basebin/fm-discord-notify-status.sh" task-a 'done: x' \
    >"$h/base.stdout" 2>"$h/base.stderr"
rc=$?
set -e
check_eq "1" "$rc" "the pre-fix bridge exits 1 with no token"
check_eq "fm-discord-notify-status: missing Discord bot token; completion not sent" \
  "$(cat "$h/base.stderr")" "the pre-fix bridge's stderr diagnostic"
printf '  base stderr=[%s]\n' "$(cat "$h/base.stderr")"

printf '\n=====================================================================\n'
printf 'RESULT: %s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
printf '=====================================================================\n'
[ "$FAIL_COUNT" -eq 0 ]
