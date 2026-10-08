# Canary 결과 보고 — `firstmate-unattended-canary-01`

작성 2026-10-08. 승인 범위: G1(실제 Scout 1회) + G2(실제 감사 1회). G3·G4·G5 미승인.
모든 실호출은 각 1회, 자동 재시도 없음.

## 최종 판정

**`CANARY_VERIFIED_PASS`** — 실제 Executor Scout와 실제 Auditor Scout를 각 1회 생성했고,
Judge가 `VERIFIED_PASS`를 반환했다. 운영 home의 tracked 파일은 변하지 않았다.
발견된 유일한 결함은 Executor 보고서의 prose 오기(1건)이며 감사 수치 불일치는 없다.

## 1. 실제 세션 ID

| 역할 | firstmate task id | session(window) | worktree |
|---|---|---|---|
| Executor | `firstmate-unattended-canary-01` | `firstmate:fm-firstmate-unattended-canary-01` | `/Users/irene/.treehouse/firstmate-697ce1/14/firstmate` |
| Auditor | `firstmate-unattended-canary-01-audit` | `firstmate:fm-firstmate-unattended-canary-01-audit` | `/Users/irene/.treehouse/firstmate-697ce1/15/firstmate` |

두 세션은 서로 다른 window·worktree(slot 14 vs 15)를 사용한다.

## 2. 생성 명령과 호출 횟수

- Executor 1회:
  `fm-unattended-adapter.sh dispatch --batch canary --task executor-survey --role executor --attempt 1`
  → 내부에서 `bin/fm-spawn.sh firstmate-unattended-canary-01 <firstmate> --scout --harness opencode --model opencode/ling-3.1-flash-free --effort low --backend tmux` 1회.
- Auditor 1회:
  `fm-unattended-adapter.sh dispatch --batch canary --task executor-survey --role auditor --attempt 1`
  → 내부에서 `bin/fm-spawn.sh firstmate-unattended-canary-01-audit <firstmate> --scout ...` 1회.
- 총 `fm-spawn.sh` 호출: **2회** (Exec 1 + Audit 1). 재시도·추가 호출 0회.

## 3. harness / model / dispatch profile

- harness: `opencode` (config/crew-harness 없음 → own harness).
- model: `opencode/ling-3.1-flash-free` (비용 0; quota-axi 는 opencode window 를 보고하지 않음).
- effort: `low`.
- backend: `tmux` (config/backend 없음 → runtime auto-detect + tmux).
- dispatch profile: `config/crew-dispatch.json` 의 "Narrow tool-heavy OpenCode tasks, quick read-only research ..." 규칙 → opencode 일치. 실행 시 fm-spawn 경고: "cannot verify ... against the opencode free-model health catalog" (health catalog 부재, models.dev check 로 진행).

## 4. 실제 작업공간

- Executor: `/Users/irene/.treehouse/firstmate-697ce1/14/firstmate` (firstmate repo 의 격리 Treehouse worktree).
- Auditor: `/Users/irene/.treehouse/firstmate-697ce1/15/firstmate`.
- 둘 다 primary checkout(`/Users/irene/Developer/kunchenguid_repos/firstmate`)과 분리됨.

## 5. ACK · RUNNING · COMPLETE 증거

- Executor: `state/firstmate-unattended-canary-01.status`
  - `working [at=1791452072]: spawned` (ACK/RUNNING)
  - `done [at=1791452530]: survey complete - 244 top-level tests/*.sh ...` (COMPLETE)
- Auditor: `state/firstmate-unattended-canary-01-audit.status`
  - `working [at=1791452586]: spawned`
  - `done [at=1791452913]: audit complete - verdict PASS ...`
- 관찰: `fm-crew-state.sh` → Executor `state: done · source: status-log`, Auditor `state: done · source: status-log`.

## 6. 테스트 결과와 원본 로그

- Executor 보고서: `data/firstmate-unattended-canary-01/report.md` (123줄, sha256 `dce1fa159403f4667f09d196c3f8bd231a995d83c3d87afdfa2f4b0eb32cb259`).
- 감사 보고서: `data/firstmate-unattended-canary-01-audit/report.md` (91줄).
- 로컬 독립 재계수 증거: `canary/evidence/runs/executor-survey/executor/`(stdout/command-log/manifest/rc) + `canary/evidence/executor/`.

## 7. 감사 결과와 독립 재현 증거

Auditor verdict: **PASS**. 별도 세션·별도 worktree에서 재계수:
- `244` top-level `tests/*.sh` = `234` `*.test.sh` + `10` helpers, recursive 동일.
- `2` `*.test.py`, `1` `*.test.mjs`.
- runner `bin/fm-test-run.sh`; `--list-families` 재현.
- `bin/fm-test-run.sh tests/fm-brief.test.sh` 재실행 → exit=0, duration_ms≈8845 (Executor 8913ms 와 일치).
- 불일치 1건(감사가 발견): Executor 보고서 prose가 "14 families"라고 썼으나 실제 `--list-families` 는 **15개**(Executor 자신의 표에는 15행, 합 234). 감사 수치에는 영향 없음.

## 8. Judge 판정

- `EVIDENCE_ROOT=<canary>/evidence fm-unattended-judge.sh run executor-survey` →
  `VERDICT=VERIFIED_PASS reasons=none` (exit 0).
- mode=production, auditor_kind=real, 감사 verdict=PASS, workspace 분리(14≠15), hash 일치, 테스트 완료.

## 9. 운영 환경 불변 여부

- home tracked 파일 변경: **0** (세션 시작과 동일한 13개 dirty, 그대로).
- config/, watcher, launchd, scheduler, credential/PAT/SSH, Backpass: **변경 0**.
- wake drain: **0** (fm-spawn 의 "queued wakes pending" 경고에도 drain 하지 않음).
- GitHub write: **0** (push/PR 없음).
- 생성된 신규 운영 상태(승인된 "Scout 생성"의 일부): backlog 항목 2개(Queued→In flight), `state/<id>.meta`, `state/<id>.status`, Treehouse worktree 2개, `data/<id>/brief.md`·`report.md`.

## 10. 첫 60분 무인 배치 실행 가능 여부

- **부분 가능.** fake-backend 배치는 30/30 으로 60분 내 완주 가능하고 재시작 복구가 검증됐다.
- 실제 배치는 위험 요소가 남는다: (a) 무료 opencode 모델이 느려 단일 조사에 ~10분(Executor)~5분(Auditor) 소요, (b) coordinator 의 real 경로는 "일회성 명령 증거" 모델과 "대화형 에이전트"의 불일치로 인해 dispatch 이후 구간이 수동 연결이었다. → 실제 무인 배치는 이 불일치 해소 후여야 한다.

## 11. 추가 승인 필요 사항

- **정리(teardown)**: 두 완료 Scout(worktree/task)와 각 tmux 세션(pid 30209, 42443)이 아직 살아 있다. 정리는 운영 상태 변경이므로 별도 승인 필요.
- **coordinator real E2E**: real backend 의 dispatch/identity 는 검증됐지만, state-machine 의 나머지 구간(evidence/audit/judge)을 real 실행으로 자동 구동하려면 real 경로용 executor-evidence 어댑터 설계가 필요(코드 변경).
- **모델 health catalog**: opencode 무료 모델 검증 카탈로그 부재 경고 해소.

## 12. `/clear` 가능 여부

- **가능.** 이번 세션은 cross-process 재시작 복구를 별도로 검증했고(restart suite), 운영 home 을 변경하지 않았다. 단, 남은 두 Scout 세션의 정리 승인을 받은 뒤 `/clear` 하는 편이 깔끔하다.

## Phase B — G1/G2 게이트 분석

| 게이트 | 실제로 실행할 동작 | 필요한 권한 | 운영 영향 | 위험 | 승인 상태 |
|---|---|---|---|---|---|
| G1 | `fm-spawn.sh <id> <firstmate> --scout` 로 실제 Scout 1개 생성(read-only 조사) | 실제 worker dispatch | backlog/state/worktree 생성, quota 소모 | 무료 모델 지연·오작동, orphan 세션 | **승인됨(1회, 실행 완료)** |
| G2 | 별도 세션·worktree 로 실제 감사 Scout 1개 생성, 원본 증거 독립 재검증 | 실제 audit dispatch | 감사 task/state/worktree 생성 | 감사 세션 지연 | **승인됨(1회, 실행 완료)** |

최소 승인 범위(실행에 사용): 읽기 전용 Scout 각 1개, 격리 worktree, 프로젝트 변경 없음, GitHub 쓰기 없음, 운영 설정 변경 없음, 호출 각 1회, 무제한 재시도 금지.

## Phase E — 실패·복구 검증(fake, 재실행)

`tests/` 30/30 재현: ACK timeout, 중복 dispatch 거부, identity 불일치, 증거 누락, auditor 미실행(AUDIT_UNAVAILABLE), auditor 충돌(HOLD), coordinator SIGKILL 후 재시작(중복 dispatch 없음), 허용되지 않은 외부 쓰기(HOLD), 승인 없는 다음 작업 차단(HOLD/approval-required). 원본 로그: `evidence/test-results/*.out`.

## 정리(teardown) 기록 — 2026-10-08 (승인 후)

승인 후, 소유권 재확인(ID=endpoint_task_id, worktree 일치, kind=scout, window 일치, pending inbox 0)과
status 로그의 `done`을 확인한 뒤 공식 `bin/fm-teardown.sh`로 정리했다. PID 직접 종료·타 크루 정리·공유 파일 삭제는 하지 않았다.

- Executor: `fm-teardown.sh firstmate-unattended-canary-01` 완료. worktree slot 14 풀 반환, window 제거, backlog `[x]` 닫힘.
- Auditor: `fm-teardown.sh firstmate-unattended-canary-01-audit` 완료. worktree slot 15 풀 반환, window 제거, backlog `[x]` 닫힘.
- teardown 자체가 worktree 내 leaked process(31944/42864, 43880/51276)를 공식 경로로 reap/force-kill 했다(직접 종료 아님).
- 사후: `state/<id>.meta`·`.status` 제거, tmux canary window 0, 잔여 canary 프로세스 0, worktree slot HEAD=e70daed6(pooled).
- durable 증거는 `canary/evidence/`와 `data/<id>/report.md`에 보존됨.
