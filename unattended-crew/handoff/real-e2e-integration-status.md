# Real E2E integration status — unattended crew orchestrator (2026-10-08)

Baseline SHA `5f4a10281937c4999138d61b945589d829c25d34`, isolated branch
`fm/unattended-crew-orchestrator-20261008`, isolated worktree HEAD `769e81eb`
before this batch. All changes are under `unattended-crew/` in the isolated
worktree. The operational home, watcher, scheduler, credentials, and GitHub
were not changed. **No real provider or AI audit was called in this batch.**

## 1. 구현 상태

**`IMPLEMENTED`** — the coordinator's `real` backend now drives the FULL
pipeline automatically: Task Contract → Real Executor Dispatch → ACK/상태 추적 →
Evidence Collection → Real Independent Auditor Dispatch → Audit Evidence →
Deterministic Judge → Durable Handoff.

## 2. 검증 상태

**`LOCALLY_TESTED`** — 49/49 suite cases green (30 pre-existing + 19 new
real-E2E cases) plus a separate local verification process (10/10). The real
crew audit ran in the PREVIOUS canary batch (G1/G2); this batch ran no AI audit,
so this real-E2E work is **not** claimed as `INDEPENDENTLY_VERIFIED`.

## 3. 통합 상태

**`REAL_E2E_READY_FOR_CANARY`** — the real path is wired end to end and proven
offline against a mock firstmate home that replays the recorded canary fixture.
**`INTEGRATION_HOLD`** for a LIVE unattended real E2E: the one remaining step is
the actual provider call, which is gated (section 6).

## 4. 실제 연결된 인터페이스

The coordinator reuses firstmate's existing lifecycle; it builds no parallel
agent framework.

| Interface | Implementation | Reuses |
|---|---|---|
| `dispatch(contract, role)` | `fm-unattended-adapter.sh` `_real_dispatch` | `bin/fm-spawn.sh <id> <project> --scout` (isolated worktree) |
| `observe(task_id)` | `fm-unattended-adapter.sh` `_real_status` | `bin/fm-crew-state.sh` (one deterministic state line) |
| `identity` | `fm-unattended-adapter.sh` `_real_identity` | `state/<id>.meta` `window` (fail-closed if absent) |
| `send` | `fm-unattended-adapter.sh` `_real_send` | `bin/fm-send.sh` (durable inbox) |
| `collect_evidence(task_id)` | `fm-unattended-evidence.sh collect` | `state/<id>.meta`, `state/<id>.status`, `fm-crew-state.sh`, `data/<id>/report.md`, worktree SHA |
| `request_audit(evidence)` | `fm-unattended.sh` `_dispatch_auditor_real` | a SECOND `fm-spawn.sh` Scout in a different worktree |
| `collect_audit(id)` | `fm-unattended.sh` `_dispatch_auditor_real` | auditor report verdict, `auditor/findings.json` |
| `judge(run_id)` | `fm-unattended-judge.sh` (deterministic, unchanged floor) | structured evidence only |
| `resume(run_id)` | `fm-unattended.sh` `resume` + `_step_real` | durable `state.jsonl`, `tasks/*.state`, session record |

Mechanics required by the mandate and how they are met:

- **dispatch profile**: the adapter passes explicit `--harness/--model/--effort/
  --backend`; the operator resolves the profile with `bin/fm-dispatch-resolve.sh`
  / `config/crew-dispatch.json` before dispatch (unchanged; the adapter refuses
  to guess a model).
- **Task ID ↔ Session ID**: session id = the spawned `window`; `state/<id>.meta`
  holds `window`/`endpoint_task_id`; the adapter records `spawn_id`.
- **ACK timeout**: `_real_wait_ack` polls `fm-crew-state.sh` for a live endpoint
  within `ack_timeout_secs`. Spawn success alone is NEVER an ACK; a dead/absent
  endpoint or an expired window is `REWORK ack-timeout`.
- **heartbeat / 완료 상태**: `_real_wait_done` polls `fm-crew-state.sh`
  (`done`→complete, `failed|absent|unknown`→dead, timeout→ still running, no
  false success).
- **역할별 workspace 격리**: executor runs in the spawned worktree; the auditor
  is a separate Scout with its own worktree; the judge holds on
  `auditor-executor-same-workspace`.
- **중복 dispatch 방지**: the adapter refuses `DUPLICATE_DISPATCH` for a live
  binding; resume adopts a live/completed run instead of re-spawning.
- **재시작 후 재연결**: `_step_real` reads the recorded `session-id`/`spawn-id`
  and reconnects; a SIGKILLed coordinator never re-dispatches (case 12).
- **실패한 작업의 안전한 HOLD**: every unrecoverable path ends in `HOLD`
  (worker-interrupted, evidence-incomplete, retry-exhausted, identity-mismatch).
- **durable 기록**: every transition appends to `state.jsonl`; current state in
  `tasks/<id>.state`; handoff in `handoff.md`.
- **fail-closed**: missing home, missing spawn id, or unmatched identity refuses
  with a nonzero exit rather than selecting a wrong session.

## 5. 아직 mock인 부분

Only the FIRSTMATE HOME is mocked, and only in the offline test. The mock is a
test double that replays the recorded canary fixture:

- `tests/mockhome/bin/fm-spawn.sh` — writes the same `state/<id>.meta`,
  `state/<id>.status`, `data/<id>/report.md` records and a background
  completion writer. Failure injection: `MOCK_SPAWN_FAIL`, `MOCK_DEAD`,
  `MOCK_NO_DONE`, `MOCK_FAIL`, `MOCK_NO_REPORT`, `MOCK_AUDIT_SPAWN_FAIL`,
  `MOCK_AUDIT_VERDICT`, `MOCK_NO_VERDICT`, `MOCK_SAME_WORKSPACE`,
  `MOCK_DONE_DELAY`.
- `tests/mockhome/bin/fm-crew-state.sh`, `fm-send.sh`, `fm-teardown.sh`.
- Fixtures are the recorded canary reports (executor sha256
  `dce1fa159403f4667f09d196c3f8bd231a995d83c3d87afdfa2f4b0eb32cb259`, matching
  `canary/canary-report.md`).

The production path is NOT mocked: the coordinator, evidence collector, auditor
harvest, and judge are the real ones. Swapping the mock home for the real home
changes only the `fm-spawn`/`fm-crew-state`/`fm-send` binaries the adapter calls.

One honest limitation: for a real interactive crew there is no single shell
command to capture, so `executor/stdout/cmd.out` is the harvested report+status
and `command-log.jsonl` records the dispatch event (or a crew-attested log when
the contract supplies `executor.attest`). This is documented, not hidden.

## 6. 실행한 테스트와 원본 결과

- Full suite: `tests/run-all.sh` → 4 suites, 49 cases, 0 failures.
  Raw: `evidence/test-results/{coordinator,judge,restart,real-e2e}.out`.
- New real-E2E suite: `tests/real-e2e.test.sh` (19 cases) — normal path,
  workspace separation, spawn refusal, dead endpoint (no ACK), missing completion
  event, worker failure, evidence incomplete, evidence tamper→HOLD, auditor
  spawn failure (bounded retry), missing audit verdict→AUDIT_UNAVAILABLE,
  auditor conflict, same workspace, SIGKILL+resume (no duplicate dispatch),
  approval-required hold, fake-auditor-in-production block (both backends).
- Separate local verification process: `verification/verify-local.sh` →
  `verification/local-check.json` `{"ok":10,"fail":0,"independent_ai_audit":false}`;
  raw `verification/run-all.out`.
- Lint: `bin/fm-lint.sh` exit 0 on all five implementation scripts and the mock
  helpers (ShellCheck).

## 7. 수정 파일과 SHA

See `handoff/real-e2e-files.sha256`. Changed since `769e81eb`:

- `implementation/fm-unattended.sh` (+204/-…): real backend dispatch/observe/
  collect/audit/judge wiring, ACK gate, bounded audit retry, flattened
  per-task contract.
- `implementation/fm-unattended-adapter.sh` (+119/-…): real `identity`/`send`/
  `status`, no self-issued ACK, fail-closed refusals.
- `implementation/fm-unattended-evidence.sh` (+77/-…): `collect` mode for a real
  crew, same evidence layout as `run`.
- NEW `tests/real-e2e.test.sh`, `tests/mockhome/**`, `verification/verify-local.sh`.
- `tests/run-all.sh`: add the `real-e2e` suite.

## 8. real E2E 실행에 필요한 정확한 승인 범위

A single LIVE real E2E = **2 real provider calls** (1 Executor Scout + 1 Auditor
Scout) in isolated worktrees, plus the resolved dispatch profile. Minimal
approval unit:

- 1 × `fm-spawn.sh <id> <firstmate> --scout --harness <H> --model <M> --effort <E> --backend tmux` (executor, read-only contract),
- 1 × `fm-spawn.sh <id>-audit <firstmate> --scout ...` (separate auditor),
- no retry, no GitHub write, no operational apply, no shared-instruction change.

This is a NEW pair beyond the already-consumed G1/G2; it is not authorized now.

## 9. 첫 60분 무인 배치 실행 조건

- Offline (mock/fake): already possible — 49/49 in well under 60 minutes,
  restart-resume proven.
- Live: the real path is wired, but on the free opencode model a single survey
  took ~5–10 minutes (canary §10). For a 60-minute unattended window: cap one
  real task per window, keep `UC_CREW_WAIT_SECS` bounded, and require the audit
  step's own `AUDIT_UNAVAILABLE` fallback. Do not claim 60-minute live
  completion until the live E2E of section 8 runs once.

## 10. G4 운영 적용의 선행 조건

1. A successful LIVE real E2E (section 8) with Judge `VERIFIED_PASS`.
2. Point `EVIDENCE_ROOT` at a durable home-adjacent location (not `/tmp`).
3. Mount `implementation/fm-unattended*.sh` into `bin/` and run the repo lint +
   no-mistakes pipeline.
4. Wire an explicit captain entrypoint (never a replacement for `/afk` or the
   watcher).
5. Fail-closed teardown of completed crews under an approved rule.

## 11. 자동 반복 스케줄러의 별도 선행 조건

1. G4 operational application complete.
2. A repeat-run quota/session cap rule.
3. An approved automatic teardown rule for completed crews.
4. An approved failure policy (auto-retry cap, auto-HOLD notification).
5. The opencode free-model health catalog gap resolved.

## 12. `/clear` 안전 여부

**Safe.** This batch changed nothing outside the isolated worktree branch; the
operational home is unchanged. Durable evidence lives in
`evidence/`, `verification/`, and `handoff/`. `/clear` loses no durable state.

## 안전 경계

- 실제 provider 호출: **0** (this batch). 이전 canary의 G1/G2 각 1회는 소비 완료.
- GitHub write (push/PR/merge): **0**.
- 운영 home 변경: **0** (tracked 파일, config/, watcher, scheduler, launchd,
  credential/PAT/SSH, Backpass 모두 불변).
- 다른 세션 영향: **0** (타 세션 프로세스 종료·dirty 파일 수정 없음).
- wake drain: **0**.
