#!/usr/bin/env bash
set -eu
# Verify known CI finding registration and the gate-level all-or-nothing resolver.
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-known-regression)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
DATA="$HOME_DIR/data"
SEND_LOG="$TMP_ROOT/send.log"
mkdir -p "$STATE" "$DATA"
cat > "$TMP_ROOT/fake-send" <<'SH'
#!/usr/bin/env bash
set -eu
id=$1
shift
[ "$1" = --resolve-key ]
key=$2
shift 2
answer=$1
printf '%s\t%s\t%s\n' "$id" "$key" "$answer" >> "$FM_SEND_LOG"
printf 'resolved [key=%s]: %s\n' "$key" "$answer" >> "$FM_HOME/state/$id.status"
SH
chmod +x "$TMP_ROOT/fake-send"

mark() {
  FM_HOME="$HOME_DIR" FM_SEND_BIN="$TMP_ROOT/fake-send" FM_SEND_LOG="$SEND_LOG" \
    "$ROOT/bin/fm-known-regression.sh" mark "$1" "$2" "$3" >/dev/null
}

apply() {
  FM_HOME="$HOME_DIR" FM_SEND_BIN="$TMP_ROOT/fake-send" FM_SEND_LOG="$SEND_LOG" \
    "$ROOT/bin/fm-known-regression.sh" apply "$1"
}

open_decisions() {
  local id=$1 state_dir=${2:-$STATE}
  FM_STATE_OVERRIDE="$state_dir" bash -c '
    . "$1/bin/fm-classify-lib.sh"
    status_open_decisions "$2"
  ' _ "$ROOT" "$state_dir/$id.status"
}

write_gate() {  # <task> <ids> <finding lines>
  local id=$1 ids=$2 findings=$3 snapshot
  snapshot="$DATA/$id/nm-run-ci-findings.txt"
  mkdir -p "$DATA/$id"
  printf '%s\n' "$findings" > "$snapshot"
  printf 'needs-decision [key=nm-run-ci]: ask-user findings=%s file=%s\n' "$ids" "$snapshot" > "$STATE/$id.status"
}

ANSWER='Known regression; tracked separately; no code change needed; rebase once fixed.'
mark 'Behavior portable serial 1' "$ANSWER" 'regression-pr-40'
mark 'Stock macOS Bash snapshot compatibility' "$ANSWER" 'regression-pr-40'

write_gate matching 'ci-1,ci-2' 'id=ci-1
description="CI check failing: Behavior portable serial 1 - provider reported failure - https://github.com/example/repo/actions/runs/1/job/1"

id=ci-2
description: CI check failing: Stock macOS Bash snapshot compatibility - provider reported failure - https://github.com/example/repo/actions/runs/2/job/2'
apply matching >/dev/null
[ "$(cat "$SEND_LOG")" = "matching$(printf '\t')nm-run-ci$(printf '\t')$ANSWER" ] \
  || fail "matching findings did not auto-resolve once with the recorded answer: $(cat "$SEND_LOG")"
[ -z "$(open_decisions matching)" ] || fail "matching gate remained open after its recorded answer"
pass "every matching ask-user finding auto-resolves through its keyed gate"

write_gate unmatched 'ci-1' 'id: ci-1
description: CI check failing: Unrelated test suite - provider reported failure - https://github.com/example/repo/actions/runs/3/job/3'
apply unmatched >/dev/null
[ "$(wc -l < "$SEND_LOG" | tr -d ' ')" = 1 ] || fail "unmatched finding was auto-resolved"
case "$(open_decisions unmatched)" in *$'nm-run-ci\tneeds-decision\t'*) ;; *) fail "unmatched finding did not remain an ordinary open decision" ;; esac
pass "a nonmatching finding remains an ordinary ask-user escalation"

write_gate mixed 'ci-1,ci-2' 'id=ci-1
description="CI check failing: Behavior portable serial 1 - provider reported failure - https://github.com/example/repo/actions/runs/4/job/4"

id=ci-2
description="CI check failing: Lint 2 - provider reported failure - https://github.com/example/repo/actions/runs/4/job/5"'
apply mixed >/dev/null
[ "$(wc -l < "$SEND_LOG" | tr -d ' ')" = 1 ] || fail "mixed gate was partially auto-resolved"
case "$(open_decisions mixed)" in *$'nm-run-ci\tneeds-decision\t'*) ;; *) fail "mixed gate did not remain open for ordinary triage" ;; esac
pass "a mixed gate stays open when any ask-user finding lacks a record"

mark 'Different known check' 'A different recorded decision.' 'regression-pr-41'
write_gate differing 'ci-1,ci-2' 'id=ci-1
description="CI check failing: Behavior portable serial 1 - provider reported failure - https://github.com/example/repo/actions/runs/6/job/1"

id=ci-2
description="CI check failing: Different known check - provider reported failure - https://github.com/example/repo/actions/runs/6/job/2"'
apply differing >/dev/null
[ "$(wc -l < "$SEND_LOG" | tr -d ' ')" = 1 ] || fail "gate with conflicting recorded answers was auto-resolved"
case "$(open_decisions differing)" in *$'nm-run-ci\tneeds-decision\t'*) ;; *) fail "gate with conflicting answers did not remain open" ;; esac
pass "a gate with different stored answers stays open for ordinary triage"

watch_home=$(make_case watcher)
mkdir -p "$watch_home/data/watched"
FM_HOME="$watch_home" "$ROOT/bin/fm-known-regression.sh" mark \
  'Behavior portable serial 1' "$ANSWER" 'regression-pr-40' >/dev/null
watch_snapshot="$watch_home/data/watched/nm-watch-ci-findings.txt"
cat > "$watch_snapshot" <<'EOF'
id=ci-1
description="CI check failing: Behavior portable serial 1 - provider reported failure - https://github.com/example/repo/actions/runs/5/job/1"
EOF
printf 'needs-decision [key=nm-watch-ci]: ask-user findings=ci-1 file=%s\n' "$watch_snapshot" \
  > "$watch_home/state/watched.status"
PATH="$watch_home/fakebin:$PATH" FM_HOME="$watch_home" \
  FM_STATE_OVERRIDE="$watch_home/state" \
  FM_CREW_STATE_BIN="$watch_home/fakebin/fm-crew-state.sh" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_SEND_BIN="$TMP_ROOT/fake-send" FM_SEND_LOG="$SEND_LOG" \
  "$ROOT/bin/fm-watch.sh" > "$watch_home/watch.out" &
watch_pid=$!
wait_for_exit "$watch_pid" 200 || fail "watcher did not finish the matching decision wake"
[ "$(wc -l < "$SEND_LOG" | tr -d ' ')" = 2 ] || fail "watcher did not auto-apply the known regression answer"
case "$(open_decisions watched "$watch_home/state")" in *$'nm-watch-ci\tneeds-decision\t'*) fail "watcher left the matching decision open" ;; esac
case "$(cat "$watch_home/state/.wake-queue")" in *$'\tsignal\twatched.status\tneeds-decision:'*) fail "resolved gate retained its decision-owned wake payload" ;; esac
pass "watcher auto-applies a known regression on the cross-task decision wake"
