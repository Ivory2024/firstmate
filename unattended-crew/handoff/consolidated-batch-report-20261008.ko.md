# 무인 Crew Orchestrator 통합 배치 최종 보고서

- 작성일: 2026-10-08 (UTC)
- 배치: `firstmate-unattended-guard-canary-20261008` (통합 배치, P0~P6)
- 정본(구조·이력 전체): `data/unattended-crew-orchestrator-20261008/handoff/production-readiness-final-20261008.md` §23
- 본 문서: 이번 통합 배치 하나만 self-contained로 요약한 최종 보고서

---

## 0. 최종 판정

| 항목 | 판정 |
|---|---|
| 통합 배치 실행 (P0~P6) | **PASS** — 전 단계 실제 수행·검증 완료 |
| Single-run 무중단 Live E2E | **`SINGLE_RUN_UNINTERRUPTED_PASS`** |
| G4 운영 준비도 | **`G4_NO_GO`** — blocker 1건(운영 home 충돌) |
| 실제 배포 | **NOT_DEPLOYED** (G4 자동 실행 안 함) |

**한 줄 요약:** 무인 orchestrator 파이프라인은 Executor→Evidence Guard→Auditor→Judge 전 구간이 실제 crew로 중단 없이 `VERIFIED_PASS` 도달. G4 적용만 운영 home의 미해결 충돌 때문에 보류.

---

## 1. 배경

직전 단일-run canary가 `JUDGE_HOLD`로 끝난 원인은 Executor의 자연어 보고서가 원본 증거와 불일치한 것이었다(families 14≠15, assertions 26≠25). 독립 Auditor가 이를 정상 탐지했으나, **Auditor crew를 이미 소비한 뒤**였다. 이번 배치의 목표는 (1) 그 실패 유형을 Auditor dispatch **이전에** 차단하는 결정적 Guard를 실제 구현하고, (2) 신규 단일 run으로 무중단 성공을 입증하고, (3) G4 준비도를 증거 기반으로 심사하는 것.

승인 범위: 격리 Canary 최대 1회(실 Executor 1 + Auditor 1), 로컬 구현·테스트, 읽기 전용 분석. **G3(push/PR/merge)·G4 적용·G5 공용 지침 변경·credential·Backpass·wake drain은 미승인.**

---

## 2. 단계별 결과

### P1 — 잔여 Crew 안전 Teardown → `TEARDOWN_VERIFIED`
- 대상: 직전 배치 Executor `firstmate-unattended-single-run-canary-20261008`, Auditor `…-audit`.
- 두 crew 모두 completion gate가 teardown을 거부 → 각 보고서의 §4/§5가 "미결 captain call 0"을 attest → gate 소유 명령 `fm-captain-hold.sh complete <id> --none` → 재시도 모두 `rc=0`. **강제·우회 없음.**
- 사후검증: session meta 제거, tmux window는 `claude.exe`만 남음, slot 14/15 owner 제거·pool 반환, pending inbox 0, home tracked fingerprint 불변, Judge HOLD 원본 보존.
- 기록: `canary/single-run-20261008/teardown-meta.txt` (`EXEC 1→complete 0→0`, `AUD 1→complete 0→0`).

### P2 — Executor Evidence Guard 구현 → `IMPLEMENTED`
- 신규 `implementation/fm-unattended-guard.sh`: 증거 수집과 Auditor dispatch **사이**에서 Executor가 주장한 값을 기계 유도 canonical과 대조.
- canonical source 2종: `cmd`(Executor worktree에서 읽기 전용 명령 실행) / `report`(보고서 자체의 verbatim 캡처 → 자기모순 탐지).
- claim 2종: `count`(단일 수치) / `set`(순서 무관 목록; 누락·중복 검출).
- 불일치·평가불가·보고서 누락 → `HOLD reason=evidence-guard-mismatch` (fail-closed). 무claim 계약은 no-op PASS(호환).
- brief가 요구하는 구조화 형식 `StructClaim: <id> = <n>` 기본 지원 → 모델이 손계산 대신 명령 출력을 복사.
- 배선: `fm-unattended.sh`의 real·fake 양쪽 `EVIDENCE_PENDING` 분기. 스키마 `contracts/task-contract.schema.json`에 `executor.claims` 추가.
- 상세: `handoff/executor-evidence-guard.md`.

### P3 — 로컬 회귀 테스트 → `PASS`
- `bash tests/run-all.sh` → 6 suites, **78/78** (기존 59; guard 17 신규, real-e2e 22→24).
- `bash verification/verify-local.sh` → **11 ok, 0 fail** (분리 로컬 프로세스; `independent_ai_audit:false`).
- `shellcheck`/`bash -n` clean.
- 신규 `tests/guard.test.sh` 17케이스가 mandate P3 표(15≠14, 25≠26, 정확값, 파일 누락/중복, 순서 차이, 증거 누락 fail-closed, malformed, 기존 호환, read-only)를 모두 커버. real-e2e #17/#18이 통합(PASS는 통과, 거짓 claim은 HOLD + Auditor 0회).

### P4 — 신규 단일-run Live E2E → `SINGLE_RUN_UNINTERRUPTED_PASS`
신규 고유 batch `firstmate-unattended-guard-canary-20261008` (기존 ID 미재사용). 실 Executor 1 + Auditor 1, model `opencode/ling-3.1-flash-free`(무료), backend tmux.

**상태 전이 타임라인**

```
QUEUED        11:40:10
DISPATCHING   11:40:14  dispatch-executor
ACKNOWLEDGED  11:40:30  executor-ack
RUNNING       11:40:30  executor-running
EVIDENCE_PENDING 11:48:13  evidence-collected
(Evidence Guard PASS — AUDIT_PENDING 즉시)
AUDIT_PENDING 11:48:13  awaiting-audit
AUDITING      11:48:28  auditor-dispatch
VERIFIED_PASS 11:54:19  judge
```
총 소요 ~14.2분, `RUN_EXIT=0`.

**카운트:** dispatch **1** · resume **0** · adopt **0** · retry **0** · 수동 개입 **0** · 추가 spawn **0**.

**세션/작업공간:** Executor `firstmate:fm-…guard-canary-20261008` → slot 14; Auditor `…-audit` → slot 15 (분리 확인).

**Guard 판정** (`gate/guard.json`): `test_sh 244=244`, `test_test_sh 234=234`, `helpers 10=10`, `families 15=15` → **PASS**.

**Auditor 독립 검증:** 별도 세션·별도 worktree에서 4개 StructClaim 재유도 → `Verdict: PASS`; findings `{"verdict":"PASS","auditor_kind":"real"}`.

**Judge (production):** `{"verdict":"VERIFIED_PASS","reasons":[]}`.

**성공 기준 체크:** 단일 run terminal 도달 ✓ · 수동 개입 0 ✓ · Executor 수치 정확 ✓ · Guard PASS ✓ · Auditor PASS ✓ · Judge VERIFIED_PASS ✓ · 증거 영속 ✓ · 타 세션·home 영향 0 ✓.

### P5 — 운영 Home Dirty 파일 분석(읽기 전용) → `DONE`
- dirty **13개**(수정 9 + 신규 4) 전수 인벤토리: 경로, git 상태, 변경 요약, 소유(UNKNOWN), 운영 관련성, G4 충돌 가능성, 보존·복구 방법, 파일별 sha256.
- 성격: 전부 **watcher / OpenCode arm-plugin / Codex quota** 런타임 표면, 브랜치 `fix/ci-flake-watcher-lock-hup`(main 아님).
- 보존·롤백 계획 7시나리오 설계. **백업 파일 미생성(금지 준수)**, home 파일 미수정.
- 상세: `handoff/dirty-home-inventory.md`.

### P6 — G4 준비도 심사 → `G4_NO_GO`
- GO 조건은 전부 충족. **단 하나 미충족:** 운영 적용 범위가 비청정 — 운영 home이 feature 브랜치 + watcher 표면 dirty 13개로 G4 적용 표면과 충돌, **미해결**.
- NO-GO 조건 하나 발동: 「운영 home 충돌 미해결」.
- Pipeline GREEN, blocker는 운영 home. 상세: `handoff/g4-operational-readiness-review.md`.

---

## 3. 증거·커밋

- Canary 원본: `data/unattended-crew-orchestrator-20261008/canary/guard-canary-20261008/` (`run.log`, `run-meta.txt`, `batches/<id>/state.jsonl`, `…/evidence/runs/<id>/{executor,auditor,gate}`)
- Executor report sha256 `a8dc3a0436bf3a72b492277ccfda448cdc57b7d91d29916743f2862ae485315b`
- Auditor report sha256 `a90748e53e00c99751287d8ccdfa7e6299bf2f084d6641ae17839f3efb9a94ac`
- Guard JSON: `…/gate/guard.json`; Judge JSON: `…/gate/verdict.json`
- Branch `fm/unattended-crew-orchestrator-20261008` (push 안 함), 커밋:
  - `8eaddea1` feat(unattended): Executor Evidence Guard before auditor dispatch
  - `ea5654d9` docs(unattended): single-run guard canary PASS, dirty-home plan, G4 NO-GO
  - `c707fa32` + `72ede4e9` chore: refresh handoff sha256 manifests
  - `0708c68c` test: refresh suite evidence (78/78, local 11/11)
- P3 명령/exit: `tests/run-all.sh` → `fail=0`; `verification/verify-local.sh` → `11 ok, 0 fail`.

## 4. 안전 경계 준수

운영 home tracked dirty **13, fingerprint `0c4c59e1aeb2ac84da8351c89618eae6789004f682a14510fa79efa076edddd8`** — 전 phase 불변.
G3 GitHub push/PR/merge **0** · G4 운영 적용 **0** · G5 공용 지침 변경 **0** · credential **0** · Backpass **0** · wake drain **0** · 첫 60분 무인 배치 **0** · 승인 범위 밖 crew 생성 **0**.

## 5. 잔여 자원 (teardown 미승인)

- Executor window `firstmate:fm-firstmate-unattended-guard-canary-20261008` (slot 14)
- Auditor window `firstmate:fm-firstmate-unattended-guard-canary-20261008-audit` (slot 15)
- pending inbox 0. 정리는 별도 승인 필요. 무해한 `.turn-ended` 마커는 임의 삭제 안 함.

## 6. 다음 단계

1. 잔여 2 crew teardown 승인 → 정리.
2. G4 blocker 해소: 운영 home의 해당 브랜치를 land 또는 보존 후 `main` 복원.
3. P2/P3 잔여: durable evidence root config, quota/concurrency cap + model allow-list, mounted entrypoint/unmount, 자동 teardown 규칙.
4. 그 뒤 G4 apply + 롤백 리허설 **별도 승인**. G4는 자동 실행하지 않음.
