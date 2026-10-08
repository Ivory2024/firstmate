#!/usr/bin/env bash
# mock fm-crew-state.sh - one deterministic state line, same shape as the real
# bin/fm-crew-state.sh:  state: <token> · source: <src> · <detail>
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
id=${1:?usage: fm-crew-state.sh <id>}
meta="$ROOT/state/$id.meta"
if [ ! -f "$meta" ]; then echo "state: unknown · source: none · no record for $id"; exit 0; fi
last=$(tail -1 "$ROOT/state/$id.status" 2>/dev/null)
case "$last" in
  done*)   s="done";;
  failed*) s=failed;;
  blocked*) s=blocked;;
  paused*) s=paused;;
  *)       s=working;;
esac
echo "state: $s · source: status-log · $last"
