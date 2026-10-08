# G4 Path B Mounted Live Canary + Watcher Reliability Recovery — 통합 보고서

- 작성: 2026-10-08/09 (UTC)
- 브랜치: `fm/unattended-crew-orchestrator-20261008` @ `b2dc434d`
- 경계: 운영 home working tree·watcher 본체·credential 무변경. home fingerprint `0c4c59e1aeb2ac84da8351c89618eae6789004f682a14510fa79efa076edddd8` 불변(13 dirty). G4 실제 배포·첫 60분 무인 배치 미실행.

## 최종 판정

| 축 | 판정 |
|---|---|
| Lane A (Path B live) | **`PATH_B_HOLD`** — 후보 A2~A4 green, A5 live canary는 무료 모델 엔드포인트 장애로 미완 (테스트 수준은 검증됨) |
| Lane B (Watcher recovery) | **`WATCHER_RECOVERY_PASS`** |
| G4 | **`G4_NO_GO`** — 실제 적용 미수행, 잔여 blocker 존재 |
| Deployment | NOT_DEPLOYED |

---

# Lane A — Path B Mounted Live Canary

## A1 — 백업 영속성 (PASS)
- 오프홈 durable 백업: `/Users/irene/.local/share/firstmate-g4-backups/home-snapshot-20261008/` (0700, git 밖).
- 내용: `tracked.patch`(binary-safe), `staged.patch`, `untracked/`(4개 원본), `status.txt`, `stash-list.txt`, `files.sha256`(13), `meta.txt`, `RECOVERY.txt`.
- 검증: 13/13 해시 일치, patch `git apply --check` OK, home fingerprint 불변. 스냅샷·해시만 기록했고 파일 내용/비밀값 미출력.

## A2 — 격리 Path B 후보 (PASS)
- 후보: `…/g4-lanes-20261008/laneA/firstmate`, base `e70daed660f1f116c82b4fcd16e4e5d9510bd663` (origin/main).
- orchestrator import 원본: `fm/unattended-crew-orchestrator-20261008` @ `b2dc434db91ff5f8f3322631151754f0846cfed4`.
- import manifest: `laneA/import-manifest.sha256` (232 파일, source commit + base + sha256).
- home의 dirty 13은 복사하지 않음.
- base 의존성 차이: `fm-send/fm-crew-state/fm-teardown/fm-captain-hold` 동일; `fm-spawn`·`fm-brief`는 후보가 더 최신(API 호환). 차이 1건: 후보 `fm-spawn.sh`는 free-model health catalog 미등재 `opencode/*`를 **거부**(dev는 경고만).

## A3 — 설치/제거 리허설 (PASS)
- `laneA/install-rehearsal.sh` **14 ok / 0 fail**: manifest 완전성, 파일별 before/after sha256, 무소유/수정파일 덮어쓰기 방지, 중복 설치 멱등, partial rollback(`FM_UNATTENDED_INSTALL_FAIL_AT=0..8`), 멱등 unmount(사용자 수정 보존), mounted entrypoint 실행.
- 운영 home에 미설치.

## A4 — 회귀 테스트 (PASS)
- `unattended-crew/tests/run-all.sh` → **10 suites / 127 PASS / 0 FAIL** (독립 재실행으로 재확인).
- `unattended-crew/verification/verify-local.sh` → **16 ok / 0 fail**.
- `laneA/a4-battery.sh` → **10/10** (mounted Guard, paid-model block, quota caps pre-dispatch, no-run-after-HOLD, restart durable evidence, watcher/wake-queue 미접촉).
- **battery가 찾은 실제 결함 1건 수정(후보 내)**: `implementation/fm-unattended.sh` `_drive`의 HOLD latch가 **같은 pass의 독립 후속 task**를 멈추지 않음 → per-task 루프에 `.batch-held` 검사 추가. 테스트 삭제·약화 0, 127/127 + 16/16 유지.
- 후보 내 변경만, 커밋/푸시 없음.

## A5 — Mounted Live Canary → **HOLD (모델 엔드포인트 장애)**
- Preflight `PREFLIGHT=GO`; mount `live-canary-mount` 설치·verify 완료.
- batch `firstmate-unattended-live-canary-20261008` (신규), mode production, retry_limit 1, ack 90, quota cap(동시 1·provider 2·free only).
- 모델: `opencode/ling-3.0-flash-fin-free` (카탈로그·models.dev zero·`opencode models` 3조건 충족).
- 실행(단일 run, 수동 개입 0): `QUEUED 14:44:43 → DISPATCHING 14:44:49 → ACK 14:45:04 → RUNNING 14:45:04`, 실제 Executor spawn 성공.
- **실패 지점:** Executor pane에 `Upstream request failed: Endpoint is unavailable.` — 무료 모델 엔드포인트 장애로 Executor가 보고서를 생성하지 못하고 idle. 재시도 없음(수동 개입 금지 준수).
- provider 호출 사용: 1 (executor 시도; auditor 미spawn). run 중단 `RUN_STOPPED=path_b_hold_model_unavailable 15:03:08`.
- 증거: `laneA/live-canary-failure-evidence/` (`executor-pane.txt`, `*.status`, `*.meta`, `state.jsonl`, `teardown-executor.out`), `laneA/live-canary-meta.txt`, `laneA/live-canary-run.log`.
- **동일 배치 자동 재실행 안 함.** 상세: `laneA/LANE-A-REPORT.md`, `laneA/LIVE-CANARY-RUNBOOK.md`.

## A5 잔여 자원
- Executor crew `firstmate-unattended-live-canary-20261008` **잔존**(window + meta + agent pid). 
- teardown 시도 → `REFUSED: … has no report` (모델 장애로 report 미생성). **force는 discard 명시 승인 필요라 미실행.**
- mount `laneA/live-canary-mount` 설치 상태 유지(재실행 대비).

---

# Lane B — Watcher Reliability Recovery (`WATCHER_RECOVERY_PASS`)

상세: `unattended-crew/handoff/lane-b-watcher-reliability-recovery-20261008.ko.md`.

- **B1** 재검증: watcher pid 39384 정상, heartbeat fresh, lock identity 일치 → `FALSE_ALERT` 재확인. launchd job `dev.firstmate.watcher-liveness-alert`가 **slot13 경로**에서 실행되며 `FM_ROOT_OVERRIDE`=운영 home.
- **B2** 수정(1줄): `bin/fm-watcher-liveness-alert.sh:134` `"$SCRIPT_DIR/fm-watch.sh"` → `"$FM_ROOT/bin/fm-watch.sh"`. 격리 clone(slot13 미수정). 회귀 7종 + **mutation proof**(revert 시 실패).
- **B3** launchd 안전 복구: durable 고정 사본 `/Users/irene/.local/share/firstmate-watcher-alert-fix-20261008/`로 재지정, plist 백업 `laneB/plist-backup.orig.plist`, job 로드됨, `check=healthy`. **watcher 본체 미재시작.**
- **B4** 적체 원인: 활성 procevent `when-pr107-nm-resume`의 terminal `condition-error` 결과가 `handled` 전까지 재공지 → 845 check row; 감독 세션 미배출.
- **B5** 격리: `fm-procevent.sh handled when-pr107-nm-resume 1` + `fm-procevent-when.sh retire` → flood 중단.
- **B6** 감독하 처리: `fm-wake-drain.sh` 프레젠테이션 → `--ack-through 6670 --recovery-generation 17242.1791468285.nA2EsN` → queue **1363→0**, marker `acked`. 재증가·heartbeat 이상 없음.

---

# 교차·경계

- **파일 경로 충돌 없음:** Lane B 수정 대상 `bin/fm-watcher-liveness-alert.sh`는 운영 home에 부재(dirty 13 아님). Lane A 후보와도 무관.
- **런타임 경로 간접 겹침:** 둘 다 watcher/launchd 표면.
- 운영 home fingerprint 전 구간 불변(13 dirty). credential·GitHub(구현코드/운영변경)·watcher 본체·wake 강제 drain 없음.

# 커밋·증거 경로

- 브랜치 구현: `fm/unattended-crew-orchestrator-20261008` @ `b2dc434d` (이전 승인 push).
- Lane B 수정·A4 수정은 **미커밋**(각 격리 워크스페이스). 이번 배치 push는 보고서·인수인계 문서에 한정.
- 증거: `laneA/`(import-manifest, install-rehearsal, a4-battery, live-canary-failure-evidence, LANE-A-REPORT), `laneB/`(plist-backup.orig.plist), `unattended-crew/handoff/lane-b-watcher-reliability-recovery-20261008.ko.md`.

# 다음 승인 필요

1. **A5 무료 모델 재시도**: 엔드포인트 장애로 미완. 카탈로그 등재·가용 모델(예: `opencode/mimo-v2.6-flash-free`)로 신규 batch 1회 재실행 승인 필요(`PATH_B_LIVE_VERIFIED` 판정 위해).
2. **Lane A 잔여 crew teardown**: report 없는 failed scout → `--force` discard 승인 필요.
3. **Lane B 수정 land**: 브랜치 `fm/discord-reaction-recovery-20261008`에 1줄 수정 정규 리뷰·land.
4. G4 실제 적용은 별도 승인.
