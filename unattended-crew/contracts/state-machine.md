# State machine contract

The batch coordinator is a durable, idempotent state machine over a list of task
contracts. All state lives outside any suite workspace and survives a coordinator
crash.

## Directory layout (`$UC_HOME/batches/<batch>/`)

```
contract.json          the loaded batch contract (copy of the init input)
batch.meta             batch_id, baseline_sha, created_at
state.jsonl            append-only transition log (the event log)
tasks/<task>.state     current state (one `new=<STATE>` line)
tasks/<task>.attempts  dispatch attempt counter
sessions/<sid>/meta    adapter session record (task, role, attempt, identity, workdir, state)
sessions/<sid>/events.jsonl  ACK / ACTIVE / COMPLETE / FAILED / MESSAGE
evidence/runs/<task>/  executor + auditor + gate evidence (evidence-runner layout)
  task-contract.json   per-task contract mirror read by the judge
  executor/{rc,command-log.jsonl,stdout/,stderr/,wd,artifact-manifest.json,pid,patch-hash,test-count,session.json}
  auditor/{findings.json,session.json}
  gate/{verdict.json,summary.md}
evidence/runs/<task>.attempt<N>/   archived evidence of a superseded attempt
work/<task>/           executor workspace
audit-ws/<task>/       auditor workspace (MUST differ from the executor workspace)
handoff.md             durable handoff record
```

## States

`QUEUED, DISPATCHING, ACKNOWLEDGED, RUNNING, EVIDENCE_PENDING, AUDIT_PENDING,
AUDITING, VERIFIED_PASS, REWORK, HOLD, AUDIT_UNAVAILABLE, CANCELLED`

- `QUEUED` — recorded, not yet dispatched (dependencies may still block it).
- `DISPATCHING` — a dispatch handshake is in flight; no ACK yet.
- `ACKNOWLEDGED` — the adapter returned an ACK with a valid identity.
- `RUNNING` — the tracked executor command is executing out of process.
- `EVIDENCE_PENDING` — the executor exited; evidence is being finalized.
- `AUDIT_PENDING` — evidence is complete; the task awaits its independent audit.
- `AUDITING` — the auditor session has been dispatched and is active.
- `VERIFIED_PASS` — every floor condition met and the audit passed. Terminal.
- `REWORK` — a retryable failure (nonzero exit, missing ACK, auditor dispatch failure). Retried until `retry_limit`, then `HOLD retry-exhausted`.
- `HOLD` — a non-retryable or exhausted result requiring supervisor/captain action (approval-required, identity mismatch, audit conflict, forbidden write, hash mismatch, interrupted worker, retry exhausted).
- `AUDIT_UNAVAILABLE` — the executor evidence is clean but no independent audit exists; never `VERIFIED_PASS`.
- `CANCELLED` — reserved for supervisor cancellation.

## Transitions

```
QUEUED --dispatch--> DISPATCHING --ack--> ACKNOWLEDGED --launch--> RUNNING
RUNNING --exit--> EVIDENCE_PENDING --(audit required)--> AUDIT_PENDING
AUDIT_PENDING --dispatch--> AUDITING --judge--> VERIFIED_PASS | REWORK | HOLD | AUDIT_UNAVAILABLE
EVIDENCE_PENDING --(no audit)--> judge directly
DISPATCHING --no ack--> REWORK
DISPATCHING --bad identity--> HOLD
RUNNING --runner dead, no exit code--> HOLD worker-interrupted
REWORK --attempts >= retry_limit--> HOLD retry-exhausted
AUDIT_PENDING/AUDITING --auditor dispatch failed--> REWORK
QUEUED --approval_required--> HOLD approval-required
```

Dependency rule: a task is dispatched only after every id in `depends_on`
reaches `VERIFIED_PASS`.

## Transition record

Every transition appends one line to `state.jsonl`:

```
at=<UTC ISO8601> run_id=<batch> task_id=<id> attempt=<n> session=<sid>
role=<executor|auditor> baseline_sha=<sha> prev=<state> new=<state>
reason=<slug> evidence=<ref>
```

`baseline_sha` is the batch baseline; `evidence` points at the gate verdict or
artifact when the transition is evidence-driven.

## Idempotency

- A duplicate transition is suppressed by the key
  `task_id+attempt+new+reason`; re-driving a batch records no second crew and no
  second outcome.
- `_dispatch_executor` adopts a completed run (`executor/rc` exists) or a live
  run (`executor-runner.pid` alive) instead of re-dispatching.
- The adapter refuses `DUPLICATE_DISPATCH` for the same `(task, role, attempt)`
  and its `send` refuses a session owned by a different task.
- A retry starts a fresh run directory (`evidence/runs/<task>.attempt<N>`), so a
  new attempt never inherits the previous attempt's verdict.

## Workspace separation

The executor runs in `work/<task>/`; the auditor runs in `audit-ws/<task>/`.
The judge fails (`auditor-executor-same-workspace`) when the recorded auditor
workdir equals the executor `wd`. The auditor may read the executor's raw
evidence but never writes into the executor workspace.

## Deterministic judge floor conditions

`VERIFIED_PASS` requires all of: contract present; exit code present and zero;
raw stdout/stderr/command-log/manifest/git-before/git-after present; every
manifest artifact hash matches; no live child; not a reused prior PASS; not
interrupted; executed tests >= `required_tests`; no forbidden-write marker; no
patch-hash mismatch; and an audit verdict `PASS` from a non-fake auditor in
`mode=production`. Otherwise: `AUDIT_UNAVAILABLE` when only the audit is missing;
`REWORK` for a fixable executor failure; `HOLD` for every other unmet floor.

## Durable handoff

`handoff.md` records: baseline SHA, per-task state + attempts, active sessions
with task/role/workdir, the next runnable task (`NONE` when none), and the
evidence root. It is regenerated on every `run`/`resume`/`handoff` and is the
cold-start pickup point.
