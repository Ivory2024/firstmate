# Unattended crew orchestrator

The unattended crew orchestrator is Firstmate's internal fault-recovery verification suite.
It drives a batch of task contracts through a crew executor, an evidence collector, an independent auditor, and a deterministic judge, and it lands the repo's mock and real-crew E2E gates for the `REAL_CREW_3FAULT_E2E_PASS` acceptance contract.
It is repository-internal verification tooling, not part of the primary runtime: the coordinator never touches a watcher, a credential, or GitHub, and with the default fake backend it never calls a worker or provider at all.

The suite is the 12 `fm-unattended-*.sh` scripts plus `fake-auditor.sh` in `bin/`, indexed in [`scripts.md`](scripts.md).
This page is the maintainer-architecture owner of the cross-script pipeline, the safety floors, and the E2E entry points.
Each script header owns the exact commands, flags, and contracts.

## Batch pipeline

`bin/fm-unattended.sh` is the only captain-facing way to drive a batch.
It resolves the implementation directory, records the config and evidence-root choice, enforces role separation, and executes the coordinator with the unchanged call contract `init|run|resume|status|next|handoff|stop --batch B [--contract C]`.
It never reads or writes `state/.afk` and never drains or acks the durable wake queue; the firstmate watcher and scheduler stay the supervisor.

`bin/fm-unattended-coordinator.sh` is the top-level entrypoint of the batch: it drives one task through a durable, restart-safe, idempotent state machine.

```
CAPTAIN REQUEST -> TASK CONTRACT -> BATCH COORDINATOR
  -> CREW EXECUTOR -> EVIDENCE COLLECTOR
  -> INDEPENDENT AUDITOR -> AUDIT EVIDENCE
  -> DETERMINISTIC JUDGE -> VERIFIED_PASS|REWORK|HOLD|AUDIT_UNAVAILABLE
  -> NEXT SAFE TASK / HANDOFF
```

Persistence lives outside every suite workspace under `$UC_HOME/batches/<batch>/`: `state.jsonl` (append-only transitions), `tasks/`, `sessions/`, `evidence/runs/<task>/` (executor plus auditor plus gate), and `handoff.md`.
The state machine is driven by `advance`, one meaningful step per task, so a coordinator killed mid-task is resumed, not duplicated: a live or completed evidence run is adopted instead of re-dispatched.
A HOLD sets the durable `.batch-held` latch, and the drive loop stops all further dispatch in that batch once the latch exists.

The evidence root is configurable (`evidence_root` in the config file, or `UC_EVIDENCE_ROOT`) and is recorded in `batch.meta` at init so a later resume re-reads the same evidence after a restart.
The compatibility default is `$UC_HOME/batches/<batch>/evidence`, the path the live canaries already used.
`bin/fm-unattended-config.sh` is the single owner of config-path resolution, evidence-root resolution with its permission, collision, and path-escape checks, and the per-batch `.batch` ownership marker.

## Dispatch adapter seam

`bin/fm-unattended-adapter.sh` is the seam between the batch coordinator and a worker runtime, exposing the verbs `dispatch`, `identity`, `send`, `status`, and `emit` behind a backend switch so the coordinator never hard-codes one runtime.

- `fake` (the default) is a file-backed fake session; no worker or provider is called.
- `real` bridges onto `bin/fm-spawn.sh`, `bin/fm-send.sh`, and `bin/fm-crew-state.sh` against the pinned isolated home `UC_FM_HOME`; dispatch is a real crew in a real worktree with a real endpoint.

Spawn success is not an ACK.
The coordinator must observe a live endpoint (`working`, `parked`, or `done`) within the contract's ACK window before it treats a dispatch as acknowledged.
The real adapter reads identity from the authoritative `state/<spawn>.meta`, and it never emits ACK on its own.
A session is bound to exactly one (task, role, attempt), and the adapter refuses a duplicate dispatch for a live or completed binding and a send whose `--task` does not own the session.
A real dispatch, identity, status, or send with a missing home, a missing spawn id, an unreadable meta, or an unmatched identity refuses with a nonzero exit instead of guessing a session.

## Evidence, guard, auditor, and judge

`bin/fm-unattended-evidence.sh` runs a tracked test and records durable evidence outside the suite workspace, and refuses to clean up a run whose tracked test process is still alive.
Two collection modes produce the same on-disk layout: `run` executes a one-shot command, while `collect` harvests a real crew session's durable artifacts (`state/<id>.meta`, status, the `fm-crew-state.sh` line, the worker report, the worktree SHA before and after, and an optional attested command log).
A completion with no report or with a non-`done` crew state is recorded as a nonzero rc so the judge refuses it.

`bin/fm-unattended-guard.sh` runs between evidence collection and auditor dispatch.
It compares the executor's claimed values against machine-derived canonical values from the contract's `executor.claims` list, and on any mismatch it holds the task (`evidence-guard-mismatch`) instead of spending an auditor crew.
It never weakens the auditor or the judge, and it fails closed.

`bin/fake-auditor.sh` is the default test-mode auditor.
It writes the same structured evidence a real auditor writes (`auditor/findings.json`) and marks itself `auditor_kind=fake`.
The fake auditor is valid only in `mode=test`; the judge holds a `mode=production` run that used one.

`bin/fm-unattended-judge.sh` consumes structured evidence only, never the coordinator report text, and emits one verdict: `VERIFIED_PASS`, `REWORK`, `HOLD`, or `AUDIT_UNAVAILABLE`.
It reuses the original floor conditions and adds the batch-required enforcements: a fake auditor in production, a missing audit, an incomplete test, an artifact hash mismatch, a reused prior PASS, an auditor sharing the executor's workspace, and fewer executed tests than the contract requires are all refusals.

## Quota floor

`bin/fm-unattended-quota.sh` is the single owner of the per-window spending safety floor for the real backend: a per-window maximum of concurrent crews, a per-window maximum of provider calls, a free-model allow-list, refusal of any model not on the allow-list, a safe HOLD when the quota is unknown, and idempotent accounting that refuses a duplicate reservation instead of over-spending on a retried dispatch.
The window is the batch: every batch gets its own counter file under `$UC_HOME/state/`, and the batch's HOLD latch stops all further work in that window once a block is recorded.
Enforcement is opt-in and activates on `UC_QUOTA_ENFORCE=1` or when a config file exists; without a config the historic uncapped behavior is preserved so the offline suites are unaffected.

## Failover policy

`bin/fm-unattended-failover.sh` is a data-only policy: it classifies a failure and decides the next route within a bounded budget.
It never calls a paid API, free models come first, and a subscription CLI is only ever returned as an approval-hold candidate.
It performs no dispatch itself, and the retry budget is per failure class, not one global counter.

## Autoteardown safety bounds

`bin/fm-unattended-autoteardown.sh` is a policy and decision helper only: it answers whether a completed task's crews and resources may be cleaned up automatically, and the actual cleanup stays with the firstmate teardown owner (`bin/fm-teardown.sh`) as a separate, explicitly approved action.
It is disabled unless `UC_AUTOTEARDOWN_ENABLE=1`, and production must not enable it yet.
A task is eligible only when all six conditions hold: terminal `VERIFIED_PASS` state, zero pending inbox records, zero open captain calls, persisted and re-readable evidence, every session bound to the task with a recorded identity, and no other non-terminal task in the batch.
Any failed or unevaluable condition is a refusal with the exact reason.

## Recovery

`bin/fm-unattended-recovery.sh` is the autonomous self-healing policy: it maps a detected failure (a coordinator HOLD reason or a failover failure class) to a bounded recovery category: `AUTO_RECOVERABLE`, `REQUIRES_DIAGNOSIS`, `NON_RECOVERABLE`, `QUOTA_WAIT`, or `CAPTAIN_APPROVAL_REQUIRED`.
It is a data-only decision layer over the existing coordinator: it never dispatches and never rebuilds the state machine.
`bin/fm-unattended-recovery-state.sh` persists per-task recovery bookkeeping as durable key=value metadata under `<UC_HOME>/recovery/<task>.recovery`, outside the coordinator's lifecycle, so recovery progress is never expressed as new lifecycle states.
The record is atomic (`mkdir` lock) and restart-safe, so a fresh process reads the same record and never re-runs an already-terminal recovery.

## E2E fault-injection gates

The mock contract, `tests/fm-unattended-faultinject-e2e.test.sh`, drives the coordinator's fake backend with three real fault types in a throwaway `UC_HOME`: an executor that fails, a missing ACK, and a dispatch identity mismatch.
It proves exact fault handling, safe HOLD, no duplicate dispatch, no state loss, and that the operational home is never touched.
Fault 3 (`FM_FAKE_WRONG_IDENTITY`) has no real-crew trigger and stays a mock-only lever.

The real-crew contract, `tests/fm-unattended-realcrew-3fault-e2e.test.sh`, drives `FM_UNATTENDED_ADAPTER=real` so every dispatch is a real `bin/fm-spawn.sh` crew in a real worktree with a real endpoint.
It runs on a private tmux server (`TMUX_TMPDIR` with `TMUX` unset) so a crew can never land in the operator's session, and every fault is produced from outside the coordinator by acting on that real crew or on the real dispatch boundary.

- F1: a real crew lost after the run starts (killed once `RUNNING`).
- F2: a real crew lost inside the dispatch window (killed the moment its window appears).
- F3: a real dispatch refused at project resolution, before any crew window exists.

F3 refuses at project resolution because of the flat-spawn limitation: `fm-spawn.sh` creates the crew window before its base-refresh refusal, so a verified-base-refusal variant would leak an orphan crew window and the residual-0 assertion could never hold.
The test asserts per fault: terminal HOLD, dispatches bounded by `retry_limit+1`, no dispatch after HOLD, residual crew 0, and unchanged operator tmux inventory and wake queue.
The exact HOLD reason is recorded, not asserted, because a real fault reaches HOLD through whichever real signal arrives first.
The guard is opt-in (`FM_REALCREW_E2E=1`) and spends real model tokens.
A3's fault 3 (identity-mismatch) stays mock-only because the adapter reads identity from the same `state/<spawn>.meta` a successful dispatch just wrote and clears a stale meta before spawning, so no real crew fault can make identity mismatch the session.

The suite's configuration file surface is [`config/unattended-crew.json`](configuration.md#unattended-crew-config-configunattended-crewjson).