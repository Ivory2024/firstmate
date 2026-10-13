#!/usr/bin/env bash
# fake-auditor.sh - default TEST-MODE auditor for the unattended coordinator.
#
# It exists only to exercise the audit -> judge protocol without spending a crew.
# It writes the same structured evidence a real auditor writes
# (auditor/findings.json) and marks itself auditor_kind=fake, so the judge can
# refuse it outside mode=test (fm-unattended-judge.sh:114).
#
# Usage: fake-auditor.sh <run-dir>
set -u
rd=${1:?fake-auditor: need the run dir}
[ -d "$rd" ] || { echo "fake-auditor: no run dir $rd" >&2; exit 2; }
mkdir -p "$rd/auditor"
printf '{"verdict":"PASS","auditor_kind":"fake","findings":[],"at":"%s"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$rd/auditor/findings.json"
echo "fake-auditor: PASS ($rd)"
