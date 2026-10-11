#!/usr/bin/env bash
# Usage: fm-nm-gate-guard.sh install <gate-dir> <owner>/<repo>
#        fm-nm-gate-guard.sh remove|status|verify <gate-dir>
#
# Install, remove, inspect, or exercise the fail-closed push boundary of one
# no-mistakes gate bare repository. This is the call site that makes
# bin/fm-pr-target-guard.sh a guard rather than a helper: `install` writes the
# gate's own `hooks/pre-receive.no-mistakes-user`, which no-mistakes' vendor
# `hooks/pre-receive` execs after its own `daemon admit-push`, and git then
# rejects the push when the guard refuses. Because the boundary lives in the
# gate repository instead of in the no-mistakes `repos` row, a run start cannot
# revert it the way it reverts a row-only edit: the run start re-derives its
# target from the pushing checkout's `origin`, and the push that would carry
# that run into the pipeline is exactly what this hook refuses.
#
# The user-hook seam is deliberate. no-mistakes owns `hooks/pre-receive` and
# reinstalls it, so writing there would fight the vendor hook and would be lost
# on the next refresh; `pre-receive.no-mistakes-user` is the extension point
# that vendor hook documents and execs, and nothing else writes it.
# `install` therefore refuses when the gate has no vendor `pre-receive` that
# chains to that name, because a boundary nothing would run is not a boundary.
#
# `install <gate-dir> <owner>/<repo>` records the named repository as
# `no-mistakes.prTarget` in the gate's own config, so the guard's gate mode can
# compare the gate's real remotes against it, and refuses a target it cannot
# prove is owned by the authenticated forge user. It also refuses to overwrite
# a user hook it did not write. The target is always explicit: a boundary that
# silently picked its own target would be the same implicit routing this hook
# exists to remove.
#
# Nothing here pushes anywhere, opens anything, or touches a forge: `install`
# only writes into the named gate repository, and `verify` only reads.
#
# Exit codes: 0 success, 1 the guard refused the gate as it stands, 2 invalid
# request or an unsafe gate to modify, 3 a target or the authenticated user
# could not be verified.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GUARD="$SCRIPT_DIR/fm-pr-target-guard.sh"
HOOK_MARKER='firstmate: no-mistakes push-target boundary'
HOOK_SEAM='pre-receive.no-mistakes-user'

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() { # <message> <exit-code>
  printf 'error: fm-nm-gate-guard: %s\n' "$1" >&2
  exit "$2"
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  install|remove|status|verify) ;;
  '')
    usage >&2
    exit 2
    ;;
  *)
    die "unknown action '$1'" 2
    ;;
esac

ACTION=$1
GATE=${2:-}
REQUESTED_TARGET=${3:-}
[ -n "$GATE" ] || die "$ACTION requires a gate directory" 2
[ -d "$GATE" ] || die "gate '$GATE' does not exist" 2
git -C "$GATE" rev-parse --git-dir >/dev/null 2>&1 || die "gate '$GATE' is not a git repository" 2
case $GATE in
  */hooks|*/hooks/*) die "gate '$GATE' names a hooks path, not a gate repository" 2 ;;
esac

[ -d "$GATE/hooks" ] || die "gate '$GATE' has no hooks directory" 2
HOOK="$GATE/hooks/$HOOK_SEAM"
VENDOR_HOOK="$GATE/hooks/pre-receive"

hook_is_ours() {
  [ -f "$HOOK" ] && grep -qF "$HOOK_MARKER" "$HOOK" 2>/dev/null
}

write_hook() { # <gate-dir> <guard-path>
  local gate=$1 guard=$2 tmp
  tmp="$HOOK.tmp.$$"
  cat > "$tmp" <<HOOK
#!/bin/sh
# $HOOK_MARKER
# Refuses any push whose target is not the approved owned repository. Installed
# by firstmate bin/fm-nm-gate-guard.sh; remove with:
#   fm-nm-gate-guard.sh remove $gate
GUARD='$guard'
GATE_DIR=\$(git rev-parse --absolute-git-dir 2>/dev/null || :)
case "\$GATE_DIR" in
  /*) ;;
  *) GATE_DIR=\$(CDPATH= cd -- "\$(dirname -- "\$0")/.." && pwd -P) ;;
esac
rc=0
while read -r old new ref; do
  [ -n "\$ref" ] || continue
  "\$GUARD" --gate "\$GATE_DIR" --ref "\$ref" --old "\$old" --new "\$new" || rc=1
done
exit "\$rc"
HOOK
  chmod 755 "$tmp"
  mv -f "$tmp" "$HOOK"
}

case $ACTION in
  install)
    [ -x "$VENDOR_HOOK" ] \
      || die "gate '$GATE' has no executable no-mistakes pre-receive hook, so a user hook would never run" 2
    grep -qF "$HOOK_SEAM" "$VENDOR_HOOK" 2>/dev/null \
      || die "gate '$GATE' has a pre-receive hook that does not chain to $HOOK_SEAM, so a user hook would never run" 2
    if [ -e "$HOOK" ] && ! hook_is_ours; then
      die "gate '$GATE' already has a $HOOK_SEAM hook this installer did not write; refusing to overwrite it" 2
    fi
    [ -n "$REQUESTED_TARGET" ] \
      || die "install requires the approved <owner>/<repo> target to record and enforce" 2
    FM_PR_TARGET=$REQUESTED_TARGET "$GUARD" "$REQUESTED_TARGET" >/dev/null \
      || die "the target '$REQUESTED_TARGET' did not pass the ownership guard" 3
    git -C "$GATE" config no-mistakes.prTarget "$REQUESTED_TARGET" \
      || die "could not record the approved target in gate '$GATE'" 3
    write_hook "$GATE" "$GUARD"
    printf 'FM_NM_GATE_GUARD: installed gate=%s target=%s hook=%s\n' \
      "$GATE" "$REQUESTED_TARGET" "$HOOK"
    ;;
  remove)
    if hook_is_ours; then
      rm -f "$HOOK" || die "could not remove '$HOOK'" 3
    fi
    git -C "$GATE" config --unset no-mistakes.prTarget 2>/dev/null || true
    printf 'FM_NM_GATE_GUARD: removed gate=%s hook=%s\n' "$GATE" "$HOOK"
    ;;
  status)
    if hook_is_ours; then
      printf 'FM_NM_GATE_GUARD: installed gate=%s target=%s\n' \
        "$GATE" "$(git -C "$GATE" config --get no-mistakes.prTarget 2>/dev/null || printf 'unrecorded')"
    elif [ -e "$HOOK" ]; then
      printf 'FM_NM_GATE_GUARD: foreign gate=%s (a %s hook exists that this installer did not write)\n' \
        "$GATE" "$HOOK_SEAM"
    else
      printf 'FM_NM_GATE_GUARD: absent gate=%s\n' "$GATE"
    fi
    ;;
  verify)
    base=$(git -C "$GATE" symbolic-ref --short HEAD 2>/dev/null || printf 'main')
    head=$(git -C "$GATE" rev-parse --verify --quiet "refs/heads/$base^{commit}" 2>/dev/null || true)
    [ -n "$head" ] || die "gate '$GATE' has no commit on '$base' to verify against" 3
    "$GUARD" --gate "$GATE" --ref refs/heads/fm/fm-nm-gate-guard-probe --old "$head" --new "$head"
    ;;
esac
