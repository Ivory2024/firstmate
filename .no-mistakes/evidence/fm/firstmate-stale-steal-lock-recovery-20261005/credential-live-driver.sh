#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
REAL_NODE=$(command -v node)
fixture=$(mktemp -d "$ROOT/.credential-live.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/hostile/state" "$fixture/fake-bin" "$fixture/tmp"
cat > "$fixture/hostile/.env" <<'ENV'
FM_DISCORD_BOT_TOKEN=dummy-hostile-bot
FM_DISCORD_CHANNEL_ID=1000000000000000001
FMX_PAIRING_TOKEN=dummy-hostile-relay
ENV
cat > "$fixture/transport.cjs" <<'JS'
const fs = require('node:fs');
globalThis.fetch = async (url, options = {}) => {
  fs.appendFileSync(process.env.REQUEST_LOG, JSON.stringify({url, method: options.method || 'GET'}) + '\n');
  if (options.method === 'POST') {
    fs.appendFileSync(process.env.POST_LOG, 'POST\n');
    return Response.json({id: '1352000000000000999', channel_id: '1000000000000000001'});
  }
  if (url.endsWith('/users/@me')) return Response.json({id:'9000000000000000001'});
  return Response.json([]);
};
JS
cat > "$fixture/fake-bin/node" <<'SH'
#!/usr/bin/env bash
exec "$REAL_NODE" --require "$TRANSPORT" "$@"
SH
chmod +x "$fixture/fake-bin/node"
export REAL_NODE TRANSPORT="$fixture/transport.cjs" POST_LOG="$fixture/posts" REQUEST_LOG="$fixture/requests"
export PATH="$fixture/fake-bin:$PATH" TMPDIR="$fixture/tmp"
: > "$POST_LOG"
: > "$REQUEST_LOG"
echo 'CONTROL: production notification CLI with dummy credential and intercepted fetch'
FM_HOME="$fixture/hostile" bash "$ROOT/bin/fm-discord-notify.sh" --report 1000000000000000001 'isolated transport control'
[ "$(wc -l < "$POST_LOG" | tr -d ' ')" = 1 ]
echo 'CONTROL: exactly one fake POST; no real network transport'
: > "$POST_LOG"
: > "$REQUEST_LOG"
export ROOT HOSTILE="$fixture/hostile"
FM_HOME="$HOSTILE" FM_DISCORD_BOT_TOKEN=dummy-inherited-bot FM_DISCORD_TOKEN=dummy-inherited-alias FMX_PAIRING_TOKEN=dummy-inherited-relay FMX_ENV_FILE="$HOSTILE/.env" bash -euc '
  unset FM_TEST_LIB_SOURCED
  . "$ROOT/tests/lib.sh"
  for name in FM_DISCORD_BOT_TOKEN FM_DISCORD_TOKEN FMX_PAIRING_TOKEN FMX_ENV_FILE; do
    printf "%s=%s\n" "$name" "${!name-<unset>}"
    [ "${!name+x}" != x ]
  done
  [ "$FM_HOME" = "$FM_TEST_DEFAULT_HOME" ]
  [ "$FM_HOME" != "$HOSTILE" ]
  [ -f "$FM_HOME/.env" ] && [ ! -s "$FM_HOME/.env" ]
  for dir in state config data; do [ -d "$FM_HOME/$dir" ]; done
  echo "HOME: replaced with credential-free default; state/config/data exist"
  set +e
  bash "$ROOT/bin/fm-discord-notify.sh" --report 1000000000000000001 "hostile isolation probe"
  rc=$?
  set -e
  printf "CLI exit=%s\n" "$rc"
  [ "$rc" = 1 ]
  [ ! -s "$POST_LOG" ] && [ ! -s "$REQUEST_LOG" ]
  echo "PASS: actual production CLI; zero POSTs; zero transport requests"
'
