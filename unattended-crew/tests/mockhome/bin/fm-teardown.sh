#!/usr/bin/env bash
# mock fm-teardown.sh - removes a mock session's durable records.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
id=$1; shift || true
[ -n "$id" ] || { echo "mock fm-teardown: need id" >&2; exit 2; }
rm -f "$ROOT/state/$id.meta" "$ROOT/state/$id.status"
echo "torn down $id"
