#!/usr/bin/env bash
set -eu
ROOT=$PWD
LAB=$(mktemp -d "$ROOT/.credential-live.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
mkdir -p "$LAB/hostile/state" "$LAB/fake-bin" "$LAB/tmp"
printf '%s\n' 'FM_DISCORD_BOT_TOKEN=dummy-home-token' 'FM_DISCORD_CHANNEL_ID=1000000000000000001' > "$LAB/hostile/.env"
export REAL_NODE=$(command -v node)
export POST_LOG="$LAB/posts" REQUEST_LOG="$LAB/requests"
: > "$POST_LOG"
: > "$REQUEST_LOG"
cat > "$LAB/transport.cjs" <<'JS'
const fs = require('node:fs');
globalThis.fetch = async (url, options = {}) => {
 fs.appendFileSync(process.env.REQUEST_LOG, String(url) + '\n');
 if (options.method === 'POST') fs.appendFileSync(process.env.POST_LOG, String(url) + '\n');
 return Response.json({id:'1352000000000000999',channel_id:'1000000000000000001'});
};
JS
cat > "$LAB/fake-bin/node" <<'SH'
#!/usr/bin/env bash
exec "$REAL_NODE" --require "$TRANSPORT" "$@"
SH
chmod +x "$LAB/fake-bin/node"
export TRANSPORT="$LAB/transport.cjs" PATH="$LAB/fake-bin:$PATH"
unset FM_DISCORD_BOT_TOKEN FMX_ENV_FILE FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_TEST_LIB_SOURCED
export FM_HOME="$LAB/hostile" FM_DISCORD_TOKEN=dummy-alias FMX_PAIRING_TOKEN=dummy-pairing
bash "$ROOT/bin/fm-discord-notify.sh" --report 1000000000000000001 'disposable transport control'
[ "$(wc -l < "$POST_LOG" | tr -d ' ')" = 1 ]
printf 'Control: actual notification CLI produced 1 intercepted POST; no network transport used.\n'
: > "$POST_LOG"
: > "$REQUEST_LOG"
export TMPDIR="$LAB/tmp"
bash -eu -c '
 . "$1/tests/lib.sh"
 [ "${FM_DISCORD_BOT_TOKEN+x}" != x ]
 [ "${FM_DISCORD_TOKEN+x}" != x ]
 [ "${FMX_PAIRING_TOKEN+x}" != x ]
 [ "$FM_HOME" = "$FM_TEST_DEFAULT_HOME" ]
 [ "$FM_HOME" != "$2/hostile" ]
 [ ! -s "$FM_HOME/.env" ]
 for dir in state config data; do [ -d "$FM_HOME/$dir" ]; done
 printf "After library: BOT=<unset> alias=<unset> FMX=<unset>; home replaced; empty .env; state/config/data exist.\n"
 bash "$1/bin/fm-discord-notify.sh" ask-user isolated-task nm-live "isolated decision" "Approve|Reject" Approve
 printf "Decision CLI exit=0.\n"
 set +e
 bash "$1/bin/fm-discord-notify.sh" --report 1000000000000000001 "isolated report"
 rc=$?
 set -e
 [ "$rc" = 1 ]
 printf "Report CLI exit=1 (missing token).\n"
' _ "$ROOT" "$LAB"
[ ! -s "$POST_LOG" ]
[ ! -s "$REQUEST_LOG" ]
printf 'Isolated actual notification CLI: 0 POSTs; 0 transport requests. PASS.\n'
