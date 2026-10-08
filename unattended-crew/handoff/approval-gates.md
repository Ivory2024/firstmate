# Approval gates

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

## G2 — Real independent AI audit
- **Action**: replace `fake-auditor.sh` with a real out-of-session auditor and
  run it in `mode=production`.
- **Why**: the final audit status is `AUDIT_UNAVAILABLE` until this runs; only
  then may `INDEPENDENTLY_VERIFIED` be claimed.

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
