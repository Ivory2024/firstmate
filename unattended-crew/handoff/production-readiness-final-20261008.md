# 무인 크루 Orchestrator 운영 준비 최종 보고서 — `firstmate-unattended-production-readiness-20261008`

작성 2026-10-08. 하나의 통합 배치, 하나의 run_id
(`firstmate-unattended-real-e2e-canary-20261008`), 하나의 최종 보고서.
코드·명령·파일명·상태값은 원문을 유지한다.

## 1. Executive Summary

- pstack 5대 영역을 원본(`cursor/plugins@pstack`)과 비교했다.
- Coordinator real 경로의 치명 결함 2건을 찾아 고쳤다:
  (a) 실제 seam 이 brief/backlog 없이는 spawn 자체가 거부되던 문제,
  (b) auditor 완료 대기를 ACK 창(90s)으로 오판하던 문제 + real 경로 중복 dispatch 가드 부재.
- **Live Real E2E Canary 1회** 실행: Coordinator가 `run` 1회로 실제 Executor Scout와
  실제 Auditor Scout를 **순차 자동** 생성·관찰·감사·판정했다. 사람이 두 크루를 손으로
  연결하지 않았다. Judge `VERIFIED_PASS`.
- 정직한 한계: 첫 `run`이 (b) 결함으로 `AUDIT_UNAVAILABLE`에서 멈췄고, 수정 후
  **같은 batch를 `resume`**으로 재개해 **이미 실행 중이던 동일 Auditor를 adopt**하여
  완료했다(새 크루 생성 0). 즉 성공은 "1회 run + 결함수정 + 재관찰"의 결과다.
- 운영 home tracked 파일 불변(13 dirty 그대로). G3/G4/G5 미실행.

## 2. 시작·종료 시각 및 실제 소요 시간

- Batch init: 2026-10-08T10:36:47Z
- 첫 `run`: 10:36:55Z → 10:46:52Z (AUDIT_UNAVAILABLE 종료)
- 결함 수정 + 로컬 재검증: 10:46Z → 10:58Z
- `resume`(adopt): 10:58:16Z → 10:58:17Z → `VERIFIED_PASS`
- 총 wall-clock: 약 28분. Executor 활성 10:37:11Z→10:44:13Z(≈7분), Auditor 활성 10:44:30Z→10:52:13Z(≈7.7분).

## 3. 구현·검증·통합 3축

| 축 | 판정 | 근거 |
|---|---|---|
| Implementation | **`IMPLEMENTED`** | Coordinator·adapter·evidence·judge 정상; real 경로 결함 2건 수정; pstack 안전 기능 보완 |
| Verification | **`LOCALLY_TESTED`** | 5 suites 59/59 + 분리 로컬 검증 10/10 + drift 0. (구현 코드의 독립 AI 감사는 없음) |
| Integration | **`REAL_E2E_VERIFIED`** | 실제 Executor+Auditor 자동 위임, 실제 독립 감사 verdict PASS, Judge `VERIFIED_PASS` |

`DEPLOYED`는 선언하지 않는다(G4 미실행). `AUDIT_UNAVAILABLE`도 아니다(실제 감사 성공).

## 4. Coordinator Real E2E 검수 결과

`Task Contract → Executor Dispatch → ACK → Completion → Evidence → Auditor Dispatch →
Audit Evidence → Judge → Durable Handoff` 전 구간이 실제 코드로 동작함을 Live Canary로 확인.

발견·수정한 real 경로 결함:

1. **brief/backlog 부재로 spawn 불가** — `fm-spawn.sh`는 scout에 brief가 없으면 거부하고,
   tasks-axi home에서 backlog 행이 없으면 거부한다. 이전 canary는 운영자가 수동 생성했다.
   수정: `_real_dispatch`가 `bin/fm-brief.sh`로 brief를 생성하고 `{TASK}`/`{FIRSTMATE_SPEC}`를
   미션으로 채우며 `bin/fm-tasks-axi.sh add`로 backlog 행을 등록한다(멱등·fail-closed).
2. **auditor 완료 대기 오판** — 완료 대기에 `ack_timeout_secs`(90s)를 써서 실제 auditor(수분)를
   `AUDIT_UNAVAILABLE`로 오판했다. 수정: ACK는 ack 창, 완료는 `UC_CREW_WAIT_SECS`로 대기.
   아직 작업 중이면 판정하지 않고 다음 `resume`으로 넘긴다.
3. **real 경로 중복 dispatch 가드 부재** — fake 경로에만 있던 `_find_binding` 중복 검사가
   real 경로에 없어 resume 시 재spawn 위험이 있었다. 수정: `_real_dispatch`에 멱등 가드 추가.
4. **AUDIT_UNAVAILABLE 관찰타임아웃 복구** — 살아있는 auditor가 있으면 `resume`이
   `AUDIT_UNAVAILABLE → AUDITING`으로 재진입해 **동일 크루를 adopt**한다(새 호출 없음).

회귀 방지: `tests/real-e2e.test.sh`에 slow-auditor 케이스와 `MOCK_REFUSE_DUP` adopt 케이스 추가.

## 5. pstack 5대 영역별 도입 현황

상세: `handoff/pstack-gap-analysis.md`. 경로 정정: `autonomous-run`·`orchestrate`·
`session-pickup`·`pause-safely`·`babysit`·`shipping`은 **플레이북**
(`pstack/skills/poteto-mode/playbooks/*.md`); `show-me-your-work`·
`create/maintain-verification-skill`은 스킬.

1. 작업 라우팅·무인 오케스트레이션 — `REUSE_EXISTING` + `IMPLEMENT_GAP`(brief+backlog 자동화).
2. 세션 인수인계·안전 중단 — `ALREADY_IMPLEMENTED`(`resume`·`state.jsonl`·restart 7/7).
3. 결정 기록·증거 추적 — `ALREADY_IMPLEMENTED`(저장소) + `IMPLEMENT_GAP`(뷰 `verification/decision-trail.sh`).
4. 재사용 검증 절차 — `IMPLEMENT_GAP`(`verification/verification-map.md`, `verification/check-drift.sh`).
5. PR 감시·독립 Shipping 검증 — `REUSE_EXISTING`(live 경로) + `IMPLEMENT_GAP`(읽기 전용 `verification/pr-classify.sh`).
미이식: pstack의 무제한 자율 실행·자율 merge·중복 evidence 저장소·swarm/arena.

## 6. 변경 파일·diff·commit SHA

기준 커밋 `58b27732` → 이번 배치 커밋(§부록 `handoff/production-readiness-files.sha256`).
`git diff --stat 58b27732 -- unattended-crew` = 14 files, +164/-35 (문서 제외 변화).

핵심 변경:
- `implementation/fm-unattended.sh` (brief/auditor wait/멱등/AUDIT_UNAVAILABLE 복구).
- `implementation/fm-unattended-adapter.sh` (brief 저작, backlog 등록, real 중복 가드).
- `contracts/task-contract.schema.json` (executor/audit intent·spec).
- 신규: `verification/decision-trail.sh`, `verification/check-drift.sh`, `verification/pr-classify.sh`,
  `verification/verification-map.md`, `tests/pr-classify.test.sh`, `tests/mockhome/bin/fm-brief.sh`.
- `tests/real-e2e.test.sh`(20→22), `tests/run-all.sh`(5 suites).

## 7. 전체 테스트·lint 결과

- `bash tests/run-all.sh` → 5 suites, **59/59**, fail 0:
  coordinator 12/12, judge 11/11, restart 7/7, real-e2e 22/22, pr-classify 7/7.
  원본: `evidence/test-results/*.out`, `evidence/command-log.jsonl`, `evidence/artifact-manifest.json`.
- 분리 검증 `verification/verify-local.sh` → 10/10, `verification/local-check.json`
  `{"ok":10,"fail":0,"independent_ai_audit":false}`.
- drift: `verification/check-drift.sh` → 0 drifted.
- lint: 구현 스크립트 + 신규 스크립트 `bin/fm-lint.sh` exit 0.

## 8. 실패 주입·재시작 복구 결과

`tests/real-e2e.test.sh`(mock home, 실제 provider 호출 없음) 커버:
spawn 실패, dead endpoint(무 ACK), 완료 이벤트 누락, worker 실패, evidence 누락,
hash mismatch(tamper→HOLD), auditor spawn 실패(상한 재시도), audit verdict 누락→AUDIT_UNAVAILABLE,
auditor conflict, 동일 workspace, SIGKILL+resume(중복 dispatch 없음, `MOCK_REFUSE_DUP`),
slow-auditor(crew budget 대기), AUDIT_UNAVAILABLE 관찰타임아웃 adopt, approval-required HOLD,
production fake-auditor 차단(양 backend), no-brief fail-closed.
`restart.test.sh` 7/7 재확인.

## 9. 실제 Canary 세션·worktree·모델

| 역할 | task id | session(window) | worktree |
|---|---|---|---|
| Executor | `firstmate-unattended-real-e2e-canary-20261008` | `firstmate:fm-firstmate-unattended-real-e2e-canary-20261008` | `/Users/irene/.treehouse/firstmate-697ce1/14/firstmate` |
| Auditor | `firstmate-unattended-real-e2e-canary-20261008-audit` | `firstmate:fm-firstmate-unattended-real-e2e-canary-20261008-audit` | `/Users/irene/.treehouse/firstmate-697ce1/15/firstmate` |

harness `opencode`, model `opencode/ling-3.1-flash-free`(비용 0), effort `low`,
backend `tmux`. primary checkout과 분리(슬롯 14 ≠ 15).

## 10. 실제 provider 호출 횟수

**2회**: `fm-spawn.sh` Executor 1 + Auditor 1. 자동 재시도 0, 추가 Executor/Auditor 0.
resume은 기존 Auditor를 adopt했을 뿐 새 호출이 아니다.

## 11. Executor/Auditor 원본 증거·hash

- Executor report: `data/firstmate-unattended-real-e2e-canary-20261008/report.md`,
  sha256 `4bfdf61aabee09042cff06f330b78528e834d19a678314a13b9d0e3d7559adf6`.
- Auditor report: `data/firstmate-unattended-real-e2e-canary-20261008-audit/report.md`,
  sha256 `48a4e9746f5b67598502ff533adfa462e72694c109528e6e1ec4d83e9fad36a3`.
- Executor evidence: `canary/real-e2e-20261008/.../evidence/runs/<task>/executor/`
  (`rc=0`, command-log, stdout/stderr, artifact-manifest, git-before/after, meta/status/crew-state).
- Auditor evidence: `.../auditor/findings.json` `{"verdict":"PASS","auditor_kind":"real"}`,
  `.../auditor/session.json` workdir slot 15.
- Auditor 보고서 verdict: `Verdict: PASS` — 카운트·대표 suite 재실행이 Executor와 일치.

## 12. Judge 판정

`evidence/runs/<task>/gate/verdict.json` → `{"verdict":"VERIFIED_PASS","reasons":[]}`, mode `production`.
조건: contract 존재, rc=0, stdout/stderr/log/manifest/git-before/after 존재, hash 일치,
실행 테스트 ≥ 요구, 금지 쓰기 없음, patch hash 일치, auditor_kind=real + verdict=PASS,
workspace 분리(14≠15). `VERIFIED_PASS`는 이 계약의 검증 성공일 뿐 운영 배포·PR 병합 승인이 아니다.

## 13. 금지 작업·운영 환경 불변 확인

- 실제 provider 호출: 승인된 2회(Executor/Auditor)만.
- GitHub write(push/PR/merge): **0**.
- 운영 home tracked 파일: **13 dirty 그대로, 변경 0**.
- config/·watcher·scheduler·launchd·credential/PAT/SSH·Backpass: **변경 0**.
- wake drain: **0**. 다른 세션 프로세스 종료·dirty 파일 수정: **0**.
- 승인된 부수 상태 생성: backlog row 2개, `state/<id>.meta`·`.status`, Treehouse worktree 2개,
  `data/<id>/brief.md`·`report.md`. (G1/G2 크루 생성의 일부)

## 14. 잔여 세션·teardown 필요 여부

- 두 Scout 세션(Executor=slot 14, Auditor=slot 15)과 tmux window 2개(`firstmate:1`,`firstmate:2`)가
  아직 살아 있다. 양쪽 pending inbox **0**.
- **teardown은 실행하지 않았다.** 자동 teardown 금지. 별도 승인이 필요하다(§20).

## 15. G4 운영 적용 준비도

`handoff/g4-operational-readiness-review.md`. G4는 **검토만** 했다. 선행 조건:
(1) 통과한 live canary(본 배치에서 충족), (2) durable `EVIDENCE_ROOT` 설정화,
(3) quota/동시성 상한, (4) 완료 크루 자동 정리 규칙 승인, (5) 실패 정책(retry cap·HOLD 알림),
(6) OpenCode 무료 모델 health catalog 해소 또는 allow-list.

## 16. 첫 60분 무인 배치 가능 여부

- 로컬(mock/fake): 59/59로 60분 내 완주 가능, 재시작 복구 검증됨.
- 실제: 본 canary의 실제 처리 시간은 Executor ≈7분 + Auditor ≈7.7분 ≈ 15분(two real tasks).
  단일 real task 기준 60분 창은 가능하나, 완료 관찰 타임아웃(`UC_CREW_WAIT_SECS`)과
  무료 모델 지연 변동을 고려해 **창당 real task 1개** 계약을 권장한다.

## 17. 1시간 반복 실행 가능 여부

**불가.** 별도 선행 조건: G4 적용, 반복 간 quota/세션 상한, 완료 크루 자동 정리 규칙,
실패 정책, health catalog. 이번 배치는 스케줄러를 만들지 않았다.

## 18. `/clear` 가능 여부

**가능.** 운영 home tracked 파일은 불변(13 dirty). durable 증거는
`canary/real-e2e-20261008/`·`evidence/`·`verification/`·`handoff/`에 남아 있다.
단 잔여 두 Scout 세션의 정리 승인을 받은 뒤 `/clear`를 권장한다.

## 19. 미완료 HOLD

- Live canary 잔여 크루 teardown — 미승인.
- G3(GitHub push/PR)·G4(운영 적용)·G5(공유 지침 변경) — 미승인.
- 1시간 반복 스케줄러 — G4 선행 필요.
- OpenCode 무료 모델 health catalog — 미해소.
- canary 첫 `run`의 관찰타임아웃 결함은 수정·회귀테스트 완료했으나, **새 batch에서
  단일 `run` 한 번으로 끝까지 통과하는 재확인**(결함수정 반영 live 재실행)은 미실행(HOLD).

## 20. Captain에게 필요한 다음 승인

1. **잔여 2개 크루 정리(teardown) 승인**:
   `bin/fm-teardown.sh firstmate-unattended-real-e2e-canary-20261008`,
   `bin/fm-teardown.sh firstmate-unattended-real-e2e-canary-20261008-audit`
   (운영 상태 변경).
2. **(선택) 단일 `run` live 재확인**: 수정 반영 후 새 real E2E 1쌍(Executor+Auditor 각 1회)
   승인 시, `resume` 없이 한 번에 `VERIFIED_PASS`인지 확인.
3. G4 운영 적용 검토 결과에 대한 go/no-go.
4. G3(push/PR)·G5(공유 지침)는 각각 별도 승인.
