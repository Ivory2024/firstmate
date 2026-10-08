# G4 Preflight + Watcher 진단 — 통합 보고서 (2026-10-08)

한 문서에 두 워크스트림을 합친다.

- **Part 1 — G4 Preflight 통합 배치** (P1~P5): 운영 적용 선행 조건의 증거 기반 검증 + G4 후보 구현.
- **Part 2 — P0 Watcher no-consumer 진단**: 반복 Discord HIGH 경고의 원인 규명.

브랜치: `fm/unattended-crew-orchestrator-20261008`. 격리 dev worktree에서만 코드 변경. 운영 home·launchd·watcher·wake queue·GitHub는 명시 승인 전 불변. 상세 부속 문서는 `handoff/`에 있다.

---

# Part 1 — G4 Preflight (P1~P5)

## 판정 요약

| Phase | 결과 | 핵심 증거 |
|---|---|---|
| P1 Crew teardown | **`TEARDOWN_VERIFIED`** | guard-canary 두 crew 제거, window `claude.exe`만, slot 14/15 반환, inbox 0, fingerprint 불변, Judge `VERIFIED_PASS` 보존 |
| P2 Home snapshot + 복구 리허설 | **`SNAPSHOT_VERIFIED` + `RESTORE_REHEARSAL_PASS`** | 오프홈 스냅샷, 13/13 해시 일치, patch 적용 정합, 격리 복구 트리 fingerprint 일치 |
| P3 브랜치 충돌 해소 계획 | **Path B 권고** | A/B/C 위험·작업량·검증·복구 비교 |
| P4 G4 잔여 기능 구현 | **`IMPLEMENTED`** (격리) | 5개 기능 + 4개 신규 suite |
| P5 회귀 + 테스트 | **PASS** | 10 suites **127/127**, local **16/16**, shellcheck clean, drift 0 |

## P1 — 잔여 Crew 안전 정리 (`TEARDOWN_VERIFIED`)

대상 `firstmate-unattended-guard-canary-20261008`(+`-audit`).
- 사전: 배치 소유권 일치, 두 crew `done`, inbox 0, slot 14/15 소유 일치, Judge `VERIFIED_PASS` 보존, 타 세션 worktree·tmux 미사용.
- teardown: Executor rc=0, Auditor rc=0 (양쪽 completion gate는 meta의 `decisions_reviewed=1`·빈 `decision_keys`로 통과). 강제/우회/pool 초기화 없음.
- 사후: meta 제거, tmux `claude.exe`만, slot 반환, inbox 0, home fingerprint `0c4c59e1…ddd8` 불변.
- 기록: `data/unattended-crew-orchestrator-20261008/canary/guard-canary-20261008/teardown-meta.txt`.

## P2 — 운영 Home 무결성 스냅샷 + 격리 복구 리허설

운영 home은 읽기만 했다. `git stash/reset/clean/checkout` 미사용. 기존 stash 3개 불변.

- 브랜치 `fix/ci-flake-watcher-lock-hup` @ `5f4a1028`, dirty 13(수정 9 + 신규 4), fingerprint `0c4c59e1aeb2ac84da8351c89618eae6789004f682a14510fa79efa076edddd8`.
- **오프홈 스냅샷**: `/private/var/folders/pg/_5jy7w915bv_qt8hkrnpxm6w0000gn/T/opencode/g4-preflight-20261008/home-snapshot/` (0700) — `status.txt`, `tracked.patch`(569행, binary-safe), `staged.patch`(0), `untracked/`(4개 원본), `files.sha256`(13), `meta.txt`, `stash-list.txt`, `RECOVERY.txt`. 민감 내용 미출력.
- **무결성**: patch `git apply --check` OK, 13/13 존재, untracked 4개 해시 일치, home fingerprint·stash 불변.
- **격리 리허설**: 오프홈 clone → base `5f4a1028` checkout → patch 적용 → untracked 복원 → **fingerprint 완전 일치**, **13/13 해시 일치**, `tests/fm-opencode-watch-arm-plugin-export.test.sh` **PASS**, `tests/fm-watcher-lock.test.sh` **32 ok / 0 not ok**. 운영 home에는 복구 명령 미실행.

## P3 — 브랜치 충돌 해소 계획 (읽기 전용)

운영 home은 feature 브랜치 + 13 dirty가 watcher/arm-plugin/quota 런타임 표면. G4 mount 파일명(`bin/fm-unattended*.sh` 등)과 **파일 경로 충돌은 0**, 충돌은 (a) main 아님, (b) 소유 미상 uncommitted가 G4가 다룰 운영 기계에 존재.

| 경로 | 위험 | 작업량 | 검증 | 복구 |
|---|---|---|---|---|
| A 브랜치 land 후 G4 | HIGH (타인/미상 작업, 10-commit rebase) | HIGH | watcher/plugin tests + CI + 소유자 리뷰 | PR revert + dirty 재유도 |
| **B 보존 + 격리 main 후보** | **LOW** (home 미기록) | **MEDIUM** | 127/127 + 16/16 + rehearse + canary 1회 | 후보 worktree 삭제; home 무변경 |
| C 브랜치 위 통합(즉시) | HIGHEST (dirty 표면 직접 편집) | HIGH | home에서 watcher+controller 동시 (금지) | 최약; uncommitted 위험 |

**권고: Path B.** home을 쓰지 않고 신뢰 가능한 G4 후보에 도달, 13 dirty는 보존, live watcher 불변. "브랜치 land"와 "home을 main으로" 두 인간 결정을 별도 승인으로 미룸. 상세: `handoff/p3-branch-conflict-plan.md`.

## P4 — G4 잔여 기능 구현 (격리, `IMPLEMENTED`)

| 기능 | owner 파일 |
|---|---|
| 4.1 Durable Evidence Root | `implementation/fm-unattended-config.sh` |
| 4.2 Quota & Concurrency Cap | `implementation/fm-unattended-quota.sh` |
| 4.3 Mounted Entrypoint | `bin/fm-unattended.sh` (staging) |
| 4.4 Mount & Rollback | `bin/fm-unattended-install.sh` (staging) |
| 4.5 Auto-teardown | `implementation/fm-unattended-autoteardown.sh` |

- 4.1: `UC_EVIDENCE_ROOT`/config/`batch.meta` 기록, canary 경로 호환, 0700, `.batch` 마커, `..`·realpath escape·collision·missing fail-closed, 재시작 시 동일 evidence 재조회.
- 4.2: 배치당 최대 동시 crew/최대 provider 호출, 무료 allow-list, 유료 차단, quota 미확인→HOLD, lock 카운터, real dispatch 전 게이트, HOLD 후 `.batch-held` latch로 추가 실행 정지.
- 4.3: 얇은 wrapper, 호출 계약 동일, 역할 분리(비-captain role 거부), `/afk`·wake queue 미접촉.
- 4.4: 설치 manifest, 덮어쓰기 방지, 파일별 before/after sha256, 부분 설치 롤백, idempotent unmount(사용자 편집 보존), `verify`, temp `rehearse`.
- 4.5: 6조건 rule, **기본 비활성**, 운영 미활성.
- **home에 아무것도 설치하지 않음.** 상세: `handoff/p4-g4-features.md`.

## P5 — 회귀 + 테스트 (`PASS`)

- `bash tests/run-all.sh` → exit 0, **10 suites, 127/127** (기존 6/78). 신규: evidence-root 11, quota 13, entrypoint 14, autoteardown 11.
- `bash verification/verify-local.sh` → **16 ok / 0 fail** (`independent_ai_audit:false`).
- `shellcheck -x` exit 0, `bash -n` clean, `check-drift` 0 drifted. 테스트 삭제·약화 0.
- 알려진 한계: 신규 suite는 fake backend/mock home. mounted entrypoint 실 canary는 별도 승인 단계.

## G4 판정 갱신

G4는 여전히 **`NO_GO`**(실제 적용 안 함). 단, 단일 blocker였던 "운영 home 충돌"에 대해 (i) 오프홈 보존·복구 리허설 검증(P2), (ii) 안전 경로 B 확정(P3), (iii) G4 기능 구현·회귀(P4/P5)로 **해소 경로가 구체화**됐다. 실제 적용은 별도 승인 필요.

---

# Part 2 — P0 Watcher no-consumer 진단

대상 경고(원문): `HIGH reliability alert: durable wake queue is pending while watcher consumer is no-consumer (beacon grace 300s).`
진단: 전면 읽기 전용(신규 보고서 파일 1개만 작성). 상세: `handoff/p0-watcher-consumer-diagnostic.md`.

## 판정: `FALSE_ALERT`

라이브 watcher는 전 구간 정상(pid 생존, beat 46s < 300s grace, lock identity 일치). `no-consumer`는 **결정적 decode 버그**다.

| 항목 | 값 |
|---|---|
| pending queue 수 | **1070** (seq 5308~6372; 스냅샷 시점) |
| 가장 오래된 항목 대기 | **7h 11m 55s** (epoch 1791436249 = 14:10:49 KST) |
| 마지막 정상 소비 | **≈ 14:10 KST** (마지막 ack ≤ seq 5307), 이후 무 ack |
| 중복 생산자 | `procevent:when-pr107-nm-resume:1`가 662행 (~1행/38s) |

## 근본 원인 (검증됨)

- 경고 생산자: launchd `dev.firstmate.watcher-liveness-alert` (60s), 프로그램은 **slot 13 checkout** `/Users/irene/.treehouse/firstmate-697ce1/13/firstmate/bin/fm-watcher-liveness-alert.sh`, `FM_ROOT_OVERRIDE`=운영 home, `FM_WATCHER_STALE_GRACE=300`.
- `SCRIPT_DIR`=자기 checkout(slot13). `classify_consumer` **line 134**가 기대 watcher 경로로 `"$SCRIPT_DIR/fm-watch.sh"`(=slot13 경로)를 `fm_watcher_lock_matches_pid`에 넘긴다. 락에 기록된 실제 경로는 **운영 home** `…/firstmate/bin/fm-watch.sh`. → 경로 불일치 → 항상 `no-consumer`.
- 재현(읽기 전용): 동일 live pid로 slot13 경로 → `rc=1`(no-consumer), 운영 경로 → `rc=0`(healthy). `no-consumer` 문자열은 이 경로/identity 분기에서만 나오며 grace window와 무관. 메시지의 300s는 grace 텍스트일 뿐 도달한 적 없음.
- 반복 주기: queue가 14:10부터 계속 비어있지 않아 매 60s `pending=true`, `COOLDOWN=3600`으로 매시간 재발. `watcher-liveness-recovered` 이벤트 전무(경로 버그로 healthy 복귀 불가).

## 가설 판정

| # | 가설 | 판정 |
|---|---|---|
| A | watcher 실제 종료 | REJECTED — live pid + lock 생존, cycle-exit `exit_code=0` 연속 |
| B | beacon 갱신 실패 | REJECTED — beat age 46s < 300s, mtime 진행 |
| C | re-arm 실패/루프 | REJECTED(원인 아님) — 매 cycle `exit_code=0`, watchdog FAILED 없음 |
| D | quota resume 후 consumer 복귀 실패 | REJECTED — quota 스크립트는 watcher 미기동, 최고령 14:10(03:47 아님) |
| E | 오래된 queue/상태 오탐 | PARTIAL — queue는 실제 미ack(7h12m), 그러나 오탐은 pending이 아니라 no-consumer |
| F | 다중 watcher/소유권 불일치 | REJECTED — 단일 watcher+arm, lock 단일 owner, pid/identity 일치 |
| G | 경고 조건/grace 계산 버그 | **CONFIRMED (decisive)** — 기대 경로를 `$SCRIPT_DIR`에서 유도 |

## 최소 수정 (승인 필요)

1. `bin/fm-watcher-liveness-alert.sh` line 134 → `"$FM_ROOT/bin/fm-watch.sh"` (1줄). 이 파일은 slot13 브랜치에만 존재(운영 home엔 없음) → 그 브랜치 소유 경로로 land 필요.
2. launchd job 재설치/reload(`install`) — **launchd 변경 → 별도 승인**.
3. `bin/fm-wake-lib.sh`·dirty `bin/fm-watch*.sh` 변경 불필요.
4. (별건) `when-pr107-nm-resume` 중복 생산자 격리, queue drain은 감독 세션에서.

## 회귀 테스트(제안)

slot13 `tests/fm-watcher-liveness-alert.test.sh` 확장: cross-checkout healthy 분류, healthy+non-empty queue에서 high 미발행, no-lock/stale 양성 대조, identity guard, stale→healthy `recovered` 발행.

## 복구 순서(승인 게이트)

1. 오탐 확정(본 보고서) — 런타임 무변경. 2. 소유 브랜치에서 1줄 수정 + 테스트. 3. captain 승인 후 launchd reload. 4. `check` 1회 검증(healthy, cooldown 동안 신규 high 없음). 5. 감독 세션에서 queue drain + 중복 생산자 정리.

---

# Part 3 — 두 워크스트림 상호관계

- **파일 경로 충돌: 없음.** 경고 수정 대상 `bin/fm-watcher-liveness-alert.sh`는 운영 home에 **부재**하며 dirty 13에 없음. G4 mount 대상과도 다름.
- **런타임 경로 겹침: 있음(간접).** G4 경계가 "watcher/scheduler/launchd 변경"을 포함하고, 경고 수정이 정확히 launchd job 재지정 + watcher liveness 스크립트다. 둘 다 G4가 결국 정합해야 할 watcher liveness 기계를 건드린다.
- **독립 수정 가능: YES.** 경고 결함은 alert producer + launchd binding에 국한. G4 controller mount, home main 복원, dirty 13 변경 없이 수정·land 가능. G4 fingerprint를 바꾸지 않음(그리고 그래서도 안 됨). launchd reload만 별도 승인.

---

# 최종 상태·다음 승인

| 항목 | 상태 |
|---|---|
| G4 Preflight | P1~P5 완료; G4 후보는 Path B, 기능 구현·127/127 |
| G4 실제 적용 | **안 함** (`NO_GO` 유지, 별도 승인) |
| Watcher 경고 | **FALSE_ALERT** 규명, 1줄 수정안 + 테스트 제안; 런타임 무변경 |
| 운영 home | dirty 13, fingerprint 불변 |
| GitHub | 이 보고서 커밋만 push(승인 지시) |

**승인 필요:** (1) Path B로 G4 후보 worktree 구축, (2) watcher 경고 1줄 수정 land + launchd reload, (3) queue drain·중복 생산자 정리(감독 세션), (4) G4 실제 적용.
