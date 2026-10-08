# Firstmate test-structure survey (read-only canary)

Task: `firstmate-unattended-real-e2e-canary-20261008` (scout, read-only)
Surveyed: commit `e70daed660f1f116c82b4fcd16e4e5d9510bd663` — "fix: enforce verified Git bases for spawn and publish (#107)" (2026-10-08 16:37:07 +0900)
Worktree: `/Users/irene/.treehouse/firstmate-697ce1/14/firstmate` (disposable, detached HEAD, clean — `git status --short --branch` showed no modifications before or after the run)
Environment: GNU bash, version 5.3.20(1)-release (aarch64-apple-darwin25.6.0), macOS darwin

No tracked file was modified. No push, no PR, no contact with any remote. Only writes outside the worktree: this report and the task status file.

## 1. Test file counts

Command and output (from the worktree root):

```
$ echo "TOPLEVEL_SH=$(ls -1 tests/*.sh 2>/dev/null | wc -l | tr -d ' ')"
TOPLEVEL_SH=244
$ echo "RECURSIVE_SH=$(find tests -name '*.sh' -type f | wc -l | tr -d ' ')"
RECURSIVE_SH=244
$ echo "RECURSIVE_ALL=$(find tests -type f | wc -l | tr -d ' ')"
RECURSIVE_ALL=258
$ echo "RECURSIVE_PY=$(find tests -name '*.py' -type f | wc -l | tr -d ' ')"
RECURSIVE_PY=3
$ ls -1 tests/*.test.sh | wc -l
234
```

- **Top-level `tests/*.sh`: 244**
- **Recursive `find tests -name '*.sh'`: 244** — every shell test/helper lives at the top level; no test scripts in subdirectories.
- Of the 244: **234 are suites** (`*.test.sh`), **10 are shared helpers** (`cmux-test-safety.sh`, `fixtures.sh`, `git-config-helpers.sh`, `herdr-client-pair-fixture.sh`, `herdr-test-safety.sh`, `lib.sh`, `remote-herdr-fixture.sh`, `secondmate-helpers.sh`, `wake-helpers.sh`, `zellij-test-safety.sh`).
- Total files under `tests/`: 258 = 244 `.sh` + 3 `.py` (`fm-backend-herdr-eventwait.test.py`, `fm-bot-manager-poll.test.py`, `fm-turnend-foreign-owner-repro.py`) + 11 non-shell fixtures (2 `.mjs`: `assets/board-render-harness.mjs`, `fm-jev-hook-guards.test.mjs`; 9 capture/fixture files under `captures/no-mistakes-v1.70.1/`).
- Subdirectories: `tests/assets`, `tests/captures`, `tests/captures/no-mistakes-v1.70.1` — fixtures only, no test scripts.

## 2. Runner entrypoints

Single owner of behavior-test execution: **`bin/fm-test-run.sh`** (98,609 bytes). From its header (`bin/fm-test-run.sh:4-31`) and `CONTRIBUTING.md:95-133`:

```
bin/fm-test-run.sh tests/<subject>.test.sh              # one script (primary local focus path, timed)
bin/fm-test-run.sh tests/<a>.test.sh tests/<b>.test.sh  # several subjects: bounded automatic concurrency
bin/fm-test-run.sh --family pure-contract-unit          # family-scoped local path (serial, timed)
bin/fm-test-run.sh --changed                          # changed-file-informed path, automatic bounded concurrency
bin/fm-test-run.sh --proven-isolated --jobs 4         # explicit local parallel of the individually proven set
bin/fm-test-run.sh --lane portable-serial             # portable serial remainder
bin/fm-test-run.sh --list-lanes                       # exact lane names, incl. CI serial shards
bin/fm-test-run.sh --check-coverage                   # prove shards + serial + Herdr equal the full inventory
bin/fm-test-run.sh --all                              # deliberate complete regression (optional)
```

Discovery convention (`CONTRIBUTING.md:133`): list `tests/*.test.sh`; each is a self-contained bash script named `<subject>.test.sh` whose header comment describes its coverage. Shared helpers: `tests/lib.sh` (reporters, temp roots, git fixtures), `tests/fixtures.sh`, `tests/wake-helpers.sh`, `tests/secondmate-helpers.sh`, `tests/git-config-helpers.sh`.

## 3. Representative suite run

Exact command:

```
$ start=$(date +%s); bin/fm-test-run.sh tests/fm-brief.test.sh; ec=$?; end=$(date +%s)
```

Full output (verbatim):

```
FM_TEST_BEGIN 2026-10-08T10:39:07Z tests/fm-brief.test.sh family=pure-contract-unit expected_gate_skip=none
ok - fm-brief: scaffolds leave the worker role scope to the launch boundary and keep the secondmate contract
ok - fm-brief.sh: bash -n succeeds
ok - fm-brief.sh: no heredoc is nested inside a command substitution (Bash 3.2 parse-safe)
ok - fm-brief.sh: --help renders the complete header
ok - fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly
ok - fm-brief.sh: ship --mode is required and closed-set validated
ok - fm-brief.sh: the explicit ship mode wins over the registered posture
ok - fm-brief.sh: --yolo and scout/secondmate --mode are refused, never silently dropped
ok - fm-brief.sh: faster paths use configured authority without stacked review
ok - fm-brief.sh: no-mistakes DOD keeps its apostrophe prose and bans --yes outright
ok - fm-brief.sh: no-mistakes ask-user findings use one event plus a verbatim snapshot
ok - fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar
ok - fm-brief.sh: --herdr-lab emits the complete hard safety contract
ok - fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path
ok - fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible
ok - fm-brief.sh: the documented {TASK} and {FIRSTMATE_SPEC} fills cannot corrupt the Herdr safety gate
ok - fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse
ok - fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse
ok - fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting
ok - fm-brief.sh: relative directory inputs ignore CDPATH, render stable absolute charter paths, or fail loudly
ok - fm-brief.sh: custom pause verb renders in every scaffold
ok - fm-brief.sh: ship and scout scaffolds teach validation-round pauses
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy
ok - fm-brief: scout and secondmate code paths still scaffold well-formed briefs
ok - fm-brief.sh: scout Lavish hosting follows the bootstrap lavish-axi floor
FM_TEST_END 2026-10-08T10:39:16Z tests/fm-brief.test.sh exit=0 duration_ms=9072 gate_skip=false
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=9172
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=1 duration_ms=9072 failed=0
FM_TEST_SLOWEST rank=1 script=tests/fm-brief.test.sh duration_ms=9072
```

- **Exit code: 0**
- **Duration: 9 s wall clock** (`date +%s` 1791455947 → 1791455956); runner-reported `duration_ms=9072` (script) / `9172` (total).
- Result: 25/25 test cases ok, 0 failed, 0 gate-skipped; family `pure-contract-unit`.

Note from the suite header (`tests/fm-brief.test.sh:14-19`): ambient `bash -n` here runs Bash 5, which cannot see the historical Bash 3.2 heredoc-in-command-substitution parse bug; cross-version enforcement lives in the `macos-stock-bash` CI job. This is a property of the suite design, not a failure.

## 4. Findings and recommendation

- Structure is uniform and healthy: one runner (`bin/fm-test-run.sh`) owns selection, lane composition, bounded concurrency, timing, and the coverage guard; 234 self-contained suites follow one naming convention (`<subject>.test.sh`); all 244 shell files sit at the top level; helpers are centralized in 10 named files.
- The representative suite ran green in 9 s with exit 0.
- Nothing here requires a captain decision, code change, or follow-up work. Informational report only; the test inventory and runner contract are in good shape.
