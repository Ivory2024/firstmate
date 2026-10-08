# Executor Evidence Guard (P2 design + P3 regression)

Status: **IMPLEMENTED + LOCALLY_TESTED** (2026-10-08). Isolated dev worktree only;
no home/project/GitHub change.

## 1. Problem (root cause of the earlier HOLD)

The single-run canary held because a real Executor report asserted two numbers
that disagreed with its own raw evidence:

- families claimed **14**, actual **15**;
- assertions claimed **26**, actual **25**.

The independent Auditor detected both and the Judge returned
`{"verdict":"HOLD","reasons":["audit-conflict"]}`. That is correct fail-closed
behaviour, but the disagreement was found only **after** a whole auditor crew had
been spawned and run. The goal is not to relax the Auditor or the Judge; it is to
detect the same class of false claim **before** the auditor is spent.

## 2. What was built

New file `implementation/fm-unattended-guard.sh` — a deterministic, read-only
**Executor Evidence Guard** the coordinator runs between evidence collection and
auditor dispatch.

The task contract may declare `executor.claims`, a list of values the Executor's
report asserts, each with a machine-derived canonical source:

```json
{ "id": "families", "kind": "count",
  "report_pattern": "패밀리\\s*([0-9]+)",
  "source": { "type": "cmd", "cmd": "bin/fm-test-run.sh --list-families",
              "reduce": "lines" } }
```

- `kind`: `count` (one number) or `set` (order-insensitive file/item list).
- `source.type`:
  - `cmd` — run the command **in the Executor worktree** and reduce stdout. This
    is the independent canonical derivation.
  - `report` — reduce the report text itself. This is self-contradiction
    detection: the summary number vs the verbatim capture the report also
    embeds.
- reducers: `lines` (non-empty stripped lines; length = count) and
  `count_re:<ERE>` (number of matching lines).
- `required` (default true): a claim the report never asserts is a failure.
- When `report_pattern` is omitted for a `count` claim, the default structured
  form is `StructClaim: <id> = <n>` (case-insensitive). The Executor brief asks
  for that low-friction form so the model copies the exact printed number rather
  than paraphrasing or hand-computing it.

Design rules satisfied (mandate P2.3): canonical source is explicit; values are
derived mechanically; claimed vs canonical are compared; mismatches are printed
exactly (`guard.json` + `reasons`); missing evidence fails closed; the guard never
mutates the report or evidence; report self-contradiction is detected; wording
vs fact is separated (only the declared numeric/item claims are judged);
non-evaluable claims are never marked verified; contracts without claims stay
compatible (no-op PASS).

## 3. Coordinator wiring

`implementation/fm-unattended.sh`:

- new `GUARD="$IMPL_DIR/fm-unattended-guard.sh"`.
- new `_evidence_guard <batch> <task>` runs the guard against
  `runs/<task>/task-contract.json`, the collected `executor/report.md`, and the
  recorded executor worktree, writing `runs/<task>/gate/guard.json`. Any nonzero
  result (mismatch **or** guard error) blocks.
- both the real (`_step_real`) and fake (`_step`) `EVIDENCE_PENDING` branches now
  run the guard first: pass → `AUDIT_PENDING`; block →
  `HOLD reason=evidence-guard-mismatch` (never reaching an auditor dispatch).

`contracts/task-contract.schema.json` documents `executor.claims` with
`additionalProperties:false` so a malformed claim table is rejected at authoring
time.

## 4. P3 regression results

Full suite (fresh evidence dir):

```
# coordinator.test.sh PASS=12 FAIL=0
# judge.test.sh PASS=11 FAIL=0
# guard.test.sh PASS=17 FAIL=0
# restart.test.sh PASS=7 FAIL=0
# real-e2e.test.sh PASS=24 FAIL=0
# pr-classify.test.sh PASS=7 FAIL=0
# run-all: 6 suites; fail=0
```

(59/59 before → **78/78** now; real-e2e 22 → 24.)

Separate local verification process (`bash verification/verify-local.sh`):
**11 ok, 0 fail** (`verification/local-check.json`, `independent_ai_audit:false`).

Mandate P3 test table → where it is proven:

| Required test | Proof |
|---|---|
| 15 vs 14 detected | `guard.test.sh` "count 14 vs canonical 15 => MISMATCH" + `real-e2e.test.sh` #18 |
| 25 vs 26 detected | `guard.test.sh` "assertion 26 vs 5 ok-lines (self-contradiction) => MISMATCH" |
| exact numbers → PASS | `guard.test.sh` "count exact (15==15) => PASS" |
| file missing detected | `guard.test.sh` "set missing file => MISMATCH" |
| file duplicate detected | `guard.test.sh` "set duplicate item => MISMATCH" |
| list order difference → PASS | `guard.test.sh` "set order difference => PASS" |
| raw evidence missing → fail-closed | `guard.test.sh` "missing report => fail-closed" |
| malformed → clear error | `guard.test.sh` "malformed contract => exit 2 error" |
| existing report compatibility | `guard.test.sh` "no claims declared => PASS" |
| duplicate dispatch idempotency | `real-e2e.test.sh` #12, `coordinator.test.sh` #2 |
| ACK / timeout stability | `coordinator.test.sh` #3, `real-e2e.test.sh` #3, #4 |
| auditor handoff contract | `real-e2e.test.sh` #8–#11, #12c |
| Judge HOLD/PASS boundary | `judge.test.sh` (11 cases) |

Lint: `shellcheck` clean on `fm-unattended-guard.sh` and `fm-unattended.sh`
(test files carry only the same SC2015/SC1091 informational notes as the existing
suites). `bash -n` clean.

## 5. Independent review status

- A **separate local verification process** (`verify-local.sh`) re-runs the full
  suite in a fresh environment and independently exercises the judge floor and
  the production fake-auditor block — recorded, but explicitly **not** an AI
  audit (`independent_ai_audit:false`).
- The **live independent audit** of the guard's real-path effect is the P4
  canary below: a separate real auditor crew re-derives the executor's claims in
  its own worktree.
- No substitute reviewer was invented; the live canary auditor is the independent
  check that keeps confidence honest.

## 6. Boundaries kept

Minimal diff; no gate weakened (Judge rules and Auditor independence unchanged);
the guard only adds an earlier, independent check; no evidence was edited to make
a test pass; the operational home was not modified.
