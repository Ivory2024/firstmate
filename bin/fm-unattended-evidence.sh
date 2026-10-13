#!/usr/bin/env bash
# fm-unattended-evidence.sh - Evidence Collector for the unattended batch
# coordinator (Track A test lifecycle + Track B evidence collection).
#
# Evolved, in an isolated copy, from the prior batch's
# data/firstmate-fork-only-write-guard-20261008/evidence-system/evidence-runner.sh
# (sha256 recorded in evidence/artifact-manifest.json). Same contract: runs a
# command as a tracked test and records durable evidence OUTSIDE the suite
# workspace, and refuses to clean up a run whose tracked test process is still
# alive (the B1/B2 failure mode where the workspace was deleted mid-run).
#
# Additions over the original: optional FM_PATCH_SHA256 is recorded so the
# judge can detect a patch/hash mismatch, and optional FM_TEST_COUNT records
# the number of test cases the command claims to have run.
#
# Two collection modes produce the SAME on-disk evidence layout, so the judge
# is mode-agnostic:
#   run     -- one-shot command (fake backend / local tests). Captures the
#              command's stdout/stderr/exit directly.
#   collect -- a REAL firstmate crew session (interactive agent, no single
#              command to execute). Harvests the durable artifacts firstmate
#              already records: state/<id>.meta, state/<id>.status, the
#              fm-crew-state.sh line, the worker's report, the worktree SHA
#              before/after, an optional attested command log, and hashes them
#              into the same executor/ layout. A completion with no report or
#              with a non-`done` crew state is recorded as a nonzero rc, so the
#              judge refuses it.
#
# Usage:
#   fm-unattended-evidence.sh run <run_id> -- <command...>
#   fm-unattended-evidence.sh collect <run_id> --home H --spawn-id ID \
#         --workdir W [--report P] [--attest A] [--start-epoch N]
#   fm-unattended-evidence.sh cleanup <run_id>
#   fm-unattended-evidence.sh status <run_id>
set -u

ROOT=${EVIDENCE_ROOT:?set EVIDENCE_ROOT to a durable, out-of-workspace dir}
RUNS="$ROOT/runs"

_run_dir() { printf '%s/%s\n' "$RUNS" "$1"; }

cmd_run() { # <run_id> -- <command...>
  local id=$1; shift
  [ "${1:-}" = "--" ] && shift
  [ "$#" -gt 0 ] || { echo "error: no command" >&2; exit 2; }
  local d; d=$(_run_dir "$id"); mkdir -p "$d/executor/stdout" "$d/executor/stderr" "$d/gate"
  : > "$d/executor/command-log.jsonl"
  local start_epoch; start_epoch=$(date +%s)
  { printf '{"sha":"%s","branch":"%s","recorded_at":%s}\n' \
      "$(git -C "${GIT_DIR_FOR_RUN:-$PWD}" rev-parse HEAD 2>/dev/null || echo unknown)" \
      "$(git -C "${GIT_DIR_FOR_RUN:-$PWD}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)" \
      "$(date +%s)"; } > "$d/executor/git-before.json"
  local out="$d/executor/stdout/cmd.out" err="$d/executor/stderr/cmd.err" rc_file="$d/executor/rc"
  "$@" > "$out" 2> "$err" &
  local pid=$!
  printf '%s\n' "$pid" > "$d/executor/pid"
  printf '%s\n' "$start_epoch" > "$d/executor/start_epoch"
  printf '%s\n' "$PWD" > "$d/executor/wd"
  wait "$pid"; local rc=$?
  printf '%s\n' "$rc" > "$rc_file"
  local end_epoch; end_epoch=$(date +%s)
  printf '{"run_id":"%s","pid":%s,"start_epoch":%s,"end_epoch":%s,"duration_s":%s,"exit":%s,"cmd":"%s"}\n' \
    "$id" "$pid" "$start_epoch" "$end_epoch" "$((end_epoch - start_epoch))" "$rc" "$(printf '%s ' "$@")" \
    >> "$d/executor/command-log.jsonl"
  [ -n "${FM_PATCH_SHA256:-}" ] && printf '%s\n' "$FM_PATCH_SHA256" > "$d/executor/patch-hash"
  [ -n "${FM_TEST_COUNT:-}" ] && printf '%s\n' "$FM_TEST_COUNT" > "$d/executor/test-count"
  { printf '{"sha":"%s","recorded_at":%s}\n' \
      "$(git -C "${GIT_DIR_FOR_RUN:-$PWD}" rev-parse HEAD 2>/dev/null || echo unknown)" "$(date +%s)"; } \
    > "$d/executor/git-after.json"
  : > "$d/executor/artifact-manifest.json"
  local f
  for f in "$d/executor/command-log.jsonl" "$out" "$err" "$rc_file" "$d/executor/git-before.json" "$d/executor/git-after.json"; do
    [ -f "$f" ] && printf '{"path":"%s","sha256":"%s"}\n' "${f#"$d"/}" "$(shasum -a 256 "$f" | awk '{print $1}')" >> "$d/executor/artifact-manifest.json"
  done
  printf '{"run_id":"%s","exit":%s,"duration_s":%s}\n' "$id" "$rc" "$((end_epoch - start_epoch))" > "$d/executor/test-results.json"
  echo "ran $id exit=$rc duration=$((end_epoch - start_epoch))s evidence=$d"
  return "$rc"
}

cmd_collect() { # <run_id> --home H --spawn-id ID --workdir W [--report P] [--attest A] [--start-epoch N]
  local id=$1; shift
  local home='' spawn='' workdir='' report='' attest='' start=0
  while [ $# -gt 0 ]; do case "$1" in
    --home) home=$2; shift 2;; --spawn-id) spawn=$2; shift 2;; --workdir) workdir=$2; shift 2;;
    --report) report=$2; shift 2;; --attest) attest=$2; shift 2;; --start-epoch) start=$2; shift 2;;
    *) echo "collect: bad arg $1" >&2; exit 2;;
  esac; done
  [ -n "$home" ] && [ -n "$spawn" ] && [ -n "$workdir" ] || { echo "collect: need --home --spawn-id --workdir" >&2; exit 2; }
  local d; d=$(_run_dir "$id"); mkdir -p "$d/executor/stdout" "$d/executor/stderr" "$d/gate"
  local meta="$home/state/$spawn.meta" status="$home/state/$spawn.status"
  local crewstate=""; [ -x "$home/bin/fm-crew-state.sh" ] && crewstate=$("$home/bin/fm-crew-state.sh" "$spawn" 2>/dev/null || true)
  [ -n "$report" ] || { [ -f "$home/data/$spawn/report.md" ] && report="$home/data/$spawn/report.md"; }

  local rc=1
  printf '%s\n' "$crewstate" | grep -q '^state:[[:space:]]*done' && [ -n "$report" ] && [ -f "$report" ] && rc=0
  printf '%s\n' "$workdir" > "$d/executor/wd"
  printf '%s\n' "$rc" > "$d/executor/rc"
  [ -f "$meta" ]   && cp "$meta"   "$d/executor/meta.txt"
  [ -f "$status" ] && cp "$status" "$d/executor/status.txt"
  [ -n "$crewstate" ] && printf '%s\n' "$crewstate" > "$d/executor/crew-state.txt"
  [ -n "$report" ] && [ -f "$report" ] && cp "$report" "$d/executor/report.md"
  { [ -f "$d/executor/report.md" ] && cat "$d/executor/report.md"; [ -f "$d/executor/status.txt" ] && { echo "--- status ---"; cat "$d/executor/status.txt"; }; } > "$d/executor/stdout/cmd.out"
  : > "$d/executor/stderr/cmd.err"

  # the command log: the crew's attested commands when provided, else the
  # single dispatch event (a real agent is not one command).
  if [ -n "$attest" ] && [ -f "$attest" ]; then
    cp "$attest" "$d/executor/command-log.jsonl"
  else
    printf '{"run_id":"%s","spawn_id":"%s","start_epoch":%s,"end_epoch":%s,"exit":%s,"cmd":"fm-spawn.sh %s"}\n' \
      "$id" "$spawn" "$start" "$(date +%s)" "$rc" "$spawn" > "$d/executor/command-log.jsonl"
  fi
  [ -n "${FM_PATCH_SHA256:-}" ] && printf '%s\n' "$FM_PATCH_SHA256" > "$d/executor/patch-hash"
  [ -n "${FM_TEST_COUNT:-}" ] && printf '%s\n' "$FM_TEST_COUNT" > "$d/executor/test-count"

  # git-before is written by the coordinator at dispatch time; fall back to a
  # snapshot here so a direct collect never leaves the floor condition unmet.
  [ -f "$d/executor/git-before.json" ] || { printf '{"sha":"%s","branch":"%s","recorded_at":%s}\n' \
      "$(git -C "$workdir" rev-parse HEAD 2>/dev/null || echo unknown)" \
      "$(git -C "$workdir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)" "$(date +%s)" > "$d/executor/git-before.json"; }
  printf '{"sha":"%s","branch":"%s","recorded_at":%s}\n' \
    "$(git -C "$workdir" rev-parse HEAD 2>/dev/null || echo unknown)" \
    "$(git -C "$workdir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)" "$(date +%s)" > "$d/executor/git-after.json"

  : > "$d/executor/artifact-manifest.json"
  local f
  for f in "$d/executor/command-log.jsonl" "$d/executor/stdout/cmd.out" "$d/executor/stderr/cmd.err" "$d/executor/rc" \
           "$d/executor/git-before.json" "$d/executor/git-after.json" "$d/executor/meta.txt" "$d/executor/status.txt" \
           "$d/executor/crew-state.txt" "$d/executor/report.md"; do
    [ -f "$f" ] && printf '{"path":"%s","sha256":"%s"}\n' "${f#"$d"/}" "$(shasum -a 256 "$f" | awk '{print $1}')" >> "$d/executor/artifact-manifest.json"
  done
  printf '{"run_id":"%s","spawn_id":"%s","exit":%s,"report":"%s"}\n' "$id" "$spawn" "$rc" "$report" > "$d/executor/test-results.json"
  echo "collected $id exit=$rc spawn=$spawn crewstate=$(printf '%s' "$crewstate" | _normalize_crew_state) evidence=$d"
  return "$rc"
}

_normalize_crew_state() { sed -n 's/^state:[[:space:]]*\([a-z-]*\).*/\1/p' | head -1; }

cmd_status() { local d; d=$(_run_dir "$1"); echo "run $1: $([ -f "$d/executor/rc" ] && echo "exit=$(cat "$d/executor/rc")" || echo no-rc)"; }

cmd_cleanup() { # <run_id>
  local id=$1; local d; d=$(_run_dir "$id")
  local pid_file="$d/executor/pid"
  if [ -f "$pid_file" ]; then
    local pid; pid=$(cat "$pid_file")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "REFUSED: run $id test pid $pid is still alive; not cleaning up" >&2
      printf '{"run_id":"%s","action":"cleanup","verdict":"REFUSED_PROCESS_ALIVE","pid":%s}\n' "$id" "$pid" \
        > "$d/gate/verdict.json"
      exit 3
    fi
  fi
  if [ ! -f "$d/executor/rc" ]; then
    echo "REFUSED: run $id has no recorded exit code (incomplete evidence)" >&2
    printf '{"run_id":"%s","action":"cleanup","verdict":"REFUSED_NO_EXIT_CODE"}\n' "$id" > "$d/gate/verdict.json"
    exit 3
  fi
  rm -rf "$d"
  echo "cleaned $id"
}

case "${1:-}" in
  run) shift; cmd_run "$@" ;;
  collect) shift; cmd_collect "$@" ;;
  cleanup) shift; cmd_cleanup "$@" ;;
  status) shift; cmd_status "$@" ;;
  *) echo "usage: fm-unattended-evidence.sh run <run_id> -- <cmd...> | collect <run_id> --home H --spawn-id ID --workdir W [--report P] [--attest A] | cleanup <run_id> | status <run_id>" >&2; exit 2 ;;
esac
