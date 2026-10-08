#!/usr/bin/env bash
# mock fm-send.sh - records a durable inbox message; no worker is steered.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
id=$1; shift || true
[ -n "$id" ] || { echo "mock fm-send: need target" >&2; exit 2; }
d="$ROOT/state/$id.inbox"; mkdir -p "$d"
printf '%s\n' "$*" > "$d/$(date +%s).msg"
echo "SENT $id"
