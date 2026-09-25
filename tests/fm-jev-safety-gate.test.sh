#!/usr/bin/env bash
set -u

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$TEST_ROOT/.no-mistakes/jev-safety-tests"
TMPDIR="$TEST_ROOT/.no-mistakes/jev-safety-tests"
export TMPDIR
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-jev-safety-gate)

GUARD="$ROOT/.claude/jev-safety/check.py"
PROJECT="$ROOT/.claude/jev-safety"
UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/secret.json"
{"content":"test token ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
JSON
if ! grep -q '"reason":"secret"' "$TMP_ROOT/secret.json"; then
  fail "detect-secrets did not block a synthetic GitHub token"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/path.json"
{"paths":["data/captain.md"],"content":"plain non-secret fixture text"}
JSON
if ! grep -q '"reason":"sensitive_path"' "$TMP_ROOT/path.json"; then
  fail "sensitive path was not blocked independently of the secret scanner"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/learnings.json"
{"paths":["data/learnings.md"],"content":"plain non-secret fixture text"}
JSON
if ! grep -q '"reason":"sensitive_path"' "$TMP_ROOT/learnings.json"; then
  fail "home-local learnings path was not blocked independently of the secret scanner"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/backlog.json"
{"paths":["data/backlog.md"],"content":"plain non-secret fixture text"}
JSON
if ! grep -q '"reason":"sensitive_path"' "$TMP_ROOT/backlog.json"; then
  fail "backlog path was not blocked independently of the secret scanner"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/bash-cwd.json"
{"tool_name":"Bash","tool_input":{"command":"cat pipelines/health/patient.txt > /tmp/result.txt"},"tool_response":"plain non-secret fixture text"}
JSON
if ! grep -q '"reason":"sensitive_path"' "$TMP_ROOT/bash-cwd.json"; then
  fail "sensitive Bash path and redirection target were not blocked"
fi

for directory in state config; do
  UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<JSON > "$TMP_ROOT/bash-$directory.json"
{"tool_name":"Bash","tool_input":{"command":"ls $directory"},"tool_response":"plain non-secret fixture text"}
JSON
  if ! grep -q '"reason":"sensitive_path"' "$TMP_ROOT/bash-$directory.json"; then
    fail "direct Bash argument for $directory was not blocked"
  fi
done

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/bash-cwd-residual.json"
{"tool_name":"Bash","tool_input":{"command":"cd state && cat private.txt"},"tool_response":"plain non-secret fixture text"}
JSON
if ! grep -q '"reason":"clean"' "$TMP_ROOT/bash-cwd-residual.json"; then
  fail "documented shell-state residual changed unexpectedly"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/result-path.json"
{"tool_response":{"content":"Read from /workspace/state/private.txt: clean fixture data"}}
JSON
if ! grep -q '"reason":"sensitive_path"' "$TMP_ROOT/result-path.json"; then
  fail "sensitive source path in the post-execution result was not blocked"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/prose.json"
{"content":"The state and config contain health settings."}
JSON
if ! grep -q '"reason":"clean"' "$TMP_ROOT/prose.json"; then
  fail "ordinary prose was blocked as a sensitive basename"
fi

pass "jev outbound gate blocks synthetic secrets and excluded paths"
node --experimental-strip-types --test "$ROOT/tests/fm-jev-hook-guards.test.mjs"
