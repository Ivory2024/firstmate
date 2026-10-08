# pstack gap analysis and adoption (Phase B/C)

Source: `https://github.com/cursor/plugins` at `main`, subtree `pstack/`.
Verified 2026-10-08 by read-only fetch of
`raw.githubusercontent.com/cursor/plugins/main/pstack/...`.

**Path note.** The mandate's referenced names are real, but their paths differ
from a flat `skills/<name>/`:
- `poteto-mode` is a skill: `pstack/skills/poteto-mode/SKILL.md`.
- `autonomous-run`, `orchestrate`, `session-pickup`, `pause-safely`, `babysit`,
  `shipping` are **playbooks** under `pstack/skills/poteto-mode/playbooks/*.md`,
  not standalone skills.
- `show-me-your-work`, `create-verification-skill`, `maintain-verification-skill`
  are skills: `pstack/skills/<name>/SKILL.md`.

Decision keys: `REUSE_EXISTING`, `ALREADY_IMPLEMENTED`, `IMPLEMENT_GAP`,
`DEFER_APPROVAL`, `NOT_APPLICABLE`.

The unlimited autonomous-execution and autonomous-merge policies of pstack are
**not** imported (mandate §5); only the safe, bounded ideas are.

---

## Area 1 — Task routing · unattended orchestration

- **pstack**: `playbooks/orchestrate.md` (coordinator owns the program, never
  the code; authors briefs, drains the queue, keeps the frontier green),
  `playbooks/autonomous-run.md` (state a checkable exit predicate, drive to it,
  checkpoint every iteration), `skills/poteto-mode/SKILL.md` (route a task to a
  playbook).
- **Firstmate**: `fm-unattended.sh` (coordinator state machine), dispatch
  profile + `bin/fm-dispatch-resolve.sh`, backlog, `/afk`, crewmate/scout/
  secondmate, `bin/fm-spawn.sh`/`fm-send.sh`/`fm-crew-state.sh`.
- **Gap found and fixed** (`IMPLEMENT_GAP`): the coordinator's real path could
  not spawn at all — `fm-spawn.sh` refuses a scout with no brief and, on a
  tasks-axi home, refuses an id with no dispatchable backlog row. Both were
  manual steps in the prior canary. Now `_real_dispatch` scaffolds the brief via
  `bin/fm-brief.sh` and fills the mission, and registers the backlog row via
  `bin/fm-tasks-axi.sh add`, both idempotently and fail-closed.
- **Reused** (`REUSE_EXISTING`): role separation (Executor/Auditor), safe next
  task selection (`cmd_next` + `_deps_ok`), approval hold
  (`approval_required → HOLD`), time budget (`ack_timeout_secs`,
  `UC_CREW_WAIT_SECS`), retry cap (`retry_limit`).
- **DEFER_APPROVAL**: pstack's "coordinator never authors code / lands verified
  units itself" is an operational-posture choice that belongs to G4, not this
  batch.

## Area 2 — Session handoff · safe stop

- **pstack**: `playbooks/session-pickup.md` (read the prior trail, don't redo
  it; diff done vs pending; route to the matching playbook),
  `playbooks/pause-safely.md` (stop at a safe boundary, take no irreversible
  action, commit `wip:`, write an off-context resume note).
- **Firstmate**: durable `state.jsonl` + `tasks/*.state` + `handoff.md`;
  `resume` adopts a live/completed run without re-dispatch;
  `tests/restart.test.sh` (7 cases) proves SIGKILL resume; `bin/fm-session-start.sh`
  + `stuck-crewmate-recovery`.
- **Status: `ALREADY_IMPLEMENTED`.** The coordinator's durable state is the
  "trail"; `resume` is the pickup; a completed executor is adopted, never
  re-run. No new store created.
- **`pause-safely`** maps to firstmate's existing handoff before `/clear`; the
  coordinator writes `handoff.md` on every run/resume. No new code; the
  operational `/clear` was NOT executed in this batch.

## Area 3 — Decision record · evidence trail

- **pstack**: `skills/show-me-your-work/SKILL.md`. Row =
  `ts, phase, decision, why, evidence (SHA/PR/file:line/artifact path), result`.
  Rules: evidence is a link/path, never a paragraph; the log must be auditable
  against the transcript.
- **Firstmate**: `state.jsonl` already records
  `at, run_id, task_id, attempt, session, baseline_sha, prev, new, reason,
  evidence`; `evidence/runs/<task>/gate/verdict.json` + `artifact-manifest.json`
  are the proof artifacts.
- **`ALREADY_IMPLEMENTED`** as the durable store (no duplicate store added; the
  mandate forbids that). **`IMPLEMENT_GAP`** as a *view*: `verification/decision-trail.sh`
  derives the show-me-your-work columns from the existing `state.jsonl` and gate
  files. Verified by `verification/check-drift.sh` and the final report.

## Area 4 — Reusable verification procedure

- **pstack**: `skills/create-verification-skill/SKILL.md` (interview the repo:
  surface/run/drive/observe/isolate; seed a feature map; prove the skill),
  `skills/maintain-verification-skill/SKILL.md` (outcomes clean/changed/blocked;
  map drift detection; live pass required even when source looks clean).
- **Firstmate**: `tests/run-all.sh`, the four suites, `verification/verify-local.sh`.
- **Gap** (`IMPLEMENT_GAP`): there was no feature→test map and no drift check.
  Added `verification/verification-map.md` (feature → runnable test command →
  fresh evidence) and `verification/check-drift.sh` (fails when a mapped file or
  command disappears, and re-runs the suite). The map marks mock vs real
  evidence, per the mandate.

## Area 5 — PR watch · independent shipping verification

- **pstack**: `playbooks/babysit.md` (declare a mode; clear the lowest unmerged
  PR first; classify conflicts→threads→CI; owner approval is a wait, not a
  merge), `playbooks/shipping.md` (one independent verifier per PR; CI green is
  not a verdict; land only the contiguous verified run; re-check the verdict's
  patch-id after a rebase).
- **Firstmate**: `bin/fm-pr-check.sh` + watcher merge poll, `bin/fm-pr-merge.sh`
  (merge metadata, refuses an unproved merge), `state/<id>.merge-authority`,
  AGENTS.md §7 (Firstcrew final acceptance; `yolo` governs merge authority;
  CI-green alone insufficient; red merge needs an explicit attended waiver).
- **Status: `REUSE_EXISTING`** for the live path. **`IMPLEMENT_GAP`** for a
  read-only classifier that makes the `merge-ready` vs `merge-authorized`
  distinction explicit and testable: `verification/pr-classify.sh` reads a PR
  JSON fixture (no network, no write) and returns
  `ready-not-authorized | authorized-not-ready | ready-and-authorized | blocked`.
  **`DEFER_APPROVAL`**: any real PR write is G3 and not performed.

---

## Adoption summary

| Area | Decision | Artifact |
|---|---|---|
| 1 routing/orchestration | REUSE + IMPLEMENT_GAP (brief+backlog) | `implementation/fm-unattended-adapter.sh` |
| 2 handoff/safe-stop | ALREADY_IMPLEMENTED | `tests/restart.test.sh`, `state.jsonl`, `handoff.md` |
| 3 decision/evidence | ALREADY_IMPLEMENTED (store) + IMPLEMENT_GAP (view) | `verification/decision-trail.sh` |
| 4 verification procedure | IMPLEMENT_GAP | `verification/verification-map.md`, `verification/check-drift.sh` |
| 5 PR watch/shipping | REUSE_EXISTING + IMPLEMENT_GAP (read-only classifier) | `verification/pr-classify.sh` |

Not imported: unlimited autonomous execution, autonomous merge, a new store
duplicating firstmate's evidence, and pstack's multi-model `swarm`/`arena`.
