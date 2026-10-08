# Operational readiness — after the real canary (2026-10-08)

Canonical result: `canary/canary-report.md`. Final state: `CANARY_VERIFIED_PASS`.

> **Update 2026-10-08 (real-E2E integration batch).** The coordinator's `real`
> backend is now wired end to end (dispatch → ACK → evidence → separate auditor
> → judge → handoff) and proven offline against a mock home replaying the canary
> fixture: 49/49 suite cases + 10/10 separate local verification. No real
> provider call was made this batch. Full detail: `handoff/real-e2e-integration-status.md`.
> Status axes: `IMPLEMENTED` / `LOCALLY_TESTED` / `REAL_E2E_READY_FOR_CANARY` +
> `INTEGRATION_HOLD` for a live run. G3·G4·G5 remain NOT approved, and a LIVE
> real E2E needs its own new approval pair.

## 1. G1·G2 정확한 내용
- G1: 실제 Firstmate Scout 1회 생성 — firstmate repo 테스트 구조 read-only 조사, 격리 worktree, 운영 설정·GitHub 쓰기 없음, dispatch profile·허용 경로·금지 작업·세션 소유권 사전 검증, 미충족 시 HOLD.
- G2: 실제 감사 세션 1회 생성 — Executor와 다른 세션·worktree, 원본 증거 검토 + 테스트 파일 목록·실행 명령 독립 재확인, 감사 불완전 시 VERIFIED_PASS 금지.

## 2. 승인된 범위 / 미승인 범위
- 승인: 위 G1·G2 각 1회 (실행 완료).
- 미승인: G3(GitHub push/PR), G4(운영 적용), G5(공유 지침 변경), 그리고 두 완료 Scout 의 **정리(teardown)**.

## 3. 실제 크루 호출 여부
- 호출함. `fm-spawn.sh` 2회 (Executor 1, Auditor 1). 재시도·추가 호출 없음.

## 4. 실제 감사 크루 호출 여부
- 호출함. 별도 세션·worktree 감사 Scout 1회, verdict PASS.

## 5. Canary 실행 결과
- 실행 완료. Judge `VERIFIED_PASS`. 발견 결함 1건: Executor 보고서 prose "14 families" → 실제 15 (감사 수치 불일치 아님).

## 6. 원본 로그·해시·세션 ID
- Executor report sha256 `dce1fa159403f4667f09d196c3f8bd231a995d83c3d87afdfa2f4b0eb32cb259`.
- Executor session `firstmate:fm-firstmate-unattended-canary-01`; Auditor session `firstmate:fm-firstmate-unattended-canary-01-audit`.
- 증거: `canary/evidence/executor/`, `canary/evidence/auditor/`, `canary/evidence/runs/executor-survey/` (stdout·command-log·manifest·rc·gate/verdict.json).

## 7. 재시작 복구 결과
- fake suite `restart.test.sh` 7/7 재현: coordinator SIGKILL 후 resume 이 live run 을 adopt 하고 중복 dispatch 없이 완료.

## 8. 기존 watcher·home 과의 충돌
- tracked 파일 변경 0. 단 fm-spawn 이 "WORKTREE TANGLE (home on feature branch)" 및 "queued wakes pending" 경고를 출력했고, 이번 세션은 wake drain 을 하지 않았다(금지 준수). home 은 여전히 `fix/ci-flake-watcher-lock-hup` + 13 dirty 이다.

## 9. 첫 60분 무인 배치 실행 가능 여부
- fake: 가능(30/30, 재시작 복구 검증). real: 부분 가능 — 무료 모델 지연으로 단일 조사 ~5~10분, coordinator real 경로의 evidence/audit 구간은 설계 보완 필요.

## 10. 1시간 반복 스케줄링에 추가로 필요한 조건
- real 경로용 executor-evidence 어댑터(대화형 에이전트 → 명령 증거) 설계.
- 실패 시 자동 정리(teardown) 승인 및 안전 규칙.
- opencode 무료 모델 health catalog 준비.
- 반복 실행 간 quota·세션 상한 규칙.

## 11. `/clear` 가능 여부
- 가능. 단 남은 두 Scout 세션(pid 30209, 42443)의 정리 승인을 받은 뒤 실행 권장.

## 열린 승인 요청 (최소 패키지)
1. **정리 승인**: `fm-teardown.sh firstmate-unattended-canary-01`, `fm-teardown.sh firstmate-unattended-canary-01-audit` 로 두 완료 Scout 과 그 tmux 세션을 정리(운영 상태 변경).
2. (선택) coordinator real 경로의 evidence/audit 자동 구간 설계 착수 승인.
