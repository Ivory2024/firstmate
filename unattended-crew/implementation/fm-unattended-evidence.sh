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
# Usage:
#   fm-unattended-evidence.sh run <run_id> -- <command...>
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
  cleanup) shift; cmd_cleanup "$@" ;;
  status) shift; cmd_status "$@" ;;
  *) echo "usage: fm-unattended-evidence.sh run <run_id> -- <cmd...> | cleanup <run_id> | status <run_id>" >&2; exit 2 ;;
esac
