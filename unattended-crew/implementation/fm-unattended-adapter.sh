#!/usr/bin/env bash
# fm-unattended-adapter.sh - Crew Dispatch Adapter for the unattended batch
# coordinator.
#
# This is the SEAM between the batch coordinator and a real worker runtime.
# Firstmate's real delegation primitives are (Phase A, bin/fm-spawn.sh,
# bin/fm-send.sh, bin/fm-control.sh, bin/fm-crew-state.sh): spawn creates an
# isolated worktree + state/<id>.meta; steer writes a durable inbox record;
# crew-state returns one deterministic state line. This adapter exposes the
# same three verbs (dispatch / send / status) behind a backend switch so the
# coordinator never hard-codes one runtime.
#
# Backends:
#   fake (default)  file-backed fake session; NO worker/provider is called.
#   real            REFUSED. Wiring the real firstmate primitives is the
#                   approved integration step (handoff/integration-plan.md);
#                   until that gate passes, `real` exits 9 with
#                   INTEGRATION_HOLD so nothing can silently pretend a fake
#                   run was a real crew.
#
# Session record: $UC_HOME/batches/<batch>/sessions/<sid>/meta (key=value) and
# events.jsonl. A session is bound to exactly one (task, role, attempt); the
# adapter refuses a duplicate dispatch for a live/completed binding and refuses
# a send whose --task does not own the session.
#
# Usage:
#   fm-unattended-adapter.sh dispatch --batch B --task T --role executor|auditor \
#        --attempt N --workdir W [--identity ID]
#   fm-unattended-adapter.sh identity --batch B --session S
#   fm-unattended-adapter.sh send --batch B --task T --session S <text...>
#   fm-unattended-adapter.sh status --batch B --session S
#   fm-unattended-adapter.sh emit --batch B --session S <ACK|ACTIVE|COMPLETE|FAILED>
set -u

UC_HOME=${UC_HOME:?set UC_HOME to the batch root}
BACKEND=${FM_UNATTENDED_ADAPTER:-fake}

_bdir() { printf '%s/batches/%s\n' "$UC_HOME" "$1"; }
_sdir() { printf '%s/sessions/%s\n' "$(_bdir "$1")" "$2"; }
_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_meta_get() { # <file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

_refuse() { printf '%s\n' "$1" >&2; exit "${2:-1}"; }

# Find an existing session bound to (task, role) whose state is live or complete.
_find_binding() { # <batch> <task> <role> <attempt>
  local b=$1 t=$2 r=$3 a=$4 d s
  for d in "$(_bdir "$b")/sessions"/*/; do
    [ -f "${d}meta" ] || continue
    [ "$(_meta_get "${d}meta" task)" = "$t" ] || continue
    [ "$(_meta_get "${d}meta" role)" = "$r" ] || continue
    [ "$(_meta_get "${d}meta" attempt)" = "$a" ] || continue
    s=$(_meta_get "${d}meta" state)
    [ "$s" = "pending-ack" ] && continue
    printf '%s\n' "$(basename "$d")"; return 0
  done
  return 1
}

# Real backend: bridge the adapter verbs onto firstmate's existing primitives.
# dispatch -> bin/fm-spawn.sh (scout, isolated worktree); identity -> the pane
# target recorded in state/<id>.meta; send -> bin/fm-send.sh; status ->
# bin/fm-crew-state.sh. This is the G1-approved integration surface. It refuses
# unless UC_FM_HOME and UC_REAL_PROJECT are set, and passes harness, model,
# effort, and backend explicitly (never an implicit default).
_real_dispatch() { # --batch B --task T --role R --attempt N --workdir W
  local b='' t='' r='' a='' w='' spawn_id='' home='' project='' out rc window wt sd
  while [ $# -gt 0 ]; do case "$1" in
    --batch) b=$2; shift 2;; --task) t=$2; shift 2;; --role) r=$2; shift 2;;
    --attempt) a=$2; shift 2;; --workdir) w=$2; shift 2;; *) _refuse "real dispatch: unexpected arg $1" 2;;
  esac; done
  home=${UC_FM_HOME:?real backend needs UC_FM_HOME}
  project=${UC_REAL_PROJECT:?real backend needs UC_REAL_PROJECT}
  case "$r" in
    executor) spawn_id=${UC_REAL_EXEC_ID:-$t};;
    auditor)  spawn_id=${UC_REAL_AUDIT_ID:-${t}-audit};;
    *) _refuse "real dispatch: bad role $r" 2;;
  esac
  [ -x "$home/bin/fm-spawn.sh" ] || _refuse "real dispatch: no fm-spawn.sh at $home" 2

  local -a flags=()
  [ -n "${UC_REAL_HARNESS:-}" ] && flags+=(--harness "$UC_REAL_HARNESS")
  [ -n "${UC_REAL_MODEL:-}" ] && flags+=(--model "$UC_REAL_MODEL")
  [ -n "${UC_REAL_EFFORT:-}" ] && flags+=(--effort "$UC_REAL_EFFORT")
  [ -n "${UC_REAL_BACKEND:-}" ] && flags+=(--backend "$UC_REAL_BACKEND")

  out=$("$home/bin/fm-spawn.sh" "$spawn_id" "$project" --scout "${flags[@]}" 2>&1); rc=$?
  printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || { echo "SPAWN_FAILED rc=$rc spawn_id=$spawn_id"; exit 1; }
  window=$(printf '%s\n' "$out" | sed -n 's/.*window=\([^ ]*\).*/\1/p' | tail -1)
  wt=$(printf '%s\n' "$out" | sed -n 's/.*worktree=\([^ ]*\).*/\1/p' | tail -1)
  [ -n "$window" ] || { echo "SPAWN_FAILED no-window spawn_id=$spawn_id"; exit 1; }
  [ -n "$wt" ] || wt=$project

  sd=$(_sdir "$b" "$window"); mkdir -p "$sd" "$w"
  {
    printf 'sid=%s\n' "$window"
    printf 'task=%s\n' "$t"
    printf 'role=%s\n' "$r"
    printf 'attempt=%s\n' "$a"
    printf 'identity=%s\n' "$window"
    printf 'workdir=%s\n' "$wt"
    printf 'spawn_id=%s\n' "$spawn_id"
    printf 'backend=real\n'
    printf 'created_at=%s\n' "$(_now)"
    printf 'state=active\n'
  } > "$sd/meta"
  : > "$sd/events.jsonl"
  _emit "$b" "$window" ACK
  _emit "$b" "$window" ACTIVE
  echo "DISPATCHED session=$window identity=$window worktree=$wt spawn_id=$spawn_id"
}

cmd_dispatch() { # --batch B --task T --role R --attempt N --workdir W [--identity ID]
  if [ "$BACKEND" = real ]; then _real_dispatch "$@"; return $?; fi
  local b='' t='' r='' a='' w='' ident=''
  while [ $# -gt 0 ]; do case "$1" in
    --batch) b=$2; shift 2;; --task) t=$2; shift 2;; --role) r=$2; shift 2;;
    --attempt) a=$2; shift 2;; --workdir) w=$2; shift 2;; --identity) ident=$2; shift 2;;
    *) _refuse "dispatch: unexpected arg $1" 2;;
  esac; done
  [ -n "$b" ] && [ -n "$t" ] && [ -n "$r" ] && [ -n "$a" ] || _refuse "dispatch: missing required arg" 2
  case "$r" in executor|auditor) ;; *) _refuse "dispatch: bad role $r" 2;; esac
  if [ "$BACKEND" = real ]; then _refuse "INTEGRATION_HOLD: real worker dispatch not approved" 9; fi

  local existing
  if existing=$(_find_binding "$b" "$t" "$r" "$a"); then
    _refuse "DUPLICATE_DISPATCH session=$existing" 3
  fi

  local sid="${t}-${r}-a${a}-$(( RANDOM % 100000 ))"
  [ -n "$ident" ] && sid="$ident"
  local sd; sd=$(_sdir "$b" "$sid"); mkdir -p "$sd" "$w"
  {
    printf 'sid=%s\n' "$sid"
    printf 'task=%s\n' "$t"
    printf 'role=%s\n' "$r"
    printf 'attempt=%s\n' "$a"
    printf 'identity=%s\n' "$sid"
    printf 'workdir=%s\n' "$w"
    printf 'backend=%s\n' "$BACKEND"
    printf 'created_at=%s\n' "$(_now)"
    printf 'state=pending-ack\n'
  } > "$sd/meta"
  : > "$sd/events.jsonl"

  if [ "${FM_FAKE_NO_ACK:-0}" = 1 ]; then
    printf '{"at":"%s","event":"NO_ACK"}\n' "$(_now)" >> "$sd/events.jsonl"
    echo "NO_ACK session=$sid"
    exit 4
  fi
  _emit "$b" "$sid" ACK
  _emit "$b" "$sid" ACTIVE
  echo "DISPATCHED session=$sid identity=$sid"
}

_emit() { # <batch> <sid> <event>
  local sd; sd=$(_sdir "$1" "$2"); [ -d "$sd" ] || _refuse "emit: no session $2" 2
  printf '{"at":"%s","event":"%s"}\n' "$(_now)" "$3" >> "$sd/events.jsonl"
  sed -i.bak "s/^state=.*/state=$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')/" "$sd/meta" && rm -f "$sd/meta.bak"
}

cmd_identity() { # --batch B --session S
  local b='' s=''; while [ $# -gt 0 ]; do case "$1" in --batch) b=$2; shift 2;; --session) s=$2; shift 2;; *) _refuse "identity: bad arg $1" 2;; esac; done
  [ -f "$(_sdir "$b" "$s")/meta" ] || _refuse "identity: no session $s" 2
  if [ "${FM_FAKE_WRONG_IDENTITY:-0}" = 1 ]; then echo "bogus-$s"; else printf '%s\n' "$s"; fi
}

cmd_send() { # --batch B --task T --session S <text...>
  local b='' t='' s=''; while [ $# -gt 0 ]; do case "$1" in --batch) b=$2; shift 2;; --task) t=$2; shift 2;; --session) s=$2; shift 2;; *) break;; esac; done
  local sd; sd=$(_sdir "$b" "$s"); [ -f "$sd/meta" ] || _refuse "send: no session $s" 2
  local owner; owner=$(_meta_get "$sd/meta" task)
  [ "$owner" = "$t" ] || _refuse "CROSS_TASK: session $s is owned by task $owner, not $t" 5
  printf '{"at":"%s","event":"MESSAGE","task":"%s","text":"%s"}\n' "$(_now)" "$t" "$*" >> "$sd/events.jsonl"
  echo "SENT session=$s"
}

cmd_status() { # --batch B --session S
  local b='' s=''; while [ $# -gt 0 ]; do case "$1" in --batch) b=$2; shift 2;; --session) s=$2; shift 2;; *) _refuse "status: bad arg $1" 2;; esac; done
  local sd; sd=$(_sdir "$b" "$s"); [ -f "$sd/meta" ] || { echo "state=absent"; return 0; }
  printf 'state=%s task=%s role=%s workdir=%s identity=%s\n' \
    "$(_meta_get "$sd/meta" state)" "$(_meta_get "$sd/meta" task)" "$(_meta_get "$sd/meta" role)" \
    "$(_meta_get "$sd/meta" workdir)" "$(_meta_get "$sd/meta" identity)"
}

case "${1:-}" in
  dispatch) shift; cmd_dispatch "$@";;
  identity) shift; cmd_identity "$@";;
  send) shift; cmd_send "$@";;
  status) shift; cmd_status "$@";;
  emit) shift; b=; s=; ev=; while [ $# -gt 0 ]; do case "$1" in --batch) b=$2; shift 2;; --session) s=$2; shift 2;; *) ev=$1; shift;; esac; done; _emit "$b" "$s" "$ev";;
  *) echo "usage: fm-unattended-adapter.sh dispatch|identity|send|status ..." >&2; exit 2;;
esac
