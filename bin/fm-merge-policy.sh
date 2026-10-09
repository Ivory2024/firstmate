#!/usr/bin/env bash
# fm-merge-policy.sh - policy engine for risk-based autonomous merge (isolated).
#
# Firstmate/Crewmate = execute; Claude = independent review; THIS engine = decide.
# It never merges. It classifies risk by changed paths and decides merge
# eligibility FAIL-CLOSED: HIGH risk or unknown risk requires an explicit policy
# scope, and any missing evidence yields MERGE_HOLD.
#
# Usage:
#   fm-merge-policy.sh classify-risk <file> [<file>...]
#   fm-merge-policy.sh merge-eligible --risk R --ci pass|fail --review pass|fail \
#       --head-match yes|no --protected yes|no --unresolved yes|no --scope <none|low|med|high>
set -u

# Protected / high-risk path patterns (firstmate core control, credentials, deploy).
HIGH_PATTERNS='(^|/)(bin/(fm-watch|fm-wake|fm-control|fm-spawn|fm-teardown|fm-classify|fm-lease|fm-send|fm-crew-state|fm-blocker|fm-merge|fm-lock|fm-busy|fm-dispatch)[a-z-]*\.sh|\.github/workflows/|launchd/|.*credential.*|.*secret.*|.*\.env$|bin/deploy)'
# Medium-risk: general execution logic / limited bugfixes.
MED_PATTERNS='(^|/)(bin/|AutomationSync/|pipelines/).*\.(sh|py)$'

classify_risk() {
  local f risk=LOW
  for f in "$@"; do
    # docs/tests stay LOW regardless of location
    case "$f" in
      *.md|*.test.sh|*_test.py|test_*.py) continue;;
    esac
    case "$f" in */docs/*|*/tests/*) continue;; esac
    if printf '%s' "$f" | grep -qE "$HIGH_PATTERNS"; then echo HIGH; return 0; fi
    if printf '%s' "$f" | grep -qE "$MED_PATTERNS"; then [ "$risk" = LOW ] && risk=MEDIUM; continue; fi
    echo HIGH; return 0   # unknown path -> HIGH (fail-closed)
  done
  echo "$risk"
}

merge_eligible() {
  local risk='' ci='' review='' head='' prot='' unres='' scope=none apr='' asha='' hsha='' aprec=''
  while [ $# -gt 0 ]; do case "$1" in
    --risk) risk=$2; shift 2;; --ci) ci=$2; shift 2;; --review) review=$2; shift 2;;
    --head-match) head=$2; shift 2;; --protected) prot=$2; shift 2;;
    --unresolved) unres=$2; shift 2;; --scope) scope=$2; shift 2;;
    --approved-pr) apr=$2; shift 2;; --approved-sha) asha=$2; shift 2;; --head-sha) hsha=$2; shift 2;;
    --approval-record) aprec=$2; shift 2;;
    *) shift;; esac; done

  # fail-closed gates (any miss -> HOLD)
  [ "$ci" = pass ] || { echo "MERGE_HOLD reason=ci-not-pass"; return 0; }
  [ "$review" = pass ] || { echo "MERGE_HOLD reason=no-independent-review"; return 0; }
  [ "$head" = yes ] || { echo "MERGE_HOLD reason=head-changed"; return 0; }
  [ "$prot" = no ] || { echo "MERGE_HOLD reason=protected-path"; return 0; }
  [ "$unres" = no ] || { echo "MERGE_HOLD reason=unresolved-findings"; return 0; }

  # scope=high is NOT self-grantable: it needs an explicit captain approval bound
  # to a PR number AND an approved SHA that matches the current head SHA, AND a
  # durable approval record the auto-executor cannot author (captain-hold record).
  if [ "$scope" = high ]; then
    [ -n "$apr" ] || { echo "MERGE_HOLD reason=high-scope-needs-approval-pr"; return 0; }
    [ -n "$asha" ] && [ -n "$hsha" ] && [ "$asha" = "$hsha" ] \
      || { echo "MERGE_HOLD reason=high-scope-sha-mismatch"; return 0; }
    [ -n "$aprec" ] && [ -f "$aprec" ] || { echo "MERGE_HOLD reason=no-approval-record"; return 0; }
    grep -q "signer=captain" "$aprec" 2>/dev/null || { echo "MERGE_HOLD reason=approval-not-captain"; return 0; }
    grep -q "pr=$apr" "$aprec" 2>/dev/null || { echo "MERGE_HOLD reason=approval-pr-mismatch"; return 0; }
    grep -q "head=$hsha" "$aprec" 2>/dev/null || { echo "MERGE_HOLD reason=approval-head-mismatch"; return 0; }
  fi

  # risk scope: HIGH (or unknown) needs an explicit high scope
  case "$risk" in
    LOW)  case "$scope" in low|med|high) echo MERGE_ELIGIBLE;; *) echo "MERGE_HOLD reason=scope-low-required";; esac;;
    MEDIUM) case "$scope" in med|high) echo MERGE_ELIGIBLE;; *) echo "MERGE_HOLD reason=scope-med-required";; esac;;
    HIGH) case "$scope" in high) echo MERGE_ELIGIBLE;; *) echo "MERGE_HOLD reason=high-needs-explicit-scope";; esac;;
    *) echo "MERGE_HOLD reason=unknown-risk";;
  esac
}

review_route() { # --risk R -> reviewer tier plan (free-first, escalate for HIGH)
  local risk=''
  while [ $# -gt 0 ]; do case "$1" in --risk) risk=$2; shift 2;; *) shift;; esac; done
  case "$risk" in
    LOW)    echo "reviewer=free-primary tier=free independent=required";;
    MEDIUM) echo "reviewer=free-cross tier=free-x2 independent=required escalate_on=conflict,low-confidence";;
    HIGH)   echo "reviewer=escalated tier=high-capability independent=required dual=optional free_prepass=yes";;
    *)      echo "reviewer=none action=HOLD reason=unknown-risk";;
  esac
}

# independence gate: an implementation model may not be the sole reviewer.
independent_ok() { # <impl-model> <review-model>
  [ -n "$1" ] && [ -n "$2" ] || { echo "REVIEW_INDEPENDENCE_HOLD reason=missing-model"; return 0; }
  [ "$1" != "$2" ] || { echo "REVIEW_INDEPENDENCE_HOLD reason=same-model"; return 0; }
  echo "INDEPENDENT_OK"
}

case "${1:-}" in
  classify-risk) shift; classify_risk "$@";;
  merge-eligible) shift; merge_eligible "$@";;
  review-route) shift; review_route "$@";;
  independent-ok) shift; independent_ok "$1" "$2";;
  *) echo "usage: fm-merge-policy.sh classify-risk|merge-eligible|review-route|independent-ok ..." >&2; exit 2;;
esac
