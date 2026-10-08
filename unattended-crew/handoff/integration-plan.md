# Integration plan

The MVP is isolated and fake-backend only. This is the ordered path to a real,
approved integration. Every step needs its own approval gate
(`approval-gates.md`); none is authorized by this batch.

## 1. Mount the controller in firstmate

- Move `implementation/fm-unattended*.sh`, `fake-auditor.sh` into `bin/` and
  `implementation/*.test.sh`/`tests/*` into `tests/` on a project branch.
- Rename to firstmate style if desired (`bin/fm-unattended.sh` already fits).
- Keep `contracts/` and `architecture/` as `docs/` entries.
- Run `bin/fm-lint.sh` over the mounted files and the shared tracked-material
  rules from `firstmate-coding-guidelines` before any PR.

## 2. Implement the `real` dispatch backend

In `fm-unattended-adapter.sh`, the `real` backend (`_real_dispatch`) is now
implemented and was used for the canary (see `canary/canary-report.md`). It maps
the adapter verbs onto the existing primitives, with no duplication:

- `dispatch` → resolve dispatch profile (`bin/fm-dispatch-resolve.sh`,
  `config/crew-dispatch.json`), then `bin/fm-spawn.sh <task> <project>
  --mode <m> --yolo <off> --harness/--model/--effort`.
- `identity` → read `state/<id>.meta` (`window`/`backend`), verify it matches.
- `send` → `bin/fm-send.sh <target> ... <text>` (durable inbox).
- `status` → `bin/fm-crew-state.sh <id>` (one deterministic state line).
- Lifecycle `interrupt|exit|relaunch` stays supervisor-owned; the coordinator
  must never call it.

## 3. Replace the fake auditor with a real out-of-session auditor

**Status 2026-10-08**: the real auditor path is implemented (`_dispatch_auditor_real`
spawns a second Scout, harvests its verdict as `auditor/findings.json` with
`auditor_kind: real`); `mode=production` refuses the fake auditor at the
coordinator and in the judge. The real crew dispatch itself still needs its own
approval.

- Point `audit.command` at a real worker (a second worker session, separate
  worktree and identity), returning the same `auditor/findings.json` schema
  with `auditor_kind: real`.
- The judge already refuses `VERIFIED_PASS` for a fake auditor in
  `mode=production`; in production the audit must be real.

## 4. Evidence and backlog wiring

- Point `EVIDENCE_ROOT` at a durable home-adjacent location, not `/tmp`.
- Optionally mirror a batch task to the tasks-axi backlog; never merge or tear
  down from the coordinator.

## 5. Operational posture

- Wire the coordinator behind an explicit captain entrypoint (a new command or a
  session-start hook), never as a replacement for `/afk` or the watcher.
- Ship the whole change through firstmate's no-mistakes pipeline and PR path.

## Ordering rationale

Steps 1–2 can be validated with the fake backend still in place; step 3 is the
first real provider call and therefore the first hard gate; step 4–5 are
operational and stay behind the remaining gates. Do not start step 3 before a
real-worker approval explicitly names this work.
