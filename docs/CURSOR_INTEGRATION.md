# Cursor GUI 통합

Cursor GUI Agent가 한 턴을 끝낼 때(`stop` Hook) AIWorkerNotifier가
`ai-task-complete`을 호출하도록 연결합니다.

알림 실패는 Cursor Agent 작업 결과를 바꾸지 않습니다.

## 설치

```powershell
cd <AIWorkerNotifier-repo-root>
.\scripts\install-cursor-hook.ps1
```

또는 `AIWorkerNotifier-Setup.bat` → **6. Cursor Hook** → 설치.

설치 대상(사용자 전역):

```text
%USERPROFILE%\.cursor\hooks.json
```

Hook 구현 본체는 저장소 내부에 둡니다.

```text
bin\AIWorkerNotifier-CursorHook.cmd
integrations\cursor\notify-agent-stop.ps1
```

기존 `hooks.json`은 덮어쓰지 않고 병합합니다. AIWorkerNotifier stop 항목만
추가·갱신합니다. 설치 전 Secret이 없는 JSON 백업을
`%LOCALAPPDATA%\AIWorkerNotifier\backups\cursor-hooks\`에 남깁니다.

Cursor가 hooks.json을 다시 로드하지 않으면 **Cursor 재시작**이 필요할 수 있습니다.

## 제거

```powershell
.\scripts\uninstall-cursor-hook.ps1
```

AIWorkerNotifier가 추가한 stop 항목만 제거합니다. 다른 Hook은 유지합니다.

## 알림 모드

사용자 로컬 상태:

```text
%LOCALAPPDATA%\AIWorkerNotifier\state\integration-settings.json
```

```powershell
.\scripts\set-cursor-hook-mode.ps1 -Mode always   # 기본
.\scripts\set-cursor-hook-mode.ps1 -Mode off
.\scripts\set-cursor-hook-mode.ps1 -Get
```

| 모드 | 의미 |
|------|------|
| `always` | Cursor Agent stop마다 알림 |
| `off` | Cursor Hook 알림 생성 안 함 |

`workflow_only`는 지원하지 않습니다. PROMPT_ID와 generation 연결이 안정화되면
후속 작업으로 둡니다.

## 저장소 이동 후

Hook 명령은 설치 시점의 절대경로를 사용합니다. 저장소 폴더를 옮기면
`install-cursor-hook.ps1`을 다시 실행하세요.

## 문제 확인

1. 설정 메뉴에서 Cursor Hook 상태가 `설치됨`인지 확인
2. Cursor **Hooks** 출력 채널에서 `stop` 실행 여부 확인
3. `%LOCALAPPDATA%\AIWorkerNotifier\inbox`에 이벤트가 쌓이는지 확인
4. 알림 전달이 ON인지, Webhook이 연결됐는지 확인

## 소유권

- Cursor GUI stop → AIWorkerNotifier Hook → `ai-task-complete` → inbox → watcher → Discord
- Agent 본체가 `ai-task-complete`을 직접 호출하지 않아도 됩니다.
- 역할·TASK·Milestone 정책은 AI-WorkFlow 저장소가 소유합니다.

## 다른 IDE

같은 패턴으로 Adapter를 추가할 수 있습니다.

```text
integrations/<ide>/...
scripts/install-<ide>-hook.ps1
```

공통 Queue·Discord·Credential은 재구현하지 말고 기존 `ai-task-complete`을
호출하세요.
