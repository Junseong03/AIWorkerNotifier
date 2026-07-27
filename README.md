# AI Worker Notifier (PowerShell MVP)

Windows PowerShell 5.1 이상에서 Cursor CLI, Orca, 기타 자동화 작업의 최종 상태를 로컬 이벤트로 기록하고 Discord Webhook으로 전달하는 독립 도구입니다.

이 MVP는 다음 두 프로세스로 나뉩니다.

- `ai-task-complete`: 작업 종료 이벤트를 `%LOCALAPPDATA%\AIWorkerNotifier\inbox`에 원자적으로 기록
- `AIWorkerNotifier`: inbox를 감시하고 Discord Webhook으로 전송

알림 실패는 제품 작업, 테스트, Git 결과를 바꾸지 않습니다. CLI는 이벤트 기록 실패가 발생해도 경고만 출력하고 종료 코드 0을 유지합니다.

## 설치 위치

압축을 다음 위치에 풉니다.

```text
C:\dev\SW\AIWorkerNotifier
```

## 빠른 시작

### 가장 쉬운 설정 메뉴

탐색기에서 다음 파일을 더블클릭합니다.

```text
AIWorkerNotifier-Setup.bat
```

CMD 메뉴에서 다음 작업을 선택할 수 있습니다.

```text
1. 현재 사용자의 PATH에 AIWorkerNotifier\bin 등록
2. 현재 사용자의 PATH에서 AIWorkerNotifier\bin 제거
3. Discord Webhook 설정 또는 교체
4. 저장된 Discord Webhook 제거
5. Discord mention role 설정
6. Discord mention role 제거
7. 상세 상태 보기
8. 종료
```

PATH 제거는 프로그램 파일이나 `%LOCALAPPDATA%\AIWorkerNotifier` 실행 데이터를 삭제하지 않습니다. PATH를 변경한 뒤에는 새 PowerShell 또는 새 Cursor CLI 세션을 열어야 합니다.

### PowerShell에서 개별 실행

PowerShell에서:

```powershell
cd 'C:\dev\SW\AIWorkerNotifier'

# 1. 사용자 PATH에 bin 추가
.\scripts\install-user-path.ps1

# 2. Discord Webhook을 현재 Windows 사용자 DPAPI로 암호화 저장
.\scripts\set-discord-webhook.ps1

# 3. 새 PowerShell/Cursor CLI를 열고 명령 확인
Get-Command ai-task-complete

# 4. Notifier 실행
AIWorkerNotifier

# 5. 다른 터미널에서 테스트 이벤트 생성
ai-task-complete `
  --task 'TEST-001' `
  --status 'AUDIT_COMPLETE' `
  --summary 'AI Worker Notifier 설치 시험' `
  --next 'VERIFY_DISCORD_MOBILE_NOTIFICATION'
```

Discord 메시지를 실제 전송하지 않고 이벤트 처리만 확인하려면:

```powershell
AIWorkerNotifier -DryRun -Once -Backlog
```

## 현재 MVP 범위

포함:

- Git 프로젝트/branch/HEAD 자동 감지
- UTF-8 한글 JSON 이벤트
- `.tmp` 작성 후 `.json` rename
- live-only 및 backlog 모드
- Discord 전송, 짧은 timeout, 1회 재시도
- 중복 completion key 억제
- 필드 길이 제한과 기본 sanitization
- runtime cleanup 및 크기 제한
- DPAPI 사용자 범위 Webhook 저장
- 한글 CMD 설정 메뉴 (`AIWorkerNotifier-Setup.bat`)
- PATH 설치/제거 스크립트

후속 범위:

- Windows 트레이 UI
- Windows Credential Manager 직접 연동
- Orca 프로세스 비정상 종료 감시
- 프로젝트별 Webhook routing

## 런타임 경로

```text
%LOCALAPPDATA%\AIWorkerNotifier\
├─ inbox
├─ processing
├─ failed
├─ history
├─ state
└─ logs
```

Webhook은 기본적으로 다음 파일에 Windows 사용자 DPAPI로 암호화되어 저장됩니다.

```text
%LOCALAPPDATA%\AIWorkerNotifier\state\discord-webhook.dpapi
```

선택적 멘션 역할 ID(숫자만)는 다음 파일에 저장됩니다. Git에 포함하지 않습니다.

```text
%LOCALAPPDATA%\AIWorkerNotifier\state\discord-mention-role.id
```

환경 변수 `AI_WORKER_NOTIFIER_WEBHOOK_URL`이 설정되어 있으면 그 값이 우선합니다.

## 문서

- `docs/AGENT_CONTRACT.md`: 에이전트 호출 계약
- `docs/DISCORD_SETUP.md`: Discord 설정
- `docs/OPERATIONS.md`: 운영 및 장애 처리
- `docs/SECURITY.md`: Secret·로그 정책
- `docs/PROJECT_INTEGRATION.md`: Epub Viewer 등 프로젝트 연결 원칙
