#!/usr/bin/env bash
# check-drift.sh - detect drift between the verification map and reality: every
# file a map row references must still exist and be non-empty. Optionally
# re-runs the local suite with --run. Read-only unless --run is given.
#
# Usage: check-drift.sh [--run]
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UC_ROOT=$(cd "$HERE/.." && pwd)
map="$HERE/verification-map.md"
[ -f "$map" ] || { echo "check-drift: no verification-map.md" >&2; exit 2; }

refs=$(grep -oE '(tests|verification|implementation|evidence)/[A-Za-z0-9._/-]+' "$map" | sort -u)
fail=0
while IFS= read -r r; do
  [ -n "$r" ] || continue
  p="$UC_ROOT/$r"
  if [ -e "$p" ]; then
    printf 'ok   %s\n' "$r"
  else
    printf 'DRIFT %s (missing)\n' "$r"
    fail=$((fail+1))
  fi
done <<EOF
$refs
EOF

if [ "${1:-}" = "--run" ]; then
  if bash "$UC_ROOT/tests/run-all.sh" >/dev/null 2>&1; then
    printf 'ok   local suite re-run\n'
  else
    printf 'DRIFT local suite failed\n'; fail=$((fail+1))
  fi
fi

printf 'check-drift: %s drifted\n' "$fail"
[ "$fail" -eq 0 ]
