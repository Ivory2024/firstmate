#!/usr/bin/env bash
# fm-unattended-install.sh - install / unmount / verify the mounted unattended
# crew entrypoint.
#
# Mount target layout (relative to --root, normally the firstmate home):
#   bin/fm-unattended.sh              <- bin/fm-unattended.sh      (the wrapper)
#   bin/fm-unattended-coordinator.sh  <- implementation/fm-unattended.sh
#   bin/fm-unattended-{adapter,evidence,judge,guard,config,quota,autoteardown}.sh
#
# Safety contract:
#   - --root is mandatory; the script never defaults to the home.
#   - no-overwrite: an existing target that this tool does not own (no manifest
#     record, or the file changed since install) is refused, not clobbered.
#   - per-file before/after sha256 are recorded in <root>/.fm-unattended-manifest.json.
#   - partial-install failure handling: all files are staged and every overwrite
#     policy checked BEFORE any target is touched; a mid-commit failure restores
#     the files committed so far from <root>/.fm-unattended-backup/.
#   - uninstall is idempotent and never deletes a file whose bytes differ from the
#     recorded after-hash (user edits are preserved).
#
# Usage:
#   fm-unattended-install.sh file-list
#   fm-unattended-install.sh install   --root R [--force]
#   fm-unattended-install.sh verify    --root R
#   fm-unattended-install.sh uninstall --root R
#   fm-unattended-install.sh rehearse  [--root R]   # isolated temp dir by default
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UC_ROOT=$(cd "$HERE/.." && pwd)
MANIFEST_NAME='.fm-unattended-manifest.json'
BACKUP_DIR='.fm-unattended-backup'

# "source-relative-to-UC_ROOT|target-relative-to-root"
FILES=(
  "bin/fm-unattended.sh|bin/fm-unattended.sh"
  "implementation/fm-unattended.sh|bin/fm-unattended-coordinator.sh"
  "implementation/fm-unattended-adapter.sh|bin/fm-unattended-adapter.sh"
  "implementation/fm-unattended-evidence.sh|bin/fm-unattended-evidence.sh"
  "implementation/fm-unattended-judge.sh|bin/fm-unattended-judge.sh"
  "implementation/fm-unattended-guard.sh|bin/fm-unattended-guard.sh"
  "implementation/fm-unattended-config.sh|bin/fm-unattended-config.sh"
  "implementation/fm-unattended-quota.sh|bin/fm-unattended-quota.sh"
  "implementation/fm-unattended-autoteardown.sh|bin/fm-unattended-autoteardown.sh"
)

sha() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }
die() { printf 'install: %s\n' "$1" >&2; exit "${2:-1}"; }

_owned_sha() { # <root> <target-rel> -> owned after-sha or "" 
  local m="$1/$MANIFEST_NAME" d=$2
  [ -f "$m" ] || return 0
  python3 -c 'import json,sys
p=sys.argv[2]
try:
    for line in open(sys.argv[1]):
        o=json.loads(line)
        if o.get("path")==p: print(o.get("sha256",""))
except Exception: pass' "$m" "$d" 2>/dev/null
}

cmd_file_list() {
  local e; for e in "${FILES[@]}"; do printf '%s -> %s\n' "${e%%|*}" "${e##*|}"; done
}

_parse_root() {
  ROOT=''; FORCE=0
  while [ $# -gt 0 ]; do case "$1" in
    --root) ROOT=$2; shift 2;; --force) FORCE=1; shift;;
    *) die "bad arg $1" 2;;
  esac; done
  [ -n "$ROOT" ] || die "need --root R (never defaults to the home)" 2
  case "$ROOT" in /|'') die "refusing unsafe --root '$ROOT'" 2;; esac
  ROOT=$(cd "$ROOT" 2>/dev/null && pwd) || die "root does not exist: $ROOT" 2
}

cmd_install() {
  _parse_root "$@"
  mkdir -p "$ROOT/bin" || die "cannot create $ROOT/bin"

  # 1. Preflight: sources exist; overwrite policy satisfied for every target.
  local e src dst owned cur
  for e in "${FILES[@]}"; do
    src="$UC_ROOT/${e%%|*}"; dst="$ROOT/${e##*|}"
    [ -f "$src" ] || die "missing source $src"
    if [ -e "$dst" ]; then
      owned=$(_owned_sha "$ROOT" "${e##*|}")
      cur=$(sha "$dst")
      if [ -z "$owned" ]; then
        [ "$FORCE" = 1 ] || die "target exists and is not owned: ${e##*|} (refusing to overwrite)" 3
      elif [ "$owned" != "$cur" ]; then
        [ "$FORCE" = 1 ] || die "target modified since install: ${e##*|} (refusing to overwrite)" 3
      fi
    fi
  done

  # 2. Stage every file out of band; compute after-hashes.
  local stage; stage=$(mktemp -d "${TMPDIR:-/tmp}/uc-install.XXXXXX") || die "no temp dir"
  local -a DSTS ASHAS
  local n=0
  for e in "${FILES[@]}"; do
    src="$UC_ROOT/${e%%|*}"; dst="$ROOT/${e##*|}"
    cp "$src" "$stage/$n" || { rm -rf "$stage"; die "stage failed for ${e##*|}"; }
    chmod 0755 "$stage/$n"
    DSTS[n]="$dst"; ASHAS[n]="$(sha "$stage/$n")"
    n=$((n+1))
  done

  # 3. Commit. Back up any overwritten target; on failure, roll back this run.
  local bk="$ROOT/$BACKUP_DIR"; mkdir -p "$bk"
  local i=0 committed=0
  _rollback() { # <count-committed>
    local j=0 d
    while [ $j -lt "$1" ]; do
      d=${DSTS[$j]}
      if [ -e "$bk/$(printf '%s' "${d#"$ROOT"/}" | tr / _)" ]; then
        cp "$bk/$(printf '%s' "${d#"$ROOT"/}" | tr / _)" "$d" 2>/dev/null || true
      else
        rm -f "$d"
      fi
      j=$((j+1))
    done
  }
  : > "$ROOT/$MANIFEST_NAME.tmp"
  while [ $i -lt "$n" ]; do
    # Test seam: deterministically exercise the partial-install rollback path.
    if [ "${FM_UNATTENDED_INSTALL_FAIL_AT:-}" = "$i" ]; then
      _rollback "$committed"
      rm -rf "$stage" "$ROOT/$MANIFEST_NAME.tmp"
      die "injected commit failure at index $i; rolled back this run" 1
    fi
    dst=${DSTS[$i]}
    if [ -e "$dst" ]; then
      cp -p "$dst" "$bk/$(printf '%s' "${dst#"$ROOT"/}" | tr / _)" 2>/dev/null || true
      printf '{"path":"%s","sha256":"%s","before_sha256":"%s","at":"%s"}\n' \
        "${dst#"$ROOT"/}" "${ASHAS[$i]}" "$(sha "$dst")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$ROOT/$MANIFEST_NAME.tmp"
    else
      printf '{"path":"%s","sha256":"%s","before_sha256":"-","at":"%s"}\n' \
        "${dst#"$ROOT"/}" "${ASHAS[$i]}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$ROOT/$MANIFEST_NAME.tmp"
    fi
    if ! cp "$stage/$i" "$dst"; then
      _rollback "$committed"
      rm -rf "$stage" "$ROOT/$MANIFEST_NAME.tmp"
      die "commit failed at ${dst#"$ROOT"/}; rolled back this run" 1
    fi
    chmod 0755 "$dst"
    committed=$((committed+1)); i=$((i+1))
  done
  mv "$ROOT/$MANIFEST_NAME.tmp" "$ROOT/$MANIFEST_NAME" || die "cannot write manifest"
  rm -rf "$stage"
  printf 'installed %s file(s) into %s\n' "$n" "$ROOT"
}

cmd_verify() {
  _parse_root "$@"
  local m="$ROOT/$MANIFEST_NAME"
  [ -f "$m" ] || die "not installed (no manifest in $ROOT)" 4
  local bad=0 path want cur
  while IFS= read -r line; do
    path=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get("path",""))' "$line" 2>/dev/null || echo "")
    want=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get("sha256",""))' "$line" 2>/dev/null || echo "")
    [ -n "$path" ] || continue
    cur=$(sha "$ROOT/$path")
    if [ -z "$cur" ] || [ "$cur" != "$want" ]; then
      printf 'MISMATCH %s (want %s got %s)\n' "$path" "$want" "${cur:-missing}"; bad=$((bad+1))
    fi
  done < "$m"
  [ "$bad" = 0 ] || die "$bad file(s) failed verification" 1
  echo "verified $ROOT"
}

cmd_uninstall() {
  _parse_root "$@"
  local m="$ROOT/$MANIFEST_NAME"
  [ -f "$m" ] || { echo "already uninstalled (no manifest in $ROOT)"; return 0; }
  local kept=0 removed=0 path want cur
  while IFS= read -r line; do
    path=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get("path",""))' "$line" 2>/dev/null || echo "")
    want=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get("sha256",""))' "$line" 2>/dev/null || echo "")
    [ -n "$path" ] || continue
    cur=$(sha "$ROOT/$path")
    if [ -z "$cur" ]; then continue; fi
    if [ "$cur" = "$want" ]; then rm -f "$ROOT/$path"; removed=$((removed+1))
    else printf 'kept modified file: %s\n' "$path"; kept=$((kept+1)); fi
  done < "$m"
  rm -f "$m"
  rmdir "$ROOT/$BACKUP_DIR" 2>/dev/null || { rm -rf "${ROOT:?}/$BACKUP_DIR"; }
  printf 'uninstalled %s file(s); kept %s modified\n' "$removed" "$kept"
}

cmd_rehearse() {
  local root=''
  while [ $# -gt 0 ]; do case "$1" in --root) root=$2; shift 2;; *) die "rehearse: bad arg $1" 2;; esac; done
  local tmp
  if [ -n "$root" ]; then
    case "$root" in /Users/*) die "refusing to rehearse into a real home path: $root" 2;; esac
    tmp=$root; mkdir -p "$tmp"
  else
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/uc-rehearse.XXXXXX")
  fi
  cmd_install --root "$tmp" >/dev/null || die "rehearse: install failed"
  cmd_verify --root "$tmp" >/dev/null || die "rehearse: verify failed"
  cmd_uninstall --root "$tmp" >/dev/null || die "rehearse: uninstall failed"
  local leftovers
  leftovers=$(find "$tmp/bin" -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$leftovers" = 0 ] || die "rehearse: $leftovers file(s) left after unmount"
  rm -rf "$tmp"
  echo "rehearse PASS (install -> verify -> unmount -> clean)"
}

case "${1:-}" in
  file-list) shift; cmd_file_list "$@";;
  install) shift; cmd_install "$@";;
  verify) shift; cmd_verify "$@";;
  uninstall) shift; cmd_uninstall "$@";;
  rehearse) shift; cmd_rehearse "$@";;
  *) echo "usage: fm-unattended-install.sh file-list|install|verify|uninstall|rehearse --root R" >&2; exit 2;;
esac
