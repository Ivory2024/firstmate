# pstack adaptation (Phase B input)

Source: `cursor/plugins`, `pstack/` (verified file names below, retrieved 2026-10-08).
pstack is NOT installed wholesale. Only design principles are ported into
firstmate's existing architecture.

## Verified sources consulted

- `pstack/skills/poteto-mode/SKILL.md`
- `pstack/skills/poteto-mode/playbooks/autonomous-run.md`
- `pstack/skills/poteto-mode/playbooks/orchestrate.md`
- `pstack/skills/poteto-mode/playbooks/session-pickup.md`
- `pstack/skills/poteto-mode/playbooks/pause-safely.md`
- `pstack/skills/poteto-mode/playbooks/babysit.md`
- `pstack/skills/poteto-mode/playbooks/shipping.md`
- `pstack/skills/interrogate/SKILL.md`
- `pstack/skills/blast-radius/SKILL.md`
- `pstack/skills/principle-prove-it-works/SKILL.md`
- `pstack/skills/principle-sequence-verifiable-units/SKILL.md`
- `pstack/skills/principle-make-operations-idempotent/SKILL.md`

## Adopted

| pstack source | Principle | Where it lands in firstmate |
|---|---|---|
| `autonomous-run` | Own the exit condition as a checkable predicate; don't relax it to declare victory | Task contract carries the predicate; the deterministic judge is the only thing that can emit `VERIFIED_PASS` |
| `sequence-verifiable-units` | Small units, each verified before the next | Ordered `tasks[]` with `depends_on`; a task dispatches only after its deps are `VERIFIED_PASS` |
| `make-operations-idempotent` | Converge regardless of partial runs; idempotent scheduling; content-based cleanup | Dedup transition key; adopt live/completed runs; archive superseded attempt dirs; adapter refuses duplicate dispatch |
| `prove-it-works` | Check the real artifact, not a self-report; script the check; keep the artifact | `fm-unattended-evidence.sh` records raw stdout/stderr/exit/duration/sha256 manifest; judge never reads coordinator prose |
| `session-pickup` | Read the prior trail; diff done vs pending; don't redo; verify inherited claims | `state.jsonl` + `handoff.md` are the trail; `resume` adopts instead of re-running; judge re-checks the real evidence |
| `pause-safely` | Stop at a safe boundary; durable checkpoint; no irreversible action | `handoff.md` is the resume note; the coordinator never pushes, merges, or tears down |

## Excluded (deliberately)

- **Autonomous PR merge / autopilot.** pstack's `autopilot-full`/`autopilot-stack`
  and "land the stack even if CI flakes" are NOT ported. Merge authority stays
  with the captain; this work performs zero GitHub writes. The orchestrator stops
  at `VERIFIED_PASS` and hands off.
- **Cursor-specific runtime.** `/loop`, `subagent_type`, and the Cursor
  transcript store are replaced by firstmate's own watcher/wake queue and
  `state/` records.
- **Multi-model arena / swarm routing.** Firstmate already owns dispatch
  profiles (`config/crew-dispatch.json`, `bin/fm-dispatch-resolve.sh`); the
  adapter exposes a seam to them rather than importing pstack's model panel.
- **`show-me-your-work` commit culture.** Kept only as the evidence trail; no
  commit-per-iteration requirement, because the isolated worktree is scratch.

## Boundaries this adaptation keeps

The pstack principles are process discipline, not authority. Porting them cannot
expand firstmate's delegation or merge authority, weaken a safety rule, or
describe an unbuilt feature as done. The `real` adapter backend therefore refuses
with `INTEGRATION_HOLD` until a separate approval gate passes.
