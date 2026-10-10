# Recovery state machine

This is the maintainer-architecture owner of FirstCrew's autonomous recovery contract: how a failed execution path is separated from a failed objective, diagnosed, repaired inside an already-approved boundary, and handed back to the original work.

The mechanism is owned by two scripts and nothing else.

- [`bin/fm-recovery-lib.sh`](../bin/fm-recovery-lib.sh) is the contract: the state vocabulary, the transition table, the action-authority table, the failure classes, the fingerprint rule, the pilot bounds, the execution class, and the playbook status rule.
- [`bin/fm-recovery.sh`](../bin/fm-recovery.sh) is the durable store and the CLI: the recovery record, the append-only ledger, the claim lock, the bounds enforcement, the authority gate, the measurement export, and the evidence-preserving archive.

Neither is an agent.
The capability adds no Goal, no Loop, no watcher, no daemon, and no recovery worker; it is an adjunct of the same shape as [`bin/fm-inactive-reconcile.sh`](../bin/fm-inactive-reconcile.sh), and it reuses the existing registry, current-state read, approval boundary, lock primitive, and status verb vocabulary.

## Reuse map

| Need | Existing owner this reuses | Why not a new one |
|---|---|---|
| Task queue state | `data/backlog.md` through `bin/fm-tasks-axi.sh` | The recovery never invents a second queue |
| Current worker state | [`bin/fm-crew-state.sh`](../bin/fm-crew-state.sh) | One deterministic current-state read already exists |
| Status vocabulary | `bin/fm-classify-lib.sh` verbs | A second writer of `state/<id>.status` would corrupt the open-decision fold |
| Approval boundary | [`bin/fm-captain-hold.sh`](../bin/fm-captain-hold.sh) | A hold is already "a task waiting on the captain" |
| Mutual exclusion and stale reclaim | `fm_lock_try_acquire` in `bin/fm-wake-lib.sh` | The per-task lock and its stale-owner proof already exist |
| Lifecycle control | [`bin/fm-control.sh`](../bin/fm-control.sh) | Resuming work is already `relaunch` |
| Condition-to-action arming | `bin/fm-procevent-when.sh` | The recovery only exposes a predicate; arming stays with that owner |

## States and their authority

The recovery state is internal to a recovery record.
What the rest of Firstmate reads is the registry projection, printed by `fm-recovery.sh status --verb` and never written into a worker's status log.

| State | Registry projection | Authority |
|---|---|---|
| `RETRYABLE` | `working` | Automatic: re-run the same step, bounded by the same-cause retry budget |
| `DIAGNOSING` | `working` | Automatic, read-only |
| `ALTERNATIVE_SEARCH` | `working` | Automatic, read-only |
| `VALIDATING` | `working` | Automatic, inside an isolated worktree only |
| `RECOVERABLE` | `working` | Automatic only for an action whose verdict is automatic; otherwise it moves to `WAITING_APPROVAL` |
| `WAITING_DEPENDENCY` | `paused` | Automatic wait on a cause outside this home |
| `WAITING_APPROVAL` | `needs-decision` | None: the captain owns the call, recorded as an ordinary captain hold |
| `BLOCKED_EXHAUSTED` | `blocked` | None: escalated with the original work preserved |
| `RESUMED` | `none` | Handed back to the ordinary work path |

`WAITING_APPROVAL` is only ever published together with a recorded captain hold.
The hold is raised before the state is written, and a hold that cannot be recorded is a fail-closed stop: the recovery refuses to open or escalate onto `WAITING_APPROVAL` rather than publishing a wait that nothing is waiting on.

A recovery record is one line of space-separated `key=value` fields.
Every value is escaped on write and unescaped on read, so a value that contains a space, an `=`, or a newline round-trips exactly instead of being truncated at its first space or read back as a second field.
That is what keeps a free-text argument from injecting a field: `exec_class=production` inside a signature, a target, a reason, or an alternative name is data, never the record's own class.

## Transitions

Every transition not listed here is refused.

```text
RETRYABLE          -> RETRYABLE | DIAGNOSING | ALTERNATIVE_SEARCH | WAITING_APPROVAL
                    | WAITING_DEPENDENCY | BLOCKED_EXHAUSTED
DIAGNOSING         -> ALTERNATIVE_SEARCH | WAITING_DEPENDENCY | WAITING_APPROVAL
                    | BLOCKED_EXHAUSTED
ALTERNATIVE_SEARCH -> VALIDATING | WAITING_APPROVAL | WAITING_DEPENDENCY
                    | BLOCKED_EXHAUSTED
VALIDATING         -> RECOVERABLE | ALTERNATIVE_SEARCH | BLOCKED_EXHAUSTED
RECOVERABLE        -> WAITING_APPROVAL | RESUMED | BLOCKED_EXHAUSTED
WAITING_DEPENDENCY -> DIAGNOSING | BLOCKED_EXHAUSTED
WAITING_APPROVAL   -> RECOVERABLE | BLOCKED_EXHAUSTED
```

Two transitions are forced rather than requested, so a recovery always converges on an escalation instead of looping: exhausting the alternative budget, the same-cause retry budget, or the whole-recovery budget moves the record to `BLOCKED_EXHAUSTED`.
A failed verification with an alternative still available returns to `ALTERNATIVE_SEARCH` so a different alternative is tried.

## Failure classes

A class is a cause category, never a verdict on the objective.
`fm-recovery.sh classify` derives it from the worker's current state and status log by exact deterministic matching, never from a model.

| Class | First state |
|---|---|
| `run-failed`, `daemon-down`, `pr-target-mismatch`, `watcher-successor-none`, `worktree-base-contamination`, `unknown` | `RETRYABLE` |
| `dependency-unavailable` | `WAITING_DEPENDENCY` |
| `approval-boundary` | `WAITING_APPROVAL` |

## Fingerprint and dedupe

A fingerprint is `sha256(task | class | normalized-signature | target)`, truncated to 16 hex characters.
Normalization lowercases the text, replaces commit-like hex runs, paths, and numbers with placeholders, and squeezes whitespace, so the same failure with different ids or paths dedupes.

The fingerprint deliberately excludes the spawn incarnation.
That is what makes a worker death a checkpoint restore: the restarted recovery lands on the same record, keeps its state and counters, and appends a `resume` ledger line instead of beginning again.
A short-lived claim lock (`fm_lock_try_acquire`) makes two simultaneous starts of one failure impossible, and a completed recovery retires its record so a genuinely new occurrence opens a new one.

The lease inside the record is a TTL heartbeat, not a process-liveness claim, because the engine's own processes are short-lived by design.
A lease whose heartbeat stopped for longer than `FM_RECOVERY_LEASE_TTL_SECS` is stale and may be taken over.

## Bounds

All pilot values are owned by `fm_recovery_bound` in the library, and a malformed value falls back to the conservative default rather than opening the bound.

| Bound | Pilot value | Effect |
|---|---|---|
| `FM_RECOVERY_MAX_ALTERNATIVES` | 3 | More than three alternatives escalates |
| `FM_RECOVERY_MAX_SAME_CAUSE_RETRIES` | 2 | A third identical retry is refused and forces `DIAGNOSING` |
| `FM_RECOVERY_DIAGNOSIS_SECS` | 900 | A diagnosis that outlives the window asks for the supervisor |
| `FM_RECOVERY_TOTAL_SECS` | 1800 | A recovery that outlives the window escalates |
| `FM_RECOVERY_MAX_CONCURRENT` | 4 | The existing execution slot cap is retained, never raised |
| `FM_RECOVERY_LEASE_TTL_SECS` | 300 | Lease heartbeat window |

## Authority gate

`fm-recovery.sh apply` asks `fm_recovery_action_verdict` and reports exactly what it answers.
The capability ships inert, so `apply` performs no action itself: it prints `would-apply:` for a permitted action and records the decision in the ledger.

| Verdict | Actions | Behavior |
|---|---|---|
| `automatic` | `read-only-probe`, `retry-same-step`, `cache-refresh`, `reattach-run`, `refresh-clone-read`, `isolated-branch-edit`, `isolated-test-run`, `isolated-worktree-reset`, `revert-isolated-commit` | Permitted: the engine records the decision and performs no action |
| `approval-required` | `config-reload`, `queue-requeue`, `external-draft-notify`, `discard-unlanded`, `force-terminate`, `credential-change`, `external-publish`, `rollback-destructive` | Permitted only with a recorded approval token; the engine still performs no action |
| `refused` | `upstream-write`, `shared-remote-change`, `shared-db-change`, `pr-create`, `pr-retarget`, `attestation-reuse`, `attestation-fabricate`, `gate-waiver`, `merge`, `production-deploy`, `launchd-change`, `auto-recovery-activate`, `daemon-restart` | Never performed here, with or without a token; the recovery escalates instead |
| `undecidable` | Anything unrecognized | Stops, fail-closed |

An approval token reaches only the `approval-required` class.
It is not a key: there is no string, and no argument, that turns a `refused` action into a permitted one.

## Recovery playbook

`data/recovery-playbooks.tsv` holds one tab-separated entry per line: `fingerprint`, `class`, `status`, `alternative`, `scope`, `verified_at`, `evidence`.

Status is `hypothesis`, `validating`, or `verified`.
Only `verified` may inform an apply decision, and only while its recorded scope still matches the current environment: a `verified` entry whose scope has moved reads `stale` and owes re-verification.
Scope is the worker's `harness/backend` pair, so a repair proven on one runtime is not silently reused on another.

A playbook entry can only propose an alternative.
It cannot widen authority: an entry naming a `refused` action is never applicable, whatever its status, because the authority gate is consulted on the action itself.

The pilot's named cases are no-mistakes PR target mismatch, watcher `successor=none`, and worktree base contamination; each starts as a `hypothesis` entry and is promoted only by recorded evidence in the current scope.

## Checkpoint, retention, and evidence-preserving rollback

A recovery record and its ledger are incident evidence: they say what was classified, what was tried, what was refused, and why the captain was asked.
Nothing in this capability deletes them.

**Checkpoint policy.**
The record is durable and the fingerprint excludes the spawn incarnation, so an interrupted recovery resumes from the same record.
A terminal recovery is retained live until it is retired, and `fm-recovery.sh retire --fingerprint <fp>` moves the record and its ledger, byte for byte, into `data/recovery-archive/<fingerprint>/<epoch>.{rec,ledger}` and appends a `retire` event to the archived ledger, so the archived ledger stays a complete, self-contained event stream.
A second retire of the same fingerprint inside the same epoch second is refused rather than allowed to overwrite the first archived record and ledger: archived evidence is never replaced.
Retiring is what lets a recurring failure of the same fingerprint open a new recovery; without it the terminal record correctly refuses a duplicate forever.

**Audit-event retention.**
Every ledger event is evidence and is kept for the life of the home: `begin`, `attempt`, `alternative`, `validate`, `transition`, `escalate`, `apply`, `resume`, `retire`.
Retention is unbounded by design, because these are small text lines and the events a later investigation needs cannot be predicted at write time.

**Rollback procedure (capability removal without evidence loss).**
`rm -rf state/recovery` is not a rollback: it destroys the incident trail.

1. Run `fm-recovery.sh archive-all --reason "<why>"` while the code is still present.
   It moves every live `.rec` and `.ledger` into `data/recovery-archive/rollback-<UTC>/` and writes `ROLLBACK.audit`.
   A second `archive-all` inside the same UTC second is refused: two rollbacks never merge into one directory, because that would truncate the first rollback's audit record.
2. Verify `ROLLBACK.audit` lists every archived file with its byte size and sha256.
3. Remove the capability code: `bin/fm-recovery.sh`, `bin/fm-recovery-lib.sh`, and their registrations.
   `data/recovery-archive/` is deliberately outside `state/`, so removing the capability cannot touch it.
4. Do not delete `data/recovery-archive/`; it is the surviving incident evidence.

**How the rollback is auditable.**
`ROLLBACK.audit` is the record that the capability was withdrawn: schema `fm-recovery-rollback.v1`, the UTC timestamp, the acting identity, the reason, the source directory, the archive directory, and a `sha256=` line for every preserved file.
The only things `archive-all` removes are transient claim locks, which hold a pid and no incident content, and it names each one it removed.

## Execution class and measurement linkage

Every recovery record carries an execution class, and the engine records only `simulation` or `isolated`.
`production` is refused here by name: assigning it is the job of the separately approved control plane that activates the capability.
The class is a record field the engine writes, never a value derived from free text, so no argument to `fm-recovery.sh begin` can relabel test output as operational output: the record's escaping rule means an `exec_class=production` inside a signature, a target, a reason, or an alternative name is stored as data and can never become the record's own class.

A `simulation` recovery is inert in effect as well as in label.
It writes its own recovery record and ledger, which carry the class, but it never mutates the real backlog: it raises no captain hold, and it touches no file outside this engine's own store.

`fm-recovery.sh export-events` is the read-only seam to the measurement layer.
It writes nothing, and it owns none of the measurement layer's files: the metrics layer owns its own event log and dashboard, while this engine owns the recovery records and ledgers.
Each exported event carries `incident_id`, `recovery_attempt_id`, `failure_fingerprint`, `failure_class`, `stage`, `actor`, and `exec_class`, so a consumer can separate simulation, isolated, and production executions and can never present an isolated success rate as the production auto-recovery rate.

## Not activated by this contract

This state machine ships inert.
Wiring it into a watcher or a condition-to-action watch, applying it to shared operational code, and changing launchd are separate decisions that need the captain's explicit approval.
