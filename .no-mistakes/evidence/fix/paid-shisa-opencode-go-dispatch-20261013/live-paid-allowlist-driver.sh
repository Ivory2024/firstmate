#!/usr/bin/env bash
# Live drive of the real bin/fm-spawn.sh OpenCode paid-id allowlist.
# External catalog transport is a local opencode stub serving the REAL captured
# `opencode models` catalog; pricing metadata is fetched from the REAL
# models.dev API with the real curl; tmux/treehouse are isolated stubs so no
# real agent launches. The product under test (bin/fm-spawn.sh) is unmodified
# and run for real.
set -u
ROOT="/Users/irene/.no-mistakes/worktrees/e10922160f77/01M4TEXASEB7X7Q0J6A8R6GW2R"
CATALOG="${1:?usage: driver <real-catalog-file>}"
cd "$ROOT"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$ROOT/tests/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
unset LAVISH_AXI_HOST
TMP_ROOT=$(fm_test_tmproot fm-live-paid)

make_spawn_pi_probe() {
  local fakebin=$1 tool=$2
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  printf '%s\n' "Pi ${FM_FAKE_PI_VERSION:-0.84.0}" 'Options: --help --tui-mode <mode> --approve'
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$dir")
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  cat > "$fakebin/cursor-agent" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --list-models ]; then printf '%s\n' 'cursor-grok-4.5-high'; fi
exit 0
SH
  chmod +x "$fakebin/timeout" "$fakebin/cursor-agent"
  make_spawn_pi_probe "$fakebin" pi
  make_spawn_pi_probe "$fakebin" pi-signed
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  git -C "$proj" config firstmate.baseMode local
  git -C "$proj" config firstmate.baseRef refs/heads/main
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  if [ "$harness" = opencode ]; then
    mkdir -p "$home/user-home/Developer/IMAC/AutomationSync/knowledge"
    printf '%s\n' '{"models":[{"id":"opencode-free/space-bunny-free","status":"active","early_termination_detected":false,"is_expiring_soon":false},{"id":"opencode-free/longcat-2.5-preview-free","status":"active","early_termination_detected":false,"is_expiring_soon":false}]}' \
      > "$home/user-home/Developer/IMAC/AutomationSync/knowledge/opencode-free-models.json"
  fi
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="${FM_TEST_PANE_LOG:-}" \
    FM_FAKE_PI_VERSION="${FM_TEST_PI_VERSION:-0.84.0}" \
    FM_FAKE_OPENCODE_MODELS="${FM_TEST_OPENCODE_MODELS:-}" \
    FM_FAKE_OPENCODE_MODELS_STATUS="${FM_TEST_OPENCODE_MODELS_STATUS:-0}" \
    FM_OPENCODE_PAID_MODELS="${FM_TEST_OPENCODE_PAID_MODELS:-}" \
    FM_FAKE_MODELS_DEV_STATUS="${FM_TEST_MODELS_DEV_STATUS:-0}" \
    GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

install_live_fakebin() { # <fakebin>
  local fakebin=$1
  # Use the REAL models.dev feed: no curl stub.
  rm -f "$fakebin/curl"
  # Serve the REAL captured `opencode models` catalog through a local instance
  # of the catalog command.
  cat > "$fakebin/opencode" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = models ]; then
  [ -n "\${2:-}" ] && { echo "error: unexpected positional argument" >&2; exit 1; }
  cat "$CATALOG"
fi
exit 0
SH
  chmod +x "$fakebin/opencode"
}

allowlist_file() { # <home> <content>
  printf '%b' "$2" > "$1/config/opencode-paid-models"
}

check() { # <label> <expected-status> <actual-status> <needle|-> <out>
  local label=$1 want=$2 got=$3 needle=$4 out=$5
  if [ "$got" = "$want" ]; then
    if [ "$needle" = "-" ]; then
      printf 'ok - %s (exit=%s)\n' "$label" "$got"
    else
      case "$out" in
        *"$needle"*) printf 'ok - %s (exit=%s) [saw: %s]\n' "$label" "$got" "$needle" ;;
        *) printf 'not ok - %s (exit=%s but MISSING: %s)\n' "$label" "$got" "$needle" ;;
      esac
    fi
  else
    printf 'not ok - %s (want exit=%s got=%s)\n' "$label" "$want" "$got"
  fi
}

scenario() { printf '\n===== %s =====\n' "$1"; }

M="opencode-go/kimi-k3"        # real paid id (models.dev input=3 output=15)
cost=$(curl --fail --silent --show-error --location --max-time 15 https://models.dev/api.json 2>/dev/null \
  | jq -c --arg m "${M#*/}" '."opencode-go".models[$m].cost' 2>/dev/null)
[ -n "$cost" ] || { echo "FATAL: models.dev unreachable; cannot drive live"; exit 3; }
printf 'models.dev reachable; REAL cost for %s: %s\n' "$M" "$cost"

# --- S1: free-only default still refuses a paid id (no allowlist) ---
scenario "S1 default free-only gate refuses the paid id (no allowlist)"
rec=$(make_spawn_case live-paid-default opencode s1); read_case_record "$rec"
install_live_fakebin "$FAKEBIN_DIR"
out=$(FM_TEST_OPENCODE_MODELS="$M" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" s1 "$PROJ_DIR" --model "$M"); st=$?
check "S1 paid id refused against real models.dev cost" 1 "$st" "is not classified as free by models.dev" "$out"
printf '  agent launched: %s\n' "$([ -s "$LAUNCH_LOG" ] && echo yes || echo no)"
printf '%s\n' "$out" | sed 's/^/    | /'

# --- S2: env allowlist allows the paid id ---
scenario "S2 FM_OPENCODE_PAID_MODELS allows the paid id"
rec=$(make_spawn_case live-paid-env opencode s2); read_case_record "$rec"
install_live_fakebin "$FAKEBIN_DIR"
out=$(FM_TEST_OPENCODE_MODELS="$M" FM_TEST_OPENCODE_PAID_MODELS="$M" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" s2 "$PROJ_DIR" --model "$M"); st=$?
check "S2 env allowlist dispatches the paid id" 0 "$st" "-" "$out"
check "S2 warns untracked, does not refuse" 0 "$st" "not tracked by the opencode free-model health catalog" "$out"
printf '  meta: %s\n' "$(grep -E '^(model|harness)=' "$HOME_DIR/state/s2.meta" 2>/dev/null | tr '\n' ' ')"
printf '  agent launched: %s\n' "$([ -s "$LAUNCH_LOG" ] && echo yes || echo no)"
printf '  launch model token: %s\n' "$(tr '\n' ' ' < "$LAUNCH_LOG" 2>/dev/null | grep -o -- "--model [^ ]*" | head -1)"
printf '%s\n' "$out" | sed 's/^/    | /'

# --- S3: config file allowlist allows the paid id ---
scenario "S3 config/opencode-paid-models allows the paid id"
rec=$(make_spawn_case live-paid-file opencode s3); read_case_record "$rec"
install_live_fakebin "$FAKEBIN_DIR"
allowlist_file "$HOME_DIR" '# captain approved\n\n   '"$M"'\t\r\nopencode-go/some-other-paid\n'
out=$(FM_TEST_OPENCODE_MODELS="$M" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" s3 "$PROJ_DIR" --model "$M"); st=$?
check "S3 file allowlist dispatches the paid id" 0 "$st" "-" "$out"
printf '  agent launched: %s\n' "$([ -s "$LAUNCH_LOG" ] && echo yes || echo no)"
printf '%s\n' "$out" | sed 's/^/    | /'

# --- S4: adversarial exact-id matching (prefix/suffix/wildcard) ---
scenario "S4 exact-id only: prefix/suffix/wildcard must NOT match"
_s4i=0
for spelling in "opencode-go/kimi" "opencode-go/kimi-k3-extra" "opencode-go/kimi-*" "opencode-go/kimi-k3 " "opencode-go/kimi-k3 # captain approved"; do
  _s4i=$((_s4i+1))
  rec=$(make_spawn_case "live-paid-exact-$_s4i" opencode s4); read_case_record "$rec"
  install_live_fakebin "$FAKEBIN_DIR"
  out=$(FM_TEST_OPENCODE_MODELS="$M" FM_TEST_OPENCODE_PAID_MODELS="$spelling" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" s4 "$PROJ_DIR" --model "$M"); st=$?
  case "$spelling" in
    *' # '*) want=1; needle="is not classified as free by models.dev" ;; # inline comment is not stripped: fail closed
    *' ') want=0; needle="-" ;;   # surrounding whitespace is trimmed by design, so this matches
    *) want=1; needle="is not classified as free by models.dev" ;;
  esac
  check "S4 entry '$spelling'" "$want" "$st" "$needle" "$out"
  printf '  agent launched: %s\n' "$([ -s "$LAUNCH_LOG" ] && echo yes || echo no)"
done

# --- S5: free model dispatch unchanged by a present allowlist ---
scenario "S5 real free model dispatch unchanged with paid allowlist present"
FM_FREE="opencode-go/longcat-2.5-preview-free"
rec=$(make_spawn_case live-paid-free opencode s5); read_case_record "$rec"
install_live_fakebin "$FAKEBIN_DIR"
out=$(FM_TEST_OPENCODE_MODELS="$FM_FREE" FM_TEST_OPENCODE_PAID_MODELS="$M" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" s5 "$PROJ_DIR" --model "$FM_FREE"); st=$?
check "S5 free model dispatches" 0 "$st" "-" "$out"
case "$out" in
  *"not tracked by the opencode free-model health catalog"*) printf 'not ok - S5 free model wrongly took the allowlist skip path\n' ;;
  *) printf 'ok - S5 free model did not take the allowlist skip path\n' ;;
esac
printf '  agent launched: %s\n' "$([ -s "$LAUNCH_LOG" ] && echo yes || echo no)"
printf '%s\n' "$out" | sed 's/^/    | /'

# --- S6: unreadable allowlist path keeps the free-only gate ---
scenario "S6 unreadable allowlist path keeps the free-only gate"
rec=$(make_spawn_case live-paid-dir opencode s6); read_case_record "$rec"
install_live_fakebin "$FAKEBIN_DIR"
mkdir -p "$HOME_DIR/config/opencode-paid-models"
out=$(FM_TEST_OPENCODE_MODELS="$M" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" s6 "$PROJ_DIR" --model "$M"); st=$?
check "S6 directory allowlist path refuses the paid id" 1 "$st" "is not classified as free by models.dev" "$out"
printf '  agent launched: %s\n' "$([ -s "$LAUNCH_LOG" ] && echo yes || echo no)"
printf '%s\n' "$out" | sed 's/^/    | /'

# --- S7: a tracked unhealthy catalog entry is still enforced for an allowlisted paid id ---
scenario "S7 allowlisted paid id with a tracked unhealthy health entry still refuses"
rec=$(make_spawn_case live-paid-health opencode s7); read_case_record "$rec"
install_live_fakebin "$FAKEBIN_DIR"
printf '%s\n' '{"models":[{"id":"opencode-free/kimi-k3","status":"retired","early_termination_detected":false,"is_expiring_soon":false}]}' \
  > "$HOME_DIR/user-home/Developer/IMAC/AutomationSync/knowledge/opencode-free-models.json"
out=$(FM_TEST_OPENCODE_MODELS="$M" FM_TEST_OPENCODE_PAID_MODELS="$M" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" s7 "$PROJ_DIR" --model "$M"); st=$?
check "S7 tracked unhealthy entry refuses" 1 "$st" "flagged unhealthy in the free-model health catalog" "$out"
printf '  agent launched: %s\n' "$([ -s "$LAUNCH_LOG" ] && echo yes || echo no)"
printf '%s\n' "$out" | sed 's/^/    | /'

# --- S8: an unreadable models.dev response is NOT exempted by the allowlist ---
scenario "S8 allowlist does not exempt an unreadable models.dev response"
rec=$(make_spawn_case live-paid-metafail opencode s8); read_case_record "$rec"
install_live_fakebin "$FAKEBIN_DIR"
cat > "$FAKEBIN_DIR/curl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAKEBIN_DIR/curl"
out=$(FM_TEST_OPENCODE_MODELS="$M" FM_TEST_OPENCODE_PAID_MODELS="$M" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" s8 "$PROJ_DIR" --model "$M"); st=$?
check "S8 models.dev failure still refuses" 1 "$st" "could not verify OpenCode model" "$out"
printf '  agent launched: %s\n' "$([ -s "$LAUNCH_LOG" ] && echo yes || echo no)"
printf '%s\n' "$out" | sed 's/^/    | /'

printf '\n===== live drive complete =====\n'
