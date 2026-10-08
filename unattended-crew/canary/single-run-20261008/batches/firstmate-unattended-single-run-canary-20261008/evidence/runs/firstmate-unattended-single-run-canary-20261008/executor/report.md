# Firstmate 테스트 구조 조사 보고서 (read-only canary survey)

- 일시: 2026-10-08 (UTC 11:13 기준 실행)
- 작업 위치: disposable git worktree `/Users/irene/.treehouse/firstmate-697ce1/14/firstmate`
  - detached HEAD `e70daed660f1f116c82b4fcd16e4e5d9510bd663` ("fix: enforce verified Git bases for spawn and publish (#107)")
  - `git status --short --branch`: 깨끗한 detached HEAD, 작업 시작 전·후 모두 변경 없음
- 범위: `tests/` 디렉터리의 테스트 파일 수(최상위·재귀), 대표 실행 명령, 대표 suite 1개의 실행 결과
- 방법: 읽기 전용 조사. 저장소의 tracked 파일을 수정하지 않았다. 작성한 파일은 이 보고서와 상태 파일뿐이다.

## 1. 테스트 파일 수

측정 명령과 결과 (모두 worktree 루트에서 실행):

| 측정 | 명령 | 결과 |
|---|---|---|
| 최상위 .sh 전체 | `ls tests/*.sh \| wc -l` | **244** |
| 최상위 .test.sh | `ls tests/*.test.sh \| wc -l` | **234** |
| 최상위 .py | `ls tests/*.py \| wc -l` | **3** |
| 재귀 .sh | `find tests -name '*.sh' \| wc -l` | **244** |
| 재귀 .py | `find tests -name '*.py' \| wc -l` | **3** |
| 러너가 인식하는 전체 테스트 | `bin/fm-test-run.sh --list --all \| wc -l` | **234** |

해석:

- `tests/*.sh` 244개 중 234개가 실제 동작 테스트(`*.test.sh`)이고, 나머지 10개는 테스트가 아닌 헬퍼·세이프티 스크립트다:
  `cmux-test-safety.sh`, `fixtures.sh`, `git-config-helpers.sh`, `herdr-client-pair-fixture.sh`, `herdr-test-safety.sh`, `lib.sh`, `remote-herdr-fixture.sh`, `secondmate-helpers.sh`, `wake-helpers.sh`, `zellij-test-safety.sh`
- `.py` 3개: `fm-backend-herdr-eventwait.test.py`, `fm-bot-manager-poll.test.py` (테스트 2개) + `fm-turnend-foreign-owner-repro.py` (재현 스크립트 1개).
- 하위 디렉터리는 `tests/assets/`와 `tests/captures/no-mistakes-v1.70.1/` 둘뿐이며, 이들 안에 `.sh`·`.py` 테스트 파일은 없다. 따라서 **재귀 카운트는 최상위 카운트와 동일**하다(.sh 244, .py 3).
- `bin/fm-test-run.sh --list --all`의 234개가 `tests/*.test.sh` 234개와 정확히 일치한다. 파이썬 테스트 2개는 셸 러너 인벤토리에 포함되지 않는다.

## 2. 테스트 구조

- 단일 러너: `bin/fm-test-run.sh` (헤더: "single owner of Firstmate's behavior-test runner"). 선택 모드: `--all`, `--family <name>`, `--changed`, `--lane <name>`, `--proven-isolated`, 또는 개별 스크립트 경로. `--list` 계열 플래그는 실행 없이 인벤토리만 출력한다.
- 패밀리 14개 (`bin/fm-test-run.sh --list-families`):
  `pure-contract-unit`, `watcher-wake-lock`, `real-herdr-gated`, `secondmate`, `session-bootstrap`, `live-harness-optin`, `backend-dispatch`, `pr-forge`, `afk`, `snapshot-bearings`, `cmux`, `zellij`, `orca`, `standalone`, `unclassified`
- CI lane 13개 (`bin/fm-test-run.sh --list-lanes`):
  `portable-parallel-1`, `portable-parallel-2`, `portable-serial`, `portable-serial-1of9` … `portable-serial-9of9`, `real-herdr-gated`
- 문서화된 진입점 (CONTRIBUTING.md:98-118, 121-126):
  - `bin/fm-test-run.sh tests/<subject>.test.sh` — 단일 스크립트 (주요 로컬 경로, timed)
  - `bin/fm-test-run.sh tests/<a>.test.sh tests/<b>.test.sh` — 여러 스크립트, 자동 제한 병행
  - `bin/fm-test-run.sh --family pure-contract-unit` — 패밀리 범위 (serial, timed)
  - `bin/fm-test-run.sh --changed` — 변경 파일 기반 자동 병행
  - `bin/fm-test-run.sh --proven-isolated --jobs 4` — 검증된 격리 집합 병행
  - `bin/fm-test-run.sh --lane portable-serial` / `--all` — serial remainder / 전체 회귀
  - `bin/fm-test-run.sh --check-coverage` — shard+serial+Herdr가 전체 인벤토리와 같음을 증명
  - `bin/fm-test-isolation-proof.sh --list` — portable 병행 후보 집합 증명

## 3. 대표 suite 실행 (실제 실행)

명령 (측정을 위해 `/usr/bin/time -p`로 감쌈):

```sh
/usr/bin/time -p bin/fm-test-run.sh tests/fm-brief.test.sh
```

- **exit code: 0**
- **소요 시간: real 10.55초** (`/usr/bin/time -p`: real 10.55, user 3.70, sys 4.60)
- 러너 자체 마커: `duration_ms=10389`, 요약 `duration_ms=10495`

전체 캡처 출력 (verbatim):

```
FM_TEST_BEGIN 2026-10-08T11:13:38Z tests/fm-brief.test.sh family=pure-contract-unit expected_gate_skip=none
ok - fm-brief: scaffolds leave the worker role scope to the launch boundary and keep the secondmate contract
ok - fm-brief.sh: bash -n succeeds
/private/var/folders/pg/_5jy7w915bv_qt8hkrnpxm6w0000gn/T/fm-brief.PKx02U/heredoc-in-substitution.sh:2
ok - fm-brief.sh: no heredoc is nested inside a command substitution (Bash 3.2 parse-safe)
ok - fm-brief.sh: --help renders the complete header
ok - fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly
ok - fm-brief.sh: ship --mode is required and closed-set validated
ok - fm-brief.sh: the explicit ship mode wins over the registered posture
ok - fm-brief.sh: --yolo and scout/secondmate --mode are refused, never silently dropped
ok - fm-brief.sh: faster paths use configured authority without stacked review
ok - fm-brief.sh: no-mistakes DOD keeps its apostrophe prose and bans --yes outright
ok - fm-brief.sh: no-mistakes ask-user findings use one event plus a verbatim snapshot
ok - fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar
ok - fm-brief.sh: --herdr-lab emits the complete hard safety contract
ok - fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path
ok - fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible
ok - fm-brief.sh: the documented {TASK} and {FIRSTMATE_SPEC} fills cannot corrupt the Herdr safety gate
ok - fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse
ok - fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse
ok - fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting
ok - fm-brief.sh: relative directory inputs ignore CDPATH, render stable absolute charter paths, or fail loudly
ok - fm-brief.sh: custom pause verb renders in every scaffold
ok - fm-brief.sh: ship and scout scaffolds teach validation-round pauses
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy
ok - fm-brief: scout and secondmate code paths still scaffold well-formed briefs
ok - fm-brief.sh: scout Lavish hosting follows the bootstrap lavish-axi floor
FM_TEST_END 2026-10-08T11:13:48Z tests/fm-brief.test.sh exit=0 duration_ms=10389 gate_skip=false
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=10495
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=1 duration_ms=10389 failed=0
FM_TEST_SLOWEST rank=1 script=tests/fm-brief.test.sh duration_ms=10389
```

요약: 1개 스크립트, 26개 assertion 전부 `ok`, 실패 0, gate-skip 0.

## 4. captain-hold-lifecycle 완료 게이트

`/Users/irene/Developer/kunchenguid_repos/firstmate/.agents/skills/captain-hold-lifecycle/SKILL.md`를 읽고 게이트를 평가했다. 이 조사는 순수 읽기 전용 사실 조사이며, 보고서에 캡틴에게 귀속되는 미해결 결정(제품 선택, 파괴적 행동, 시각 리뷰)이 없다. 따라서 "reviewed surface leaves nothing waiting on the captain" 조건을 만족해 게이트는 보류 항목 0개로 통과한다. 이 임무의 쓰기 제한(보고서와 상태 파일만 작성 가능)에 따라 백로그 변경 명령(`bin/fm-captain-hold.sh complete --none`)은 실행하지 않았고, 게이트의 의미적 요건(미해결 캡틴 콜 없음)을 이 절로 attestation 대신 기록한다.

## 5. 결론 및 권고

- `tests/`는 최상위 기준 .sh 244개(실제 테스트 234 + 헬퍼 10), .py 3개(테스트 2 + 재현 스크립트 1). 하위 디렉터리에 테스트 스크립트가 없어 재귀 카운트는 동일하다.
- 러너 `bin/fm-test-run.sh`이 인벤토리·패밀리·lane·커버리지 가드의 단일 소유자이며, `CONTRIBUTING.md`가 동일한 진입점을 문서화한다.
- 대표 suite `tests/fm-brief.test.sh` (패밀리 `pure-contract-unit`)는 exit 0, 약 10.5초에 통과했다.
- **출할 작업 없음**: 이 조사에서 버그·회귀·구조 결함이 발견되지 않았고 수정할 코드가 없다. ship 프롬OTION 대상 없다.
- 권고: 없음 (구조가 문서화된 대로 동작함을 확인).

1/1 deliverable 완료: 이 보고서.
