# Lane B — Watcher Reliability Recovery (2026-10-08)

대상 경고(원문): `HIGH reliability alert: durable wake queue is pending while watcher consumer is no-consumer (beacon grace 300s).`
경계: 운영 home working tree·slot13·watcher 본체·기존 queue 처리 외 런타임은 불변. 실행 전 fingerprint `0c4c59e1…ddd8` 유지.

## B1 — 라이브 상태 재검증: `FALSE_ALERT` 재확인

- watcher pid `39384`, command `bash /Users/irene/Developer/kunchenguid_repos/firstmate/bin/fm-watch.sh`, PID identity가 lock `pid-identity`와 일치.
- lock owner: pid 39384, `watcher-path` = **운영 home** 경로, `fm-home` = 운영 home.
- heartbeat `.last-watcher-beat` age ≪ 300s grace (fresh).
- launchd job `dev.firstmate.watcher-liveness-alert`: `ProgramArguments[0]` = **slot13** 경로, `FM_ROOT_OVERRIDE` = 운영 home → 경로 불일치가 원인.
- queue: 1352행(스냅샷), oldest seq 5308, `.wake-queue.seq` 6659.
- producer: 단일 watcher 프로세스. process-event source `when-pr107-nm-resume`가 동일 check 행을 800+회 재생산.
- alert state: `pending-wake-no-consumer-high …` → 현재도 `no-consumer`로 오분류, 실제 고장/루프 아님. → **FALSE_ALERT 확정.**

## B2 — 오탐 코드 수정 (격리 clone)

- 위치 규칙 준수: slot13 직접 수정 안 함. home repo를 읽기 전용 clone 후 브랜치 `fm/discord-reaction-recovery-20261008` @ `fb5735eb` checkout.
- 수정(1줄), `bin/fm-watcher-liveness-alert.sh:134`:
  ```
  - ... fm_watcher_lock_matches_pid "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$pid" "$FM_HOME"
  + ... fm_watcher_lock_matches_pid "$STATE" "$FM_ROOT/bin/fm-watch.sh" "$pid" "$FM_HOME"
  ```
  `fm_watcher_lock_matches_pid`는 `watcher-path`를 정확 문자열 비교하므로, 기대 경로를 모니터 대상 root(`$FM_ROOT`)에서 유도하는 것이 단일 소유 정답. watcher 자체의 `WATCH_PATH`(`$SCRIPT_DIR/...`)는 그대로 둠.
- 회귀 테스트(`tests/fm-watcher-liveness-alert.test.sh`) 7종 추가:
  1. 다른 checkout의 정상 watcher → healthy
  2. healthy watcher + pending queue → HIGH 미발행
  3. lock 부재 → HIGH
  4. stale heartbeat → HIGH
  5. PID identity mismatch → HIGH
  6. 장애→정상 회복 시 recovered 이벤트
  7. 기존 단일 checkout 호환
- 결과: 수정본 `EXIT=0`; **mutation proof** — 1줄 revert 시 `EXIT=1` (`not ok - watcher in a different checkout was misclassified`). shellcheck clean.

## B3 — Launchd binding 안전 복구

게이트 확인:
- 현재 plist `ProgramArguments[0]` = slot13 경로 확인.
- 실행 스크립트 소유 브랜치 = `fm/discord-reaction-recovery-20261008` 확인.
- 변경 대상은 정확히 `dev.firstmate.watcher-liveness-alert` 하나; 공유 경로 없음(`DiskUnmountWatcher` 등 무관).
- 기존 plist 복구본 보존.

메커니즘: slot13 무수정 유지 위해 **durable 고정 사본으로 재지정**.
- durable 고정 사본: `/Users/irene/.local/share/firstmate-watcher-alert-fix-20261008/` (수정 반영 clone).
- 기존 plist 백업: `…/g4-lanes-20261008/laneB/plist-backup.orig.plist`.
- `render` 검증(런타임 무변경) 후 `install`로 재설치 → bootout + bootstrap.
- 결과 plist `ProgramArguments[0]` = durable 경로, env = 운영 home, GRACE 300. job 로드됨(pid 67122).
- plist diff: PATH 재정렬 + ProgramArguments[0] 재지정만.
- live `check` 1회 → exit 0, alert state `healthy 0 0`.
- **watcher 본체 미재시작.**
- 롤백: 백업 plist 복원 후 `launchctl bootout/bootstrap`.

한계 명시: queue가 비어 `pending=false`인 상태라 live `check`는 classify를 강제하지 않는다. 오탐 수정의 결정적 증명은 B2 회귀의 mutation proof다.

## B4 — Durable wake queue 적체 원인

- 활성 procevent source `when-pr107-nm-resume`가 **terminal `condition-error` 결과**(14:10 KST, action 미실행)를 `handled` 전까지 poll마다 재공지 → 845 `check` 행 중 대부분.
- 감독 세션이 `--ack-through`로 소비하지 않아 durable queue에 누적(마지막 ack ≤ seq 5307, ≈14:10 KST).
- 나머지 518 `signal` 행은 teardown된 canary들의 turn-ended/status(무해).
- 결론: watcher consumer 실패가 아니라 (i) 미처리 procevent 결과 재공지 + (ii) 미배출 queue.

## B5 — 중복 producer 안전 격리

- `state/procevent-inbox/when-pr107-nm-resume.1.result`를 `classify` → `condition-error`(action 미실행, 재시도 불필요).
- `bin/fm-procevent.sh handled when-pr107-nm-resume 1` → `handled: …` (재공지 중단).
- `bin/fm-procevent-when.sh retire when-pr107-nm-resume` → `retired`.
- `bin/fm-procevent.sh list`: 해당 소스 미등록(활성 아님). 이후 queue 증가 정지 확인.

## B6 — 감독하 queue 처리 + ack 검증

- `bin/fm-wake-drain.sh` 프레젠테이션 성공, `WAKE_ACK_REQUIRED: … --ack-through 6670 --recovery-generation 17242.1791468285.nA2EsN`.
- `bin/fm-wake-drain.sh --ack-through 6670 --recovery-generation 17242.1791468285.nA2EsN` 실행.
- 검증: queue **1363행 → 0행**, recovery marker `announced:handling:…` → `acked:handling:…`. 재적체 없음.
- 프로세스/추가 spawn 0, watcher 본체 미변경.

## Lane B 판정

`WATCHER_RECOVERY_PASS`: 오탐 원인 수정(1줄, 회귀+변이 증명), launchd binding 안전 복구(durable 재지정, 백업·롤백 보유), 적체 원인 규명 + producer 격리 + queue 0 ack.

필요 후속(승인): 브랜치 `fm/discord-reaction-recovery-20261008`에 1줄 수정 land(정규 리뷰), 이후 home `bin/fm-watcher-liveness-alert.sh` 정착 시 launchd를 home 경로로 재지정.
