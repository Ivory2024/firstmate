#!/usr/bin/env bash
# Shared test harness for the unattended crew orchestrator tests.
set -u
TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UCX=${UCX:-$(cd "$TESTS_DIR/../implementation" && pwd)}
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok - $1"; }
no()  { FAIL=$((FAIL+1)); echo "not ok - $1"; }

new_home() { export UC_HOME; UC_HOME=$(mktemp -d "${TMPDIR:-/tmp}/uc-test.XXXXXX"); export UC_IMPL_DIR="$UCX"; }

mkcontract() { # <file> <mode> <retry_limit> <tasks-json>
  cat > "$1" <<EOF
{ "batch_id": "$(basename "$1" .json)", "baseline_sha": "TESTBASE", "mode": "$2",
  "forbidden_operations": ["github_write","real_worker_call"],
  "retry_limit": $3, "ack_timeout_secs": 3, "tasks": $4 }
EOF
}

run_uc() { "$UCX/fm-unattended.sh" "$@"; }
task_state() { sed -n "s/^new=//p" "$UC_HOME/batches/$1/tasks/$2.state" 2>/dev/null | tail -1; }
task_reason() { # <batch> <task> <new-state>
  sed -n "s/.*task_id=$2 .* new=$3 reason=\([^ ]*\).*/\1/p" "$UC_HOME/batches/$1/state.jsonl" 2>/dev/null | tail -1; }
verdict_of() { sed -n 's/.*"verdict":"\([^"]*\)".*/\1/p' "$UC_HOME/batches/$1/evidence/runs/$2/gate/verdict.json" 2>/dev/null | tail -1; }
cleanup_home() { rm -rf "$UC_HOME"; }
