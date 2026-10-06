#!/usr/bin/env bash
set -eu
root=$PWD
export FM_HOME="$root/.local-test-phase/home" FM_PROCEVENT_CLAIM_ROOT="$root/.local-test-phase/claims"
export FM_STATE_OVERRIDE="$FM_HOME/state"
unset FM_HOME_OVERRIDE FM_DISCORD_BOT_TOKEN FM_DISCORD_TOKEN FMX_PAIRING_TOKEN FMX_ENV_FILE
mkdir -p "$FM_HOME/state" "$FM_HOME/config" "$FM_HOME/data" "$FM_PROCEVENT_CLAIM_ROOT"
: > "$FM_HOME/.env"
lock="$FM_PROCEVENT_CLAIM_ROOT/bot-manager-issues.lock"
"$root/bin/fm-procevent.sh" register bot-manager bot-manager-issues -- /usr/bin/true
for suffix in '' .steal .steal.steal; do
 mkdir -p "$lock$suffix"
 printf '999999\n' > "$lock$suffix/pid"
 touch -t 202001010000 "$lock$suffix"
done
printf '\nPublic list with stale primary and two stale suffixes:\n'
"$root/bin/fm-procevent.sh" list
[ ! -e "$lock.steal.steal.steal" ]
printf 'No third steal suffix; public list returned.\n'
. "$root/bin/fm-wake-lib.sh"
exec 8>"$FM_HOME/fd8" 9>"$FM_HOME/fd9" 10>"$FM_HOME/fd10"
for mode in yes no; do
 p="$FM_HOME/$mode.lock"
 for suffix in '' .steal .steal.steal; do
  mkdir -p "$p$suffix"; printf '999999\n' > "$p$suffix/pid"; touch -t 202001010000 "$p$suffix"
 done
 fm_lock_try_acquire "$p" "$mode"
 printf '%s\n' "$mode" >&8; printf '%s\n' "$mode" >&9; printf '%s\n' "$mode" >&10
 fm_lock_release "$p"
done
for fd in 8 9 10; do printf 'Caller FD %s bytes: ' "$fd"; tr '\n' ' ' < "$FM_HOME/fd$fd"; printf '\n'; done
sleep 60 &
peer=$!
trap 'kill "$peer" 2>/dev/null || true; wait "$peer" 2>/dev/null || true' EXIT
p="$FM_HOME/live.lock"
mkdir "$p"; printf '%s\n' "$peer" > "$p/pid"; printf 'mismatched stale identity\n' > "$p/pid-identity"
if fm_lock_try_acquire "$p"; then echo 'ERROR displaced live PID'; exit 1; fi
kill -0 "$peer"
[ "$(cat "$p/pid")" = "$peer" ]
printf 'Unrelated live PID %s survived; lock owner unchanged.\n' "$peer"
