#!/usr/bin/env bash
# tests/fixtures.sh - shared fake-toolchain and spawn-world builders.
#
# Source this from a test file:
#   # shellcheck source=tests/fixtures.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
#
# Generic reporters, temp roots, git fixtures, and fail/pass/fm_test_cleanup
# come from tests/lib.sh, pulled in below. This file owns the shared fake
# no-mistakes, gh, gh-axi, tmux, ssh, and spawn-world helpers. Wake-queue mocks
# stay in wake-helpers.sh; secondmate-lifecycle mocks stay in
# secondmate-helpers.sh.
#
# FM_TEST_NO_MISTAKES_VERSION is the single default version for the shared fake
# no-mistakes banner. Override a single case with FM_FAKE_NO_MISTAKES_VERSION
# rather than editing a stub body.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -n "${FM_TEST_FIXTURES_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_FIXTURES_SOURCED=1

# Production floor lives in bin/fm-bootstrap.sh (NO_MISTAKES_MIN). Keep this
# equal to that floor so a bump is one constant here plus that production pin.
export FM_TEST_NO_MISTAKES_VERSION=1.46.0
export FM_TEST_NO_MISTAKES_FAKE_VERSION="no-mistakes version v${FM_TEST_NO_MISTAKES_VERSION} (fake)"
export FM_TEST_NO_MISTAKES_FAKE_VERSION_TS="${FM_TEST_NO_MISTAKES_FAKE_VERSION} 2026-06-27T00:02:18Z"
export FM_TEST_GH_AXI_VERSION=0.1.29

# --- fake no-mistakes -------------------------------------------------------

# fm_test_fake_no_mistakes <fakebin>
# Drops a no-mistakes stub that answers --version with
# FM_TEST_NO_MISTAKES_FAKE_VERSION (or FM_FAKE_NO_MISTAKES_VERSION when set)
# and exits 0 for every other invocation.
fm_test_fake_no_mistakes() {
  local fakebin=$1
  cat > "$fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\\n' "\${FM_FAKE_NO_MISTAKES_VERSION:-$FM_TEST_NO_MISTAKES_FAKE_VERSION}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
}

# fm_test_fake_no_mistakes_init_doctor <fakebin>
# Secondmate-lifecycle stub: init/doctor touch marker files; other verbs exit 2.
# Does not answer --version (those suites never probe the floor).
fm_test_fake_no_mistakes_init_doctor() {
  local fakebin=$1
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
}

# --- fake gh / gh-axi -------------------------------------------------------

# fm_test_fake_gh <fakebin>
# Authenticates (`gh auth status` exits 0) and otherwise exits 0.
fm_test_fake_gh() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
}

# fm_test_fake_gh_axi <fakebin>
# Answers --version with FM_FAKE_GH_AXI_VERSION or FM_TEST_GH_AXI_VERSION.
fm_test_fake_gh_axi() {
  local fakebin=$1
  fm_fake_version_tool "$fakebin" gh-axi FM_FAKE_GH_AXI_VERSION "$FM_TEST_GH_AXI_VERSION"
}

# --- merge-evidence forge fixture -------------------------------------------
#
# bin/fm-pr-merge.sh runs the evidence collector shipped beside it
# (bin/fm-merge-evidence.sh) and that path is not caller-selectable, so a suite
# that drives a real merge must satisfy the shipped collector instead of
# standing in for it. These helpers write a controlled forge fixture and install
# shims that answer only the shipped collector's own reads (plus `no-mistakes axi
# status`), delegating every other forge invocation to the suite's own mock. The
# gate under test is therefore the real collector: a case changes its verdict by
# changing the fixture, not by replacing the collector.

# fm_test_write_forge_evidence_fixture <dir> [changed-path]
# Writes the GitHub and GitLab payloads the shipped collector reads. The token
# __HEAD__ is replaced with the case's live head when the shim serves a file, so
# one fixture stays consistent with whatever head the case reads.
fm_test_write_forge_evidence_fixture() {
  local dir=$1 path=${2:-docs/fixture.md}
  mkdir -p "$dir"
  cat > "$dir/gh-protection.json" <<'JSON'
{"required_status_checks":{"contexts":["ci"]},"required_pull_request_reviews":{}}
JSON
  printf '%s\n' '[[]]' > "$dir/gh-rulesets.json"
  printf '%s\n' '[{"check_runs":[]}]' > "$dir/gh-check-runs.json"
  cat > "$dir/gh-statuses.json" <<'JSON'
[[{"context":"ci","sha":"__HEAD__","created_at":"2026-10-10T00:00:00Z","id":1,"state":"success"}]]
JSON
  cat > "$dir/gh-reviews.json" <<'JSON'
[[{"state":"APPROVED","user":{"login":"reviewer"},"commit_id":"__HEAD__","submitted_at":"2026-10-10T00:00:00Z"},{"state":"APPROVED","user":{"login":"captain"},"commit_id":"__HEAD__","submitted_at":"2026-10-10T00:01:00Z"}]]
JSON
  printf '[[{"filename":"%s"}]]\n' "$path" > "$dir/gh-files.json"
  printf '%s\n' '[{"name":"main","required_pipeline":{"id":5}}]' > "$dir/glab-protected.json"
  cat > "$dir/glab-jobs.json" <<'JSON'
[{"pipeline":{"id":5},"commit":{"id":"__HEAD__"},"status":"success"}]
JSON
  printf '%s\n' '{"approvals_left":0,"approved_by":[{"user":{"username":"reviewer","id":2}}]}' \
    > "$dir/glab-approvals.json"
  printf '%s\n' '{"reset_approvals_on_push":true}' > "$dir/glab-project.json"
  printf '{"overflow":false,"changes_count":"1","changes":[{"new_path":"%s","old_path":"%s"}]}\n' \
    "$path" "$path" > "$dir/glab-changes.json"
}

# fm_test_install_forge_evidence_shims <dir> [<delegate-bin-dir>]
# Installs the gh/glab/no-mistakes shims in <dir>. Prepending <dir> to PATH is
# what makes them answer, so a suite that builds its own PATH must include it.
# Every unrecognised invocation is delegated to <delegate-bin-dir>, so the
# suite's existing mocks keep owning the merge, verify, and poll reads.
fm_test_install_forge_evidence_shims() {
  local dir=$1 delegate=${2:-} tmp
  mkdir -p "$dir"
  tmp="$dir/.forge-evidence-shim.$$"
  cat > "$tmp" <<'SH'
#!/usr/bin/env bash
# Answers only the reads bin/fm-merge-evidence.sh makes of the forge, plus
# `no-mistakes axi status`; everything else goes to the suite's own mock.
set -u
tool=${0##*/}
D=${FM_TEST_EVIDENCE_DIR:-}
delegate() {
  if [ -x "__DELEGATE__/$tool" ]; then
    exec "__DELEGATE__/$tool" "$@"
  fi
  case "$tool" in
    no-mistakes) exit 0 ;;
    *) exit 1 ;;
  esac
}
log_call() {
  case "$tool" in
    gh) [ -n "${FM_TEST_GH_LOG:-}" ] && printf '%s\n' "$*" >> "$FM_TEST_GH_LOG" ;;
    glab) [ -n "${FM_TEST_GLAB_LOG:-}" ] && printf '%s\n' "$*" >> "$FM_TEST_GLAB_LOG" ;;
  esac
  return 0
}
# Without a controlled fixture this invocation is not the merge boundary's own
# evidence read, so hand it straight to the suite's mock.
if [ -z "$D" ] || [ ! -d "$D" ]; then
  delegate "$@"
fi
head=${FM_TEST_EVIDENCE_HEAD:-}
if [ -n "${FM_TEST_EVIDENCE_HEAD_FILE:-}" ] && [ -r "${FM_TEST_EVIDENCE_HEAD_FILE}" ]; then
  head=$(tr -d '\n' < "$FM_TEST_EVIDENCE_HEAD_FILE")
fi
# A GitLab case's live head is the merge request's own head, not the GitHub head
# file it never uses, so derive it from the payload both reads already share.
if [ -r "${FM_TEST_GLAB_JSON:-}" ] && command -v jq >/dev/null 2>&1; then
  mh=$(jq -r '.sha // empty' "$FM_TEST_GLAB_JSON" 2>/dev/null) || mh=
  case "$mh" in
    '' | *[!0-9a-fA-F]*) ;;
    *) [ "${#mh}" -eq 40 ] && head=$mh ;;
  esac
fi
serve() { local f=$1; shift; log_call "$@"; sed "s/__HEAD__/$head/g" "$D/$f"; }
case "$tool" in
  gh)
    case "${1:-} ${2:-}" in
      "pr view")
        case " $* " in
          *author,headRefOid,baseRefName,changedFiles*)
            log_call "$@"
            printf '{"author":{"login":"author"},"headRefOid":"%s","baseRefName":"main","changedFiles":1}\n' "$head"
            exit 0
            ;;
        esac
        ;;
      "api user") log_call "$@"; printf '%s\n' '{"login":"captain"}'; exit 0 ;;
      "api "*)
        case " $* " in
          *"--slurp"*"/rules/branches/"*) serve gh-rulesets.json "$@"; exit 0 ;;
          *"/branches/"*"/protection"*) serve gh-protection.json "$@"; exit 0 ;;
          *"--slurp"*"/check-runs"*) serve gh-check-runs.json "$@"; exit 0 ;;
          *"--slurp"*"/statuses"*) serve gh-statuses.json "$@"; exit 0 ;;
          *"--slurp"*"/reviews"*) serve gh-reviews.json "$@"; exit 0 ;;
          *"--slurp"*"/files"*) serve gh-files.json "$@"; exit 0 ;;
        esac
        ;;
    esac
    ;;
  glab)
    case "${1:-} ${2:-}" in
      "api "*)
        case " $* " in
          *"/protected_branches"*) serve glab-protected.json "$@"; exit 0 ;;
          *"/jobs"*) serve glab-jobs.json "$@"; exit 0 ;;
          *"/approvals"*) serve glab-approvals.json "$@"; exit 0 ;;
          *"/changes"*) serve glab-changes.json "$@"; exit 0 ;;
          *"merge_requests/"*) exit 1 ;;
          *"projects/"*) serve glab-project.json "$@"; exit 0 ;;
        esac
        ;;
    esac
    ;;
  no-mistakes)
    if [ "${1:-}" = axi ] && [ "${2:-}" = status ]; then
      printf 'run:\n  id: fixture-run\n  status: completed\n  head_sha: %s\n  pr: "%s"\n  findings: 0 awaiting\n  steps[1]{step,status,findings,duration_ms}:\n    test,completed,0,1\noutcome: passed\n' \
        "$head" "${FM_TEST_EVIDENCE_PR_URL:-}"
      exit 0
    fi
    ;;
esac
delegate "$@"
SH
  if [ -n "$delegate" ]; then
    sed "s|__DELEGATE__|$delegate|g" "$tmp" > "$dir/forge-evidence-shim"
    rm -f "$tmp"
  else
    mv "$tmp" "$dir/forge-evidence-shim"
  fi
  chmod +x "$dir/forge-evidence-shim"
  ln -sf forge-evidence-shim "$dir/gh"
  ln -sf forge-evidence-shim "$dir/glab"
  ln -sf forge-evidence-shim "$dir/no-mistakes"
}

# --- fake tmux / ssh / sleep ------------------------------------------------

# fm_test_fake_tmux_spawn <fakebin>
# Spawn-world tmux: pane_current_path from FM_FAKE_PANE_PATH, session named
# firstmate, window ops succeed, send-keys succeed. When FM_FAKE_LAUNCH_LOG is
# set, each send-keys -l payload is appended one per line. When FM_FAKE_PANE_LOG
# is set, each send-keys TEXT-LINE payload (the pre-launch pane exports, which
# carry no -l) is appended there instead, one per line in send order. Optional
# FM_FAKE_DUPLICATE_WINDOW is printed from list-windows.
#
# The pane path defaults to empty when FM_FAKE_PANE_PATH is unset. Window
# cleanup and option operations are no-ops. Launch logging is env-gated, so
# suites that do not set FM_FAKE_LAUNCH_LOG keep a silent send-keys.
fm_test_fake_tmux_spawn() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    if [ -n "${FM_FAKE_DUPLICATE_WINDOW:-}" ]; then
      printf '%s\n' "$FM_FAKE_DUPLICATE_WINDOW"
    fi
    exit 0
    ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          # A spawn types a short line sourcing its staged launch file; log
          # the staged command itself so suites assert what the pane runs.
          # Direct literals past the terminal line buffer are truncated, so a
          # long launch only survives when it arrived through that short source.
          case "$a" in
            ". '"*"'")
              staged=${a#". '"}
              staged=${staged%"'"}
              if [ -f "$staged" ]; then
                a=$(cat "$staged")
              elif [ "${#a}" -gt 1024 ]; then
                a=${a:0:1024}
              fi
              ;;
            *)
              if [ "${#a}" -gt 1024 ]; then
                a=${a:0:1024}
              fi
              ;;
          esac
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    # The pre-launch pane exports ride the text-line form
    # (`send-keys -t <target> <text> Enter`), which carries no -l flag, so a
    # suite that asserts on what the pane shell received opts in with its own
    # log. Skip the flags, the target, and the trailing key so only the payload
    # is recorded, one per line, in send order.
    if [ -n "${FM_FAKE_PANE_LOG:-}" ]; then
      shift
      skip_next=
      literal=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) literal=1; continue ;;
          Enter|C-m) continue ;;
          *) [ -n "$literal" ] || printf '%s\n' "$a" >> "$FM_FAKE_PANE_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

# fm_test_fake_tmux_send <fakebin>
# Send-world tmux: logs send-keys -l payloads to FM_SEND_LOG, reports a numeric
# cursor_y, and renders an empty bordered composer so the submit path reads
# empty. Env knobs:
#   FM_FAKE_TMUX_SEND_FAIL=1  send-keys exits 1
#   FM_FAKE_TMUX_COMPOSER=pending  capture-pane shows leftover composer text
fm_test_fake_tmux_send() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
    fi
    exit 0
    ;;
  display-message)
    for a in "$@"; do
      case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac
    done
    printf 'fakepane\n'
    exit 0
    ;;
  capture-pane)
    if [ "${FM_FAKE_TMUX_COMPOSER:-}" = pending ]; then
      printf '╭──────────────╮\n│ leftover txt │\n╰──────────────╯\n'
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0
    ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

# fm_test_fake_ssh <fakebin> [name]
# Records argv to FM_SSH_LOG, consumes stdin, exits FM_FAKE_SSH_RC (default 0).
# Default name is fake-ssh so tests can point FM_SSH_BIN at it without
# shadowing a real ssh on PATH.
fm_test_fake_ssh() {
  local fakebin=$1 name=${2:-fake-ssh}
  cat > "$fakebin/$name" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$*" >> "${FM_SSH_LOG:-/dev/null}"
exit "${FM_FAKE_SSH_RC:-0}"
SH
  chmod +x "$fakebin/$name"
}

# fm_test_fake_sleep_noop <fakebin>
fm_test_fake_sleep_noop() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
}

# fm_test_fake_sleep_log <fakebin>
# Records each requested duration to FM_SLEEP_LOG instead of sleeping.
fm_test_fake_sleep_log() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "${FM_SLEEP_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$fakebin/sleep"
}

# --- spawn-world ------------------------------------------------------------

# fm_test_spawn_home <home> [harness]
# Minimal firstmate home layout plus watcher-liveness beat. Optional harness
# pin is written to config/crew-harness.
fm_test_spawn_home() {
  local home=$1 harness=${2-}
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  if [ -n "$harness" ]; then
    printf '%s\n' "$harness" > "$home/config/crew-harness"
  fi
}

# fm_test_spawn_brief <home> <id> [captain-intent]
fm_test_spawn_brief() {
  local home=$1 id=$2 intent=${3:-brief for $2}
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
$intent

## Firstmate spec
Exercise the spawn behavior under test.
EOF
}

# fm_test_make_spawn_fakebin <dir> [extra-exit0-tool...]
# Creates <dir>/fakebin with the spawn tmux stub, a no-op treehouse, and any
# extra exit-0 tools. Echoes the fakebin path.
fm_test_make_spawn_fakebin() {
  local dir=$1 fakebin
  shift
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_tmux_spawn "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse "$@"
  printf '%s\n' "$fakebin"
}

# Drop-in name used by the spawn suites. Extra args are additional exit-0 tools
# (gh, gh-axi, pi, ...).
make_spawn_fakebin() {
  fm_test_make_spawn_fakebin "$@"
}

# fm_test_run_spawn <home> <pane-path> <fakebin> [fm-spawn args...]
# Common spawn env. Extra variables in the caller (GROK_HOME, FM_FAKE_LAUNCH_LOG,
# CLAUDE_CONFIG_DIR, ...) are inherited. Does not add --mode/--yolo; ship tests
# that need a delivery contract pass those flags themselves.
fm_test_run_spawn() {
  local home=$1 pane=$2 fakebin=$3
  shift 3
  if [ "${FM_TEST_BASE_CONTRACT:-local}" = local ]; then
    local fixture_ref
    fixture_ref=$(git -C "$pane" for-each-ref --format='%(refname)' refs/heads/main 2>/dev/null | head -1 || true)
    [ -n "$fixture_ref" ] || fixture_ref=$(git -C "$pane" for-each-ref --format='%(refname)' refs/heads 2>/dev/null | head -1 || true)
    if [ -n "$fixture_ref" ]; then
      git -C "$pane" config firstmate.baseMode local
      git -C "$pane" config firstmate.baseRef "$fixture_ref"
    fi
  fi
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), so every spawn here runs against a throwaway
  # HOME; without it the suite would write the developer's real ~/.claude.json.
  # CLAUDE_CONFIG_DIR must be pinned too, and pinned EMPTY: the script resolves
  # the store as ${CLAUDE_CONFIG_DIR:-${HOME:-}}, so a value inherited from the
  # developer's shell would beat the throwaway HOME and the sandbox would not
  # hold, while an empty value falls through to it. Empty rather than a path
  # because bin/fm-spawn.sh prefixes the launch only when the value is non-empty,
  # so every launch-shape assertion in the suite keeps reading the same command.
  # A test that needs the set case opts in through FM_TEST_CLAUDE_CONFIG_DIR.
  local spawn_home=$home/user-home
  mkdir -p "$spawn_home"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$spawn_home" \
    CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="${TMUX:-fake,1,0}" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

# --- send-world stubs -------------------------------------------------------

# make_stubs <dir>
# Send-world fakebin: send tmux + no-op sleep. Echoes the fakebin path.
# Suites that need recording sleep, herdr, or ssh add those on top of this
# fakebin (or replace sleep via fm_test_fake_sleep_log).
make_stubs() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_tmux_send "$fakebin"
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}
