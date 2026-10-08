#!/usr/bin/env bash
# preflight.sh - G1/G2 precondition check for the real unattended canary.
#
# READ-ONLY. It validates every precondition the captain's G1/G2 approval names
# before any real spawn: session-lock ownership, verified harness, backend
# availability, an isolated worktree-capable git project, a resolved dispatch
# profile with an explicit (non-default) model, contract allowed paths and
# forbidden operations, and task-id ownership. It prints GO or HOLD with exact
# reasons and never spawns anything.
#
# Usage:
#   preflight.sh --home <firstmate-home> --project <git-dir> --harness <h> \
#                --model <m> [--effort <e>] [--backend <b>] \
#                --task-id <id> [--contract <json>]
set -u
H=/Users/irene/Developer/kunchenguid_repos/firstmate
PROJECT=""; HARNESS=""; MODEL=""; EFFORT=""; BACKEND=""; TASKID=""; CONTRACT=""
while [ $# -gt 0 ]; do case "$1" in
  --home) H=$2; shift 2;; --project) PROJECT=$2; shift 2;; --harness) HARNESS=$2; shift 2;;
  --model) MODEL=$2; shift 2;; --effort) EFFORT=$2; shift 2;; --backend) BACKEND=$2; shift 2;;
  --task-id) TASKID=$2; shift 2;; --contract) CONTRACT=$2; shift 2;;
  *) echo "preflight: bad arg $1" >&2; exit 2;;
esac; done

REASONS=()
ck() { REASONS+=("$1"); }
VERIFIED_HARNESSES="claude codex opencode pi pi-signed grok kimi cursor omp"

# 1. session lock held by a live harness
lock=$(bash "$H/bin/fm-lock.sh" status 2>/dev/null || true)
printf '%s' "$lock" | grep -q 'held by live harness pid' || ck "session-lock-not-held(${lock:-none})"

# 2. crew harness is a verified adapter
if [ -z "$HARNESS" ]; then HARNESS=$(bash "$H/bin/fm-harness.sh" crew 2>/dev/null || echo unknown); fi
case " $VERIFIED_HARNESSES " in *" $HARNESS "*) ;; *) ck "unverified-harness($HARNESS)";; esac

# 3. an explicit model (never an implicit default)
[ -n "$MODEL" ] || ck "no-explicit-model"
case "$MODEL" in default|"") ck "model-not-explicit($MODEL)";; esac

# 4. backend tool available
[ -n "$BACKEND" ] || BACKEND=tmux
command -v "$BACKEND" >/dev/null 2>&1 || ck "backend-unavailable($BACKEND)"

# 5. project is a git repo with an origin (for the base freshness check)
if [ -z "$PROJECT" ]; then ck "no-project"; else
  git -C "$PROJECT" rev-parse --git-dir >/dev/null 2>&1 || ck "project-not-git($PROJECT)"
  git -C "$PROJECT" remote get-url origin >/dev/null 2>&1 || ck "project-no-origin($PROJECT)"
fi

# 6. contract allowed paths and forbidden operations
if [ -n "$CONTRACT" ]; then
  ap=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("allowed_paths") or []))' "$CONTRACT" 2>/dev/null || echo 0)
  [ "$ap" -gt 0 ] || ck "contract-allowed-paths-empty"
  for op in github_write credential_change real_worker_call wake_drain backpass_change kill_other_session_process; do
    grep -q "\"$op\"" "$CONTRACT" || ck "contract-missing-forbidden($op)"
  done
fi

# 7. task id not already live
[ -n "$TASKID" ] || ck "no-task-id"
[ -n "$TASKID" ] && [ -e "$H/state/$TASKID.meta" ] && ck "task-id-already-live($TASKID)"

# report
echo "preflight: harness=$HARNESS model=${MODEL:-<none>} effort=${EFFORT:-<none>} backend=$BACKEND project=${PROJECT:-<none>} task=$TASKID"
echo "preflight: session-lock: ${lock:-<none>}"
if [ "${#REASONS[@]}" -eq 0 ]; then
  echo "PREFLIGHT=GO"
  exit 0
else
  printf 'PREFLIGHT=HOLD reasons=%s\n' "${REASONS[*]}"
  exit 3
fi
