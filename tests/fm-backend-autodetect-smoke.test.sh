#!/usr/bin/env bash
# tests/fm-backend-autodetect-smoke.test.sh - retired backend markers cannot
# affect backend auto-detection or restore an unsupported backend choice.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

detect() {
  env -u TMUX -u CMUX_WORKSPACE_ID -u __CFBundleIdentifier \
    -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION \
    "$@" bash -c '
      . "$1"
      if backend=$(fm_backend_detect); then
        printf "detected:%s\n" "$backend"
      else
        printf "undetected\n"
      fi
      if fm_backend_list_contains "$FM_BACKEND_KNOWN" herdr ||
        fm_backend_list_contains "$FM_BACKEND_SPAWN" herdr; then
        printf "unsupported-backend-listed\n"
        exit 1
      fi
    ' _ "$ROOT/bin/fm-backend.sh"
}

WITH_RETIRED_MARKERS=$(detect HERDR_ENV=1 HERDR_PANE_ID=%123 HERDR_SESSION=default)
WITHOUT_RETIRED_MARKERS=$(detect)
[ "$WITH_RETIRED_MARKERS" = "$WITHOUT_RETIRED_MARKERS" ] ||
  fail "retired Herdr environment markers changed backend auto-detection: $WITH_RETIRED_MARKERS != $WITHOUT_RETIRED_MARKERS"
case "$WITH_RETIRED_MARKERS" in
  *unsupported-backend-listed*) fail "Herdr remains in the supported backend list" ;;
esac
pass "Herdr environment markers do not affect backend auto-detection or supported backend choices"
