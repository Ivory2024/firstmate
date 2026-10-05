#!/usr/bin/env bash
# Map one newly received status record to the self-hosted Discord decision push.
# Only send: (a) captain action/approval/choice requests and (b) completed task
# outcomes. Do NOT send routine blocked/failed status, progress, stale requests,
# internal diagnostics, or replayed/duplicate completion messages.
# Usage: fm-discord-notify-status.sh <status-task-id> <status-line>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-discord-lib.sh
. "$SCRIPT_DIR/fm-discord-lib.sh"

# Push a plain one-line message to this home's configured Discord channel,
# reusing fm-discord-notify.sh --report's send path. Silent no-op when Discord
# is not configured. Return nonzero so completion markers are not written when
# no delivery could occur.
fm_discord_send_plain_report() {
  local message=$1 channel_id
  fm_discord_load_config
  [ -n "${FM_DISCORD_TOKEN:-}" ] || return 2
  channel_id=$(fm_discord_trim "${FM_DISCORD_CHANNELS%%,*}")
  case "$channel_id" in ''|*[!0-9]*) return 2 ;; esac
  "$SCRIPT_DIR/fm-discord-notify.sh" --report "$channel_id" "$message"
}

# Dedup marker for plain reports (done messages). Prevents duplicate Discord
# posts when the same status line is re-read across polling cycles.
fm_discord_plain_report_marker() {
  local task_id=$1 note=$2 marker_path hash
  hash=$(printf '%s' "$task_id" | shasum -a 256 | cut -d' ' -f1)
  hash="${hash}$(printf '%s' "$note" | shasum -a 256 | cut -d' ' -f1)"
  printf '%s/discord-plain-%s.json' "${FM_STATE_OVERRIDE:-$FM_HOME/state}/x-context" "$hash"
}

fm_discord_mark_plain_report_sent() {
  local task_id=$1 note=$2 marker_path
  marker_path=$(fm_discord_plain_report_marker "$task_id" "$note")
  printf '{"task_id":"%s","note":"%s","sent_at":%s}\n' "$task_id" "$note" "$(date +%s)" > "$marker_path"
}

[ "$#" -eq 2 ] || exit 2
task_id=$1
line=$2
verb=$(status_line_verb "$line")
key=$(_fm_decision_key "$line" 2>/dev/null) || key=

case "$verb:$key" in
  needs-decision:nm-*)
    # A raw ask-user gate is not a captain-facing event: firstmate decides most
    # findings in-scope (ask-user-authority) with no captain involvement at all.
    # A genuine escalation records a captain-held task instead
    # (bin/fm-captain-hold.sh hold), which pushes its own Discord notification
    # carrying the real question, at the point firstmate actually escalates.
    exit 0
    ;;
  needs-decision:pr-ready-*)
    note=$(status_line_note "$line")
    case "$note" in *'yolo=off'*) ;; *) exit 0 ;; esac
    route_task_id=$task_id
    detail=" $note "
    case "$detail" in
      *" task="*) route_task_id=${detail#* task=}; route_task_id=${route_task_id%% *} ;;
    esac
    url=''
    case "$detail" in
      *" pull request ready: "*) url=${detail#* pull request ready: }; url=${url%% choose *} ;;
    esac
    # Name the repo up front (from a GitHub owner/repo or GitLab project path)
    # so a captain merging non-IMAC repos manually from this ping knows which
    # project it is without parsing the URL.
    repo=''
    case "$url" in
      https://github.com/*/*/pull/*)
        repo=${url#https://github.com/}
        repo=${repo%%/pull/*}
        repo=${repo##*/}
        ;;
      https://*/*/-/merge_requests/*)
        repo=${url#https://*/}
        repo=${repo%%/-/merge_requests/*}
        repo=${repo##*/}
        ;;
    esac
    if [ -n "$repo" ]; then
      summary="$repo 저장소: 검토할 풀 리퀘스트가 준비되었습니다."
    else
      summary="검토할 풀 리퀘스트가 준비되었습니다."
    fi
    [ -z "$url" ] || summary="$summary $url"
    "$SCRIPT_DIR/fm-discord-notify.sh" pr-ready "$route_task_id" "$key" \
      "$summary" "병합|열어 두기" "열어 두기" "$task_id"
    ;;
  done:*)
    note=$(status_line_note "$line")
    note=$(printf '%s' "$note" | tr '\n\r' '  ')
    case "$note" in *'run still monitoring PR'*) exit 0 ;; esac
    marker_path=$(fm_discord_plain_report_marker "$task_id" "$note")
    [ -f "$marker_path" ] && exit 0
    fm_discord_send_plain_report "작업 완료 [$task_id]: ${note:-완료}" || exit $?
    fm_discord_mark_plain_report_sent "$task_id" "$note"
    ;;
  *) exit 0 ;;
esac
