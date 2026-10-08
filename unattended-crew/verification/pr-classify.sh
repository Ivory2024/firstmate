#!/usr/bin/env bash
# pr-classify.sh - READ-ONLY PR readiness classifier (pstack babysit/shipping
# adaptation). It reads a PR JSON fixture and separates merge-READY (the forge
# agrees it can merge) from merge-AUTHORIZED (a human/standing merge authority
# exists). It performs no network call and no GitHub write; a real merge stays
# behind G3 and the captain's authority.
#
# Input JSON fields: state, mergeStateStatus, statusCheckRollup[].conclusion,
#   reviewDecision, authorized (bool).
# Output: merged | blocked | ready-not-authorized | authorized-not-ready |
#   ready-and-authorized
# Usage: pr-classify.sh <pr.json>
set -u
f=${1:?usage: pr-classify.sh <pr.json>}
[ -f "$f" ] || { echo "pr-classify: no file $f" >&2; exit 2; }
python3 - "$f" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
state=(d.get("state") or "").upper()
mss=(d.get("mergeStateStatus") or "").upper()
review=(d.get("reviewDecision") or "").upper()
auth=bool(d.get("authorized"))
if state=="MERGED": print("merged"); sys.exit(0)
if state in ("CLOSED",""): print("blocked"); sys.exit(0)
bad={"FAILURE","CANCELLED","TIMED_OUT","ACTION_REQUIRED","STALE","STARTUP_FAILURE"}
rollup=d.get("statusCheckRollup") or []
concl={(c.get("conclusion") or "").upper() for c in rollup if isinstance(c,dict)}
if concl & bad: print("blocked"); sys.exit(0)
if mss=="DIRTY": print("blocked"); sys.exit(0)  # merge conflict
ready = (mss=="CLEAN") and (review != "CHANGES_REQUESTED") and not (concl & bad)
if ready and auth: print("ready-and-authorized")
elif ready: print("ready-not-authorized")
elif auth: print("authorized-not-ready")
else: print("blocked")
PY
