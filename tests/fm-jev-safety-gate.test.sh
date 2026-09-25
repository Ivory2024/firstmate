#!/usr/bin/env bash
set -u

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$TEST_ROOT/.no-mistakes/jev-safety-tests"
TMPDIR="$TEST_ROOT/.no-mistakes/jev-safety-tests"
export TMPDIR
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-jev-safety-gate)

assert_verdict() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as verdict_file:
    verdict = json.load(verdict_file)
expected = sys.argv[2]
assert verdict["allowed"] is (expected == "clean"), verdict
assert verdict["reason"] == expected, verdict
PY
}

GUARD="$ROOT/.claude/jev-safety/check.py"
PROJECT="$ROOT/.claude/jev-safety"
UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/secret.json"
{"content":"test token ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
JSON
if ! assert_verdict "$TMP_ROOT/secret.json" secret; then
  fail "detect-secrets did not block a synthetic GitHub token"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/path.json"
{"paths":["data/captain.md"],"content":"plain non-secret fixture text"}
JSON
if ! assert_verdict "$TMP_ROOT/path.json" sensitive_path; then
  fail "sensitive path was not blocked independently of the secret scanner"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/learnings.json"
{"paths":["data/learnings.md"],"content":"plain non-secret fixture text"}
JSON
if ! assert_verdict "$TMP_ROOT/learnings.json" sensitive_path; then
  fail "home-local learnings path was not blocked independently of the secret scanner"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/backlog.json"
{"paths":["data/backlog.md"],"content":"plain non-secret fixture text"}
JSON
if ! assert_verdict "$TMP_ROOT/backlog.json" sensitive_path; then
  fail "backlog path was not blocked independently of the secret scanner"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/bash-cwd.json"
{"tool_name":"Bash","tool_input":{"command":"cat pipelines/health/patient.txt > /tmp/result.txt"},"tool_response":"plain non-secret fixture text"}
JSON
if ! assert_verdict "$TMP_ROOT/bash-cwd.json" sensitive_path; then
  fail "sensitive Bash path and redirection target were not blocked"
fi

for directory in state config; do
  UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<JSON > "$TMP_ROOT/bash-$directory.json"
{"tool_name":"Bash","tool_input":{"command":"ls $directory"},"tool_response":"plain non-secret fixture text"}
JSON
  if ! assert_verdict "$TMP_ROOT/bash-$directory.json" sensitive_path; then
    fail "direct Bash argument for $directory was not blocked"
  fi
done

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/bash-cwd-residual.json"
{"tool_name":"Bash","tool_input":{"command":"cd state && cat private.txt"},"tool_response":"plain non-secret fixture text"}
JSON
if ! assert_verdict "$TMP_ROOT/bash-cwd-residual.json" sensitive_path; then
  fail "unresolved Bash directory context was not blocked"
fi

for directory in state config pipelines/health pipelines/health-manager pipelines/health-connect-sync pipelines/finance; do
  UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<JSON > "$TMP_ROOT/bash-cd.json"
{"tool_name":"Bash","tool_input":{"command":"cd $directory && cat private.txt"},"tool_response":"plain non-secret fixture text"}
JSON
  if ! assert_verdict "$TMP_ROOT/bash-cd.json" sensitive_path; then
    fail "Bash directory change into $directory was not blocked"
  fi
done

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/result-path.json"
{"tool_response":{"content":"Read from /workspace/state/private.txt: clean fixture data"}}
JSON
if ! assert_verdict "$TMP_ROOT/result-path.json" sensitive_path; then
  fail "sensitive source path in the post-execution result was not blocked"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/prose.json"
{"content":"The state and config contain health settings."}
JSON
if ! assert_verdict "$TMP_ROOT/prose.json" clean; then
  fail "ordinary prose was blocked as a sensitive basename"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/health.json"
{"messages":[{"role":"user","content":"I have diabetes and use insulin."}]}
JSON
if ! assert_verdict "$TMP_ROOT/health.json" health_data; then
  fail "common health data was not blocked independently of secret scanning"
fi

pass "jev outbound gate blocks secrets, private paths, and health text"
node --experimental-strip-types --test "$ROOT/tests/fm-jev-hook-guards.test.mjs"
