# Firstmate integration map (Phase A)

Baseline: firstmate fork `Ivory2024/firstmate`, home HEAD `5f4a1028`, origin/main `e70daed6`.
All paths below are read directly from that code; nothing here is inferred. The
unattended orchestrator is a new controller that *reuses* these primitives through
a dispatch-adapter seam. It does not duplicate or replace them.

## Scope note

The captain's `/afk` posture is a supervision MODE. This orchestrator is a WORK
CONTROLLER (task contract + completion gate). They are complementary and are not
merged: `/afk` stays the away posture; the batch coordinator owns task selection,
evidence gating, independent audit, and durable handoff.

## Capability map

### 1. Crewmate creation and work delivery
- **Entrypoint**: `bin/fm-spawn.sh <task-id> <project-dir> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> [--harness H] [--model M] [--effort E]`.
- **Mechanics**: resolves a genuine isolated treehouse/Orca worktree distinct from the primary checkout; renders `launch-brief.md`; validates the brief's `Delivery contract: mode=` line; refuses a primary-checkout launch.
- **Inputs**: task id, project dir, delivery mode, yolo posture, optional harness/model/effort/backend.
- **Outputs / persistent state**: `state/<id>.meta` (observed keys: `window`, `endpoint_task_id`, `worktree`, `project`, `harness`, `kind`, `mode`, `yolo`, `tasktmp`, `model`, `effort`, `busy_gen`, `spawn_gen`, `backend`, `herdr_session`, `herdr_workspace_id`, `herdr_tab_id`, `herdr_pane_id`), `data/<id>/brief.md`, and the backlog transition to *In flight*.
- **Authority**: supervisor-only; it is the single spawn path.
- **Restart**: `fm-spawn.sh <task-id> --relaunch` reuses the recorded worktree/endpoint from validated meta.
- **Reuse for the orchestrator**: this is the real dispatch backend behind the adapter's `real` mode. NOT invoked in this batch.

### 2. Scout investigation
- **Entrypoint**: `bin/fm-spawn.sh <task-id> <project-dir> --scout [...]`.
- **Output**: a self-contained `data/<id>/report.md`; scratch worktree is disposable only after the report exists and the completion gate passes.
- **Reuse**: a scout task is a batch task whose executor command writes a report artifact instead of a code change; the evidence/audit/judge pipeline is identical.

### 3. Secondmate delegation
- **Entrypoint**: `bin/fm-spawn.sh <task-id> [<home>] --secondmate`; routing table `data/secondmates.md`; skill `secondmate-provisioning`.
- **Reuse**: out of scope for this MVP. The orchestrator's adapter seam can target a secondmate home later; documented in `handoff/integration-plan.md`.

### 4. Crew dispatch profile and model selection
- **Entrypoints**: `config/crew-dispatch.json`, `bin/fm-dispatch-resolve.sh`, skill `quota-array-dispatch`, `bin/fm-harness.sh` (`crew`, `secondmate`, `validate-native-effort`).
- **Observed**: a matched profile array is ranked by `quota-axi` spendPriority after eligibility/reasoning-class/runway gates.
- **Reuse**: the adapter's `real` mode must accept a resolved `profile:` line; the fake backend models the ACK/ACTIVE/COMPLETE lifecycle without any provider call.

### 5. Task metadata and status transitions
- **Metadata**: `state/<id>.meta` (key=value, above).
- **Event log**: `state/<id>.status` is append-only and is a wake EVENT, not current state; `bin/fm-classify-lib.sh` owns the syntax. Recognized captain-relevant tokens: `done:`, `needs-decision:`, `blocked:`, `failed:`; `paused:` is an expected external wait, not a captain-relevant terminal event (`FM_CLASSIFY_CAPTAIN_RE_DEFAULT`).
- **Current state**: `bin/fm-crew-state.sh <id>` prints one line: `state: <working|parked|done|blocked|paused|failed|unknown> · source: <run-step|pane|status-log|remote-endpoint|none> · <detail>`.
- **Reuse**: the orchestrator's transition record mirrors this event-vs-state distinction: `state.jsonl` is the event log, `tasks/<id>.state` is current state.

### 6. Worker ACK, progress, and exit signals
- **ACK/inbox**: `bin/fm-send.sh` writes a durable record under `state/<id>.inbox/NNN.msg`; the worker's `mv` into `state/<id>.inbox/handled/` IS the acknowledgement (`bin/fm-task-inbox-lib.sh`, record `schema=fm-task-inbox.v1`).
- **Progress/exit**: the worker appends `state/<id>.status` events and touches `state/<id>.turn-ended` / `state/<id>.progress`.
- **Reuse**: the adapter's `send` verb maps to this inbox; the fake backend models ACK failure, wrong identity, and duplicate completion.

### 7. Steering through `fm-send.sh`
- **Entrypoint**: `bin/fm-send.sh <target> [--resolve-key K]... <text...>`; data plane only; refusal over guessing.
- **Lifecycle control**: `bin/fm-control.sh <task-id> interrupt|exit|relaunch` (control plane, closed verb list, `bin/fm-control-lib.sh` per-harness mechanics).
- **Reuse**: `send` is the text plane; `interrupt/exit/relaunch` remain supervisor-owned and are never issued by the unattended coordinator.

### 8. Watcher and wake queue
- **Entrypoint**: `bin/fm-watch.sh`; absorbs benign wakes, queues actionable ones into `state/.wake-queue` (`epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload`); session-start prints `WAKE_ACK_REQUIRED` with a generation-bound `--ack-through`.
- **Kinds**: `signal:`, `stale:`, `check:`, `heartbeat:`.
- **Reuse**: the orchestrator is a *producer* of durable state that the watcher can classify; it does not run its own supervisory loop and does not drain the queue.

### 9. `/afk` and `/quiet` supervision
- **Skill**: `.agents/skills/afk`, `.agents/skills/quiet`; durable flag `state/.afk`; posture record `state/.afk-contract` (written by `bin/fm-afk-contract.sh` after read-back).
- **Reuse**: none — deliberately. Away mode changes notification and decision handling, not authority; the orchestrator's own decision points are held as `HOLD` and surface through the ordinary status/wake path.

### 10. Restart / reconcile
- **Session start**: `bin/fm-session-start.sh` (single owner of the digest); bootstrap reconciliation sweeps run only when the lock is held.
- **Crew recovery**: skill `stuck-crewmate-recovery`; `bin/fm-control.sh relaunch` reuses the recorded worktree/endpoint.
- **Reuse**: the orchestrator implements the same convergence contract at task granularity — adopt a live session, adopt a completed run, never re-run finished work (see `contracts/state-machine.md`).

### 11. Failure, interruption, orphan handling
- **Wedges**: `bin/fm-watch.sh` wedge escalation with a bounded recheck cadence; `state/.wedge-defer-*` deferrals.
- **Declared waits**: `paused:` is an expected external wait; `blocked:` needs firstmate action.
- **Reuse**: the orchestrator maps: missing ACK / nonzero exit / interrupted run → retryable `REWORK` or terminal `HOLD`; a genuinely unrecoverable task is held, never silently dropped.

### 12. Results and backlog linkage
- **Backlog**: default tasks-axi backend (`data/backlog.md`), driven through `bin/fm-tasks-axi.sh`; `bin/fm-spawn.sh`/`bin/fm-teardown.sh` own the automatic transitions.
- **Reuse**: the orchestrator persists its own batch record; it does not write the firstmate backlog and does not merge or tear down.

## Code paths that must not be written by this work

`projects/`, `state/` (operational), `config/`, `.env`, watchers/schedulers, credentials, and any GitHub write. The implementation in `unattended-crew/` is isolated; wiring into `bin/` is a separate, approved integration step.
