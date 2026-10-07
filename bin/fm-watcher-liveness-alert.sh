#!/usr/bin/env bash
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

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-discord-lib.sh
. "$SCRIPT_DIR/fm-discord-lib.sh"
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

case "${1:-}" in
  check) check_liveness ;;
  install) install_agent ;;
  remove) remove_agent ;;
  render) render_agent ;;
  *) usage ;;
esac
