# Approval gates

> **Update 2026-10-08 (real-E2E integration batch).** This batch added **no**
> gate. It wired the coordinator's `real` backend end to end and proved it
> offline with a mock firstmate home replaying the recorded canary fixture
> (`handoff/real-e2e-integration-status.md`). It made **zero** real provider
> calls and **zero** GitHub writes, and changed nothing outside the isolated
> worktree branch.
>
> A single **LIVE** real E2E now needs its own new, minimal approval — a NEW
> pair beyond the consumed G1/G2: **1 real Executor Scout + 1 real Auditor
> Scout** (2 provider calls), no retry, isolated worktrees, no GitHub write, no
> operational apply. That pair is **NOT** authorized by this batch. **G3, G4,
> G5 remain NOT approved.**
>
> **Update 2026-10-08 (canary batch).** The captain gave a current, explicit,

> bounded in-chat approval for this work only: **G1 and G2 approved for exactly
> one real Scout + one real audit session each**, no retry, no GitHub write, no
> operational apply, no shared-instruction change. Both were executed once and
> closed — see `canary/canary-report.md` (Executor session
> `firstmate:fm-firstmate-unattended-canary-01`, Auditor session
> `firstmate:fm-firstmate-unattended-canary-01-audit`, Judge `VERIFIED_PASS`).
> Cleanup/teardown of the two completed Scout sessions was **not** part of that
> approval and remains an open approval. **G3, G4, G5 remain NOT approved.**
> The text below is the original standing gate definition, preserved.

Nothing below is authorized by this batch. Each gate needs an explicit,
in-the-moment captain decision naming the concrete action.

## G1 — Real worker/provider dispatch
- **Action**: implement and run the `real` adapter backend (spawn/steer/status a
  real firstmate worker).
- **Why it needs approval**: it spends quota and starts real agents in real
  worktrees. This batch forbade it.
- **Preconditions**: `bin/fm-spawn.sh`, `bin/fm-send.sh`, `bin/fm-crew-state.sh`
  callable; dispatch profile resolved; the task contract's `allowed_paths` and
  `forbidden_operations` enforced.
- **Status 2026-10-08**: APPROVED (1 call) and EXECUTED; real backend implemented
  in `implementation/fm-unattended-adapter.sh` (`_real_dispatch`); preflight GO.

## G2 — Real independent AI audit
- **Action**: replace `fake-auditor.sh` with a real out-of-session auditor and
  run it in `mode=production`.
- **Why**: the final audit status is `AUDIT_UNAVAILABLE` until this runs; only
  then may `INDEPENDENTLY_VERIFIED` be claimed.
- **Status 2026-10-08**: APPROVED (1 call) and EXECUTED; real auditor Scout in a
  separate session/worktree returned verdict PASS; Judge `VERIFIED_PASS`.

## G3 — GitHub write / PR
- **Action**: push the branch and open a PR for the mounted implementation.
- **Why**: this batch made zero GitHub writes. Merge authority stays with the
  captain regardless of any `yolo` posture.

## G4 — Operational application
- **Action**: mount the controller into `bin/`, wire an entrypoint, point
  `EVIDENCE_ROOT` at a durable location, and enable it in the live home.
- **Why**: changes the operational runtime. `DEPLOYED` must not be claimed
  before this gate.

## G5 — Firstmate instruction change
- **Action**: update `AGENTS.md` / `.agents/skills/` to describe the controller.
- **Why**: shared tracked material; must preserve every safety boundary, not
  expand delegation authority, and not describe an unbuilt feature as done.

## Standing boundaries that no gate relaxes
Destructive, irreversible, and security-sensitive actions; credential/PAT/SSH
changes; watcher/scheduler/launchd changes; wake drain; Backpass changes;
killing another session's processes; editing another worker's dirty files.
