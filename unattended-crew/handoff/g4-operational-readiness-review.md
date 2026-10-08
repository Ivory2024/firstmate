# G4 operational-readiness review (review only — no apply)

Batch: `firstmate-unattended-production-readiness-20261008`.
**G4 is NOT executed.** This document evaluates what applying the unattended
controller to the live home would require. No operational home change was made.

## What G4 would change

- Mount `implementation/fm-unattended*.sh` into `bin/`, point `EVIDENCE_ROOT` at
  a durable location, and wire a captain entrypoint. All of that is G4 and is
  forbidden now.

## Readiness checklist

| Item | Requirement | Current state | Gap to close before G4 |
|---|---|---|---|
| Entrypoint | explicit captain command, never a replacement for `/afk`/watcher | none exists; coordinator runs as `implementation/fm-unattended.sh` | a `bin/` wrapper + a documented captain invocation |
| Durable evidence root | home-adjacent, not `/tmp` | live canary used `data/unattended-crew-orchestrator-20261008/canary/real-e2e-20261008` | make the root a config value and document it |
| watcher/`/afk` compatibility | controller produces durable state; watcher classifies it; no second supervision loop | coordinator writes only its own batch tree; it never drains the wake queue and never arms a watcher | confirm a mounted controller is a producer, not a supervisor |
| Restart recovery | adopt live/completed run, no duplicate dispatch | proven: `tests/restart.test.sh` 7/7 and the live canary resume path | mount + one live restart drill |
| Concurrency limit | bounded in-flight crews | one task per batch; `retry_limit` bounds attempts | define a per-window concurrency cap |
| Quota/cost cap | bounded spend | canary used a zero-priced OpenCode model; quota-axi does not report an opencode window | a per-window budget rule and a model allow-list |
| Retry limit | bounded auto-retry | `retry_limit` (canary = 1, no auto-retry); audit retries capped and never re-run a completed executor | keep `retry_limit` in the mounted default |
| HOLD auto-stop | every unrecoverable path stops, never advances | `_step_real` ends at `HOLD`; `cmd_next` returns `NONE` for held tasks; no auto next task after a canary | document HOLD as terminal for the window |
| Rollback | remove the entrypoint and the mounted files; leave state intact | the batch tree is self-contained and disposable; the home tracked surface is untouched | a one-command unmount note |
| Dirty-file protection | never touch unrelated unlanded work | canary kept the home at the same 13 dirty files; coordinator writes only its own batch tree + the spawned task's own records | an explicit preflight that records the dirty set |
| First-60-min contract | one real task per window, bounded wait, `AUDIT_UNAVAILABLE` fallback | see `handoff/operational-readiness.md` §9 | a 60-min wall-clock cap in the wrapper |
| Hourly scheduler | separate gate | not built | G4 + quota cap + auto-teardown rule + failure policy + health catalog |

## Blocking prerequisites for G4

1. A passing live Real E2E canary (this batch).
2. A durable evidence root config.
3. A per-window quota/cost cap and concurrency cap.
4. An approved automatic teardown rule for completed crews.
5. A failure policy (retry cap, HOLD notification).
6. The OpenCode free-model health-catalog gap resolved, or an explicit
   allow-list.

## Rollback sketch (for the eventual G4 step)

1. Remove the `bin/` entrypoint wrapper.
2. Delete the mounted `bin/fm-unattended*.sh`.
3. Leave `EVIDENCE_ROOT` contents for audit; remove nothing the captain did not
   ask to remove.
4. The home tracked surface is unchanged by construction, so no git rollback is
   needed.
