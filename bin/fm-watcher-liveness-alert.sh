#!/usr/bin/env bash
# Watcher liveness alert plus session-independent re-arm.
#
# `check` is the launchd entry point (StartInterval 60). It runs two stages:
#
#   1. The unchanged liveness alert: classify this home's watcher consumer and
#      emit a deduplicated HIGH / Recovered Discord report while the durable
#      wake queue is pending and the consumer is unhealthy.
#   2. A session-independent re-arm. The watcher is one-shot, so a successor arm
#      must follow every cycle; that successor was owned only by harness events
#      (OpenCode's session.idle, a Claude Stop, a Pi turn end), so a session that
#      never goes idle could strand the chain. This stage re-arms from the 60s
#      tick alone, with no harness event and no session state.
#
# Re-arm gates (ALL must hold; any failure leaves the home untouched):
#   - no away/quiet posture: state/.afk and state/.afk-contract absent;
#   - no maintenance HOLD: state/.watch-hold absent (its first line is the
#     operator's reason). Create it to stop automatic recovery deliberately;
#   - supervision is needed: an in-flight task, a registered event source or
#     custom check, the Relay poll, or a non-empty durable wake queue;
#   - no healthy watcher: no live identity-matched watcher holds
#     state/.watch.lock with a beacon fresh within the grace window;
#   - no live lock owner: a lock naming any live pid is never stolen;
#   - the newest state/.watch-cycle-exits.log record proves the chain ended:
#     successor=none, a rearmable reason (rearm_reason_rearmable), and both the
#     recorded arm and watcher pids dead, so the prior cycle fully exited. A
#     deliberate stop (arm-interrupted) is never rearmable.
#
# Re-arm mechanics:
#   - state/.watch-rearm.lock is the atomic guard, so two overlapping ticks can
#     never both start a watcher;
#   - the approved bin/fm-watch-arm.sh path is reused (plain arm, never
#     --restart, so a healthy watcher is never killed);
#   - the arm starts detached in its OWN process group (set -m plus nohup).
#     bin/fm-watch-arm.sh warns against a bare shell `&` because a harness reaps
#     that child when the tool call returns; under launchd the job's own process
#     group is killed when the job exits, and the new group is what survives
#     (the same escape bin/fm-remote-job-lib.sh uses). The launchd job therefore
#     stays a fast tick and alerting is never blocked by a live cycle;
#   - a bounded confirmation window (FM_WATCH_REARM_CONFIRM_TIMEOUT) decides the
#     outcome; a live identity-matched watcher with a fresh beacon, or the arm's
#     own `watcher: started|attached` line, is success, so a cycle that surfaced
#     a durable wake and exited is never mistaken for a failure. A real failure
#     increments state/.watch-rearm-state, applies bounded exponential backoff,
#     and emits one alert per failure episode.
#   - re-arm never touches the durable wake queue, the steering inbox, ACK
#     cursors, or checkpoints: the watcher owns those idempotently, and this
#     script only reads the queue to decide whether supervision is needed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LABEL=dev.firstmate.watcher-liveness-alert
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/$LABEL.log"
POLL=${FM_POLL:-15}
COOLDOWN=${FM_WATCHER_ALERT_COOLDOWN:-3600}
LAUNCH_PATH=${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
WATCH="$SCRIPT_DIR/fm-watch.sh"
WATCH_LOCK="$STATE/.watch.lock"
CYCLE_LOG="$STATE/.watch-cycle-exits.log"
ARM_BIN=${FM_WATCH_ARM_BIN:-$FM_ROOT/bin/fm-watch-arm.sh}
REARM_LOCK="$STATE/.watch-rearm.lock"
REARM_STATE="$STATE/.watch-rearm-state"
REARM_HOLD="$STATE/.watch-hold"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-discord-lib.sh
. "$SCRIPT_DIR/fm-discord-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-$(fm_poll_derived_grace "$POLL")}}

usage() {
  printf 'usage: fm-watcher-liveness-alert.sh check|install|remove|render\n' >&2
  exit 2
}

plist_safe() {
  case "$1" in *'&'*|*'<'*|*'>'*|*'"'*|*"'"*) return 1 ;; esac
}

render_agent() {
  plist_safe "$SCRIPT_DIR/fm-watcher-liveness-alert.sh" && plist_safe "$FM_HOME" \
    && plist_safe "$FM_ROOT" && plist_safe "$STATE" && plist_safe "$GRACE" \
    && plist_safe "$LOG" && plist_safe "$LAUNCH_PATH" || return 1
  cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$SCRIPT_DIR/fm-watcher-liveness-alert.sh</string><string>check</string></array>
<key>EnvironmentVariables</key><dict>
<key>FM_HOME</key><string>$FM_HOME</string>
<key>FM_ROOT_OVERRIDE</key><string>$FM_ROOT</string>
<key>FM_STATE_OVERRIDE</key><string>$STATE</string>
<key>FM_WATCHER_STALE_GRACE</key><string>$GRACE</string>
<key>PATH</key><string>$LAUNCH_PATH</string>
</dict>
<key>StartInterval</key><integer>60</integer>
<key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>$LOG</string>
<key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
XML
}

install_agent() {
  local uid out tmp actual expected
  [ "$(uname)" = Darwin ] || return 0
  fm_discord_load_config
  if [ -z "${FM_DISCORD_TOKEN:-}" ] || [ -z "${FM_DISCORD_CHANNELS:-}" ]; then
    remove_agent || true
    return 0
  fi
  mkdir -p "${PLIST%/*}" "${LOG%/*}" || return 1
  tmp="$PLIST.tmp.$$"
  render_agent > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ -f "$PLIST" ] && [ ! -L "$PLIST" ]; then
    actual=$(tr -d ' \t\r\n' < "$PLIST" 2>/dev/null || true)
    expected=$(tr -d ' \t\r\n' < "$tmp" 2>/dev/null || true)
    if [ "$actual" = "$expected" ]; then
      rm -f "$tmp"
      uid=$(id -u)
      launchctl print "gui/$uid/$LABEL" >/dev/null 2>&1 && return 0
      out=$(launchctl bootstrap "gui/$uid" "$PLIST" 2>&1) || {
        printf 'fm-watcher-liveness-alert: launchctl bootstrap failed: %s\n' "$out" >&2
        return 1
      }
      return 0
    fi
  fi
  if ! chmod 0644 "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$PLIST"; then
    rm -f "$tmp"
    return 1
  fi
  uid=$(id -u)
  launchctl bootout "gui/$uid/$LABEL" >/dev/null 2>&1 || true
  out=$(launchctl bootstrap "gui/$uid" "$PLIST" 2>&1) || {
    printf 'fm-watcher-liveness-alert: launchctl bootstrap failed: %s\n' "$out" >&2
    return 1
  }
}

remove_agent() {
  local uid label argument command home root
  [ -f "$PLIST" ] && [ ! -L "$PLIST" ] || return 0
  label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$PLIST" 2>/dev/null) || return 1
  argument=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST" 2>/dev/null) || return 1
  command=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$PLIST" 2>/dev/null) || return 1
  home=$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:FM_HOME' "$PLIST" 2>/dev/null) || return 1
  root=$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:FM_ROOT_OVERRIDE' "$PLIST" 2>/dev/null) || return 1
  [ "$label" = "$LABEL" ] && [ "$argument" = "$SCRIPT_DIR/fm-watcher-liveness-alert.sh" ] \
    && [ "$command" = check ] \
    && [ "$home" = "$FM_HOME" ] && [ "$root" = "$FM_ROOT" ] || return 1
  uid=$(id -u)
  launchctl bootout "gui/$uid/$LABEL" >/dev/null 2>&1 || true
  rm -f "$PLIST"
}

report() { # <event-id> <message>
  local event_id=$1 message=$2 channel=${FM_DISCORD_CHANNELS%%,*}
  [ -n "${FM_DISCORD_TOKEN:-}" ] && [ -n "$channel" ] || return 1
  FM_DISCORD_BOT_TOKEN="$FM_DISCORD_TOKEN" FM_DISCORD_CHANNEL_ID="$channel" \
    "$SCRIPT_DIR/fm-discord-notify.sh" --report "$channel" "$message" "$event_id"
}

report_sent() { # <event-id>
  node --input-type=module - "$STATE" "$1" <<'NODE'
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
const [state, event] = process.argv.slice(2);
const digest = createHash("sha256").update(`completion\0${event}`).digest("hex");
const record = JSON.parse(readFileSync(join(state, "x-context", `discord-completion-${digest}.json`), "utf8"));
if (record.event !== event || record.state !== "sent" || !record.message_id) process.exit(1);
NODE
}

classify_consumer() {
  local pid age
  pid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
  if ! fm_pid_alive "$pid" || ! fm_watcher_lock_matches_pid "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$pid" "$FM_HOME"; then
    printf 'no-consumer\n'
    return
  fi
  age=$(fm_path_age "$STATE/.last-watcher-beat")
  case "$age" in ''|*[!0-9]*) age=999999 ;; esac
  if [ "$age" -ge "$GRACE" ]; then printf 'stale-heartbeat\n'; else printf 'healthy\n'; fi
}

check_liveness() {
  local state_file="$STATE/.watcher-liveness-alert-state" lock="$STATE/.watcher-liveness-alert.lock"
  local consumer class pending now prior prior_class last_alert high_since event message high=false
  fm_lock_try_acquire "$lock" || return 0
  trap 'fm_lock_release "$STATE/.watcher-liveness-alert.lock" 2>/dev/null || true' EXIT HUP INT TERM
  fm_discord_load_config
  consumer=$(classify_consumer)
  pending=false
  [ -s "$FM_WAKE_QUEUE" ] && pending=true
  class=$consumer
  now=$(date +%s)
  prior=$(cat "$state_file" 2>/dev/null || true)
  prior_class=$(printf '%s\n' "$prior" | awk -F '\t' '{print $1}')
  last_alert=$(printf '%s\n' "$prior" | awk -F '\t' '{print $2}')
  high_since=$(printf '%s\n' "$prior" | awk -F '\t' '{print $3}')
  case "$last_alert:$high_since" in *[!0-9:]*|:*) last_alert=0; high_since=0 ;; esac
  if [ "$pending" = true ] && [ "$consumer" != healthy ]; then
    class="pending-wake-$consumer-high"
    high=true
    case "$prior_class" in pending-wake-*-high)
      if [ "$prior_class" != "$class" ]; then last_alert=0; high_since=$now; fi
      ;;
      *) last_alert=0; high_since=$now ;;
    esac
  fi
  printf '%s\t%s\t%s\n' "$class" "$last_alert" "$high_since" > "$state_file.tmp.$$" \
    && mv -f "$state_file.tmp.$$" "$state_file" || return 1

  if [ "$high" = true ]; then
    if [ $((now - last_alert)) -ge "$COOLDOWN" ]; then
      event="watcher-liveness-$class-$high_since-$last_alert"
      message="HIGH reliability alert: durable wake queue is pending while watcher consumer is $consumer (beacon grace ${GRACE}s)."
      "$SCRIPT_DIR/fm-discord-notify.sh" --retry-pending >/dev/null 2>&1 || true
      if report "$event" "$message" >/dev/null && report_sent "$event"; then
        last_alert=$now
      fi
    fi
  elif [ "$high_since" -gt 0 ] && [ "$last_alert" -gt 0 ] && [ "$consumer" = healthy ]; then
    event="watcher-liveness-recovered-$high_since"
    message="Recovered: watcher consumer is healthy again after a pending-wake liveness alert."
    "$SCRIPT_DIR/fm-discord-notify.sh" --retry-pending >/dev/null 2>&1 || true
    if report "$event" "$message" >/dev/null && report_sent "$event"; then high_since=0; last_alert=0; fi
  fi
  printf '%s\t%s\t%s\n' "$class" "$last_alert" "$high_since" > "$state_file.tmp.$$" \
    && mv -f "$state_file.tmp.$$" "$state_file"
}

# --- session-independent re-arm --------------------------------------------
#
# Contract owned by this section: the gates above, the atomic lock, the
# detached plain-arm invocation, the bounded confirmation, and the backoff and
# alert state. Nothing here is called by install/remove/render.

# Numeric knobs accept only a positive integer; anything else takes the default.
positive_int() { # <value> <fallback>
  case "$1" in ''|*[!0-9]*|0) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}

REARM_CONFIRM_TIMEOUT=$(positive_int "${FM_WATCH_REARM_CONFIRM_TIMEOUT:-}" 30)
REARM_BACKOFF_BASE=$(positive_int "${FM_WATCH_REARM_BACKOFF_BASE:-}" 60)
REARM_BACKOFF_MAX=$(positive_int "${FM_WATCH_REARM_BACKOFF_MAX:-}" 1800)
REARM_ALERT_AFTER=$(positive_int "${FM_WATCH_REARM_ALERT_AFTER:-}" 3)

# cycle_field <line> <key>: the value of a key=value tab-separated ledger field.
cycle_field() {
  printf '%s' "$1" | awk -F'\t' -v key="$2" '{
    for (i = 1; i <= NF; i += 1) {
      if (index($i, key "=") == 1) { print substr($i, length(key) + 2); exit }
    }
  }'
}

# cycle_record_last: read the newest arm-layer ledger row into CYCLE_* vars.
cycle_record_last() {
  local line
  CYCLE_ARM_PID=''
  CYCLE_WATCHER_PID=''
  CYCLE_REASON=''
  CYCLE_SUCCESSOR=''
  [ -s "$CYCLE_LOG" ] || return 1
  line=$(tail -n 1 "$CYCLE_LOG" 2>/dev/null) || return 1
  [ -n "$line" ] || return 1
  CYCLE_ARM_PID=$(cycle_field "$line" arm_pid)
  CYCLE_WATCHER_PID=$(cycle_field "$line" watcher_pid)
  CYCLE_REASON=$(cycle_field "$line" reason)
  CYCLE_SUCCESSOR=$(cycle_field "$line" successor)
  [ -n "$CYCLE_REASON" ] || return 1
  return 0
}

# rearm_reason_rearmable <reason>: true only for a cycle that ended after doing
# its job or died unexpectedly without a successor. Unknown reasons and every
# deliberate or in-progress reason stay un-rearmed.
rearm_reason_rearmable() {
  case "$1" in
    actionable-signal|actionable-stale|actionable-check|actionable-heartbeat|\
    clean-exit-delivered-wake|attached-delivered-wake|\
    unexpected-clean-exit|nonzero-exit|signal-exit)
      return 0
      ;;
  esac
  return 1
}

# watch_path_for_health: the watcher path this home's lock records, falling back
# to this script's own sibling. The lock's own value is used because the deployed
# script and the armed watcher can live in different code roots.
watch_path_for_health() {
  local recorded
  recorded=$(cat "$WATCH_LOCK/watcher-path" 2>/dev/null || true)
  if [ -n "$recorded" ]; then
    printf '%s\n' "$recorded"
  else
    printf '%s\n' "$WATCH"
  fi
}

# watch_lock_live_pid: print the pid when this home's watch lock names a live
# process, any process. A live owner is never stolen from.
watch_lock_live_pid() {
  local pid
  pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  [ -n "$pid" ] || return 1
  fm_pid_alive "$pid" || return 1
  printf '%s\n' "$pid"
}

rearm_eligible() {
  local watch
  if [ -e "$STATE/.afk" ] || [ -e "$STATE/.afk-contract" ]; then return 1; fi
  if [ -e "$REARM_HOLD" ]; then return 1; fi
  if ! fm_supervision_needed "$STATE" "$GRACE" && [ ! -s "$STATE/.wake-queue" ]; then
    return 1
  fi
  watch=$(watch_path_for_health)
  if fm_watcher_healthy "$STATE" "$watch" "$GRACE" "$FM_HOME"; then return 1; fi
  if watch_lock_live_pid >/dev/null; then return 1; fi
  cycle_record_last || return 1
  [ "$CYCLE_SUCCESSOR" = none ] || return 1
  rearm_reason_rearmable "$CYCLE_REASON" || return 1
  if fm_pid_alive "$CYCLE_WATCHER_PID"; then return 1; fi
  if fm_pid_alive "$CYCLE_ARM_PID"; then return 1; fi
  return 0
}

# state/.watch-rearm-state, one tab-separated line:
#   failures  last_attempt  next_attempt  first_failure  alerted
REARM_FAILURES=0
REARM_LAST=0
REARM_NEXT=0
REARM_FIRST=0
REARM_ALERTED=0

rearm_state_read() {
  local line
  REARM_FAILURES=0 REARM_LAST=0 REARM_NEXT=0 REARM_FIRST=0 REARM_ALERTED=0
  line=$(head -n 1 "$REARM_STATE" 2>/dev/null || true)
  if [ -n "$line" ]; then
    IFS=$'\t' read -r REARM_FAILURES REARM_LAST REARM_NEXT REARM_FIRST REARM_ALERTED <<< "$line"
  fi
  case "$REARM_FAILURES" in ''|*[!0-9]*) REARM_FAILURES=0 ;; esac
  case "$REARM_LAST" in ''|*[!0-9]*) REARM_LAST=0 ;; esac
  case "$REARM_NEXT" in ''|*[!0-9]*) REARM_NEXT=0 ;; esac
  case "$REARM_FIRST" in ''|*[!0-9]*) REARM_FIRST=0 ;; esac
  case "$REARM_ALERTED" in 1) REARM_ALERTED=1 ;; *) REARM_ALERTED=0 ;; esac
}

rearm_state_write() { # <failures> <last> <next> <first> <alerted>
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" > "$REARM_STATE.tmp.$$" 2>/dev/null \
    && mv -f "$REARM_STATE.tmp.$$" "$REARM_STATE" 2>/dev/null \
    || rm -f "$REARM_STATE.tmp.$$" 2>/dev/null || true
}

rearm_note_success() {
  rearm_state_write 0 "$(date +%s)" 0 0 0
}

# rearm_note_failure <now>: advance the bounded backoff and emit one alert per
# failure episode once the threshold is reached.
rearm_note_failure() {
  local now=$1 failures first exp delay next event message
  rearm_state_read
  failures=$((REARM_FAILURES + 1))
  first=$REARM_FIRST
  [ "$first" -gt 0 ] || first=$now
  exp=$((failures - 1))
  [ "$exp" -le 12 ] || exp=12
  delay=$((REARM_BACKOFF_BASE * (1 << exp)))
  [ "$delay" -le "$REARM_BACKOFF_MAX" ] || delay=$REARM_BACKOFF_MAX
  next=$((now + delay))
  rearm_state_write "$failures" "$now" "$next" "$first" "$REARM_ALERTED"
  if [ "$failures" -ge "$REARM_ALERT_AFTER" ] && [ "$REARM_ALERTED" != 1 ]; then
    fm_discord_load_config
    event="watcher-rearm-failed-$first"
    message="HIGH reliability alert: automatic watcher re-arm failed $failures time(s); the next attempt is bounded to ${delay}s backoff."
    "$SCRIPT_DIR/fm-discord-notify.sh" --retry-pending >/dev/null 2>&1 || true
    if report "$event" "$message" >/dev/null && report_sent "$event"; then
      rearm_state_read
      rearm_state_write "$REARM_FAILURES" "$REARM_LAST" "$REARM_NEXT" "$REARM_FIRST" 1
    fi
  fi
}

# start_rearm_arm <output-path>: fork the approved arm detached in its own
# process group and set REARM_ARM_PID. `set -m` gives the child its own process
# group so the launchd job's exit cannot kill it; see this script's header.
REARM_ARM_PID=''
start_rearm_arm() { # <output-path>
  local out=$1
  REARM_ARM_PID=''
  set -m
  nohup env FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    "$ARM_BIN" >> "$out" 2>&1 < /dev/null &
  REARM_ARM_PID=$!
  set +m
}

# arm_reported_ready <output-path>: true when the arm itself verified a live
# watcher. bin/fm-watch-arm.sh prints `watcher: started|attached ...` only after
# it confirmed the child holds the lock with a fresh beacon, so this is the
# authoritative success signal even when that watcher cycle has already ended
# after surfacing a durable wake.
arm_reported_ready() {
  [ -s "$1" ] || return 1
  grep -Eq '^watcher: (started|attached)\b' "$1"
}

# wait_for_rearm <arm-pid> <output-path>: bounded confirmation that the spawned
# arm produced a live identity-matched watcher with a fresh beacon, or verified
# one itself. A cycle that surfaced a durable wake and exited is a successful
# re-arm, not a failure: the wake is durable and the next tick re-arms again.
wait_for_rearm() { # <arm-pid> <output-path>
  local arm_pid=$1 out=$2 deadline watch
  deadline=$(( $(date +%s) + REARM_CONFIRM_TIMEOUT + 1 ))
  while :; do
    watch=$(watch_path_for_health)
    if fm_watcher_healthy "$STATE" "$watch" "$GRACE" "$FM_HOME"; then return 0; fi
    if arm_reported_ready "$out"; then return 0; fi
    fm_pid_alive "$arm_pid" || break
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 1
  done
  watch=$(watch_path_for_health)
  fm_watcher_healthy "$STATE" "$watch" "$GRACE" "$FM_HOME" && return 0
  arm_reported_ready "$out"
}

maybe_rearm() {
  local now out
  rearm_eligible || return 0
  # Atomic guard: exactly one tick may start a watcher.
  fm_lock_try_acquire "$REARM_LOCK" || return 0
  # Re-verify under the lock: a peer may have armed while we waited.
  if ! rearm_eligible; then
    fm_lock_release "$REARM_LOCK"
    return 0
  fi
  rearm_state_read
  now=$(date +%s)
  if [ "$REARM_NEXT" -gt 0 ] && [ "$now" -lt "$REARM_NEXT" ]; then
    fm_lock_release "$REARM_LOCK"
    return 0
  fi
  out="$STATE/.watch-rearm-output.$$"
  start_rearm_arm "$out"
  if wait_for_rearm "$REARM_ARM_PID" "$out"; then
    rearm_note_success
  else
    rearm_note_failure "$now"
  fi
  rm -f "$out" 2>/dev/null || true
  fm_lock_release "$REARM_LOCK"
  return 0
}

case "${1:-}" in
  check) check_liveness; maybe_rearm ;;
  install) install_agent ;;
  remove) remove_agent ;;
  render) render_agent ;;
  *) usage ;;
esac
