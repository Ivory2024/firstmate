# P4 — G4 features: design + implementation notes

Scope: implemented and tested **in this isolated worktree only**. Nothing was
installed into the operational home, no watcher/scheduler/launchd was touched, no
provider was called, no commit/push/PR was made. All changes are uncommitted.

Five features, one owner per file:

| Feature | New owner file |
|---|---|
| 4.1 Durable Evidence Root | `implementation/fm-unattended-config.sh` |
| 4.2 Quota & Concurrency Cap | `implementation/fm-unattended-quota.sh` |
| 4.3 Mounted Entrypoint | `bin/fm-unattended.sh` |
| 4.4 Mount & Rollback | `bin/fm-unattended-install.sh` |
| 4.5 Auto-teardown Policy | `implementation/fm-unattended-autoteardown.sh` |

Integration edits: `implementation/fm-unattended.sh` (evidence-root resolution,
quota gate, HOLD latch). Supporting: `config/unattended-crew.example.json`.
Tests: `tests/evidence-root.test.sh`, `tests/quota.test.sh`,
`tests/entrypoint.test.sh`, `tests/autoteardown.test.sh` (registered in `tests/run-all.sh`).

---

## 4.1 Durable Evidence Root — `implementation/fm-unattended-config.sh`

**Goal:** make the evidence root an explicit config value while keeping the
per-batch canary path working; create/own the directory safely; let the same
evidence be re-read after a restart; fail closed on anything unusable.

**Config (default `config/unattended-crew.json`, or `$UC_CONFIG_FILE`, or
`$UC_HOME/config/unattended-crew.json` when present):**

```json
{ "evidence_root": "/absolute/durable/path" }
```

**Resolution order for batch `B`:**
1. `UC_EVIDENCE_ROOT` (explicit env),
2. config key `evidence_root`,
3. **compatibility default** `$UC_HOME/batches/<B>/evidence` (the path the live
   canaries already used).
When (1)/(2) apply, the per-batch dir is `<root>/<B>`; the printed value is always
the directory that **contains `runs/`** (the evidence/judge contract).

**Guarantees / fail-closed rules**
- Batch id must match `^[A-Za-z0-9._-]+$`; `..`/`.`/slashes refused.
- A root containing a `..` path segment is refused.
- A realpath check refuses any per-batch dir that escapes its base.
- The per-batch dir is created (`mkdir -p`) and `chmod 0700`; an unreadable or
  unwritable dir is refused. `--no-create` refuses a missing dir.
- A per-batch dir stamped `.batch` for a different batch is a collision refusal; a
  matching stamp makes the resolve idempotent.
- A file where a directory is expected is refused.

**Restart durability:** `cmd_init` resolves the root once and records
`evidence_root=` in `batch.meta`. `_evroot()` reads that recorded value first, so a
resume re-reads the **same** evidence even if the env var/config changed or vanished.
Batches without a recorded root fall back to the compatibility default (old batch
trees stay readable).

**CLI:**
```
fm-unattended-config.sh config-path [--config F]
fm-unattended-config.sh get --key K [--config F]
fm-unattended-config.sh settings [--config F]
fm-unattended-config.sh evidence-root --batch B [--home H] [--config F] [--no-create]
```

---

## 4.2 Quota & Concurrency Cap — `implementation/fm-unattended-quota.sh`

**Goal:** per-window caps on concurrent crews and provider calls, a free-model
allow-list, refusal of unapproved paid models, a safe HOLD when quota is unknown,
no duplicate dispatch, no infinite retry, and no further run once HOLD.

**Config keys (same file):**
```json
{ "quota": {
    "max_concurrent_crews": 1,
    "max_provider_calls": 2,
    "free_models": ["opencode/ling-3.1-flash-free"],
    "allow_paid_models": false } }
```

**The "window" is the batch.** Counters live at `$UC_HOME/state/quota-<batch>.json`,
guarded by a `mkdir` spin-lock. Enforcement is **opt-in**: it activates only when
`UC_QUOTA_ENFORCE=1` or a config file is present, so the offline suites are
unaffected. Once active, an unknown cap is a HOLD (fail-closed).

**CLI:** `check-model --model M`, `reserve --batch B --role R --home H`,
`release --batch B --home H`, `state --batch B --home H`, `reset --batch B --home H`.
Exit codes: `0` allowed, `3` blocked, `4` unknown (HOLD), `2` usage.

**Coordinator integration** (`implementation/fm-unattended.sh`, real backend only):
- `_quota_gate <batch> <role>` runs `check-model` then `reserve` immediately before
  a real spawn. A block records `gate/quota-block.txt` and transitions the task to
  `HOLD reason=quota-blocked` — **before** any crew is spawned.
- The executor's crew slot is released when its evidence is collected; the auditor's
  when the judge returns. This models a sequential crew chain under
  `max_concurrent_crews = 1` without over-blocking the normal path.
- **Duplicate dispatch** is already refused by the adapter's `_find_binding`; the
  reservation only happens after that guard, so a retried/adopted dispatch cannot
  double-count.
- **Infinite retry** is bounded twice: the contract's `retry_limit` and the window's
  `max_provider_calls`.
- **Once HOLD, no further run:** `_transition` sets a durable batch latch
  `.batch-held` on any HOLD; `_drive` refuses to advance any task while the latch
  exists, until the captain clears it. `status` shows `batch-held`.

---

## 4.3 Mounted Entrypoint — `bin/fm-unattended.sh`

Thin wrapper, the **only** captain-facing entrypoint. Unchanged call contract:
```
fm-unattended.sh init|run|resume|status|next|handoff --batch B [--contract C]
```
- Resolves the implementation dir: explicit `$UC_IMPL_DIR` → installed sibling
  `fm-unattended-coordinator.sh` → repo `../implementation` (local/uninstalled).
- Execs the coordinator with `UC_IMPL_DIR` set so sibling scripts resolve.
- **Role separation:** refuses to run unless `UC_ENTRYPOINT_ROLE` is `captain`
  (default). It is a **producer** of durable batch state, never a supervisor: it
  never reads/writes `state/.afk` and never drains/acks the wake queue. The
  watcher/scheduler stays the supervisor.
- **No `/afk` conflict:** the controller writes only its own batch tree under
  `UC_HOME`; it does not read or write the away posture.

---

## 4.4 Mount & Rollback — `bin/fm-unattended-install.sh`

**Install file list** (`file-list`): wrapper + coordinator (renamed so it can live
beside the wrapper) + adapter/evidence/judge/guard/config/quota/autoteardown:

```
bin/fm-unattended.sh                              -> bin/fm-unattended.sh
implementation/fm-unattended.sh                   -> bin/fm-unattended-coordinator.sh
implementation/fm-unattended-{adapter,evidence,judge,guard,config,quota,autoteardown}.sh -> bin/…
```

`implementation/fake-auditor.sh` is deliberately **not** installed (defense in
depth: the test double must not sit next to the production entrypoint; production
already refuses a fake auditor by contract + judge).

**Safety contract**
- `--root` is mandatory; the script never defaults to the home; `/` and a missing
  root are refused.
- **No overwrite** of an existing target this tool does not own (no manifest record,
  or changed since install) → refuse, target untouched.
- **Per-file before/after sha256** in `<root>/.fm-unattended-manifest.json`.
- **Partial-install failure handling:** every source is staged and every overwrite
  policy checked *before* any target is written; a mid-commit failure restores the
  files committed so far from `<root>/.fm-unattended-backup/`.
- **Idempotent unmount:** a second `uninstall` is a clean no-op; a file whose bytes
  differ from the recorded after-hash (user edit) is **kept**, not deleted.
- **Verification command:** `verify --root R` re-hashes every manifest entry.
- **Isolated rehearsal:** `rehearse [--root R]` runs install → verify → unmount →
  clean; default root is a fresh temp dir and a real home path is refused.

---

## 4.5 Auto-teardown Policy — `implementation/fm-unattended-autoteardown.sh`

A **policy/decision helper only**; it never tears anything down (cleanup stays with
the firstmate teardown owner, separately approved). **Disabled by default**
(`UC_AUTOTEARDOWN_ENABLE=1` required) — **not enabled in production**.

A task is eligible only when **all six** hold:
1. terminal state `VERIFIED_PASS`;
2. pending inbox `0` (real home `state/<spawn>.inbox/`, or the batch-local count);
3. **zero captain calls** (no open decision on the task);
4. evidence persisted and re-readable (`rc=0` + artifact manifest + gate verdict
   `VERIFIED_PASS`);
5. session ownership verified (every session bound to the task owns it and records an
   identity — no orphan/foreign session);
6. no other active work using the resources (no other non-terminal task in the batch).

Any failed condition is an exact refusal; anything unevaluable is a refusal
(fail-closed). CLI: `enabled`, `check --batch-dir D --task T [--home H]`,
`plan --batch-dir D [--home H]`. `check` exits `0` eligible, `3` refused, `4` disabled.

---

## What is deliberately NOT done

- **Not installed into the operational home.** Only the temp-dir rehearsal ran.
- **Auto-teardown not enabled.** Rule designed + tested only.
- **Quota not turned on by default.** It activates only with a config/`UC_QUOTA_ENFORCE`.
- **No merge, push, PR, watcher/scheduler/launchd change, credential change, or
  provider call.**

## Test mapping

| Feature | Suite |
|---|---|
| Evidence root (config/default/permissions/collision/escape/restart) | `tests/evidence-root.test.sh` (11) |
| Quota caps / allow-list / unknown-HOLD / integration / latch | `tests/quota.test.sh` (13) |
| Entrypoint contract + role + install/verify/unmount/rollback/rehearse | `tests/entrypoint.test.sh` (14) |
| Auto-teardown six-condition rule + disabled default | `tests/autoteardown.test.sh` (11) |
