#!/usr/bin/env bash
# Behavioral tests for bin/fm-procevent-bot-manager.sh ensure.
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ADAPTER="$ROOT/bin/fm-procevent-bot-manager.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-procevent-bot-manager.XXXXXX")
trap 'rm -rf "$LAB"' EXIT

run_ensure() {
  local home="$1" state="$2"
  HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ROOT" \
    FM_STATE_OVERRIDE="$state" "$ADAPTER" ensure
}

# A home without the approved Notion runtime credential file has no ledger to
# watch: ensure must register nothing and exit successfully, not fail the
# caller (this reproduces the reported CI failure in a credential-less HOME).
mkdir -p "$LAB/no-credential" "$LAB/no-credential-state"
run_ensure "$LAB/no-credential" "$LAB/no-credential-state"
[ ! -e "$LAB/no-credential-state/procevent/bot-manager-issues.source" ]

# A home with the approved credential file registers the source.
mkdir -p "$LAB/with-credential/.claude/prompts" "$LAB/with-credential-state"
printf 'NOTION_TOKEN=test\n' > "$LAB/with-credential/.claude/prompts/discord-bot.env"
run_ensure "$LAB/with-credential" "$LAB/with-credential-state"
[ -f "$LAB/with-credential-state/procevent/bot-manager-issues.source" ]

printf '%s\n' "PASS: Bot Manager ensure skips registration without a readable credential file"
