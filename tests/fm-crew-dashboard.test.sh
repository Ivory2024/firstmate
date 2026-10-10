#!/usr/bin/env bash
# Behavioral tests for bin/fm-crew-dashboard.py: lane liveness classification
# and the snapshot cache's freshness/single-flight contract.
#
# -W ignore::ResourceWarning: the dashboard's own readers are bare open() calls
# that predate these tests and are out of scope here, and their warnings would
# otherwise interleave with the test report.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -W ignore::ResourceWarning "$SCRIPT_DIR/fm-crew-dashboard.test.py"
