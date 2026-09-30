# AI Worker Notifier

AI Worker Notifier는 AI/자동화 작업이 사용자에게 진행 상황·완료·실패·확인 요청을 전달하는 **독립 알림 계층**입니다.

현재는 두 가지 실행 경로를 제공합니다.

- **Windows Local Mode** — 로컬 inbox와 watcher를 사용해 Discord로 전달
- **Headless Relay Mode** — OCI 같은 상시 실행 Host가 HTTP API를 받아 Discord로 전달

알림이 실패해도 원래 작업·테스트·Git 결과는 바꾸지 않습니다. Agent나 프로젝트는 Discord Webhook을 직접 알 필요가 없고, Headless Mode에서는 공용 Notification API만 호출합니다.

| 구성 | 역할 |
|------|------|
| `ai-task-complete` | 작업 종료 이벤트를 로컬 inbox에 기록 |
| `ai-notify` | 작업 중 사용자에게 전달할 임의 메시지를 로컬 inbox에 기록 |
| `AIWorkerNotifier` | Windows inbox를 감시해 provider로 전달 |
| Headless Relay API | Tailnet의 여러 작업환경에서 공용 알림 요청을 수신 |
| `ai-notify-remote.py` | 공용 API를 편하게 호출하는 선택적 CLI wrapper |
| Cursor Hook | GUI Agent `stop` 시 `ai-task-complete` 자동 호출 |
| 설정 메뉴 (`AIWorkerNotifier-Setup.bat`) | Webhook·멘션·ON/OFF·Cursor Hook·테스트를 한곳에서 관리 |

현재 provider 구현은 **Discord**입니다. Relay API와 호출자는 provider에 종속되지 않도록 유지하며, 이후 다른 메신저 provider를 추가할 수 있습니다.

요구 환경은 실행 모드에 따라 다릅니다. Windows Local Mode는 **Windows + PowerShell 5.1+**, Headless Relay Mode는 현재 **Python 3.9+**에서 동작합니다.

---

## 1분 시작

1. 이 저장소를 원하는 폴더에 둡니다. (예: `C:\dev\SW\AIWorkerNotifier`)
2. `AIWorkerNotifier-Setup.bat`를 실행합니다.
3. **Webhook 설정** → Discord Webhook URL 입력  
4. (선택) **역할 멘션 설정** → 역할 ID 저장  
5. **알림 전달 ON/OFF** → `ON` (초록)
6. **알림 테스트**로 Discord에 실제로 오는지 확인

메뉴 구성:

```text
알림 전달   ON / OFF
Webhook     연결됨 / 없음
역할 멘션   설정됨 / 없음
명령 등록   등록됨 / 미등록
Cursor Hook 설치됨 / 미설치

1. 알림 전달 ON/OFF
2. Webhook 설정
3. 역할 멘션 설정
4. 알림 테스트   (@역할 / @사용자 / @everyone)
5. 명령 등록
6. Cursor Hook
0. 나가기
```

Cursor GUI 완료 알림:

```powershell
.\scripts\install-cursor-hook.ps1
.\scripts\set-cursor-hook-mode.ps1 -Mode always
```

상세: [`docs/CURSOR_INTEGRATION.md`](docs/CURSOR_INTEGRATION.md)

명령 등록을 하면 새 터미널에서 `ai-task-complete`, `ai-notify`, `AIWorkerNotifier`를 바로 쓸 수 있습니다. PATH 변경은 **새로 연** 터미널부터 적용됩니다.

---

## 사용 예

```powershell
ai-task-complete `
  -Task 'TEST-001' `
  -Status 'AUDIT_COMPLETE' `
  -Summary '설치 시험 완료' `
  -NextAction 'VERIFY_DISCORD'
```

작업 도중 사용자에게 바로 전달할 메시지는 `ai-notify`를 사용합니다. 본문은 에이전트가 쓴 문장을 그대로 우선 표시하고, Project/Agent 같은 기계 메타데이터는 아래 코드블럭으로 분리합니다.

```powershell
ai-notify '지금 5초 내로 Windows에서 Pair 버튼을 눌러 주세요.' -Agent ChatGPT
```

Discord에서는 설정된 역할 멘션 뒤에 대략 이렇게 표시됩니다.

````text
@AI-Worker-Notify

지금 5초 내로 Windows에서 Pair 버튼을 눌러 주세요.

```text
Project: AudioHub
Agent: ChatGPT
```
````

`-Title`은 사람이 읽을 제목이 정말 필요할 때만 선택적으로 사용할 수 있고, 기본 헤더는 붙지 않습니다. `Project`를 생략하면 현재 Git 저장소 이름을 자동 감지합니다. `-Agent`는 기존 `-AgentRole`의 짧은 alias입니다.

`ai-notify`는 완료 상태를 만들지 않고 별도 message event를 queue합니다. 설정된 Discord 역할 멘션이 있으면 기존 `allowed_mentions.roles` 경로로 실제 멘션을 함께 보냅니다.

한글 인수는 **PowerShell에서 직접** 넘기는 편이 안전합니다. `ai-notify.ps1`은 PATH에서 PowerShell ExternalScript로 직접 실행되므로 CMD `%*`를 거치지 않습니다.

전송 없이 로컬 처리만 확인:

```powershell
AIWorkerNotifier -DryRun -Once -Backlog
```

스크립트로만 설정할 때:

```powershell
cd 'C:\dev\SW\AIWorkerNotifier'
.\scripts\install-user-path.ps1
.\scripts\set-discord-webhook.ps1
AIWorkerNotifier   # 또는 설정 메뉴에서 ON
```

## 공용 Headless Relay API

항상 켜진 OCI 같은 Host에서는 Windows inbox/watcher 없이 독립 Relay API만 실행할 수 있습니다. **HTTP API가 정본 인터페이스**이고 `bin/ai-notify-remote.py`는 그 API를 편하게 호출하는 선택적 wrapper입니다.

```text
Agent / CI / Script / App
        │
        │ HTTPS + Bearer token
        ▼
Notification Relay API
        │
        ▼
Provider Adapter
        │
        └─ Discord (현재)
```

API:

```text
GET  /health
GET  /api/v1/status
POST /api/v1/notifications
```

`POST /api/v1/notifications`의 필수 필드는 `message` 하나입니다. `title`, `project`, `agent`, `severity`, `source`는 선택입니다.

```json
{
  "message": "테스트가 끝났습니다.",
  "project": "AudioHub",
  "agent": "integration",
  "severity": "info"
}
```

직접 API 호출:

```bash
curl -X POST 'https://<tailnet-host>:8771/api/v1/notifications' \
  -H 'Authorization: Bearer <relay-token>' \
  -H 'Content-Type: application/json' \
  -d '{"message":"테스트가 끝났습니다.","project":"AudioHub","agent":"integration"}'
```

선택적 CLI wrapper:

```bash
AI_WORKER_NOTIFIER_RELAY_URL='https://<tailnet-host>:8771' \
AI_WORKER_NOTIFIER_RELAY_TOKEN_FILE='~/.config/ai-worker-notifier/relay-token' \
python3 bin/ai-notify-remote.py '테스트가 끝났습니다.' --project AudioHub --agent integration
```

접근 조건은 **Tailnet 연결 + Relay Bearer Token**입니다. `/health`는 인증 없이 확인할 수 있지만 `/api/v1/status`와 `/api/v1/notifications`는 Bearer token을 요구합니다.

Relay backend는 `127.0.0.1:8771`에만 bind하고 Tailscale Serve 같은 private ingress를 통해 노출하는 구성을 권장합니다. Discord Webhook 같은 provider credential은 Relay Host만 소유하며 caller에게 배포하지 않습니다.

Provider-neutral 구조와 향후 메신저 확장 원칙은 [`docs/NOTIFICATION_RELAY.md`](docs/NOTIFICATION_RELAY.md)를 참고하세요.

---

## 동작 요약

1. `ai-task-complete`가 이벤트를 `%LOCALAPPDATA%\AIWorkerNotifier\inbox`에 `.tmp` → `.json`으로 원자적 기록합니다.
2. 알림 전달이 `ON`이면 inbox를 읽어 Discord로 보냅니다.
3. Webhook URL은 Windows **DPAPI**(현재 사용자)로 암호화해 로컬에만 둡니다. 저장소에 넣지 않습니다.
4. 역할 멘션이 설정돼 있으면 `<@&역할ID>` + `allowed_mentions.roles`로 실제 `@역할` 알림을 울립니다.

```text
%LOCALAPPDATA%\AIWorkerNotifier\
├─ inbox / processing / failed / history
├─ state\
│  ├─ discord-webhook.dpapi      # Webhook (암호화)
│  ├─ discord-mention-role.id    # 역할 ID (숫자만)
│  └─ integration-settings.json  # Cursor Hook 모드 등
└─ logs\
```

환경 변수 `AI_WORKER_NOTIFIER_WEBHOOK_URL`이 있으면 파일보다 우선합니다.

---

## 포함 / 미포함

**포함**

- 설정 메뉴(UTF-8 한글), 알림 전달 ON/OFF(백그라운드)
- Discord Webhook + `@역할` / `@사용자` / `@everyone` 테스트
- Cursor GUI `stop` Hook 설치·제거·always/off 모드
- Git 프로젝트·branch·HEAD 자동 감지, UTF-8 한글 이벤트
- 중복 completion key 억제, 재시도·타임아웃, 런타임 정리
- 알림 실패 시에도 CLI 종료 코드 0 유지

**아직 없음**

- 트레이 UI, Credential Manager UI, 프로젝트별 Webhook 라우팅
- Cursor Hook `workflow_only` 모드
- Orca 비정상 종료 감시

버전: `VERSION` 파일 참고 (현재 0.1.x MVP)

---

## 향후 업데이트 방향

AI Worker Notifier는 AI 작업의 실행 정책을 관리하는 도구가 아니라,
여러 AI 도구의 완료·실패 이벤트를 안정적으로 수집하고 전달하는
독립 알림 계층을 목표로 합니다.

업데이트 우선순위는 다음과 같습니다.

### 1. 안정성과 진단 개선

- Cursor Hook 입력 형식과 인코딩 회귀 테스트 유지
- Local Queue·Watcher·Headless Relay·Provider 단계별 상태 확인 개선
- 민감정보를 남기지 않는 진단 로그와 오류 분류
- 설치·업데이트 후 자동 점검 명령 제공

### 2. IDE·에이전트 통합 확대

- Cursor 외 IDE와 CLI Adapter 추가
- 공통 `ai-task-complete` / Notification API 계약을 통한 통합
- IDE별 구현은 얇은 Adapter로 유지
- Agent가 provider credential이나 메신저별 API를 직접 알지 않도록 유지

### 3. Provider와 알림 라우팅 확장

- Discord 외 Slack·Telegram·Teams 등 Provider Adapter 추가 가능
- 공용 Notification API는 provider-neutral 상태로 유지
- 필요가 생기면 프로젝트·중요도·상태에 따른 Relay routing policy 도입
- 트레이 UI와 전달 상태 확인
- 설정 백업·복원과 안전한 업데이트

### 4. 워크플로 연동

- AI-WorkFlow 같은 외부 워크플로에서 역할·Task·Milestone 정보를 전달받아 표시
- 워크플로 정책 자체는 이 저장소에 두지 않음
- 전역 IDE 알림과 워크플로 전용 알림의 중복 방지

세부 일정과 확정되지 않은 기능은 구현이 시작될 때 별도 Roadmap 문서로 관리합니다.

---

## 보안

- **Provider credential을 Git에 커밋하지 마세요.** Discord Webhook, 향후 Slack/Telegram token 등은 모두 같은 원칙을 적용합니다.
- Windows Local Mode는 Discord Webhook을 `%LOCALAPPDATA%`의 DPAPI 파일에 저장합니다. Headless Relay는 provider credential과 relay token을 owner-only 파일로 보관합니다.
- 공개 저장소에 올릴 때는 노출된 credential을 즉시 폐기·재발급하고 Git 히스토리에 비밀이 없는지 확인하세요.

자세한 정책: [`docs/SECURITY.md`](docs/SECURITY.md)

---

## 문서

| 문서 | 내용 |
|------|------|
| [`docs/DISCORD_SETUP.md`](docs/DISCORD_SETUP.md) | Discord Webhook·멘션 설정 |
| [`docs/CURSOR_INTEGRATION.md`](docs/CURSOR_INTEGRATION.md) | Cursor GUI Hook 설치·모드 |
| [`docs/AGENT_CONTRACT.md`](docs/AGENT_CONTRACT.md) | 에이전트 호출 계약 |
| [`docs/OPERATIONS.md`](docs/OPERATIONS.md) | 운영·장애 처리 |
| [`docs/SECURITY.md`](docs/SECURITY.md) | Secret·로그 정책 |
| [`docs/NOTIFICATION_RELAY.md`](docs/NOTIFICATION_RELAY.md) | 공용 Relay API·Provider-neutral 아키텍처 |
| [`docs/PROJECT_INTEGRATION.md`](docs/PROJECT_INTEGRATION.md) | 다른 프로젝트 연동 원칙 |

테스트: `.\tests\Test-AIWorkerNotifier.ps1`, `.\tests\Test-CursorHookIntegration.ps1`
