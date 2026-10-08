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
- 후속 전용 승인으로 **잔여 Executor·Auditor 두 크루를 안전 정리**했다(§21, `TEARDOWN_VERIFIED`).
- 이어 고유 신규 batch로 **단일 run 무중단 재검증**을 실행했다(§22). 결론: `JUDGE_HOLD`.
  신규 run 1회가 수동 개입 없이 terminal까지 도달했으나, Auditor가 Executor 보고서의
  prose off-by-one 2건(패밀리 14≠15, assertion 26≠25)을 독립 검증으로 잡아 `CONFLICT`를
  반환했고 Judge가 `HOLD`(`audit-conflict`)로 정확히 거부했다. 즉 **무중단 기제는 작동**,
  **최종 성공 판정은 HOLD**(Executor 모델의 보고서 산술 실수, Coordinator 결함 아님).

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
| Verification | **`LOCALLY_TESTED`** | 6 suites 78/78 (guard 17·real-e2e 24 신규 포함) + 분리 로컬 검증 11/11 + drift 0. (구현 코드의 독립 AI 감사는 P4 실제 Auditor가 수행) |
| Integration | **`REAL_E2E_VERIFIED`** | 실제 Executor+Auditor 자동 위임, 실제 독립 감사 verdict PASS, Judge `VERIFIED_PASS` |
| Single-run uninterrupted | **`PASS`** | 신규 batch `firstmate-unattended-guard-canary-20261008`: 단일 run 무중단, 1 dispatch, resume/adopt/retry 0, Guard PASS, Auditor PASS, Judge `VERIFIED_PASS`. §23 |
| Deployment | **`NOT_DEPLOYED` / G4 NO-GO** | 운영 home 충돌 미해결로 G4 NO-GO(§23, `g4-operational-readiness-review.md`) |
| Crew cleanup | **`PASS`** | 선행 배치 두 Scout teardown 완료(§21); 본 배치 두 crew는 승인 밖이라 잔존(§23) |
| Executor Evidence Guard | **`IMPLEMENTED`** | 증거 수집↔Auditor 사이 결정적 대조, 불일치 시 `evidence-guard-mismatch` HOLD. §23 |

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

- **정리 완료.** 두 Scout(Executor slot 14, Auditor slot 15)와 tmux window 2개를
  공식 `bin/fm-teardown.sh`로 teardown했다. 결과·사후검증은 §21.
- teardown은 자동이 아니라 이번 전용 승인으로 실행했다. 다른 crew·pool·watcher는 건드리지 않았다.

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

- **단일 `run` 무중단 통과 검증** — 첫 run은 `AUDIT_UNAVAILABLE` 관찰타임아웃으로 멈췄고,
  수정 후 `resume`/adopt로 완료했다. 결함은 수정·회귀테스트 완료했으나, **새 batch에서
  단일 `run` 한 번으로 끝까지 통과하는 재확인**은 미실행.
- G3(GitHub push/PR)·G4(운영 적용)·G5(공유 지침 변경) — 미승인.
- 1시간 반복 스케줄러 — G4 선행 필요.
- OpenCode 무료 모델 health catalog — 미해소.
- Crew teardown은 이번에 완료(§21). HOLD 아님.

## 20. Captain에게 필요한 다음 승인

1. **신규 재검증 크루 2개 정리(teardown) 승인** (이번 재검증은 teardown 미포함):
   `bin/fm-teardown.sh firstmate-unattended-single-run-canary-20261008`,
   `bin/fm-teardown.sh firstmate-unattended-single-run-canary-20261008-audit`.
2. **(선택) Executor 보고서 충실도 개선 후 단일 run 재재검증**: Executor brief에
   "보고서의 개수 요약을 캡처와 대조하라"는 지시를 추가하거나 모델을 상향해 prose off-by-one을
   없앤 뒤, 신규 batch로 단일 run `VERIFIED_PASS` 재확인.
3. G4 운영 적용 검토 결과에 대한 go/no-go.
4. G3(push/PR)·G5(공유 지침)는 각각 별도 승인.

## 21. Crew cleanup 결과 (teardown, 2026-10-08)

**판정: `TEARDOWN_VERIFIED`.**

- 승인 범위: Executor `firstmate-unattended-real-e2e-canary-20261008`,
  Auditor `firstmate-unattended-real-e2e-canary-20261008-audit` 두 크루만.

사전 점검(읽기 전용): 두 id 모두 `kind=scout`, `endpoint_task_id` 일치,
worktree 가 각각 slot 14/15, `.fm-slot-owner` 소유자도 각 task/home과 일치,
다른 meta가 slot 14/15를 참조하지 않음, pending inbox 0, status `done`, Judge
`VERIFIED_PASS` 보존 확인.

실행:

| 명령 | exit | 원본 증거 |
|---|---|---|
| `bin/fm-teardown.sh firstmate-unattended-real-e2e-canary-20261008` | 0 | `canary/real-e2e-20261008/teardown-executor.out` |
| `bin/fm-captain-hold.sh complete <audit> --none` (teardown의 필수 completion gate) | 0 | `.../captain-hold-inventory.out` |
| `bin/fm-teardown.sh firstmate-unattended-real-e2e-canary-20261008-audit` | 0 | `.../teardown-auditor.out` |

정직한 기록: Auditor teardown은 첫 시도에서 **completion gate로 정상 거부**(rc=1)됐다
("has not passed the captain-call completion gate"). 강제·스크립트 수정·게이트 우회 없이,
Auditor 보고서 §5가 스스로 inventory한 대로(캡틴 콜 0) `fm-captain-hold.sh complete --none`을
기록한 뒤 재시도해 통과했다. Executor meta에는 이미 `decisions_reviewed=1`이 있어 게이트를 통과했다.

사후 독립 검증:

- 두 `state/<id>.meta`·`.status` 제거.
- tmux: canary window 2개 제거, 무관한 window `0 claude.exe` 유지.
- pool: slot 14/15 모두 `.fm-slot-owner` 제거, `HEAD=e70daed660f1f116c82b4fcd16e4e5d9510bd663`로 pooled 반환.
- backlog: 두 행 `[x]` 종료.
- 운영 home tracked dirty **13개, teardown 전후 fingerprint 동일**
  (`0c4c59e1aeb2ac84da8351c89618eae6789004f682a14510fa79efa076edddd8`).
- watcher·scheduler·launchd·credential·Backpass·wake queue 변경 0 (wake drain 안 함).
- E2E 증거·보고서·Judge verdict·`c6b49b54` 커밋 모두 보존.

## 22. 단일 run 무중단 재검증 (2026-10-08, 신규 batch)

**판정: `JUDGE_HOLD`.** 무중단 기제는 작동했으나, 성공 게이트(Judge `VERIFIED_PASS`)가
Executor 보고서의 산술 실수 때문에 충족되지 않았다.

- 신규 고유 batch/run: `firstmate-unattended-single-run-canary-20261008` (기존 배치 ID 미재사용).
- 시작 11:10:17Z → 종료 11:23:12Z (약 12.9분). `RUN_EXIT=0`.
- 상태 전이: `QUEUED → DISPATCHING → ACKNOWLEDGED → RUNNING(11:10:39) →
  EVIDENCE_PENDING(11:16:14) → AUDIT_PENDING(11:16:14) → AUDITING(11:16:30) → HOLD(11:23:12)`.
- 실제 spawn 2회(Executor 1, Auditor 1), `new=DISPATCHING` 1회, **resume/adopt/retry 0회**, 수동 개입 0회.
- Executor session `firstmate:fm-firstmate-unattended-single-run-canary-20261008`, worktree slot 14.
- Auditor session `firstmate:fm-firstmate-unattended-single-run-canary-20261008-audit`, worktree slot 15 (분리 확인).
- Auditor 독립 검증: verdict `CONFLICT`. 6개 카운트·파일 목록·lane 13·러너 인벤토리 집합 동일성·
  대표 suite(exit 0, 25 ok)는 **정확히 재현**했다. 불일치는 Executor 보고서의 prose off-by-one 2건:
  패밀리 "14"(실제 15), assertion "26"(실제 25) — 둘 다 Executor 자신의 캡처와 모순.
- Judge JSON: `{"verdict":"HOLD","reasons":["audit-conflict"]}` (mode production).
- 원본 증거: `canary/single-run-20261008/` — `run.log`, `run-meta.txt`,
  `batches/<id>/state.jsonl`, `.../evidence/runs/<id>/{executor,auditor,gate}`.
  Executor report sha256 `9c098b1f2d558c390672fbaf441a3f4978a9f64ee332f2cf6ecd7d7e74405bc5`,
  Auditor report sha256 `af4f5059bd0a9ead404f42df64be765f6488edbef221c27bf621bc23c20ef261`.
- 안전 경계: 운영 home tracked dirty **13, fingerprint 불변**(`0c4c59e1…ddd8`); GitHub write 0;
  watcher/scheduler/launchd/credential/Backpass 변경 0; wake drain 0; 비용 0(무료 모델).
- **해석:** Coordinator의 단일-run 무중단 자동 위임·관찰·감사·판정 기제는 정상 작동했다.
  `HOLD`는 안전 시스템이 정상적으로 작동한 결과(독립 감사가 Executor 보고서 오류를 잡음)이며
  Coordinator 결함이 아니다. 이전 배치와 동일한 실패 유형(prose 산술 실수)이 재발했으므로
  Executor 브리프 강화 또는 모델 상향이 재재검증 선행 조건이다.
- 잔여 자원(이번 승인에 teardown 미포함): 두 window `firstmate:1`/`firstmate:2`, worktree slot 14/15,
  pending inbox 0. 후속 teardown 승인 필요(§20). 무해한 `.turn-ended` 마커는 삭제하지 않음.

## 23. 통합 배치 (2026-10-08, Guard + Single-run + G4 심사)

**최종: Pipeline GREEN / G4 `NO_GO`.** 8개 phase(P0~P6) 실행. 중간 captain 승인 요청 없음(사전 승인 범위).

### P1 Crew teardown — `TEARDOWN_VERIFIED`
- Executor `…single-run-canary-20261008`, Auditor `…-audit` 순차 teardown.
- Executor는 completion gate로 1회 거부 → `fm-captain-hold.sh complete <EX> --none`(보고서 §4/§5 미결 captain call 0 attestation) → 재시도 rc=0.
- Auditor 동일(human gate 회피 아님, gate 소유 명령). `teardown-meta.txt`: `EXEC 1→complete 0→0`, `AUD 1→complete 0→0`.
- 사후검증: meta 제거, window는 `claude.exe`만, slot 14/15 owner 제거, inbox 0, home fingerprint 불변.

### P2/P3 Evidence Guard — `IMPLEMENTED` + `LOCALLY_TESTED`
- 신규 `implementation/fm-unattended-guard.sh`. 상세: `handoff/executor-evidence-guard.md`.
- 근본 원인(Executor 보고서 families 14≠15, assertions 26≠25)을 **Auditor dispatch 이전에** 검출.
- 78/78 + local 11/11, shellcheck clean. 커밋 `8eaddea1`.

### P4 단일 run Live E2E — `SINGLE_RUN_UNINTERRUPTED_PASS`
- 신규 batch `firstmate-unattended-guard-canary-20261008` (기존 ID 미재사용), 실 Executor 1 + Auditor 1, model `opencode/ling-3.1-flash-free`(무료), backend tmux.
- 타임라인: `QUEUED 11:40:10 → DISPATCHING 11:40:14 → ACK 11:40:30 → RUNNING 11:40:30 → EVIDENCE_PENDING 11:48:13 → (Guard PASS) → AUDIT_PENDING 11:48:13 → AUDITING 11:48:28 → VERIFIED_PASS 11:54:19`. 총 ~14.2분, `RUN_EXIT=0`.
- Guard `gate/guard.json`: `test_sh 244=244`, `test_test_sh 234=234`, `helpers 10=10`, `families 15=15` → **PASS**.
- Auditor session `…-audit` worktree slot 15 (Executor slot 14, 분리 확인), verdict line `Verdict: PASS`, findings `{"verdict":"PASS","auditor_kind":"real"}`.
- Judge `{"run_id":"…","verdict":"VERIFIED_PASS","reasons":[]}` (mode production).
- 카운트: dispatch **1**, resume/adopt/retry **0**, 수동 개입 **0**, 추가 spawn **0**.
- 원본 증거: `data/unattended-crew-orchestrator-20261008/canary/guard-canary-20261008/` (`run.log`, `run-meta.txt`, `batches/<id>/state.jsonl`, `.../evidence/runs/<id>/{executor,auditor,gate}`). Executor report sha256 `a8dc3a04…5315b`, Auditor report sha256 `a90748e5…a94ac`.
- 안전 경계: home tracked dirty **13, fingerprint 불변**(`0c4c59e1…ddd8`); GitHub write 0; watcher/scheduler/launchd/credential/Backpass 0; wake drain 0; 비용 0.
- **잔여 자원(이번 승인에 teardown 미포함):** Executor `firstmate:fm-firstmate-unattended-guard-canary-20261008`(slot 14), Auditor `…-audit`(slot 15), tmux window `firstmate:1`/`firstmate:2`, pending inbox 0. 후속 teardown 승인 필요.

### P5 Dirty-home 분석 (읽기 전용) — DONE
- dirty 13개(수정 9 + 신규 4) 전수 인벤토리 + 파일별 sha256 + 보존/롤백 7시나리오: `handoff/dirty-home-inventory.md`.
- 성격: 전부 watcher/arm-plugin/quota 런타임 표면(브랜치 `fix/ci-flake-watcher-lock-hup`, 소유 UNKNOWN). **G4 충돌 위험 최고.** 백업 미생성(금지 준수).

### P6 G4 심사 — `G4_NO_GO`
- GO 조건 전부 충족 **단 하나**: 운영 적용 범위 비청정 — 운영 home이 feature 브랜치 + watcher 표면 dirty 13개로 G4 적용 표면과 충돌, **미해결**.
- NO-GO 조건 하나 발동: 「운영 home 충돌 미해결」.
- Pipeline 자체는 GREEN; blocker는 파이프라인이 아니라 운영 home. 상세: `handoff/g4-operational-readiness-review.md`.
- 우선순위 blocker: (P1) 운영 home 충돌/브랜치 tangle → (P2) durable evidence root config, quota/concurrency cap + model allow-list, mounted entrypoint/rollback, (P3) 자동 teardown 규칙.
- **G4 자동 실행 안 함.**

### 승인 경계 준수
G3 push/PR/merge 0 · G4 운영 적용 0 · G5 공용 지침 변경 0 · credential 0 · Backpass 0 · wake drain 0 · 첫 60분 무인 배치 0 · 승인 범위 밖 crew 생성 0.



