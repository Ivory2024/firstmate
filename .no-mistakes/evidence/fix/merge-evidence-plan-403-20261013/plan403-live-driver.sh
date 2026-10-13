#!/usr/bin/env bash
# Live end-to-end driver for the plan-gated 403 protection relaxation.
#
# It runs the REAL bin/fm-pr-merge.sh (which runs the real
# bin/fm-merge-evidence.sh collector and the real bin/fm-merge-outcome-lib.sh)
# against a disposable firstmate home and a disposable forge CLI. Only the
# external forge (`gh`/`gh-axi`) is a stand-in; the product under test is the
# shipped merge pipeline.
#
# Reuses the proven fixture/build helpers from tests/fm-pr-merge.test.sh by
# sourcing its function definitions only (everything before its first test
# invocation). The generated forge shim is patched in place (case-local, no
# repository edit) so the collector's own protection / branch-rules reads can
# be failed on demand.
set -u

WT=/Users/irene/.no-mistakes/worktrees/e10922160f77/01M4TFQ1CV1Q2857EAPPQYJC5R
EVDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEADFILE="$EVDIR/fm-pr-merge-head.sh"

FIRST_CALL=$(grep -n '^test_github_zero_exit_queue_required_refuses_with_exact_retry$' \
  "$WT/tests/fm-pr-merge.test.sh" | head -1 | cut -d: -f1)
[ -n "$FIRST_CALL" ] || { echo "could not locate the test invocation block" >&2; exit 1; }
sed -n "1,$((FIRST_CALL - 1))p" "$WT/tests/fm-pr-merge.test.sh" \
  | sed "s|\$(dirname \"\${BASH_SOURCE\[0\]}\")|$WT/tests|g" > "$HEADFILE"
# shellcheck disable=SC1090
. "$HEADFILE"

PASS=0
FAIL=0
ok(){ PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi; }

PLAN_403='gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)'
UNRELATED_403='gh: Resource not accessible by integration (HTTP 403)'
SERVER_500='gh: Internal Server Error (HTTP 500)'

# Inject a block into the generated forge shim right after its `set -u`, so the
# shim still runs with $0 basenamed gh/glab/no-mistakes (the symlinks). Any
# other call falls through to the shim's own proven behaviour.
patch_shim() {  # <case_dir> <inject-file>
  local case_dir=$1 inject=$2
  local shim="$case_dir/evidencebin/forge-evidence-shim"
  awk -v inject="$inject" '
    { print }
    /^set -u$/ { while ((getline line < inject) > 0) print line; close(inject) }
  ' "$shim" > "$shim.new"
  mv "$shim.new" "$shim"
  chmod +x "$shim"
  rm -f "$inject"
}

# Env-driven failure injection for the collector's protection / branch-rules
# reads; empty FM_DRIVER_* env values fall through to the normal fixture.
install_protection_override() {
  local case_dir=$1
  local inject="$case_dir/.driver-inject"
  cat > "$inject" <<'SH'
case " ${1:-} ${2:-} $* " in
  *"/branches/"*"/protection"*)
    if [ -n "${FM_DRIVER_PROT_ERR:-}" ]; then
      printf '%s\n' "$FM_DRIVER_PROT_ERR" >&2
      exit 1
    fi ;;
  *"--slurp"*"/rules/branches/"*)
    if [ -n "${FM_DRIVER_RULES_ERR:-}" ]; then
      printf '%s\n' "$FM_DRIVER_RULES_ERR" >&2
      exit 1
    fi ;;
esac
SH
  patch_shim "$case_dir" "$inject"
}

# make a fresh disposable main home case with the forge mocks installed.
new_case() {  # <name> <head>
  local name=$1 head=$2 case_dir
  case_dir=$(make_home_case "$name")
  add_gh_mocks "$case_dir" "$head"
  install_protection_override "$case_dir"
  : > "$case_dir/gh-axi.log"
  printf '%s\n' "$case_dir"
}

run_case() {  # <case_dir> <url> [extra args...]
  local case_dir=$1 url=$2
  shift 2
  LAST_RC=0
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" "$@" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || LAST_RC=$?
  LAST_CASE=$case_dir
}

assert_merge_ran() {  # <label> <case_dir> <number>
  local line
  line="pr merge $3 --repo example/repo --match-head-commit $(cat "$2/github-head") --squash"
  if grep -qxF "$line" "$2/gh.log" 2>/dev/null; then
    ok "$1: the forge merge command ran ($line)"
  else
    bad "$1: the forge merge command did not run; gh.log=$(cat "$2/gh.log" 2>/dev/null)"
  fi
}

collect_verdict() {  # <case_dir> <head> <url>
  local case_dir=$1 head=$2 url=$3
  env FM_TEST_EVIDENCE_DIR="$case_dir/$EVIDENCE_DIRNAME" \
      FM_TEST_EVIDENCE_HEAD_FILE="$case_dir/github-head" \
      FM_TEST_EVIDENCE_PR_URL="$url" \
      FM_ROOT_OVERRIDE="$ROOT" \
      FM_HOME="$case_dir/home" \
      FM_STATE_OVERRIDE="$case_dir/state" \
      FM_DRIVER_PROT_ERR="${FM_DRIVER_PROT_ERR:-}" \
      FM_DRIVER_RULES_ERR="${FM_DRIVER_RULES_ERR:-}" \
      PATH="$case_dir/evidencebin:$case_dir/fakebin:$PATH" \
      "$ROOT/bin/fm-merge-evidence.sh" collect task-x1 "$url" "$head"
}

echo '=== scenario 1: plan-gated 403 on both protection sources ==='
S1_HEAD=0000000000000000000000000000000000000001
S1_URL=https://github.com/example/repo/pull/9
S1=$(new_case plan-both-endpoints "$S1_HEAD")
export FM_DRIVER_PROT_ERR="$PLAN_403" FM_DRIVER_RULES_ERR="$PLAN_403"
S1_VERDICT=$(collect_verdict "$S1" "$S1_HEAD" "$S1_URL")
printf 'collector verdict: %s\n' "$S1_VERDICT"
run_case "$S1" "$S1_URL"
unset FM_DRIVER_PROT_ERR FM_DRIVER_RULES_ERR
check "plan-403 both: merge lands" "$LAST_RC" 0
check "plan-403 both: collector PASS" "$(printf '%s' "$S1_VERDICT" | jq -r .status)" PASS
check "plan-403 both: collector records the relaxation" \
  "$(printf '%s' "$S1_VERDICT" | jq -r .protection_source)" unavailable-by-plan
check "plan-403 both: collector does not claim protection exists" \
  "$(printf '%s' "$S1_VERDICT" | jq -r '.protection | tostring')" false
assert_merge_ran "plan-403 both" "$S1" 9
check "plan-403 both: durable merge wake names the relaxed gate" \
  "$(grep -c 'merge landed: task-x1 .* gate-relaxed(unavailable-by-plan)' "$S1/state/.wake-queue" 2>/dev/null)" 1
cat "$S1/state/.wake-queue" 2>/dev/null

echo
echo '=== scenario 2 (control): ordinary protected repo, no relaxation ==='
S2_HEAD=0000000000000000000000000000000000000002
S2_URL=https://github.com/example/repo/pull/9
S2=$(new_case ordinary-protected "$S2_HEAD")
S2_VERDICT=$(collect_verdict "$S2" "$S2_HEAD" "$S2_URL")
printf 'collector verdict: %s\n' "$S2_VERDICT"
run_case "$S2" "$S2_URL"
check "ordinary protected: merge lands" "$LAST_RC" 0
check "ordinary protected: collector enforces the gate" \
  "$(printf '%s' "$S2_VERDICT" | jq -r '.status + ":" + (.protection | tostring)')" "PASS:true"
check "ordinary protected: collector records no relaxation" \
  "$(printf '%s' "$S2_VERDICT" | jq -r '.protection_source // "none"')" none
assert_merge_ran "ordinary protected" "$S2" 9
check "ordinary protected: no relaxation tag in the durable wake" \
  "$(grep -c 'gate-relaxed' "$S2/state/.wake-queue" 2>/dev/null)" 0

echo
echo '=== scenario 3 (adversarial): unrelated 403 on protection still refuses ==='
S3_HEAD=0000000000000000000000000000000000000003
S3_URL=https://github.com/example/repo/pull/9
S3=$(new_case unrelated-403 "$S3_HEAD")
export FM_DRIVER_PROT_ERR="$UNRELATED_403" FM_DRIVER_RULES_ERR="$UNRELATED_403"
S3_VERDICT=$(collect_verdict "$S3" "$S3_HEAD" "$S3_URL")
printf 'collector verdict: %s\n' "$S3_VERDICT"
run_case "$S3" "$S3_URL"
unset FM_DRIVER_PROT_ERR FM_DRIVER_RULES_ERR
check "unrelated 403: collector holds unreadable protection" \
  "$(printf '%s' "$S3_VERDICT" | jq -r .reasons[0])" branch-protection-unreadable
[ "$LAST_RC" -ne 0 ] && ok "unrelated 403: merge refuses" || bad "unrelated 403: merge did not refuse (rc=$LAST_RC)"
check "unrelated 403: no forge merge ran" \
  "$(grep -c '^pr merge ' "$S3/gh.log" 2>/dev/null)" 0
[ ! -s "$S3/state/.wake-queue" ] && ok "unrelated 403: no merged wake recorded" \
  || bad "unrelated 403: a refused merge wrote a merged wake"
printf 'refusal: %s\n' "$(grep -o 'branch-protection-unreadable' "$S3/stderr" | head -1)"

echo
echo '=== scenario 4 (adversarial): plan on protection + 5xx on rules still refuses ==='
S4_HEAD=0000000000000000000000000000000000000004
S4_URL=https://github.com/example/repo/pull/9
S4=$(new_case partial-plan-500 "$S4_HEAD")
export FM_DRIVER_PROT_ERR="$PLAN_403" FM_DRIVER_RULES_ERR="$SERVER_500"
S4_VERDICT=$(collect_verdict "$S4" "$S4_HEAD" "$S4_URL")
printf 'collector verdict: %s\n' "$S4_VERDICT"
run_case "$S4" "$S4_URL"
unset FM_DRIVER_PROT_ERR FM_DRIVER_RULES_ERR
check "partial plan: collector holds the unreadable rules source" \
  "$(printf '%s' "$S4_VERDICT" | jq -r .reasons[0])" rulesets-unreadable
[ "$LAST_RC" -ne 0 ] && ok "partial plan: merge refuses" || bad "partial plan: merge did not refuse (rc=$LAST_RC)"
check "partial plan: no forge merge ran" \
  "$(grep -c '^pr merge ' "$S4/gh.log" 2>/dev/null)" 0

echo
echo '=== scenario 5 (adversarial): plan 403 on rules alone is not the plan proof ==='
S5_HEAD=0000000000000000000000000000000000000005
S5_URL=https://github.com/example/repo/pull/9
S5=$(new_case plan-rules-only "$S5_HEAD")
export FM_DRIVER_RULES_ERR="$PLAN_403"
S5_VERDICT=$(collect_verdict "$S5" "$S5_HEAD" "$S5_URL")
printf 'collector verdict: %s\n' "$S5_VERDICT"
run_case "$S5" "$S5_URL"
unset FM_DRIVER_RULES_ERR
check "plan rules only: healthy classic gate still passes" \
  "$(printf '%s' "$S5_VERDICT" | jq -r '.status + ":" + (.protection | tostring)')" "PASS:true"
check "plan rules only: no relaxation recorded" \
  "$(printf '%s' "$S5_VERDICT" | jq -r '.protection_source // "none"')" none
check "plan rules only: merge lands" "$LAST_RC" 0
assert_merge_ran "plan rules only" "$S5" 9
check "plan rules only: no relaxation tag in the durable wake" \
  "$(grep -c 'gate-relaxed' "$S5/state/.wake-queue" 2>/dev/null)" 0

echo
echo '=== scenario 6 (adversarial TOCTOU): protection appears before the merge ==='
S6_HEAD=0000000000000000000000000000000000000006
S6_URL=https://github.com/example/repo/pull/9
S6=$(make_home_case plan-then-real-protection)
add_gh_mocks "$S6" "$S6_HEAD"
: > "$S6/gh-axi.log"
printf '%s\n' '{"required_status_checks":{"contexts":["ci"]},"required_pull_request_reviews":{}}' \
  > "$S6/real-protection.json"
S6_INJECT="$S6/.driver-inject-6"
cat > "$S6_INJECT" <<SH
case " \${1:-} \${2:-} \$* " in
  *"/branches/"*"/protection"*)
    if [ ! -f "$S6/prot-read-1" ]; then
      : > "$S6/prot-read-1"
      printf '%s\n' "$PLAN_403" >&2
      exit 1
    fi
    cat "$S6/real-protection.json"
    exit 0 ;;
  *"--slurp"*"/rules/branches/"*)
    if [ ! -f "$S6/rules-read-1" ]; then
      : > "$S6/rules-read-1"
      printf '%s\n' "$PLAN_403" >&2
      exit 1
    fi
    printf '%s\n' '[[]]'
    exit 0 ;;
esac
SH
patch_shim "$S6" "$S6_INJECT"
run_case "$S6" "$S6_URL"
[ "$LAST_RC" -ne 0 ] && ok "TOCTOU: merge refuses when the gate appears after collection" \
  || bad "TOCTOU: merge did not refuse (rc=$LAST_RC)"
check "TOCTOU: no forge merge ran" \
  "$(grep -c '^pr merge ' "$S6/gh.log" 2>/dev/null)" 0
printf 'refusal: %s\n' "$(grep -o 'branch-protection-changed' "$S6/stderr" | head -1)"

echo
echo "# plan403-live-driver PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
