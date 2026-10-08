# G4 operational-readiness review (review only — no apply)

Batch: `firstmate-unattended-guard-canary-20261008` (2026-10-08).
**G4 is NOT executed.** This document evaluates applying the unattended
controller to the live home. No operational home change was made.

## Evidence base (this batch)

| Phase | Result | Evidence |
|---|---|---|
| P1 crew teardown | `TEARDOWN_VERIFIED` | both crews removed; slot 14/15 pooled; `claude.exe` window preserved; inbox 0; home fingerprint unchanged |
| P2 Evidence Guard | IMPLEMENTED | `implementation/fm-unattended-guard.sh`; coordinator wiring; schema; commit `8eaddea1` |
| P3 regression | PASS | suite 78/78 (guard 17, real-e2e 24); `verify-local.sh` 11/11 |
| P4 single-run live E2E | `SINGLE_RUN_UNINTERRUPTED_PASS` | new batch `firstmate-unattended-guard-canary-20261008`; Guard PASS, Auditor PASS, Judge `VERIFIED_PASS`; 1 dispatch, 0 resume/adopt/retry |
| P5 dirty-home analysis | DONE (read-only) | `handoff/dirty-home-inventory.md` |

## What G4 would change

- Mount `implementation/fm-unattended*.sh` into `bin/`, set a durable
  `EVIDENCE_ROOT`, and wire a captain entrypoint. Forbidden now.

## Readiness checklist

| Item | Current state | Gap to close before G4 |
|---|---|---|
| Entrypoint | none; runs as `implementation/fm-unattended.sh` | a `bin/` wrapper + documented captain invocation |
| Durable evidence root | live canary used `data/unattended-crew-orchestrator-20261008/canary/guard-canary-20261008` | make the root a config value and document it |
| Evidence Guard | implemented + wired + tested (this batch) | none for readiness; keep `executor.claims` in the mounted default |
| Single-run uninterrupted | proven live (P4) | mount + one live restart drill |
| watcher/`/afk` compatibility | controller writes only its own batch tree; never drains wakes or arms a watcher | confirm a mounted controller is a producer, not a supervisor |
| Restart recovery | proven (`restart.test.sh` 7/7; canary adopt path) | mount + restart drill |
| Concurrency cap | one task per batch; `retry_limit` bounds attempts | define a per-window concurrency cap |
| Quota/cost cap | zero-priced OpenCode model; quota-axi does not report an opencode window | per-window budget + model allow-list |
| HOLD auto-stop | `_step_real` ends at `HOLD`/terminal; `cmd_next` returns `NONE` | document HOLD as terminal for the window |
| Rollback | batch tree self-contained; home tracked surface untouched | one-command unmount note |
| Dirty-file protection | home kept at the same 13 dirty files; fingerprint stable across every phase | explicit preflight that records the dirty set |
| **Operational-home conflict** | **UNRESOLVED** — the home sits on feature branch `fix/ci-flake-watcher-lock-hup` (not `main`) with 13 uncommitted files on the **watcher/arm-plugin/quota** runtime surfaces G4 would touch | land or explicitly preserve the branch; restore the home to `main` in an isolated way before applying |

## Grading against the mandate

GO conditions (§6.2): teardown verified ✓; Evidence Guard implemented ✓;
regression PASS ✓; single-run uninterrupted PASS ✓; Judge `VERIFIED_PASS` ✓;
dirty files fully inventoried ✓; per-file preserve/rollback plan ✓; rollback path
clear ✓; no approval-boundary violation ✓; evidence sufficient ✓.
**Not satisfied:** operational apply scope is not clean — the operational-home
conflict (dirty watcher surfaces + pre-existing branch tangle) is unresolved.

NO-GO conditions (§6.3): exactly one fires — **"운영 home 충돌 미해결."**

## Verdict

**`G4_NO_GO`.** The orchestrator pipeline itself is green end to end; the single
blocker is the operational home, not the pipeline.

## Blockers, in priority order

1. **P1 — operational-home conflict.** 13 uncommitted files on
   `fix/ci-flake-watcher-lock-hup` occupy the watcher/arm-plugin/quota runtime
   surfaces. Applying G4 on top risks clobbering unlanded work or colliding with
   the in-flight watcher lock changes. Remediation: land the branch through the
   normal review path, or snapshot-and-preserve it off-home, then bring the home
   back to `main` in a proper isolated worktree.
2. **P2 — durable evidence root config.** Make `EVIDENCE_ROOT` a documented
   config value instead of a per-batch path.
3. **P2 — per-window quota/concurrency cap** and an OpenCode free-model
   allow-list (health-catalog gap).
4. **P2 — mounted entrypoint + unmount/rollback command.**
5. **P3 — automatic teardown rule for completed crews** (separate approval; this
   batch deliberately left the two P4 crews in place).

## Recommended next steps (no apply)

1. Resolve blocker 1 (land or preserve the branch; restore `main`).
2. Add the config entrypoint + evidence root (blockers 2/4).
3. Add the quota/concurrency cap + allow-list (blocker 3).
4. Re-run the single-run live canary once from the mounted entrypoint, then ask
   for a **separate** G4 apply + rollback rehearsal approval.

G4 apply is never started automatically.
