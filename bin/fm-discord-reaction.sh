#!/usr/bin/env bash
# Best-effort lifecycle reaction for one durably captured self-hosted Discord request.
# Usage: fm-discord-reaction.sh <request_id> <accepted|claimed|success|blocked>

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-discord-lib.sh
. "$SCRIPT_DIR/fm-discord-lib.sh"

request_id=${1:-}
phase=${2:-}
case "$request_id" in ''|.*|*[!A-Za-z0-9._-]*) exit 0 ;; esac
case "$phase" in accepted|claimed|success|blocked) ;; *) exit 0 ;; esac

fm_discord_load_config
command -v node >/dev/null 2>&1 || exit 0

export FM_HOME FM_ROOT FM_STATE_OVERRIDE="$STATE" FM_DISCORD_BOT_TOKEN="$FM_DISCORD_TOKEN"
node "$SCRIPT_DIR/fm-discord-reaction.js" "$request_id" "$phase" >/dev/null 2>&1 || true
exit 0
