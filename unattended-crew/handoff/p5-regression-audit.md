# P5 — Regression + new tests audit

Date: 2026-10-08. Isolated worktree only; no home/project/GitHub change.

## Summary

| Metric | Before | After |
|---|---|---|
| Suite runner | `bash tests/run-all.sh` | same |
| Suites | 6 | **10** |
| Cases passed | 78 | **127** |
| Cases failed | 0 | **0** |
| Separate local verification | 11 ok / 0 fail | **16 ok / 0 fail** |
| shellcheck (implementation + new bin) | clean | **clean (exit 0)** |
| `bash -n` on all new/changed scripts | — | **clean** |
| `verification/check-drift.sh` | 0 drifted | **0 drifted** |

No test was deleted, skipped, or weakened to manufacture a pass. All six original
suites are byte-for-byte unchanged and still pass; the four new suites only add
coverage.

## Commands, exit codes, per-suite results

### `bash tests/run-all.sh` → exit 0

```
# coordinator.test.sh PASS=12 FAIL=0
# judge.test.sh PASS=11 FAIL=0
# guard.test.sh PASS=17 FAIL=0
# restart.test.sh PASS=7 FAIL=0
# real-e2e.test.sh PASS=24 FAIL=0
# pr-classify.test.sh PASS=7 FAIL=0
# evidence-root.test.sh PASS=11 FAIL=0      <-- new
# quota.test.sh PASS=13 FAIL=0             <-- new
# entrypoint.test.sh PASS=14 FAIL=0        <-- new
# autoteardown.test.sh PASS=11 FAIL=0      <-- new
# run-all: 10 suites; fail=0
```

Old total: 12 + 11 + 17 + 7 + 24 + 7 = **78**. New total: 78 + 11 + 13 + 14 + 11 = **127**.

### `bash verification/verify-local.sh` → exit 0

```
ok   full suite exit 0
ok   suite coordinator has 0 failures
ok   suite judge has 0 failures
ok   suite guard has 0 failures
ok   suite restart has 0 failures
ok   suite real-e2e has 0 failures
ok   suite pr-classify has 0 failures
ok   suite evidence-root has 0 failures
ok   suite quota has 0 failures
ok   suite entrypoint has 0 failures
ok   suite autoteardown has 0 failures
tally: 127 passed, 0 failed
ok   clean production audit => VERIFIED_PASS
ok   tampered evidence => HOLD
ok   production + fake backend (no real audit) => HOLD
ok   real adapter reuses fm-spawn/fm-crew-state/fm-send
ok   implementation calls no provider CLI directly
local verification: 16 ok, 0 fail
{"check":"local-independent-verify","ok":16,"fail":0,"total":16,"at":"2026-10-08T12:48:36Z","independent_ai_audit":false}
```

`verify-local.sh` was extended to tally the four new suites (the independent checks
are unchanged). `independent_ai_audit:false` is preserved: this is a separate local
process, not an AI audit.

### `bash verification/check-drift.sh` → exit 0

`check-drift: 0 drifted`.

### `shellcheck -x` → exit 0

```
shellcheck -x implementation/fm-unattended-config.sh \
  implementation/fm-unattended-quota.sh \
  implementation/fm-unattended-autoteardown.sh \
  implementation/fm-unattended.sh \
  bin/fm-unattended.sh bin/fm-unattended-install.sh
# exit 0
```

### `bash -n` → exit 0 on every new/changed script.

## Test-seam note

`bin/fm-unattended-install.sh` supports `FM_UNATTENDED_INSTALL_FAIL_AT=<n>` to
deterministically exercise the partial-install rollback path (the one requirement
that cannot be reached without fault injection). It is inert unless the env var is
set, and the test asserts full rollback (no manifest, no leftover files).

## New suites cover

- `tests/evidence-root.test.sh` — default canary path + config root + `UC_EVIDENCE_ROOT`,
  mode 0700, `.batch` marker, collision, `..` escape, file-as-root, `--no-create`
  fail-closed, bad batch id, restart re-read (env unset).
- `tests/quota.test.sh` — free allow-list, paid refusal, unknown-model HOLD, paid
  approval, provider-call cap, concurrency cap, release, unknown-cap HOLD, real-path
  integration (block before spawn, HOLD latch, within-budget pass, paid block, unknown
  HOLD).
- `tests/entrypoint.test.sh` — role refusal, pass-through run, file list, install +
  verify, mounted layout resolves, uninstall + idempotent re-run, no-overwrite,
  idempotent re-install, user-modified preservation, injected partial-install
  rollback, rehearsal, unsafe-root and missing-root refusal.
- `tests/autoteardown.test.sh` — disabled default, all-six-conditions OK, and a
  refusal for each broken condition (non-terminal, evidence, verdict, inbox, captain
  call, session ownership, session missing, other active work), plus `plan`.

## Known limitation

The new suites exercise the **fake backend / mock home**; the quota integration cases
use the mock home (no provider call). A live single-run canary from the mounted
entrypoint remains the P4/P5 next step (separate approval), consistent with the
existing "mock never substitutes for real" rule in `verification/verification-map.md`.
