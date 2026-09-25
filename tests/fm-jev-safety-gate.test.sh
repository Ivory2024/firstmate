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

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/backlog.json"
{"paths":["data/backlog.md"],"content":"plain non-secret fixture text"}
JSON
if ! grep -q '"reason":"sensitive_path"' "$TMP_ROOT/backlog.json"; then
  fail "backlog path was not blocked independently of the secret scanner"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/bash-cwd.json"
{"tool_input":{"command":"cd data && cat captain.md; cd state && cat record; cd config && cat settings"},"tool_response":"plain non-secret fixture text"}
JSON
if ! grep -q '"reason":"sensitive_path"' "$TMP_ROOT/bash-cwd.json"; then
  fail "sensitive basenames in a Bash cd chain were not blocked"
fi

pass "jev outbound gate blocks synthetic secrets and excluded paths"
node --experimental-strip-types --test "$ROOT/tests/fm-jev-hook-guards.test.mjs"
