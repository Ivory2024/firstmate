#!/usr/bin/env bash
# fm-unattended-realcrew-3fault-e2e.test.sh - G4 Track A4: REAL-CREW 3-fault E2E.
#
# The real-crew counterpart of tests/fm-unattended-faultinject-e2e.test.sh.
# That guard drives the MOCK backend: a one-shot shell executor
# (`bash -c 'exit 7'`) plus two fixture levers (`FM_FAKE_NO_ACK`,
# `FM_FAKE_WRONG_IDENTITY`). This guard drives the coordinator's REAL backend
# (FM_UNATTENDED_ADAPTER=real), so every dispatch is a real bin/fm-spawn.sh crew
# in a real worktree with a real endpoint, and every fault is produced from
# OUTSIDE the coordinator by acting on that real crew or on the real dispatch
# boundary - never by setting a fixture variable.
#
# What the mock contract could not prove, and this one does:
#   - the ACK gate observes a real endpoint through bin/fm-crew-state.sh over a
#     real window, not an event the adapter wrote for itself;
#   - bounded retry and terminal HOLD hold under a real spawn cost and real
#     timing, not an instant shell;
#   - isolation is checked on a live shared resource (the operator's tmux window
#     inventory), not only on two files that a fake backend never touches.
#
# Faults (real-path):
#   F1  worker lost AFTER the run starts - real crew killed once RUNNING
#   F2  worker lost INSIDE the dispatch window - real crew killed the moment
#       its window appears, before the coordinator finishes the dispatch step.
#       The ACK may already have been satisfied by the live endpoint, so both
#       worker-loss scenarios can terminalize through the same timeout path;
#       the guard records the reason instead of asserting one.
#   F3  dispatch refused        - real project whose verified base cannot be
#                                 resolved, so the adapter refuses to spawn
#
# A3's third fault, identity-mismatch, has NO real-crew trigger and stays a
# mock-only lever; the guard states why as its final evidence line.
#
# Asserted per fault (the real-path safety contract):
#   terminal HOLD; dispatches bounded by retry_limit+1; no dispatch after HOLD;
#   residual crew 0; operator tmux inventory and wake queue unchanged.
# The exact HOLD reason is RECORDED, not asserted: a real fault reaches HOLD
# through whichever real signal arrives first, and pinning the reason would
# re-import the mock's determinism.
#
# Opt-in (spends real model tokens):
#   FM_REALCREW_E2E=1 tests/fm-unattended-realcrew-3fault-e2e.test.sh
#   FM_UC_IMPL_DIR=<dir holding fm-unattended.sh>   (default $ROOT/bin)
# shellcheck disable=SC2015 # ok() and no() both return 0, so `A && ok || no`
# is if/else here: the `no` branch cannot run once `ok` has run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_REALCREW_E2E opencode tmux git

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMPL="${FM_UC_IMPL_DIR:-$ROOT/bin}"
MODEL="${FM_REALCREW_MODEL:-opencode/mimo-v2.6-flash-free}"
HARNESS="${FM_REALCREW_HARNESS:-opencode}"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok - %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'NOT OK - %s\n' "$1"; }

if [ ! -x "$IMPL/fm-unattended.sh" ] || [ ! -x "$IMPL/fm-unattended-adapter.sh" ]; then
  printf 'skip: realcrew: no unattended implementation at %s (set FM_UC_IMPL_DIR)\n' "$IMPL"
  exit 0
fi

LAB=$(mktemp -d "${TMPDIR:-/tmp}/realcrew.XXXXXX")
TMUXDIR="$LAB/tmux"          # private tmux server, well under the socket path limit
mkdir -p "$TMUXDIR"
HOME_DIR="$LAB/home"
UC_HOME="$LAB/uc"
GOOD_PROJ="$LAB/proj-good"
BAD_PROJ="$LAB/proj-bad"
SESSION="fm-realcrew-e2e"

cleanup() {
  env -u TMUX TMUX_TMPDIR="$TMUXDIR" tmux kill-server >/dev/null 2>&1 || true
  chmod -R u+w "$LAB" >/dev/null 2>&1 || true
  rm -rf "$LAB" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---- operator baseline: the live resource a mock contract never checks -------
OP_WINDOWS_BEFORE=$(tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null | sort)
OP_QUEUE="$ROOT/state/.wake-queue"
if [ -f "$OP_QUEUE" ]; then
  OP_QUEUE_BEFORE=$(wc -l < "$OP_QUEUE" | tr -d ' ')
else
  OP_QUEUE_BEFORE=""
fi

# ---- isolated home and projects ---------------------------------------------
git clone --quiet --local "$ROOT" "$HOME_DIR" || fail "could not clone the isolated home"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/data"
cat > "$HOME_DIR/config/unattended-crew.json" <<JSON
{
  "evidence_root": "$UC_HOME/evidence",
  "quota": {
    "max_concurrent_crews": 1,
    "max_provider_calls": 6,
    "free_models": ["$MODEL"],
    "allow_paid_models": false
  }
}
JSON

make_project() { # <dir> <local|none>
  mkdir -p "$1"
  git -C "$1" init --quiet -b main
  printf '# scratch\n' > "$1/README.md"
  git -C "$1" add README.md
  git -C "$1" -c user.email=e2e@local -c user.name=e2e commit --quiet -m init
  git -C "$1" config firstmate.expectedRepository e2e-owner/scratch
  [ "$2" = local ] && git -C "$1" config firstmate.baseMode local
  return 0
}
make_project "$GOOD_PROJ" local
make_project "$BAD_PROJ" none

# Every coordinator call runs on the private tmux server (TMUX_TMPDIR with TMUX
# unset), so a crew can never land in the operator's session. The spawn id is
# per-fault: the adapter defaults it to the task id, and a shared id across
# batches would make scenario N+1 adopt scenario N's endpoint.
uc() { # <proj> <exec-id> <coordinator args...>
  local p=$1 xid=$2
  shift 2
  env -u TMUX TMUX_TMPDIR="$TMUXDIR" FM_TMUX_SESSION="$SESSION" \
    UC_HOME="$UC_HOME" UC_IMPL_DIR="$IMPL" UC_ENTRYPOINT_ROLE=captain \
    UC_CONFIG_FILE="$HOME_DIR/config/unattended-crew.json" \
    FM_HOME="$HOME_DIR" UC_FM_HOME="$HOME_DIR" UC_REAL_PROJECT="$p" \
    UC_REAL_EXEC_ID="$xid" UC_REAL_AUDIT_ID="${xid}-audit" \
    FM_UNATTENDED_ADAPTER=real UC_REAL_HARNESS="$HARNESS" UC_REAL_MODEL="$MODEL" \
    UC_REAL_BACKEND=tmux UC_QUOTA_ENFORCE=1 \
    UC_CREW_WAIT_SECS="${UC_CREW_WAIT_SECS:-20}" \
    UC_CREW_TIMEOUT="${UC_CREW_TIMEOUT:-25}" UC_CREW_STALL_LIMIT=1 \
    bash "$IMPL/fm-unattended.sh" "$@"
}

state_of() { sed -n 's/^new=//p' "$UC_HOME/batches/$1/tasks/t1.state" 2>/dev/null; }
reasons() { sed -n "s/.*task_id=$2 .*new=\([A-Z_]*\) reason=\([^ ]*\).*/\1:\2/p" "$UC_HOME/batches/$1/state.jsonl" 2>/dev/null | tr '\n' ' '; }
dispatches() { grep -c 'new=DISPATCHING' "$UC_HOME/batches/$1/state.jsonl" 2>/dev/null || echo 0; }
crew_windows() { env -u TMUX TMUX_TMPDIR="$TMUXDIR" tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -c '^fm-' || true; }
held() { [ -f "$UC_HOME/batches/$1/.batch-held" ]; }
kill_crew_windows() {
  local w
  for w in $(env -u TMUX TMUX_TMPDIR="$TMUXDIR" tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep '^fm-' || true); do
    env -u TMUX TMUX_TMPDIR="$TMUXDIR" tmux kill-window -t "$SESSION:$w" >/dev/null 2>&1 || true
  done
}

write_contract() { # <file> <batch> <retry_limit> <ack_timeout>
  cat > "$1" <<JSON
{
  "batch_id": "$2",
  "baseline_sha": "e2e",
  "mode": "test",
  "retry_limit": $3,
  "ack_timeout_secs": $4,
  "tasks": [
    {
      "task_id": "t1",
      "required_tests": ["t1"],
      "audit": {"required": true,
                "intent": "Independently verify the executor's report.",
                "spec": "Read the report; report PASS or FAIL. Do not modify files."},
      "executor": {
        "intent": "Read README.md in this worktree and write the one-line report.",
        "spec": "Do not modify any file. Do not commit."
      }
    }
  ]
}
JSON
}

# Re-enter the coordinator the way a supervisor would until the batch latches.
# The guard never repairs state; the injected fault is the only outside action.
drive_until_held() { # <proj> <exec-id> <batch> <max_iters>
  local p=$1 xid=$2 b=$3 max=$4 i=0
  while [ "$i" -lt "$max" ]; do
    uc "$p" "$xid" run --batch "$b" >/dev/null 2>&1 || true
    held "$b" && return 0
    i=$((i + 1))
  done
  return 1
}

assert_safety() { # <label> <proj> <exec-id> <batch> <max_dispatches>
  local label=$1 p=$2 xid=$3 b=$4 want=$5 d
  d=$(dispatches "$b")
  [ "$(state_of "$b" t1)" = HOLD ] && ok "$label: terminal HOLD" \
    || no "$label: terminal state $(state_of "$b" t1)"
  [ "$d" -ge 1 ] && [ "$d" -le "$want" ] && ok "$label: dispatch bounded ($d <= $want)" \
    || no "$label: dispatch out of bounds ($d, want 1..$want)"
  case "$(reasons "$b" t1)" in
    *HOLD:*) ok "$label: HOLD carries a reason" ;;
    *) no "$label: HOLD without a reason" ;;
  esac
  uc "$p" "$xid" resume --batch "$b" >/dev/null 2>&1 || true
  [ "$(dispatches "$b")" = "$d" ] && ok "$label: no dispatch after HOLD ($d)" \
    || no "$label: dispatched after HOLD ($d -> $(dispatches "$b"))"
  printf '    evidence %s: state=%s dispatches=%s reasons=%s\n' \
    "$label" "$(state_of "$b" t1)" "$d" "$(reasons "$b" t1)"
}

# ---- F1: real crew lost after ACK -------------------------------------------
write_contract "$LAB/f1.json" f1 1 8
uc "$GOOD_PROJ" f1-exec init --batch f1 --contract "$LAB/f1.json" >/dev/null 2>&1

inject_after_running() { # <batch>
  local b=$1 i=0
  while [ "$i" -lt 900 ]; do
    if [ "$(state_of "$b" t1)" = RUNNING ]; then kill_crew_windows; return 0; fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

inject_after_running f1 &
INJ=$!
drive_until_held "$GOOD_PROJ" f1-exec f1 40 && ok "F1: reached HOLD with no repair" \
  || no "F1: never reached HOLD"
wait "$INJ" 2>/dev/null || true
assert_safety F1 "$GOOD_PROJ" f1-exec f1 2

# ---- F2: real crew lost inside the dispatch window --------------------------
write_contract "$LAB/f2.json" f2 1 8
uc "$GOOD_PROJ" f2-exec init --batch f2 --contract "$LAB/f2.json" >/dev/null 2>&1

inject_on_window() { # kill the crew window the moment it appears
  local i=0
  while [ "$i" -lt 900 ]; do
    if [ "$(crew_windows)" != 0 ]; then kill_crew_windows; return 0; fi
    sleep 0.05; i=$((i + 1))
  done
  return 1
}

inject_on_window &
INJ=$!
drive_until_held "$GOOD_PROJ" f2-exec f2 40 && ok "F2: reached HOLD with no repair" \
  || no "F2: never reached HOLD"
wait "$INJ" 2>/dev/null || true
assert_safety F2 "$GOOD_PROJ" f2-exec f2 2

# ---- F3: real dispatch refusal (unverifiable verified base) -----------------
write_contract "$LAB/f3.json" f3 1 8
uc "$BAD_PROJ" f3-exec init --batch f3 --contract "$LAB/f3.json" >/dev/null 2>&1
drive_until_held "$BAD_PROJ" f3-exec f3 40 && ok "F3: reached HOLD with no repair" \
  || no "F3: never reached HOLD"
assert_safety F3 "$BAD_PROJ" f3-exec f3 2

# ---- residual crews: nothing left running ----------------------------------
[ "$(crew_windows)" = 0 ] && ok "residual crew 0 in the isolated session" \
  || no "residual crew $(crew_windows)"

# ---- operational invariance (live resources, not just two files) ------------
OP_WINDOWS_AFTER=$(tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null | sort)
[ "$OP_WINDOWS_BEFORE" = "$OP_WINDOWS_AFTER" ] \
  && ok "operator tmux inventory unchanged ($(printf '%s' "$OP_WINDOWS_AFTER" | wc -l | tr -d ' ') windows)" \
  || no "operator tmux inventory changed"
if [ -n "$OP_QUEUE_BEFORE" ]; then
  OP_QUEUE_AFTER=$(wc -l < "$OP_QUEUE" | tr -d ' ')
  [ "$OP_QUEUE_BEFORE" = "$OP_QUEUE_AFTER" ] && ok "operator wake queue unchanged" \
    || no "operator wake queue changed ($OP_QUEUE_BEFORE -> $OP_QUEUE_AFTER)"
else
  ok "operator wake queue not present in this checkout (nothing to compare)"
fi

# ---- the mock-only finding, stated as evidence ------------------------------
printf '    MOCK-ONLY: A3 fault-3 (identity-mismatch / FM_FAKE_WRONG_IDENTITY)\n'
printf '      has no real-crew trigger: the adapter reads identity from the very\n'
printf '      state/<spawn>.meta a successful dispatch just wrote, and it clears a\n'
printf '      stale meta before spawning, so no real crew fault can make\n'
printf '      identity != session. Real-crew coverage is therefore 2 of A3'"'"'s 3\n'
printf '      mock faults plus one real dispatch-boundary fault.\n'

printf '# fm-unattended-realcrew-3fault-e2e.test.sh PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
