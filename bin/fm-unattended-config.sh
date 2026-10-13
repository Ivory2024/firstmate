#!/usr/bin/env bash
# fm-unattended-config.sh - durable configuration and evidence-root resolver
# for the unattended crew orchestrator.
#
# Single owner of:
#   - the config file location and read access (default
#     <impl>/../config/unattended-crew.json, or $UC_CONFIG_FILE, or
#     $UC_HOME/config/unattended-crew.json when present).
#   - EVIDENCE_ROOT resolution, creation, permission, collision and path-escape
#     checks, and the durable per-batch `.batch` marker so the SAME evidence can
#     be re-read after a coordinator restart.
#   - the normalized settings blob the mounted entrypoint and the quota gate
#     consume.
#
# Evidence root resolution order for a batch:
#   1. UC_EVIDENCE_ROOT (explicit env), then
#   2. config key `evidence_root`, then
#   3. the compatibility default: $UC_HOME/batches/<batch>/evidence (the path
#      the live canaries already used, so an old batch tree is still re-readable).
# When (1) or (2) is used the per-batch dir is <root>/<batch>; the printed value
# is always the directory that CONTAINS runs/ (the evidence/judge contract).
#
# Fail-closed: a bad batch id, a root with a `..` segment, a root that escapes
# its base, a root that is not a directory, an unreadable/unwritable root, or a
# per-batch dir already owned by a different batch is a nonzero refusal. When
# --no-create is given a missing per-batch dir is also a refusal.
#
# Usage:
#   fm-unattended-config.sh config-path [--config F]
#   fm-unattended-config.sh get --key K [--config F]
#   fm-unattended-config.sh settings [--config F]
#   fm-unattended-config.sh evidence-root --batch B [--home H] [--config F] [--no-create]
set -u

IMPL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_EXPLICIT=''

refuse() { printf 'config: %s\n' "$1" >&2; exit "${2:-2}"; }

# Resolve the config path. --config wins, then $UC_CONFIG_FILE, then a home-local
# config, then the repo-shipped default location.
config_path() {
  if [ -n "$CONFIG_EXPLICIT" ]; then printf '%s\n' "$CONFIG_EXPLICIT"; return 0; fi
  if [ -n "${UC_CONFIG_FILE:-}" ]; then printf '%s\n' "$UC_CONFIG_FILE"; return 0; fi
  if [ -n "${UC_HOME:-}" ] && [ -f "$UC_HOME/config/unattended-crew.json" ]; then
    printf '%s\n' "$UC_HOME/config/unattended-crew.json"; return 0
  fi
  printf '%s\n' "$IMPL_DIR/../config/unattended-crew.json"
}

_jget() { # <file> <dotted.key> -> value on stdout; "" when absent/unreadable
  python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print(""); sys.exit(0)
cur=d
for k in sys.argv[2].split("."):
    if isinstance(cur,dict): cur=cur.get(k)
    else: cur=None; break
if cur is None: print("")
elif isinstance(cur,bool): print("true" if cur else "false")
elif isinstance(cur,(dict,list)): print(json.dumps(cur))
else: print(cur)' "$1" "$2" 2>/dev/null
}

cmd_config_path() { config_path; }

cmd_get() {
  local key=''
  while [ $# -gt 0 ]; do case "$1" in
    --key) key=$2; shift 2;; --config) CONFIG_EXPLICIT=$2; shift 2;;
    *) refuse "get: bad arg $1" 2;;
  esac; done
  [ -n "$key" ] || refuse "get: need --key" 2
  local f; f=$(config_path)
  [ -f "$f" ] || { echo ""; return 0; }
  _jget "$f" "$key"
}

# Emit the resolved config as one JSON object ({} when no config file).
cmd_settings() {
  while [ $# -gt 0 ]; do case "$1" in --config) CONFIG_EXPLICIT=$2; shift 2;; *) refuse "settings: bad arg $1" 2;; esac; done
  local f; f=$(config_path)
  if [ -f "$f" ]; then cat "$f"; else echo '{}'; fi
}

# Resolve + prepare the durable per-batch evidence root. Prints the directory
# that contains runs/. Creates it (unless --no-create), enforces mode 0700 on the
# per-batch dir, checks writability, refuses a path escape, and stamps/validates
# the `<root>/.batch` ownership marker.
cmd_evidence_root() {
  local batch='' home='' no_create=0
  while [ $# -gt 0 ]; do case "$1" in
    --batch) batch=$2; shift 2;; --home) home=$2; shift 2;;
    --config) CONFIG_EXPLICIT=$2; shift 2;; --no-create) no_create=1; shift 1;;
    *) refuse "evidence-root: bad arg $1" 2;;
  esac; done
  [ -n "$batch" ] || refuse "evidence-root: need --batch" 2
  case "$batch" in
    *[!A-Za-z0-9._-]*|''|.|..) refuse "evidence-root: bad batch id '$batch'" 2;;
  esac
  [ -n "$home" ] || home=${UC_HOME:-}
  [ -n "$home" ] || refuse "evidence-root: need --home or UC_HOME" 2

  local cfg root per base
  cfg=$(config_path)
  if [ -n "${UC_EVIDENCE_ROOT:-}" ]; then
    root=$UC_EVIDENCE_ROOT
  elif [ -f "$cfg" ]; then
    root=$(_jget "$cfg" evidence_root)
  else
    root=''
  fi

  if [ -n "$root" ]; then
    case "/$root/" in *"/../"*|*"/./"*) refuse "evidence-root: root contains a '.' or '..' path segment: $root" 2;; esac
    per="$root/$batch"; base="$root"
  else
    per="$home/batches/$batch/evidence"; base="$home/batches/$batch"
  fi

  # Realpath escape check: the per-batch dir must stay under its base.
  if ! python3 - "$per" "$base" <<'PY'
import os, sys
per = os.path.realpath(sys.argv[1]); base = os.path.realpath(sys.argv[2])
ok = per == base or per.startswith(base.rstrip(os.sep) + os.sep)
sys.exit(0 if ok else 1)
PY
  then
    refuse "evidence-root: path escape ($per not under $base)" 2
  fi

  if [ "$no_create" = 1 ]; then
    [ -d "$per" ] || refuse "evidence-root: missing (no-create): $per" 2
  else
    if [ -e "$per" ] && [ ! -d "$per" ]; then refuse "evidence-root: not a directory: $per" 2; fi
    mkdir -p "$per" || refuse "evidence-root: cannot create $per" 2
    chmod 700 "$per" 2>/dev/null || refuse "evidence-root: cannot chmod 0700 $per" 2
  fi

  # Collision: a per-batch dir already stamped for another batch is refused.
  local marker="$per/.batch"
  if [ -f "$marker" ]; then
    local owner; owner=$(cat "$marker" 2>/dev/null || echo "")
    [ "$owner" = "$batch" ] || refuse "evidence-root: collision, $per owned by '$owner'" 2
  elif [ "$no_create" != 1 ]; then
    printf '%s\n' "$batch" > "$marker" || refuse "evidence-root: cannot stamp $marker" 2
  fi

  [ -d "$per" ] && [ -r "$per" ] && [ -x "$per" ] || refuse "evidence-root: unreadable: $per" 2
  [ "$no_create" = 1 ] || { [ -w "$per" ] || refuse "evidence-root: unwritable: $per" 2; }
  printf '%s\n' "$per"
}

case "${1:-}" in
  config-path) shift; cmd_config_path "$@";;
  get) shift; cmd_get "$@";;
  settings) shift; cmd_settings "$@";;
  evidence-root) shift; cmd_evidence_root "$@";;
  *) echo "usage: fm-unattended-config.sh config-path|get|settings|evidence-root ..." >&2; exit 2;;
esac
