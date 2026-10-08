#!/usr/bin/env bash
# survey.sh - the canary executor's read-only survey of the Firstmate repo test
# structure. It NEVER writes to the repo. It prints a JSON summary and a human
# report; the evidence collector captures stdout/stderr/exit/duration.
#
# Usage: survey.sh [repo-dir]
set -u
REPO=${1:-/Users/irene/Developer/kunchenguid_repos/firstmate}
start=$(date +%s)

test_files=$(find "$REPO/tests" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
test_files_all=$(find "$REPO/tests" -type f -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
bytes=$(find "$REPO/tests" -type f 2>/dev/null | xargs wc -c 2>/dev/null | tail -1 | awk '{print $1}')
# representative run commands actually declared by the repo's own runner
runner=$( [ -f "$REPO/bin/fm-test-run.sh" ] && echo "bin/fm-test-run.sh" || echo "<no bin/fm-test-run.sh>" )

# repo must exist and be read-only for us: fail loud if absent
[ -d "$REPO/tests" ] || { echo "survey: no tests dir at $REPO" >&2; exit 2; }
[ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] || { echo "survey: not a git repo: $REPO" >&2; exit 2; }

end=$(date +%s)
cat <<EOF
{
  "repo": "$REPO",
  "tests_dir_files_total": ${bytes:-0},
  "test_sh_top_level": $test_files,
  "test_sh_recursive": $test_files_all,
  "representative_runner": "$runner",
  "sample_command": "bash $runner <suite>  (or: bash tests/<suite>.test.sh)",
  "survey_duration_s": $((end - start)),
  "writes_to_repo": 0
}
EOF
echo "SURVEY_DONE repo=$REPO top_level_tests=$test_files all_tests=$test_files_all bytes=${bytes:-0}"
