#!/usr/bin/env bash
# fm-merge-policy.sh - policy engine for risk-based autonomous merge (isolated).
#
# Firstmate/Crewmate = execute; Claude = independent review; THIS engine = decide.
# It never merges. It classifies risk by changed paths and holds eligibility
# until forge-verified evidence is available.
#
# Usage:
#   fm-merge-policy.sh classify-risk <file> [<file>...]
#   fm-merge-policy.sh merge-eligible
set -u

# Protected / high-risk path patterns (firstmate core control, credentials, deploy).
HIGH_PATTERNS='(^|/)(bin/(fm-watch|fm-wake|fm-control|fm-spawn|fm-teardown|fm-classify|fm-lease|fm-send|fm-crew-state|fm-blocker|fm-merge|fm-pr-merge|fm-lock|fm-busy|fm-dispatch)[a-z-]*\.sh|\.github/workflows/|launchd/|.*credential.*|.*secret.*|.*\.env$|bin/deploy)'
# Medium-risk: general execution logic / limited bugfixes.
MED_PATTERNS='(^|/)(bin/|AutomationSync/|pipelines/).*\.(sh|py)$'

classify_risk() {
  local f risk=LOW
  [ "$#" -gt 0 ] || { echo HIGH; return 0; }
  for f in "$@"; do
    if printf '%s' "$f" | grep -qE "$HIGH_PATTERNS"; then echo HIGH; return 0; fi
    case "$f" in
      *.md|*.test.sh|*_test.py|test_*.py) continue;;
    esac
    case "$f" in */docs/*|*/tests/*) continue;; esac
    if printf '%s' "$f" | grep -qE "$MED_PATTERNS"; then [ "$risk" = LOW ] && risk=MEDIUM; continue; fi
    echo HIGH; return 0   # unknown path -> HIGH (fail-closed)
  done
  echo "$risk"
}

case "${1:-}" in
  classify-risk) shift; classify_risk "$@";;
  merge-eligible) echo "MERGE_HOLD reason=verified-evidence-required";;
  independent-ok) echo "REVIEW_INDEPENDENCE_HOLD reason=verified-review-provenance-required";;
  *) echo "usage: fm-merge-policy.sh classify-risk|merge-eligible|independent-ok ..." >&2; exit 2;;
esac
