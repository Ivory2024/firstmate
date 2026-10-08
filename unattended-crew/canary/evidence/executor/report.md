# Firstmate test-structure survey (read-only)

Task: survey the firstmate repository's test structure — count test files under `tests/` (top-level and recursive), identify test-runner entrypoints, and state representative run commands with measured or clearly-labeled estimated runtimes. Read-only: no tracked file was modified; the only writes were this report and the task status file.

Survey date: 2026-10-08. Worktree: disposable git worktree of firstmate, detached HEAD at `e70daed6` (`fix: enforce verified Git bases for spawn and publish (#107)`), clean status before and after.

## 1. Test file counts

Commands and output:

```
$ ls tests/*.sh | wc -l
244
$ ls tests/*.test.sh | wc -l
234
$ find tests -name '*.sh' | wc -l
244
$ find tests -name '*.test.sh' | wc -l
234
$ find tests -name '*.test.py' | wc -l
2
$ find tests -name '*.test.mjs' | wc -l
1
$ find tests -mindepth 1 -type d
tests/captures
tests/captures/no-mistakes-v1.70.1
tests/assets
```

Findings:

- **Top level: 244 `.sh` files**, of which **234 are test scripts** (`*.test.sh`). The remaining 10 are shared test helpers, not runnable suites: `tests/lib.sh`, `tests/fixtures.sh`, `tests/git-config-helpers.sh`, `tests/wake-helpers.sh`, `tests/secondmate-helpers.sh`, `tests/cmux-test-safety.sh`, `tests/herdr-test-safety.sh`, `tests/herdr-client-pair-fixture.sh`, `tests/remote-herdr-fixture.sh`, `tests/zellij-test-safety.sh`.
- **Recursive count equals the top-level count** (244 / 234): the only subdirectories are `tests/assets/` and `tests/captures/` (fixture data), which contain no shell scripts.
- Non-shell test assets: 2 `*.test.py` (`fm-bot-manager-poll.test.py`, `fm-backend-herdr-eventwait.test.py`) and 1 `*.test.mjs` (`fm-jev-hook-guards.test.mjs`). These are driven by or exercised through sibling `.test.sh` wrappers (e.g. `tests/fm-bot-manager-poll.test.sh:6` runs `python3 "$SCRIPT_DIR/fm-bot-manager-poll.test.py"`), so the runner's suite inventory is the 234 `.test.sh` files.
- The runner's own coverage guard agrees: `FM_TEST_COVERAGE ok total=234 parallel=24 parallel_max_ms=417163 parallel_imbalance_ms=2894 parallel_unhinted=0 serial=194 serial_shards=9 serial_unhinted=18 herdr=16`.

## 2. Test-runner entrypoints

- **`bin/fm-test-run.sh`** — the single owner of suite selection, execution, lane composition, concurrency admission, timing markers, and coverage guarding (header lines 1-4; `CONTRIBUTING.md:121`). Selection modes (exactly one): `--all`, `--family <name>`, `--changed [--base <ref>]`, `--lane <lane>`, `--proven-isolated`, or explicit `tests/<name>.test.sh` paths. Inspection-only modes: `--list`, `--list-scheduled`, `--list-families`, `--list-lanes`, `--list-concurrent-safe-families`, `--check-coverage`. Per-script machine markers: `FM_TEST_BEGIN` / `FM_TEST_END ... duration_ms=`; summary lines `FM_TEST_SUMMARY` / `FM_TEST_SUMMARY_FAMILY` / `FM_TEST_SLOWEST`.
- **`tests/*.test.sh`** — 234 self-contained bash scripts, one per subject (`<subject>.test.sh`); each header comment states what it covers (`CONTRIBUTING.md:133`). Each sources shared primitives from `tests/lib.sh` (ok/not-ok reporters, self-cleaning temp root, fakebin/PATH shims, git-identity and fixture builders, assertions — `tests/lib.sh:1-20`).
- Supporting: `bin/fm-test-isolation-proof.sh` owns the 24-script proven-isolated set (`bin/fm-test-isolation-proof.sh --list | wc -l` → 24); `tests/lib.sh` provides `fm_live_gate` (`tests/lib.sh:293`) for live-capability families, whose unavailable tools are recorded as gate-skips rather than failures.
- Gate-skip classes (runner header lines 114-117): `herdr` (pinned real-Herdr lane), `optional-binary`, `live-capability`, `none`. A `skip:` first line is a successful gate-skip, counted as `skipped_gate`.
- Safety: the runner refuses executing modes when a task worker (`FM_TASK_ID`) resolves to the repository's primary checkout, because suites create and switch branches (header lines 98-105). All measurements below were run from the disposable worktree, as required.

## 3. Families and CI lanes

`bin/fm-test-run.sh --list-families` → 14 families; per-family script counts (from `--list --family`) and CI-duration-hint sums (hints stored in `bin/fm-test-run.sh` `portable_serial_weight_hints`/`portable_parallel_weight_hints`, refreshed from CI timing artifacts per `docs/fm-test-portable-shards.md`):

| Family | Scripts | CI-hint sum (estimate) |
|---|---:|---:|
| pure-contract-unit | 40 | ~988 s |
| watcher-wake-lock | 22 | ~1,350 s |
| real-herdr-gated | 16 | own pinned-Herdr lane (no portable hints) |
| secondmate | 22 | ~1,227 s |
| session-bootstrap | 11 | ~622 s |
| live-harness-optin | 33 | ~16 s (mostly gate-skips without live tools) |
| backend-dispatch | 18 | ~543 s |
| pr-forge | 8 | ~519 s |
| afk | 3 | ~72 s |
| snapshot-bearings | 5 | ~274 s |
| cmux | 2 | ~3.5 s |
| zellij | 2 | ~9 s |
| orca | 1 | ~23 s |
| standalone | 30 | ~934 s |
| unclassified | 21 | ~39 s (13 unhinted) |

CI lane structure (`bin/fm-test-run.sh --list-lanes`, `.github/workflows/ci.yml`, `docs/fm-test-portable-shards.md`):

- `portable-parallel-1` and `portable-parallel-2`: the 24 proven-isolated scripts, LPT-packed from measured hints; larger lane hint sum 417,163 ms (~7 min), imbalance 2,894 ms.
- `portable-serial` plus 9 CI shards (`portable-serial-1of9` … `portable-serial-9of9`): the 194 remaining portable scripts, serial per shard. The unsplit remainder historically accumulated 19m04s of script time against a 20-minute job timeout (green run 30725985757, per `docs/fm-test-portable-shards.md` "Portable serial CI shards").
- `real-herdr-gated`: 16 scripts in a dedicated lane with pinned Herdr install; healthy runs finish in about 7-10 minutes (three-tier timeout policy, `docs/fm-test-portable-shards.md` "Timeouts": fast tier 5 min, normal tier 30 min, Herdr 20-min step tripwire under a 75-min job backstop).
- Hint totals: serial table 5,787 s across 176 hinted serial scripts (18 unhinted fall back to a default weight); parallel table 831 s across 24 scripts; all hints together ~6,619 s. These are CI-derived balance hints, explicitly "estimates, not measured job wall times" (runner header lines 126-131).

## 4. Representative commands and measured runtimes

Documented local entrypoints (`CONTRIBUTING.md:95-133`):

```
bin/fm-test-run.sh tests/<subject>.test.sh        # one script (primary local focus path, timed)
bin/fm-test-run.sh tests/<a>.test.sh tests/<b>.test.sh  # several: bounded automatic concurrency
bin/fm-test-run.sh --family pure-contract-unit    # family-scoped local path (serial, timed)
bin/fm-test-run.sh --changed                      # changed-file-informed, automatic bounded concurrency
bin/fm-test-run.sh --proven-isolated --jobs 4     # explicit local parallel of the proven set
bin/fm-test-run.sh --lane portable-serial         # portable serial remainder
bin/fm-test-run.sh --all                          # deliberate complete regression (optional)
```

Measured on this host (macOS Darwin 27.0.0, aarch64, 10 CPUs, GNU bash 5.3.20, tmux 3.7c present; run from the disposable worktree):

1. Single representative script:
   ```
   $ time bin/fm-test-run.sh tests/fm-brief.test.sh
   FM_TEST_END 2026-10-08T09:37:24Z tests/fm-brief.test.sh exit=0 duration_ms=8823 gate_skip=false
   FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=8913
   FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=1 duration_ms=8823 failed=0
   2.89s user 3.54s system 71% cpu 8.964 total
   ```
   **Measured: 8.9 s wall** (runner-reported 8,913 ms). Its stored CI hint is 1,625 ms, so this script ran ~5.4x its CI hint locally — local macOS timings are not interchangeable with CI timings (`docs/fm-test-portable-shards.md` "Verification inputs").

2. Representative family suite:
   ```
   $ time bin/fm-test-run.sh --family afk
   FM_TEST_END 2026-10-08T09:39:52Z tests/fm-afk-return.test.sh exit=0 duration_ms=33777 gate_skip=false
   FM_TEST_SUMMARY total=3 failed=0 skipped_gate=0 duration_ms=87495
   FM_TEST_SUMMARY_FAMILY family=afk count=3 duration_ms=86666 failed=0
   FM_TEST_SLOWEST rank=1 script=tests/fm-afk-inject-e2e.test.sh duration_ms=33995
   18.19s user 30.08s system 55% cpu 1:27.53 total
   ```
   **Measured: 1 m 27 s wall, 3/3 passed** (runner-reported 87,495 ms) against a CI-hint sum of ~72 s (~1.2x CI on this host).

3. Full-suite expectation (estimate, labeled): a serial `bin/fm-test-run.sh --all` totals ~6,619 s (~110 min) of stored CI hints, plus 18 unhinted serial scripts at the default weight; on this host expect a multiple of that (observed per-script local/CI ratio ranged 1.2x-5.4x in the two samples above). CI wall time is far lower because the work is split: two parallel shards (~7 min each, concurrent jobs), the serial remainder across 9 shards (~19 min of script time divided by 9), and the Herdr lane (~7-10 min) — all running as separate CI jobs in parallel.

## 5. Recommendation

- For a quick focused check: `bin/fm-test-run.sh tests/<subject>.test.sh` — seconds to ~1.5 min depending on the subject (measured 8.9 s for `fm-brief`).
- For a representative suite slice: `bin/fm-test-run.sh --family <name>` — from ~4 s (`cmux`) to ~20+ min (`watcher-wake-lock`, `secondmate`, `pure-contract-unit` by CI hints); `--family afk` measured 1 m 27 s.
- For changed-file work: `bin/fm-test-run.sh --changed` (bounded automatic concurrency, serial by default).
- Budget a full local regression (`--all`) at roughly 2 hours on this host; rely on the CI lane split for the complete pass.

## 6. Scope compliance and completion gate

- No tracked file modified; no push, no PR, nothing written under `projects/` or the firstmate `state/` settings. Commands run: the counting commands in section 1, inspection modes of `bin/fm-test-run.sh` (`--list-families`, `--list-lanes`, `--list-concurrent-safe-families`, `--list --family <name>`, `--check-coverage`), `bin/fm-test-isolation-proof.sh --list`, and the two measured executions in section 4.
- Captain-hold lifecycle completion gate (`captain-hold-lifecycle` SKILL.md, read 2026-10-08): the report was inventoried for unresolved captain calls. It contains none — no product choice, destructive action, or open decision is left for the captain; every runtime figure is either measured above or labeled a CI-derived estimate. The shared completion gate passes with nothing held.
