# Rendered Discord messages delivered by the real firstmate scripts

Each block is the exact `content` posted over real HTTP to the local Discord API
stand-in while driving the real bin/fm-discord-*.sh scripts end to end.

```
channel 1000000000000000001
---
**결정 필요** - 작업: Ship the billing endpoint [task-a]

왜 연락했나: 보류된 작업을 어떻게 진행할지

**필요한 결정: 보류된 작업을 어떻게 진행할지**

**선택지**
1. 요청대로 진행
2. 보류 상태로 두기

**권장안: 보류 상태로 두기**

↩️ 답장으로 선택해 주세요.
===
channel 1000000000000000002
---
**결정 필요** - 작업: Ship the billing endpoint [task-a]

왜 연락했나: app 저장소: 검토할 풀 리퀘스트가 준비되었습니다. https://github.com/acme/app/pull/42

**필요한 결정: 풀 리퀘스트를 병합할지**

**선택지**
1. 병합
2. 열어 두기

**권장안: 열어 두기**

↩️ 답장으로 선택해 주세요.
===
channel 1000000000000000003
---
작업 완료 - Wire the billing endpoint [task-a]: endpoint wired and tested
===
channel 1000000000000000004
---
작업 완료 - 결정 필요한 로그인 버그 수정 [task-a]: login bug fixed
===
channel 1000000000000000005
---
결정 필요 - but this is a completion envelope
===
```
