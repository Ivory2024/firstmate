#!/usr/bin/env bash
# Behavioral tests for bin/fm-originals-index.py: the explicit allowlist plus
# bounded worktree discovery contract, realpath de-duplication, symlink
# boundary validation, record-unit decomposition, provenance, duplicate
# determination, the marker contract that keeps a marker-less record raw
# evidence, and mechanical aggregation.
#
# The two regression cases reproduce the omissions the audit found on the real
# host: a .stow-notes.md reachable only through an agent worktree, and a retro
# record reachable only through an orca worktree.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SCRIPT_DIR/fm-originals-index.test.py"
