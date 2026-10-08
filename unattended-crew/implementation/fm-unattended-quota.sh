#!/usr/bin/env bash
# fm-unattended-quota.sh - per-window quota and concurrency gate for the
# unattended crew orchestrator's real (provider-spending) backend.
#
# Single owner of the spending safety floor the G4 review asked for:
#   - per-window maximum concurrent crews,
#   - per-window maximum provider calls,
#   - a free-model allow-list,
#   - refusal of any model not on the allow-list (unapproved paid models),
#   - a safe HOLD when the quota is UNKNOWN (no cap configured / no model),
#   - idempotent accounting that refuses a duplicate reservation instead of
#     over-spending on a retried dispatch.
#
# The "window" is the batch: every batch gets its own counter file under
# $UC_HOME/state/, and the batch's HOLD latch (owned by the coordinator) stops
# all further work in that window once a block is recorded.
#
# Config keys (config/unattended-crew.json):
#   quota.max_concurrent_crews   (integer)
#   quota.max_provider_calls     (integer)
#   quota.free_models            (array of model ids)
#   quota.allow_paid_models      (boolean, default false)
#
# Exit codes: 0 allowed; 3 blocked (cap / not allowed); 4 unknown (fail-closed
# HOLD); 2 usage error.
#
# Usage:
#   fm-unattended-quota.sh check-model --model M [--config F]
#   fm-unattended-quota.sh reserve --batch B --role executor|auditor [--home H] [--config F]
#   fm-unattended-quota.sh release --batch B [--home H]
#   fm-unattended-quota.sh state --batch B [--home H]
#   fm-unattended-quota.sh reset --batch B [--home H]
set -u

IMPL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG="$IMPL_DIR/fm-unattended-config.sh"
UC_HOME=${UC_HOME:-}
CONFIG_EXPLICIT=''

_block() { printf '%s\n' "$1" >&2; exit "${2:-3}"; }

_settings() {
  if [ -n "$CONFIG_EXPLICIT" ]; then
    "$CONFIG" settings --config "$CONFIG_EXPLICIT"
  else
    "$CONFIG" settings
  fi
}

_qget() { # <settings-json-file> <dotted.key>
  python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
cur=d
for k in sys.argv[2].split("."):
    if isinstance(cur,dict): cur=cur.get(k)
    else: cur=None; break
if isinstance(cur,bool): print("true" if cur else "false")
elif isinstance(cur,(dict,list)): print(json.dumps(cur))
elif cur is None: print("")
else: print(cur)' "$1" "$2" 2>/dev/null
}

# Lock + counter file live per home. The lock is a mkdir spin (portable, atomic).
_state_dir() { [ -n "$UC_HOME" ] || _block "quota: UC_HOME not set" 2; printf '%s/state\n' "$UC_HOME"; }
_counter() { printf '%s/quota-%s.json\n' "$(_state_dir)" "$1"; }
_lock()   { printf '%s/quota.lock\n' "$(_state_dir)"; }

_with_lock() { # <fn> <args...>
  local fn=$1; shift
  local lock; lock=$(_lock); local i=0
  mkdir -p "$(_state_dir)" 2>/dev/null || _block "quota: cannot create state dir" 2
  while ! mkdir "$lock" 2>/dev/null; do
    i=$((i+1)); [ "$i" -gt 100 ] && _block "quota: lock timeout" 2
    sleep 0.05
  done
  local rc=0
  # Run the locked action in a subshell so an internal `exit` (e.g. a cap block)
  # releases the lock instead of terminating the lock holder.
  ( "$fn" "$@" ) || rc=$?
  rmdir "$lock" 2>/dev/null || true
  return "$rc"
}

_read_counts() { # <batch> -> "calls crews"
  local f; f=$(_counter "$1")
  python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
print(int(d.get("provider_calls",0)), int(d.get("active_crews",0)))' "$f" 2>/dev/null
}

_write_counts() { # <batch> <calls> <crews> <role>
  local f; f=$(_counter "$1"); mkdir -p "$(_state_dir)"
  python3 -c 'import json,sys
json.dump({"batch":sys.argv[1],"window":sys.argv[1],"provider_calls":int(sys.argv[2]),
           "active_crews":int(sys.argv[3]),"last_role":sys.argv[4]}, open(sys.argv[5],"w"))' \
    "$1" "$2" "$3" "$4" "$f"
}

cmd_check_model() {
  local model='' cfgf
  while [ $# -gt 0 ]; do case "$1" in --model) model=$2; shift 2;; --config) CONFIG_EXPLICIT=$2; shift 2;; *) _block "check-model: bad arg $1" 2;; esac; done
  [ -n "$model" ] || _block "quota: model unknown (no --model) => HOLD" 4
  cfgf=$(mktemp "${TMPDIR:-/tmp}/ucq.XXXXXX"); _settings > "$cfgf"
  local free allow
  free=$(_qget "$cfgf" quota.free_models); allow=$(_qget "$cfgf" quota.allow_paid_models)
  rm -f "$cfgf"
  python3 - "$model" "$free" "$allow" <<'PY'
import json, sys
model, free_s, allow_s = sys.argv[1], sys.argv[2], sys.argv[3]
free = json.loads(free_s) if free_s else []
allow = (allow_s == "true" or allow_s is True)
if model in (free or []):
    print("ALLOW free-model %s" % model); sys.exit(0)
if allow:
    print("ALLOW paid-approved %s" % model); sys.exit(0)
print("BLOCK model-not-allowed %s" % model); sys.exit(3)
PY
  return $?
}

_reserve_locked() { # <batch> <role>
  local batch=$1 role=$2 cfgf
  cfgf=$(mktemp "${TMPDIR:-/tmp}/ucq.XXXXXX"); _settings > "$cfgf"
  local maxc maxp
  maxc=$(_qget "$cfgf" quota.max_concurrent_crews); maxp=$(_qget "$cfgf" quota.max_provider_calls)
  rm -f "$cfgf"
  case "$maxc" in ''|*[!0-9]*) _block "quota: max_concurrent_crews unknown => HOLD" 4;; esac
  case "$maxp" in ''|*[!0-9]*) _block "quota: max_provider_calls unknown => HOLD" 4;; esac
  local calls crews; read -r calls crews <<EOF
$(_read_counts "$batch")
EOF
  [ "$calls" -ge "$maxp" ] && _block "quota: provider-calls-exhausted($calls/$maxp)" 3
  [ "$crews" -ge "$maxc" ] && _block "quota: concurrency-exhausted($crews/$maxc)" 3
  calls=$((calls+1)); crews=$((crews+1))
  _write_counts "$batch" "$calls" "$crews" "$role"
  printf 'RESERVED calls=%s crews=%s max_calls=%s max_crews=%s\n' "$calls" "$crews" "$maxp" "$maxc"
  return 0
}

cmd_reserve() {
  local batch='' role='' home=''
  while [ $# -gt 0 ]; do case "$1" in
    --batch) batch=$2; shift 2;; --role) role=$2; shift 2;; --home) home=$2; shift 2;;
    --config) CONFIG_EXPLICIT=$2; shift 2;; *) _block "reserve: bad arg $1" 2;;
  esac; done
  [ -n "$batch" ] || _block "reserve: need --batch" 2
  [ -n "$home" ] && UC_HOME=$home
  _with_lock _reserve_locked "$batch" "${role:-crew}"
}

cmd_release() {
  local batch='' home=''
  while [ $# -gt 0 ]; do case "$1" in --batch) batch=$2; shift 2;; --home) home=$2; shift 2;; --config) shift 2;; *) _block "release: bad arg $1" 2;; esac; done
  [ -n "$batch" ] || _block "release: need --batch" 2
  [ -n "$home" ] && UC_HOME=$home
  local calls crews; read -r calls crews <<EOF
$(_read_counts "$batch")
EOF
  [ "$crews" -gt 0 ] && crews=$((crews-1))
  _write_counts "$batch" "$calls" "$crews" release
  printf 'RELEASED calls=%s crews=%s\n' "$calls" "$crews"
  return 0
}

cmd_state() {
  local batch='' home=''
  while [ $# -gt 0 ]; do case "$1" in --batch) batch=$2; shift 2;; --home) home=$2; shift 2;; *) _block "state: bad arg $1" 2;; esac; done
  [ -n "$home" ] && UC_HOME=$home
  local calls crews; read -r calls crews <<EOF
$(_read_counts "$batch")
EOF
  printf '{"batch":"%s","provider_calls":%s,"active_crews":%s}\n' "$batch" "$calls" "$crews"
}

cmd_reset() {
  local batch='' home=''
  while [ $# -gt 0 ]; do case "$1" in --batch) batch=$2; shift 2;; --home) home=$2; shift 2;; *) _block "reset: bad arg $1" 2;; esac; done
  [ -n "$home" ] && UC_HOME=$home
  _write_counts "$batch" 0 0 reset
  printf 'RESET %s\n' "$batch"
}

case "${1:-}" in
  check-model) shift; cmd_check_model "$@";;
  reserve) shift; cmd_reserve "$@";;
  release) shift; cmd_release "$@";;
  state) shift; cmd_state "$@";;
  reset) shift; cmd_reset "$@";;
  *) echo "usage: fm-unattended-quota.sh check-model|reserve|release|state|reset ..." >&2; exit 2;;
esac
