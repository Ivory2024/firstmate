#!/usr/bin/env bash
# Repository-wide invariants over firstmate's own test suite, as opposed to the
# behavior of any one bin/ script. Source-style rules stay in bin/fm-lint.sh;
# this file owns the structural properties a test file itself must keep.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --- watcher tests pin FM_HOME ----------------------------------------------
#
# A watcher-family test that runs a child - the watcher, the guard, a plugin
# driver - hands that child the ambient FM_ROOT_OVERRIDE and FM_HOME. When the
# operator's own shell exports them, the child resolves the developer's live
# home instead of the case directory, so the suite's lock and recovery
# assertions read the real fleet's state and fail for a reason that has nothing
# to do with the code under test. tests/fixtures.sh closes that vector centrally
# for the spawn-world helpers, but a test that reaches a bin/ script or a plugin
# directly still has to pin FM_HOME on that invocation. Every
# tests/*watch*.test.sh therefore has to carry an FM_HOME assignment.
#
# The exemption below is an explicit marker rather than a spawn-detection
# heuristic. A shell test reaches a child through command substitution,
# pipelines, and `&` alike, so any pattern that tries to decide "this file
# spawns" is either too narrow - a missed spawn silently unenforces the rule -
# or too broad - a pure-logic watcher-helper test fails for a child it never
# runs. The marker keeps the exemption a deliberate, reviewable claim on the one
# file that makes it.
FM_WATCH_TEST_NO_SPAWN_MARKER='# fm-test-guard: no child process'

shopt -s nullglob
watcher_tests=( "$ROOT"/tests/*watch*.test.sh )
shopt -u nullglob
[ "${#watcher_tests[@]}" -gt 0 ] \
  || fail "tests/*watch*.test.sh matched no files; the watcher test glob is broken"

unpinned=
exempt=0
for watcher_test in "${watcher_tests[@]}"; do
  if grep -qF -- "$FM_WATCH_TEST_NO_SPAWN_MARKER" "$watcher_test"; then
    exempt=$((exempt + 1))
    continue
  fi
  # A comment may mention the variable, and an empty assignment pins nothing, so
  # the scan drops comment lines before matching and requires a non-empty value.
  if awk '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    line ~ /^#/ { next }
    line ~ /(^|[[:space:]])FM_HOME=[^[:space:]]/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$watcher_test"; then
    continue
  fi
  unpinned="$unpinned ${watcher_test#"$ROOT"/}"
done

[ -z "$unpinned" ] \
  || fail "watcher test without an FM_HOME binding or the '$FM_WATCH_TEST_NO_SPAWN_MARKER' marker:$unpinned"

pass "${#watcher_tests[@]} watcher tests pin FM_HOME (${exempt} declared no child process)"
