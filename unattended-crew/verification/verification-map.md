# Verification map (pstack create/maintain-verification-skill adaptation)

One row per feature the unattended orchestrator ships. Each row names the exact
runnable test command and the fresh evidence it must produce. `check-drift.sh`
fails when a mapped file disappears; re-run the command to refresh evidence.
Mock vs real evidence is marked so a mock result is never read as a real one.

| Feature | Test command | Evidence (fresh) | Kind |
|---|---|---|---|
| Coordinator state machine (fake) | `bash tests/coordinator.test.sh` | `evidence/test-results/coordinator.out` | mock |
| Deterministic judge floor | `bash tests/judge.test.sh` | `evidence/test-results/judge.out` | mock |
| Executor Evidence Guard | `bash tests/guard.test.sh` | `evidence/test-results/guard.out` | mock |
| Restart / session pickup | `bash tests/restart.test.sh` | `evidence/test-results/restart.out` | mock |
| Real backend E2E wiring | `bash tests/real-e2e.test.sh` | `evidence/test-results/real-e2e.out` | mock home |
| Whole suite | `bash tests/run-all.sh` | `evidence/command-log.jsonl`, `evidence/artifact-manifest.json` | mock home |
| Separate local verification | `bash verification/verify-local.sh` | `verification/local-check.json` | local process |
| Decision trail view | `bash verification/decision-trail.sh <batch-dir>` | stdout table | derived |
| PR read-only classifier | `bash tests/pr-classify.test.sh` | `evidence/test-results/pr-classify.out` | fixture |
| Durable evidence root config | `bash tests/evidence-root.test.sh` | `evidence/test-results/evidence-root.out` | mock |
| Quota / concurrency cap | `bash tests/quota.test.sh` | `evidence/test-results/quota.out` | mock home |
| Mounted entrypoint + rollback | `bash tests/entrypoint.test.sh` | `evidence/test-results/entrypoint.out` | temp dir |
| Auto-teardown policy | `bash tests/autoteardown.test.sh` | `evidence/test-results/autoteardown.out` | fixture |
| Live real E2E canary | `bash tests/run-all.sh` then the recorded local-check | `canary/real-e2e-20261008/` + final report | **real** |

Rules:
1. Every row's command must be runnable from the repo root.
2. A mock row never substitutes for a real row.
3. After changing any `implementation/*.sh`, re-run the whole-suite row; a
   passing older `artifact-manifest.json` is not fresh evidence.
4. The live real E2E row is the only real-provider row; it is bounded to the
   approved canary and is not part of the routine local suite.
