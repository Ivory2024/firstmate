# Unattended crew orchestrator — implementation status

Batch: 2026-10-08. Baseline SHA `5f4a10281937c4999138d61b945589d829c25d34`
(`Ivory2024/firstmate`). Isolated branch `fm/unattended-crew-orchestrator-20261008`.
All work is under `unattended-crew/` in an isolated worktree; **no firstmate home,
tracked file, watcher, credential, or GitHub state was changed**, and no real
worker/provider was called.

## Completion axes

| Axis | Status | Basis |
|---|---|---|
| Implementation | **IMPLEMENTED** | coordinator (fake + real backends), adapter (fake + real), evidence collector (`run` + `collect`), judge, fake auditor, real audit harvest, contracts, mock home all present and executable |
| Verification | **LOCALLY_TESTED** (49/49) + **INDEPENDENTLY_VERIFIED** (real audit, prior canary only) | 49/49 checks green incl. 19 real-E2E cases; 10/10 separate local verification process. The real separate-session AI audit happened in the PRIOR canary batch; this batch ran no AI audit, so its real-E2E is not claimed independently verified |
| Integration | **REAL_E2E_READY_FOR_CANARY** + **INTEGRATION_HOLD** (live unattended real E2E) | the real path is wired dispatch→ACK→evidence→separate auditor→judge→handoff and proven offline against the recorded fixture; the actual provider call is gated |

Real canary result: `canary/canary-report.md` (verdict `CANARY_VERIFIED_PASS`).
Real-E2E integration detail: `handoff/real-e2e-integration-status.md`.
Not claimed: `DEPLOYED` (G4 not approved), `REAL_E2E_VERIFIED` (no live run yet).

## What was built

- `implementation/fm-unattended.sh` — batch coordinator (durable idempotent state machine).
- `implementation/fm-unattended-adapter.sh` — crew dispatch adapter (fake backend + real seam).
- `implementation/fm-unattended-evidence.sh` — evidence collector (evolved from the prior batch).
- `implementation/fm-unattended-judge.sh` — deterministic judge (evolved from the prior batch).
- `implementation/fake-auditor.sh` — separate-process, protocol-only auditor (marked fake).
- `contracts/task-contract.schema.json`, `contracts/state-machine.md`.
- `architecture/firstmate-integration-map.md`, `architecture/pstack-adaptation.md`.
- Tests: `tests/coordinator.test.sh` (12), `tests/judge.test.sh` (11), `tests/restart.test.sh` (7), `tests/real-e2e.test.sh` (19) + `tests/mockhome/` (recorded-fixture test double) + `verification/verify-local.sh`.

## Verification evidence

- `evidence/command-log.jsonl` — 3 suites, exit 0 each.
- `evidence/test-results/*.out` — raw suite output (30 ok, 0 not ok).
- `evidence/artifact-manifest.json` — sha256 of every evidence file.
- `audit/findings.md`, `audit/audit-status.json` — separate-process audit: PASS,
  manifest identity verified, 30/30 cases reproduced.
- `bin/fm-lint.sh` on all five scripts: exit 0, 0 findings (ShellCheck 0.11.0).

## Fake-backend E2E (Phase D)

Normal path: contract → dispatch → ACK → RUNNING → evidence → separate-workspace
audit → judge → `VERIFIED_PASS` → next task; dependency ordering honoured.
Failure paths covered: missing ACK, worker failure + retry exhaustion, interrupted
worker, session identity mismatch, duplicate completion/wake idempotency, missing
audit, audit conflict, forbidden write, hash mismatch, same workspace, incomplete
tests, approval-required hold, no-safe-next-task, and cleanup-refusal while a test
is alive.

## Real-backend E2E (Phase F, this batch)

The `real` backend is driven end to end with no provider call by pointing the
adapter's real primitives at `tests/mockhome/`, a test double that replays the
recorded canary fixture. Covered: spawn refusal, dead endpoint (no ACK), missing
completion event, worker failure, evidence incomplete, evidence tamper → HOLD,
auditor spawn failure (bounded retry, no executor re-run), missing audit verdict
→ `AUDIT_UNAVAILABLE`, auditor conflict, same-workspace, coordinator SIGKILL +
resume (adopt, no duplicate dispatch), approval-required hold, and the
fake-auditor-in-production block on both backends.

## Restart / pickup (Phase E)

A SIGKILLed coordinator mid-execution resumes from durable state: the live run is
adopted (one executor session, no duplicate dispatch), evidence persists across the
process boundary, a finished batch is a no-op on resume, and a task parked at
`AUDIT_PENDING` can never be completed without its audit.

## Unchanged firstmate surface

`git status` in the isolated worktree shows only new files under `unattended-crew/`.
No existing firstmate suite is affected because no firstmate code changed; fm-lint
was run directly on the new scripts to prove they meet the repo's lint gate.
