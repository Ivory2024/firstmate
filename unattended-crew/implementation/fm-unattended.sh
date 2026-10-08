#!/usr/bin/env bash
# fm-unattended.sh - Batch Coordinator for Firstmate's unattended crew
# orchestrator (MVP).
#
# This is the top-level entrypoint. It drives a batch of task contracts through
# a durable, restart-safe, idempotent state machine:
#
#   CAPTAIN REQUEST -> TASK CONTRACT -> BATCH COORDINATOR
#     -> CREW EXECUTOR -> EVIDENCE COLLECTOR
#     -> INDEPENDENT AUDITOR -> AUDIT EVIDENCE
#     -> DETERMINISTIC JUDGE -> VERIFIED_PASS|REWORK|HOLD|AUDIT_UNAVAILABLE
#     -> NEXT SAFE TASK / HANDOFF
#
# It REUSES firstmate's existing direction: the dispatch stage talks to a Crew
# Dispatch Adapter (fm-unattended-adapter.sh) whose real backend would call
# bin/fm-spawn.sh + bin/fm-send.sh + bin/fm-crew-state.sh; the evidence stage
# reuses the evidence runner; the judgement stage reuses the judge. It NEVER
# calls a real worker/provider (that is the unapproved integration gate) and
# never touches a firstmate home, watcher, credential, or GitHub.
#
# Persistence lives outside every suite workspace, under
# $UC_HOME/batches/<batch>/: state.jsonl (append-only transitions), tasks/,
# sessions/, evidence/runs/<task>/ (executor + auditor + gate), handoff.md.
# The state machine is driven by `advance` (one meaningful step per task) so a
# coordinator killed mid-task is resumed, not duplicated: a live or completed
# evidence run is adopted instead of re-dispatched.
#
# Usage:
#   fm-unattended.sh init   --batch B --contract C.json
#   fm-unattended.sh run    --batch B        (first drive)
#   fm-unattended.sh resume --batch B        (restart / pickup)
#   fm-unattended.sh status --batch B
#   fm-unattended.sh next   --batch B
#   fm-unattended.sh handoff --batch B
set -u

UC_HOME=${UC_HOME:?set UC_HOME to the batch root}
IMPL_DIR=${UC_IMPL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
ADAPTER="$IMPL_DIR/fm-unattended-adapter.sh"
EVIDENCE="$IMPL_DIR/fm-unattended-evidence.sh"
JUDGE="$IMPL_DIR/fm-unattended-judge.sh"
FAKE_AUDITOR="$IMPL_DIR/fake-auditor.sh"
WAIT_SECS=${UC_WAIT_SECS:-40}
BACKEND=${FM_UNATTENDED_ADAPTER:-fake}
CREW_WAIT=${UC_CREW_WAIT_SECS:-30}

_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_bdir() { printf '%s/batches/%s\n' "$UC_HOME" "$1"; }
_evroot() { printf '%s/batches/%s/evidence\n' "$UC_HOME" "$1"; }
_tdir() { printf '%s/batches/%s/tasks\n' "$UC_HOME" "$1"; }
_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }

# ---- real-crew observation helpers -----------------------------------------
_crew_status_line() { UC_HOME="$UC_HOME" "$ADAPTER" status --batch "$1" --session "$2" 2>/dev/null || true; }
_crew_state_of() { printf '%s\n' "$1" | sed -n 's/^state=\([^ ]*\).*/\1/p' | head -1; }

# ACK gate: spawn success is NOT an ACK. A live endpoint (working/parked/done)
# must be observed within the contract's ack window; a dead/absent endpoint or
# an expired window is a refusal.
_real_wait_ack() { # <batch> <session> <secs>
  local b=$1 sid=$2 secs=${3:-5} ticks i st
  ticks=$(( secs * 5 )); i=0
  while [ $i -lt "$ticks" ]; do
    st=$(_crew_state_of "$(_crew_status_line "$b" "$sid")")
    case "$st" in working|parked|done) return 0;; failed|absent|unknown) return 1;; esac
    sleep 0.2; i=$((i+1))
  done
  return 1
}

# Wait for the crew to finish. Echo the observed state; return 0=done 1=timeout
# 2=dead. An unrecognized/dead endpoint never counts as success.
_real_wait_done() { # <batch> <session> <secs>
  local b=$1 sid=$2 secs=${3:-30} ticks i st
  ticks=$(( secs * 5 )); i=0
  while [ $i -lt "$ticks" ]; do
    st=$(_crew_state_of "$(_crew_status_line "$b" "$sid")")
    case "$st" in done) echo "done"; return 0;; failed|absent|unknown) echo "$st"; return 2;; esac
    sleep 0.2; i=$((i+1))
  done
  echo "${st:-timeout}"; return 1
}


# ---- contract access (python3) ---------------------------------------------
_jget() { python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
cur=d
for k in sys.argv[2].split("."):
    if isinstance(cur,list): cur=cur[int(k)]
    elif isinstance(cur,dict): cur=cur.get(k)
    else: cur=None; break
if cur is None: print("")
elif isinstance(cur,bool): print("true" if cur else "false")
elif isinstance(cur,(dict,list)): print(json.dumps(cur))
else: print(cur)' "$1" "$2" 2>/dev/null; }
_jlen() { python3 -c 'import json,sys
d=json.load(open(sys.argv[1]));v=d
for k in sys.argv[2].split("."):
    if isinstance(v,list): v=v[int(k)]
    elif isinstance(v,dict): v=v.get(k)
    else: v=None; break
print(len(v) if isinstance(v,list) else 0)' "$1" "$2" 2>/dev/null; }
_jarray_nul() { python3 -c 'import json,sys
d=json.load(open(sys.argv[1]));v=d
for k in sys.argv[2].split("."):
    if isinstance(v,list): v=v[int(k)]
    elif isinstance(v,dict): v=v.get(k)
    else: v=None; break
for x in (v or []): sys.stdout.write(str(x)); sys.stdout.write("\0")' "$1" "$2" 2>/dev/null; }

# Flatten one task into the per-run contract the judge reads, carrying the
# batch-level mode/patch/forbidden and the task-level required_tests so the
# judge's deterministic floor applies to this task specifically.
_write_task_contract() { # <batch-contract> <task-index> <out-file>
  python3 -c 'import json,sys
c=json.load(open(sys.argv[1])); i=int(sys.argv[2])
t=c["tasks"][i] if 0 <= i < len(c["tasks"]) else {}
flat={"batch_id":c.get("batch_id"),"mode":c.get("mode"),"patch_sha256":c.get("patch_sha256"),
      "forbidden_operations":c.get("forbidden_operations")}
for k in ("task_id","required_tests","patch_sha256","audit","executor"):
    if k in t: flat[k]=t[k]
json.dump(flat,open(sys.argv[3],"w"))' "$1" "$2" "$3" 2>/dev/null; }

_state_of() { # <batch> <task> [field]
  local f k
  f=$(_tdir "$1")/$2.state
  [ -f "$f" ] || { [ "${3:-}" = new ] && echo QUEUED || echo ""; return; }
  k=${3:-new}; sed -n "s/^$k=//p" "$f" | tail -1
}
_set_state() { printf 'new=%s\n' "$3" > "$(_tdir "$1")/$2.state"; }
_attempts() { local f; f=$(_tdir "$1")/$2.attempts; [ -f "$f" ] && cat "$f" || echo 0; }
_bump_attempts() { local f; f=$(_tdir "$1")/$2.attempts; echo "$(( $(_attempts "$1" "$2") + 1 ))" > "$f"; }

# append a transition; dedup on (task,attempt,new,reason) so a duplicate wake
# cannot record a second crew or a second outcome.
_transition() { # <batch> <task> <prev> <new> <reason> [attempt] [session] [evidence]
  local b t prev new reason attempt session ev key sl
  b=$1; t=$2; prev=$3; new=$4; reason=$5
  attempt=${6:-$(_attempts "$b" "$t")}; session=${7:-}; ev=${8:-}
  key="task_id=$t attempt=$attempt new=$new reason=$reason"
  sl=$(_bdir "$b")/state.jsonl
  if grep -qF "$key" "$sl" 2>/dev/null && [ "$new" != "RUNNING" ]; then return 0; fi
  printf 'at=%s run_id=%s task_id=%s attempt=%s session=%s role=%s baseline_sha=%s prev=%s new=%s reason=%s evidence=%s\n' \
    "$(_now)" "$b" "$t" "$attempt" "$session" "" "${UC_BASELINE_SHA:-}" "$prev" "$new" "$reason" "$ev" >> "$sl"
  _set_state "$b" "$t" "$new"
  printf '  [%s] %s -> %s (%s)\n' "$t" "$prev" "$new" "$reason"
}

_deps_ok() { # <batch> <task-index>
  local b i c n j dep st
  b=$1; i=$2; c=$(_bdir "$b")/contract.json
  n=$(_jlen "$c" "tasks.$i.depends_on")
  for (( j=0; j<n; j++ )); do
    dep=$(_jget "$c" "tasks.$i.depends_on.$j")
    st=$(_state_of "$b" "$dep" new)
    [ "$st" = "VERIFIED_PASS" ] || return 1
  done
  return 0
}

_task_index() { # <batch> <task_id> -> index or -1
  local b want c n i
  b=$1; want=$2; c=$(_bdir "$b")/contract.json
  n=$(_jlen "$c" "tasks")
  for (( i=0; i<n; i++ )); do
    [ "$(_jget "$c" "tasks.$i.task_id")" = "$want" ] && { echo "$i"; return 0; }
  done
  echo -1
}

# ---- dispatch + evidence ----------------------------------------------------
_dispatch_executor() { # <batch> <task> <attempt>
  if [ "$BACKEND" = real ]; then _dispatch_executor_real "$@"; return $?; fi
  local b t a i c ev rd ws dm sid ident runlog rpid
  local -a cmd
  b=$1; t=$2; a=$3; i=$(_task_index "$b" "$t")
  c=$(_bdir "$b")/contract.json
  ev=$(_evroot "$b"); rd=$ev/runs/$t
  # a fresh attempt starts a fresh run dir; the previous attempt's evidence is kept aside
  if [ -f "$rd/attempt" ] && [ "$(cat "$rd/attempt")" != "$a" ]; then
    mv "$rd" "$rd.attempt$(cat "$rd/attempt")"
  fi
  mkdir -p "$rd/executor" "$rd/auditor" "$rd/gate"
  printf '%s\n' "$a" > "$rd/attempt"
  _write_task_contract "$c" "$i" "$rd/task-contract.json"
  ws=$(_bdir "$b")/work/$t; mkdir -p "$ws"

  # idempotency: an existing completed or live evidence run is adopted, not redone
  if [ -f "$rd/executor/rc" ]; then _transition "$b" "$t" "$(_state_of "$b" "$t" new)" RUNNING "adopt-completed-run" "$a"; return 0; fi
  if [ -f "$rd/executor-runner.pid" ] && kill -0 "$(cat "$rd/executor-runner.pid")" 2>/dev/null; then
    _transition "$b" "$t" "$(_state_of "$b" "$t" new)" RUNNING "adopt-live-run" "$a"; return 0; fi

  dm=""
  _transition "$b" "$t" "$(_state_of "$b" "$t" new)" DISPATCHING "dispatch-executor" "$a"
  dm=$(UC_HOME="$UC_HOME" "$ADAPTER" dispatch --batch "$b" --task "$t" --role executor --attempt "$a" --workdir "$ws" 2>&1) || true
  if ! printf '%s' "$dm" | grep -q 'DISPATCHED'; then
    if printf '%s' "$dm" | grep -q 'DUPLICATE_DISPATCH'; then
      _transition "$b" "$t" DISPATCHING HOLD "duplicate-dispatch" "$a"; return 0
    fi
    _transition "$b" "$t" DISPATCHING REWORK "ack-timeout" "$a"; return 0
  fi
  sid=$(printf '%s\n' "$dm" | sed -n 's/.*session=\([^ ]*\).*/\1/p' | tail -1)
  ident=$(UC_HOME="$UC_HOME" "$ADAPTER" identity --batch "$b" --session "$sid" 2>/dev/null)
  printf '{"session_id":"%s","role":"executor","task":"%s","workdir":"%s"}\n' "$sid" "$t" "$ws" > "$rd/executor/session.json"
  if [ "$ident" != "$sid" ]; then
    _transition "$b" "$t" DISPATCHING HOLD "identity-mismatch" "$a" "$sid"; return 0
  fi
  _transition "$b" "$t" DISPATCHING ACKNOWLEDGED "executor-ack" "$a" "$sid"
  # launch the tracked test OUT of process so a coordinator restart never
  # deletes a running suite (the prior batch's failure mode).
  cmd=(); mapfile -t -d '' cmd < <(_jarray_nul "$c" "tasks.$i.executor.command")
  runlog="$rd/executor-run.log"
  EVIDENCE_ROOT="$ev" GIT_DIR_FOR_RUN="$ws" \
    "$EVIDENCE" run "$t" -- "${cmd[@]}" > "$runlog" 2>&1 &
  rpid=$!; printf '%s\n' "$rpid" > "$rd/executor-runner.pid"
  printf '%s\n' "$sid" > "$rd/executor/session-id"
  _transition "$b" "$t" ACKNOWLEDGED RUNNING "executor-running" "$a" "$sid"
  return 0
}

# ---- real-crew dispatch, evidence, and audit --------------------------------
# The real backend never runs a one-shot command: it spawns an interactive
# firstmate crew, observes the endpoint, harvests the durable evidence, then
# spawns a SEPARATE auditor crew. Nothing here calls a provider directly; the
# spawn/steer/state primitives are the adapter's, which is what the mock home
# substitutes for the offline E2E test.

_dispatch_executor_real() { # <batch> <task> <attempt>
  local b t a i c ev rd ws dm sid spawn_id wt ident ack_to gt
  b=$1; t=$2; a=$3; i=$(_task_index "$b" "$t")
  c=$(_bdir "$b")/contract.json; ev=$(_evroot "$b"); rd=$ev/runs/$t
  if [ -f "$rd/attempt" ] && [ "$(cat "$rd/attempt")" != "$a" ]; then
    mv "$rd" "$rd.attempt$(cat "$rd/attempt")"
  fi
  mkdir -p "$rd/executor" "$rd/auditor" "$rd/gate"
  printf '%s\n' "$a" > "$rd/attempt"
  _write_task_contract "$c" "$i" "$rd/task-contract.json"
  ws=$(_bdir "$b")/work/$t; mkdir -p "$ws"
  if [ -f "$rd/executor/rc" ]; then _transition "$b" "$t" "$(_state_of "$b" "$t" new)" RUNNING "adopt-completed-run" "$a"; return 0; fi

  _transition "$b" "$t" "$(_state_of "$b" "$t" new)" DISPATCHING "dispatch-executor" "$a"
  dm=$(UC_HOME="$UC_HOME" "$ADAPTER" dispatch --batch "$b" --task "$t" --role executor --attempt "$a" --workdir "$ws" 2>&1) || true
  if ! printf '%s' "$dm" | grep -q 'DISPATCHED'; then
    printf '%s' "$dm" | grep -q 'DUPLICATE_DISPATCH' && { _transition "$b" "$t" DISPATCHING HOLD "duplicate-dispatch" "$a"; return 0; }
    _transition "$b" "$t" DISPATCHING REWORK "spawn-failed" "$a"; return 0
  fi
  sid=$(printf '%s\n' "$dm" | sed -n 's/.*session=\([^ ]*\).*/\1/p' | tail -1)
  spawn_id=$(printf '%s\n' "$dm" | sed -n 's/.*spawn_id=\([^ ]*\).*/\1/p' | tail -1)
  wt=$(printf '%s\n' "$dm" | sed -n 's/.*worktree=\([^ ]*\).*/\1/p' | tail -1)
  ident=$(UC_HOME="$UC_HOME" "$ADAPTER" identity --batch "$b" --session "$sid" 2>/dev/null || true)
  printf '{"session_id":"%s","spawn_id":"%s","role":"executor","task":"%s","workdir":"%s"}\n' \
    "$sid" "$spawn_id" "$t" "${wt:-$ws}" > "$rd/executor/session.json"
  [ -n "$sid" ] && printf '%s\n' "$sid" > "$rd/executor/session-id"
  [ -n "$spawn_id" ] && printf '%s\n' "$spawn_id" > "$rd/executor/spawn-id"
  if [ "$ident" != "$sid" ]; then _transition "$b" "$t" DISPATCHING HOLD "identity-mismatch" "$a" "$sid"; return 0; fi

  # pre-run worktree SHA, recorded before the crew can change it
  gt=${wt:-$ws}
  printf '{"sha":"%s","branch":"%s","recorded_at":%s}\n' \
    "$(git -C "$gt" rev-parse HEAD 2>/dev/null || echo unknown)" \
    "$(git -C "$gt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)" "$(date +%s)" > "$rd/executor/git-before.json"
  printf '%s\n' "$gt" > "$rd/executor/wd"

  ack_to=$(_jget "$c" ack_timeout_secs); [ -n "$ack_to" ] || ack_to=5
  if ! _real_wait_ack "$b" "$sid" "$ack_to"; then
    _transition "$b" "$t" DISPATCHING REWORK "ack-timeout" "$a" "$sid"; return 0
  fi
  _transition "$b" "$t" DISPATCHING ACKNOWLEDGED "executor-ack" "$a" "$sid"
  _transition "$b" "$t" ACKNOWLEDGED RUNNING "executor-running" "$a" "$sid"
  return 0
}

_real_collect_executor() { # <batch> <task>  -> 0 clean evidence, 1 incomplete
  local b t ev rd sid spawn wd report attest c
  b=$1; t=$2; c=$(_bdir "$b")/contract.json
  ev=$(_evroot "$b"); rd=$ev/runs/$t
  sid=$(cat "$rd/executor/session-id" 2>/dev/null || echo "")
  spawn=$(cat "$rd/executor/spawn-id" 2>/dev/null || echo "")
  wd=$(cat "$rd/executor/wd" 2>/dev/null || echo "")
  [ -n "$spawn" ] || return 1
  report="${UC_FM_HOME:?}/data/$spawn/report.md"
  attest=$(_jget "$c" "tasks.$(_task_index "$b" "$t").executor.attest")
  local patch; patch=$(_jget "$c" patch_sha256)
  EVIDENCE_ROOT="$ev" FM_PATCH_SHA256="$patch" \
    "$EVIDENCE" collect "$t" --home "${UC_FM_HOME:?}" --spawn-id "$spawn" --workdir "$wd" \
    --report "$report" ${attest:+--attest "$attest"} >/dev/null 2>&1
}

_dispatch_auditor_real() { # <batch> <task> <attempt>
  local b t a i c ev rd aws dm sid spawn verdict report wt
  b=$1; t=$2; a=$3; i=$(_task_index "$b" "$t")
  c=$(_bdir "$b")/contract.json; ev=$(_evroot "$b"); rd=$ev/runs/$t
  aws=$(_bdir "$b")/audit-ws/$t; mkdir -p "$aws"
  # production path may NEVER use the built-in fake auditor
  local -a acmd; mapfile -t -d '' acmd < <(_jarray_nul "$c" "tasks.$i.audit.command")
  if [ "${#acmd[@]}" -gt 0 ] && printf '%s\n' "${acmd[*]}" | grep -q 'fake-auditor.sh'; then
    _transition "$b" "$t" "$(_state_of "$b" "$t" new)" HOLD "fake-auditor-in-production" "$a"; return 0
  fi

  dm=$(UC_HOME="$UC_HOME" "$ADAPTER" dispatch --batch "$b" --task "$t" --role auditor --attempt "$a" --workdir "$aws" 2>&1) || true
  if printf '%s' "$dm" | grep -q 'DISPATCHED'; then
    sid=$(printf '%s\n' "$dm" | sed -n 's/.*session=\([^ ]*\).*/\1/p' | tail -1)
    spawn=$(printf '%s\n' "$dm" | sed -n 's/.*spawn_id=\([^ ]*\).*/\1/p' | tail -1)
    wt=$(printf '%s\n' "$dm" | sed -n 's/.*worktree=\([^ ]*\).*/\1/p' | tail -1)
  elif printf '%s' "$dm" | grep -q 'DUPLICATE_DISPATCH'; then
    sid=$(printf '%s\n' "$dm" | sed -n 's/.*session=\([^ ]*\).*/\1/p' | tail -1); spawn=${sid##*:}
  else
    limit=$(_jget "$c" retry_limit); [ -n "$limit" ] || limit=2
    _transition "$b" "$t" "$(_state_of "$b" "$t" new)" REWORK "auditor-dispatch-failed" "$a"
    if [ "$a" -ge "$limit" ]; then _transition "$b" "$t" REWORK HOLD "retry-exhausted" "$a"; fi
    return 0
  fi
  [ -n "$wt" ] || wt=$aws
  _transition "$b" "$t" "$(_state_of "$b" "$t" new)" AUDITING "auditor-dispatch" "$a" "$sid"

  local awt st
  awt=$(_jget "$c" ack_timeout_secs); [ -n "$awt" ] || awt=5
  st=$(_real_wait_done "$b" "$sid" "$awt")
  if [ "$st" != "done" ]; then
    # no usable audit -> judge yields AUDIT_UNAVAILABLE, never VERIFIED_PASS
    printf '{"session_id":"%s","spawn_id":"%s","role":"auditor","task":"%s","workdir":"%s","auditor_kind":"real","state":"%s"}\n' \
      "$sid" "$spawn" "$t" "$wt" "$st" > "$rd/auditor/session.json"
    _judge_task "$b" "$t" "$a"; return 0
  fi
  report="${UC_FM_HOME:?}/data/$spawn/report.md"
  verdict=$(grep -oiE 'verdict[=:[:space:]]+(PASS|FAIL|CONFLICT|UNAVAILABLE)' "$report" 2>/dev/null | tail -1 | grep -oiE 'PASS|FAIL|CONFLICT|UNAVAILABLE' | tr '[:lower:]' '[:upper:]')
  printf '{"session_id":"%s","spawn_id":"%s","role":"auditor","task":"%s","workdir":"%s","auditor_kind":"real"}\n' \
    "$sid" "$spawn" "$t" "$wt" > "$rd/auditor/session.json"
  if [ -n "$verdict" ]; then
    case "$verdict" in FAIL) verdict=CONFLICT;; esac
    printf '{"verdict":"%s","auditor_kind":"real","report":"%s"}\n' "$verdict" "$report" > "$rd/auditor/findings.json"
  fi
  _judge_task "$b" "$t" "$a"
  return 0
}

_wait_runner() { # <rc_file> <runner_pid> <secs>  -> 0 if rc appeared
  local rc pid ticks i
  rc=$1; pid=$2; ticks=$(( ${3:-40} * 5 )); i=0
  while [ $i -lt "$ticks" ]; do
    [ -f "$rc" ] && return 0
    kill -0 "$pid" 2>/dev/null || { [ -f "$rc" ] && return 0; return 1; }
    sleep 0.2; i=$((i + 1))
  done
  [ -f "$rc" ]
}

_dispatch_auditor() { # <batch> <task> <attempt>
  local b t a i c ev rd aws dm sid
  local -a acmd
  b=$1; t=$2; a=$3; i=$(_task_index "$b" "$t")
  c=$(_bdir "$b")/contract.json; ev=$(_evroot "$b"); rd=$ev/runs/$t
  aws=$(_bdir "$b")/audit-ws/$t; mkdir -p "$aws"
  # production path may never use the built-in fake auditor
  if [ "$(_jget "$c" mode)" = production ] && [ "$(_jlen "$c" "tasks.$i.audit.command")" -eq 0 ]; then
    _transition "$b" "$t" "$(_state_of "$b" "$t" new)" HOLD "fake-auditor-in-production" "$a"; return 0
  fi
  dm=""
  dm=$(UC_HOME="$UC_HOME" "$ADAPTER" dispatch --batch "$b" --task "$t" --role auditor --attempt "$a" --workdir "$aws" 2>&1) || true
  if printf '%s' "$dm" | grep -q 'DISPATCHED'; then
    sid=$(printf '%s\n' "$dm" | sed -n 's/.*session=\([^ ]*\).*/\1/p' | tail -1)
  elif printf '%s' "$dm" | grep -q 'DUPLICATE_DISPATCH'; then
    # idempotent adoption: a prior attempt already registered the auditor; reuse it
    sid=$(printf '%s\n' "$dm" | sed -n 's/.*session=\([^ ]*\).*/\1/p' | tail -1)
    [ -n "$sid" ] || sid="adopted-$t-auditor"
  else
    _transition "$b" "$t" "$(_state_of "$b" "$t" new)" REWORK "auditor-dispatch-failed" "$a"; return 0
  fi
  _transition "$b" "$t" "$(_state_of "$b" "$t" new)" AUDITING "auditor-dispatch" "$a" "$sid"
  # auditor runs in its OWN workspace; the default fake auditor proves the
  # protocol only and is marked auditor_kind=fake.
  acmd=(); mapfile -t -d '' acmd < <(_jarray_nul "$c" "tasks.$i.audit.command")
  mkdir -p "$rd/auditor"
  if [ "${#acmd[@]}" -eq 0 ]; then
    ( cd "$aws" && "$FAKE_AUDITOR" "$rd" >/dev/null 2>&1 )
  else
    ( cd "$aws" && "${acmd[@]}" >/dev/null 2>&1 )
  fi
  printf '{"session_id":"%s","role":"auditor","task":"%s","workdir":"%s"}\n' "$sid" "$t" "$aws" > "$rd/auditor/session.json"
  _judge_task "$b" "$t" "$a"
  return 0
}

_judge_task() { # <batch> <task> <attempt>
  local b t a ev rd out verdict prev
  b=$1; t=$2; a=$3
  ev=$(_evroot "$b"); rd=$ev/runs/$t
  out=$(EVIDENCE_ROOT="$ev" "$JUDGE" run "$t" 2>&1)
  verdict=$(printf '%s' "$out" | sed -n 's/^VERDICT=//;s/ .*//p')
  prev=$(_state_of "$b" "$t" new)
  _transition "$b" "$t" "$prev" "$verdict" "judge" "$a" "" "$rd/gate/verdict.json"
  return 0
}

# ---- one step of the state machine -----------------------------------------
_advance() { # <batch> <task>
  local b t st a i c limit
  b=$1; t=$2; c=$(_bdir "$b")/contract.json
  i=$(_task_index "$b" "$t"); [ "$i" != "-1" ] || return 0
  st=$(_state_of "$b" "$t" new); a=$(_attempts "$b" "$t")

  case "$st" in
    QUEUED|REWORK)
      # real backend: a completed executor must not be re-run just because the
      # audit failed; retry the audit only (capped by the auditor's own retry).
      if [ "$BACKEND" = real ] && [ "$st" = REWORK ] && [ -f "$(_evroot "$b")/runs/$t/executor/rc" ]; then
        _bump_attempts "$b" "$t"
        _transition "$b" "$t" REWORK AUDIT_PENDING "retry-audit" "$(_attempts "$b" "$t")"; return 0
      fi
      [ "$(_jget "$c" "tasks.$i.approval_required")" = "true" ] && { _transition "$b" "$t" "$st" HOLD "approval-required" "$a"; return 0; }
      _deps_ok "$b" "$i" || return 0
      limit=$(_jget "$c" retry_limit); [ -n "$limit" ] || limit=2
      [ "$a" -ge "$limit" ] && { _transition "$b" "$t" "$st" HOLD "retry-exhausted" "$a"; return 0; }
      _bump_attempts "$b" "$t"; _dispatch_executor "$b" "$t" "$(_attempts "$b" "$t")" ;;
    *) return 0 ;;
  esac
}

_step_real() { # <batch> <task> <state> <attempt> <index> <contract> <rundir>
  local b=$1 t=$2 st=$3 a=$4 i=$5 c=$6 rd=$7 sid res rc
  case "$st" in
    QUEUED|REWORK) _advance "$b" "$t"; return 0 ;;
    DISPATCHING|ACKNOWLEDGED|RUNNING)
      if [ -f "$rd/executor/rc" ]; then _transition "$b" "$t" "$st" EVIDENCE_PENDING "evidence-collected" "$a"; return 0; fi
      sid=$(cat "$rd/executor/session-id" 2>/dev/null || echo "")
      if [ -z "$sid" ]; then _transition "$b" "$t" "$st" HOLD "worker-interrupted" "$a"; return 0; fi
      res=$(_real_wait_done "$b" "$sid" "$CREW_WAIT"); rc=$?
      case "$rc" in
        0) if _real_collect_executor "$b" "$t"; then
             _transition "$b" "$t" "$st" EVIDENCE_PENDING "evidence-collected" "$a"; return 0
           else
             _transition "$b" "$t" "$st" HOLD "evidence-incomplete" "$a"; return 0
           fi;;
        2) case "$res" in failed) _transition "$b" "$t" "$st" REWORK "worker-failed" "$a";; *) _transition "$b" "$t" "$st" HOLD "worker-interrupted" "$a";; esac; return 0;;
        *) return 1;;
      esac ;;
    EVIDENCE_PENDING)
      if [ "$(_jget "$c" "tasks.$i.audit.required")" = "false" ]; then _judge_task "$b" "$t" "$a"; return 0; fi
      _transition "$b" "$t" EVIDENCE_PENDING AUDIT_PENDING "awaiting-audit" "$a"; return 0 ;;
    AUDIT_PENDING|AUDITING) _dispatch_auditor_real "$b" "$t" "$a"; return 0 ;;
    VERIFIED_PASS|HOLD|CANCELLED|AUDIT_UNAVAILABLE) return 2 ;;
    *) return 0 ;;
  esac
}

_step() { # <batch> <task> : drive one task as far as evidence allows this call
  local b t i st a c ev rd rpid
  b=$1; t=$2; c=$(_bdir "$b")/contract.json
  i=$(_task_index "$b" "$t"); [ "$i" != "-1" ] || return 1
  ev=$(_evroot "$b"); rd=$ev/runs/$t
  st=$(_state_of "$b" "$t" new); a=$(_attempts "$b" "$t")
  if [ "$BACKEND" = real ]; then _step_real "$b" "$t" "$st" "$a" "$i" "$c" "$rd"; return $?; fi

  case "$st" in
    QUEUED|REWORK) _advance "$b" "$t"; return 0 ;;
    DISPATCHING|ACKNOWLEDGED|RUNNING)
      if [ -f "$rd/executor/rc" ]; then
        _transition "$b" "$t" "$st" EVIDENCE_PENDING "evidence-collected" "$a"; return 0
      fi
      rpid=$(cat "$rd/executor-runner.pid" 2>/dev/null || echo "")
      if [ -n "$rpid" ] && _wait_runner "$rd/executor/rc" "$rpid" "$WAIT_SECS"; then
        _transition "$b" "$t" "$st" EVIDENCE_PENDING "evidence-collected" "$a"; return 0
      fi
      if [ -n "$rpid" ] && kill -0 "$rpid" 2>/dev/null; then return 1; fi
      _transition "$b" "$t" "$st" HOLD "worker-interrupted" "$a"; return 0 ;;
    EVIDENCE_PENDING)
      if [ "$(_jget "$c" "tasks.$i.audit.required")" = "false" ]; then _judge_task "$b" "$t" "$a"; return 0; fi
      _transition "$b" "$t" EVIDENCE_PENDING AUDIT_PENDING "awaiting-audit" "$a"; return 0 ;;
    AUDIT_PENDING|AUDITING) _dispatch_auditor "$b" "$t" "$a"; return 0 ;;
    VERIFIED_PASS|HOLD|CANCELLED|AUDIT_UNAVAILABLE) return 2 ;;
    *) return 0 ;;
  esac
}

_drive() { # <batch>
  local b c n i t before after changed
  b=$1; c=$(_bdir "$b")/contract.json
  n=$(_jlen "$c" "tasks")
  for _ in $(seq 1 60); do
    changed=0
    for (( i=0; i<n; i++ )); do
      t=$(_jget "$c" "tasks.$i.task_id")
      before=$(_state_of "$b" "$t" new)
      _step "$b" "$t" >/dev/null 2>&1 || true
      after=$(_state_of "$b" "$t" new)
      [ "$before" != "$after" ] && changed=1
    done
    [ "$changed" = 1 ] || break
  done
}

# ---- CLI --------------------------------------------------------------------
cmd_init() {
  local b cf bd n i t baseline
  b=""; cf=""
  while [ $# -gt 0 ]; do case "$1" in --batch) b=$2; shift 2;; --contract) cf=$2; shift 2;; *) echo "bad arg $1" >&2; exit 2;; esac; done
  [ -n "$b" ] && [ -f "$cf" ] || { echo "init: need --batch and a valid --contract" >&2; exit 2; }
  bd=$(_bdir "$b"); mkdir -p "$bd" "$(_tdir "$b")" "$bd/sessions" "$bd/evidence/runs"
  cp "$cf" "$bd/contract.json"
  baseline=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("baseline_sha",""))' "$cf")
  printf 'batch_id=%s\nbaseline_sha=%s\ncreated_at=%s\n' "$b" "$baseline" "$(_now)" > "$bd/batch.meta"
  : > "$bd/state.jsonl"
  n=$(_jlen "$bd/contract.json" "tasks")
  for (( i=0; i<n; i++ )); do t=$(_jget "$bd/contract.json" "tasks.$i.task_id"); _transition "$b" "$t" "" QUEUED "batch-init" 0; done
  echo "initialized batch $b with $n task(s)"
}

cmd_drive() {
  local b
  b=""
  while [ $# -gt 0 ]; do case "$1" in --batch) b=$2; shift 2;; *) echo "bad arg $1" >&2; exit 2;; esac; done
  [ -n "$b" ] || { echo "run: need --batch" >&2; exit 2; }
  [ -f "$(_bdir "$b")/contract.json" ] || { echo "run: batch $b not initialized" >&2; exit 2; }
  UC_BASELINE_SHA=$(_get "$(_bdir "$b")/batch.meta" baseline_sha)
  _drive "$b"
  cmd_status --batch "$b"
  cmd_handoff --batch "$b" >/dev/null
}

cmd_status() {
  local b c n i t
  b=""
  while [ $# -gt 0 ]; do case "$1" in --batch) b=$2; shift 2;; *) echo "bad arg $1" >&2; exit 2;; esac; done
  c=$(_bdir "$b")/contract.json
  n=$(_jlen "$c" "tasks")
  echo "batch=$b"
  for (( i=0; i<n; i++ )); do t=$(_jget "$c" "tasks.$i.task_id"); printf '  %s: %s (attempts=%s)\n' "$t" "$(_state_of "$b" "$t" new)" "$(_attempts "$b" "$t")"; done
}

cmd_next() {
  local b c n i t st
  b=""
  while [ $# -gt 0 ]; do case "$1" in --batch) b=$2; shift 2;; *) echo "bad arg $1" >&2; exit 2;; esac; done
  c=$(_bdir "$b")/contract.json
  n=$(_jlen "$c" "tasks")
  for (( i=0; i<n; i++ )); do
    t=$(_jget "$c" "tasks.$i.task_id"); st=$(_state_of "$b" "$t" new)
    case "$st" in VERIFIED_PASS|HOLD|CANCELLED) continue;; esac
    _deps_ok "$b" "$i" || continue
    echo "$t"; return 0
  done
  echo "NONE"; return 0
}

cmd_handoff() {
  local b bd c n i t s
  b=""
  while [ $# -gt 0 ]; do case "$1" in --batch) b=$2; shift 2;; *) echo "bad arg $1" >&2; exit 2;; esac; done
  bd=$(_bdir "$b"); c=$bd/contract.json
  n=$(_jlen "$c" "tasks")
  {
    echo "# Unattended batch handoff - $b"
    echo
    echo "baseline_sha: $(_get "$bd/batch.meta" baseline_sha)"
    echo "generated_at: $(_now)"
    echo
    echo "| task | state | attempts |"
    echo "|---|---|---|"
    for (( i=0; i<n; i++ )); do t=$(_jget "$c" "tasks.$i.task_id"); printf '| %s | %s | %s |\n' "$t" "$(_state_of "$b" "$t" new)" "$(_attempts "$b" "$t")"; done
    echo
    echo "## Active sessions"
    for s in "$bd/sessions"/*/; do [ -f "${s}meta" ] || continue; printf -- '- %s: task=%s role=%s state=%s workdir=%s\n' "$(basename "$s")" "$(_get "${s}meta" task)" "$(_get "${s}meta" role)" "$(_get "${s}meta" state)" "$(_get "${s}meta" workdir)"; done
    echo
    echo "## Next runnable"
    echo "- $(cmd_next --batch "$b")"
    echo
    echo "## Evidence"
    echo "- evidence root: $(_evroot "$b")/runs/"
    echo "- per-task verdict: <task>/gate/verdict.json"
  } > "$bd/handoff.md"
  cat "$bd/handoff.md"
}

case "${1:-}" in
  init) shift; cmd_init "$@";;
  run) shift; cmd_drive "$@";;
  resume) shift; cmd_drive "$@";;
  status) shift; cmd_status "$@";;
  next) shift; cmd_next "$@";;
  handoff) shift; cmd_handoff "$@";;
  *) echo "usage: fm-unattended.sh init|run|resume|status|next|handoff --batch B" >&2; exit 2;;
esac
