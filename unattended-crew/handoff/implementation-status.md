# Unattended crew orchestrator — implementation status

Batch: 2026-10-08. Baseline SHA `5f4a10281937c4999138d61b945589d829c25d34`
(`Ivory2024/firstmate`). Isolated branch `fm/unattended-crew-orchestrator-20261008`.
All work is under `unattended-crew/` in an isolated worktree; **no firstmate home,
tracked file, watcher, credential, or GitHub state was changed**, and no real
worker/provider was called.

## Completion axes

| Axis | Status | Basis |
|---|---|---|
| Implementation | **IMPLEMENTED** | coordinator, adapter, evidence collector, judge, fake auditor, contracts all present and executable |
| Verification | **LOCALLY_TESTED** + **AUDIT_UNAVAILABLE** (real AI audit) | 30/30 checks green across 3 suites; a separate OS process re-verified; no real Codex/Claude audit ran |
| Integration | **FAKE_BACKEND_E2E_PASS** + **INTEGRATION_HOLD** (real crew) | full fake-backend E2E passed; the `real` adapter backend refuses with `INTEGRATION_HOLD` |

Not claimed: `INDEPENDENTLY_VERIFIED` (no real AI audit), `REAL_CREW_INTEGRATED`
(no real dispatch), `DEPLOYED` (operational application is an approval gate).

## What was built

- `implementation/fm-unattended.sh` — batch coordinator (durable idempotent state machine).
- `implementation/fm-unattended-adapter.sh` — crew dispatch adapter (fake backend + real seam).
- `implementation/fm-unattended-evidence.sh` — evidence collector (evolved from the prior batch).
- `implementation/fm-unattended-judge.sh` — deterministic judge (evolved from the prior batch).
- `implementation/fake-auditor.sh` — separate-process, protocol-only auditor (marked fake).
- `contracts/task-contract.schema.json`, `contracts/state-machine.md`.
- `architecture/firstmate-integration-map.md`, `architecture/pstack-adaptation.md`.
- Tests: `tests/coordinator.test.sh` (12), `tests/judge.test.sh` (11), `tests/restart.test.sh` (7).

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

## Restart / pickup (Phase E)

A SIGKILLed coordinator mid-execution resumes from durable state: the live run is
adopted (one executor session, no duplicate dispatch), evidence persists across the
process boundary, a finished batch is a no-op on resume, and a task parked at
`AUDIT_PENDING` can never be completed without its audit.

## Unchanged firstmate surface

`git status` in the isolated worktree shows only new files under `unattended-crew/`.
No existing firstmate suite is affected because no firstmate code changed; fm-lint
was run directly on the new scripts to prove they meet the repo's lint gate.
