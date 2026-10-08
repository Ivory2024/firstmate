# Independent audit: firstmate test-structure survey (canary-01)

Task: independently re-derive the executor's test-structure counts and run commands in the firstmate repository, and state agreement or disagreement. Verdict line is at the top; full evidence below.

**Verdict: PASS** — every audited count and command reproduces exactly (244 top-level `tests/*.sh`, 234 `*.test.sh`, 10 helpers with identical names, 2 `.test.py`, 1 `.test.mjs`, runner `bin/fm-test-run.sh`). One prose discrepancy found outside the audited counts: the executor's section 3 says "14 families" while the actual `--list-families` output lists **15** (the executor's own table in that same section contains 15 rows summing to 234, so the table is right and the prose count is a miscount).

Audit date: 2026-10-08. Auditor worktree: `/Users/irene/.treehouse/firstmate-697ce1/15/firstmate`, detached HEAD `e70daed660f1f116c82b4fcd16e4e5d9510bd663` (`fix: enforce verified Git bases for spawn and publish (#107)`), clean before and after. This is a different session in a different worktree from the executor (executor worktree per meta: `/Users/irene/.treehouse/firstmate-697ce1/14/firstmate`, same commit `e70daed6`), so the counts are comparable.

## 1. Executor evidence read

- `/Users/irene/Developer/kunchenguid_repos/firstmate/data/firstmate-unattended-canary-01/report.md` — readable, 123 lines.
- `/Users/irene/Developer/kunchenguid_repos/firstmate/state/firstmate-unattended-canary-01.status` — readable; two entries: `working [at=1791452072]: spawned` and `done [at=1791452530]: survey complete - 244 top-level tests/*.sh (234 *.test.sh + 10 helpers, recursive identical) plus 2 .test.py and 1 .test.mjs; runner bin/fm-test-run.sh ...`.
- `/Users/irene/Developer/kunchenguid_repos/firstmate/state/firstmate-unattended-canary-01.meta` — readable (kind=scout, harness=opencode, worktree recorded as the 14/ tree).
- Note: the brief mentioned a `status` file inside `data/firstmate-unattended-canary-01/`; that file does not exist (the directory holds only `brief.md`, `launch-brief.md`, `report.md`). The durable status lives in `state/firstmate-unattended-canary-01.status` as above. Evidence was fully readable, so the audit is not UNAVAILABLE.

## 2. Re-derived counts (my commands, my worktree, same commit)

| Claim (executor report) | Executor | Auditor re-run | Match |
|---|---:|---:|---|
| `ls tests/*.sh \| wc -l` | 244 | 244 | yes |
| `ls tests/*.test.sh \| wc -l` | 234 | 234 | yes |
| `find tests -name '*.sh' \| wc -l` | 244 | 244 | yes |
| `find tests -name '*.test.sh' \| wc -l` | 234 | 234 | yes |
| `find tests -name '*.test.py' \| wc -l` | 2 | 2 | yes |
| `find tests -name '*.test.mjs' \| wc -l` | 1 | 1 | yes |
| `find tests -mindepth 1 -type d` | 3 dirs | same 3 dirs | yes |
| helper count (non-test `.sh`) | 10 | 10 | yes |

Exact re-run output:

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
$ ls tests/*.sh | grep -v '\.test\.sh$' | wc -l
10
```

The 10 helpers are the same files the executor named, verified by listing the complement:

```
tests/cmux-test-safety.sh      tests/git-config-helpers.sh      tests/lib.sh
tests/remote-herdr-fixture.sh  tests/fixtures.sh               tests/secondmate-helpers.sh
tests/wake-helpers.sh          tests/herdr-client-pair-fixture.sh
tests/herdr-test-safety.sh     tests/zellij-test-safety.sh
```

The 2 `.test.py` files are `tests/fm-backend-herdr-eventwait.test.py` and `tests/fm-bot-manager-poll.test.py`; the 1 `.test.mjs` is `tests/fm-jev-hook-guards.test.mjs` — all three filenames match the executor's report.

## 3. Runner and cross-checks

- `bin/fm-test-run.sh` exists and is executable (`-rwxr-xr-x`, 98,609 bytes) — the single suite runner, as claimed.
- Coverage guard reproduces byte-for-byte:
  ```
  $ bin/fm-test-run.sh --check-coverage
  FM_TEST_COVERAGE ok total=234 parallel=24 parallel_max_ms=417163 parallel_imbalance_ms=2894 parallel_unhinted=0 serial=194 serial_shards=9 serial_unhinted=18 herdr=16
  ```
  Identical to the executor's quoted line, including `total=234`.
- Proven-isolated set: `bin/fm-test-isolation-proof.sh --list | wc -l` → 24, matching the executor's "24-script" claim.
- Per-family counts: `bin/fm-test-run.sh --list --family <name> | wc -l` for all families reproduces the executor's table exactly, and the counts sum to 234:
  pure-contract-unit=40, watcher-wake-lock=22, real-herdr-gated=16, secondmate=22, session-bootstrap=11, live-harness-optin=33, backend-dispatch=18, pr-forge=8, afk=3, snapshot-bearings=5, cmux=2, zellij=2, orca=1, standalone=30, unclassified=21.
- Spot-checked line references all accurate: `CONTRIBUTING.md:95` (bounded-concurrency guidance), `:121` (runner single-owner sentence), `:133` (self-contained `<subject>.test.sh` description); `bin/fm-test-run.sh:98-105` (primary-checkout placement refusal), `:114-117` (gate-skip classes herdr/optional-binary/live-capability/none), `:126-131` ("estimates, not measured job wall times"); `tests/fm-bot-manager-poll.test.sh:6` (`python3 "$SCRIPT_DIR/fm-bot-manager-poll.test.py"`); `tests/lib.sh:293` (`fm_live_gate() {`).
- Re-ran the executor's representative command on this host: `bin/fm-test-run.sh tests/fm-brief.test.sh` → `FM_TEST_END ... exit=0 duration_ms=8845`, `FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=8935`, `FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=1 duration_ms=8845 failed=0`. Consistent with the executor's measured 8,913 ms for the same script (same commit; per-host timing noise expected and the executor labeled local-vs-CI timing as non-interchangeable).

## 4. Discrepancy found (outside the audited counts)

Executor report section 3 opens with: "`bin/fm-test-run.sh --list-families` → 14 families". Actual output lists **15** families (`wc -l` = 15; the 15 names are listed in section 3 above). The executor's own family table in that same section contains 15 rows whose script counts sum to 234, matching the coverage guard's `total=234` — so the table and every downstream figure are correct; only the prose number "14" is a miscount. Impact: none on the audited test-file counts, the runner, or the CI lane description. If the report is revised, change "14 families" to "15 families".

No other disagreement found: counts, commands, filenames, directory structure, line references, and the coverage guard all reproduce.

## 5. Scope compliance and completion gate

- Read-only audit. No tracked file modified; nothing written under the executor's workspace; no push, no PR. The only files written by this audit are this report and the task status file `state/firstmate-unattended-canary-01-audit.status`.
- Captain-hold lifecycle completion gate (`/Users/irene/Developer/kunchenguid_repos/firstmate/.agents/skills/captain-hold-lifecycle/SKILL.md`, read 2026-10-08): inventory of this report found no unresolved captain call — no product choice, destructive action, or open decision is left for the captain; the one finding (prose miscount) is an evidence-backed factual correction, not a decision. Ran `FM_HOME=/Users/irene/Developer/kunchenguid_repos/firstmate bin/fm-captain-hold.sh complete firstmate-unattended-canary-01-audit --none` → `complete: firstmate-unattended-canary-01-audit captain-call inventory reviewed` (exit 0). The shared completion gate passes with nothing held.

## 6. Recommendation

The executor's survey is accurate and reproducible: reuse its counts, commands, and runtime measurements with confidence. Apply the single one-word correction ("14 families" → "15 families") if the report is edited; no ship work is warranted by this audit.
