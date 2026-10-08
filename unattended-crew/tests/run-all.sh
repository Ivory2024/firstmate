#!/usr/bin/env bash
# run-all.sh - run every unattended-crew suite and persist raw evidence:
# per-suite stdout (with the real exit code), a command log, and an artifact
# manifest of sha256 hashes. The runner fails if any suite fails.
set -u
TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UC_ROOT=$(cd "$TESTS_DIR/.." && pwd)
EVID=${UC_EVIDENCE_DIR:-$UC_ROOT/evidence}
mkdir -p "$EVID/test-results"
: > "$EVID/command-log.jsonl"
export FM_UNATTENDED_ADAPTER=fake

SUITES="coordinator judge restart real-e2e"
FAIL=0
for s in $SUITES; do
  out="$EVID/test-results/$s.out"
  start=$(date +%s)
  bash "$TESTS_DIR/$s.test.sh" > "$out" 2>&1
  rc=$?
  end=$(date +%s)
  printf '{"suite":"%s","cmd":"bash tests/%s.test.sh","exit":%s,"duration_s":%s,"at":"%s","out":"test-results/%s.out"}\n' \
    "$s" "$s" "$rc" "$((end - start))" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$s" >> "$EVID/command-log.jsonl"
  tail -1 "$out" | sed 's/^/  /'
  [ "$rc" -eq 0 ] || FAIL=1
done

# artifact manifest of every evidence file
: > "$EVID/artifact-manifest.json"
for f in "$EVID/command-log.jsonl" "$EVID"/test-results/*.out; do
  [ -f "$f" ] || continue
  printf '{"path":"%s","sha256":"%s"}\n' "${f#"$UC_ROOT"/}" "$(shasum -a 256 "$f" | awk '{print $1}')" >> "$EVID/artifact-manifest.json"
done
echo "# run-all: $(grep -c '' "$EVID/command-log.jsonl") suites; fail=$FAIL"
exit "$FAIL"
