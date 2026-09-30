# AI Worker Notifier

AI Worker Notifier는 AI/자동화 작업이 사용자에게 진행 상황·완료·실패·확인 요청을 전달하는 **독립 알림 계층**입니다.

사용자-facing 기본 경로는 하나입니다.

```text
notify "메시지"
        ↓
공용 Notification Relay API
        ↓
Provider Adapter
        ↓
Discord (현재)
```

`notify`는 로컬 inbox나 Windows watcher를 거치지 않습니다. Tailnet에 연결된 PC에서 Relay Bearer Token을 읽어 OCI의 공용 API를 직접 호출합니다. API가 정본 인터페이스이고 CLI는 얇은 편의 wrapper입니다.

| 구성 | 역할 |
|------|------|
| `notify` | 공용 Relay API로 사용자 메시지 전송 |
| Headless Relay API | Tailnet의 여러 작업환경에서 공용 알림 요청 수신 |
| Provider Adapter | 공용 notification을 Discord 등 실제 메신저 형식으로 변환 |
| `ai-task-complete` | 기존 자동 완료 통합용 compatibility 경로 |
| Cursor Hook | GUI Agent `stop` 시 기존 완료 이벤트 자동 호출 |

현재 provider 구현은 **Discord**입니다. 호출자와 API 계약은 provider-neutral하게 유지하며 이후 Slack·Telegram·Teams 등으로 확장할 수 있습니다.

알림 실패는 원래 작업·테스트·Git 결과를 바꾸지 않습니다.

---

## 1분 시작 — Windows

전제:

- PC가 Relay Host와 같은 Tailnet에 연결돼 있음
- Relay Token이 `$HOME\.config\ai-worker-notifier\relay-token`에 있음
- 이 저장소의 `bin`을 PATH에 등록함

명령 등록:

```powershell
cd 'C:\dev\SW\AIWorkerNotifier'
.\scripts\install-user-path.ps1
```

새 PowerShell을 연 뒤:

```powershell
notify "작업이 끝났습니다."
```

메타데이터가 필요하면:

```powershell
notify "실기기 확인이 필요합니다." `
  -Project AudioHub `
  -Agent ChatGPT `
  -Severity warning
```

`Project`를 생략하면 현재 Git 저장소 이름을 자동 감지합니다.

### Relay Token 배치

Windows에서 Taildrop로 받은 token은 보통 `$HOME\Downloads\relay-token`에 들어옵니다.

```powershell
New-Item -ItemType Directory -Force "$HOME\.config\ai-worker-notifier" | Out-Null
Move-Item "$HOME\Downloads\relay-token" "$HOME\.config\ai-worker-notifier\relay-token"
```

토큰 값을 명령줄이나 채팅에 직접 붙여넣지 않는 것을 권장합니다.

### 기존 완료 통합

Cursor Hook과 `ai-task-complete` 기반 자동 완료 알림은 아직 compatibility 경로로 남아 있습니다. 일반 사용자 메시지는 새 `notify` 명령만 사용합니다.

상세: [`docs/CURSOR_INTEGRATION.md`](docs/CURSOR_INTEGRATION.md)

## 공용 Headless Relay API

항상 켜진 OCI 같은 Host에서는 독립 Relay API를 실행합니다. **HTTP API가 정본 인터페이스**이고 Windows의 `notify` 명령은 그 API를 호출하는 얇은 wrapper입니다.

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

Windows에서는 보통 직접 API를 작성하지 않고 다음 명령을 사용합니다.

```powershell
notify "테스트가 끝났습니다." -Project AudioHub -Agent integration
```

API를 직접 호출해야 한다면 PowerShell에서는 `Invoke-RestMethod`를 사용합니다.

```powershell
$token = (Get-Content "$HOME\.config\ai-worker-notifier\relay-token" -Raw).Trim()
$headers = @{ Authorization = "Bearer $token" }
$body = @{ message = "테스트가 끝났습니다." } | ConvertTo-Json

Invoke-RestMethod `
  -Method Post `
  -Uri 'https://<tailnet-host>:8771/api/v1/notifications' `
  -Headers $headers `
  -ContentType 'application/json; charset=utf-8' `
  -Body $body
```

Windows PowerShell 5.1에서 `curl`은 `Invoke-WebRequest` alias일 수 있으므로 Unix용 `curl -X ...` 예제를 그대로 붙여 넣지 않습니다.

접근 조건은 **Tailnet 연결 + Relay Bearer Token**입니다. `/health`는 인증 없이 확인할 수 있지만 `/api/v1/status`와 `/api/v1/notifications`는 Bearer token을 요구합니다.

Relay backend는 `127.0.0.1:8771`에만 bind하고 Tailscale Serve 같은 private ingress를 통해 노출하는 구성을 권장합니다. Discord Webhook 같은 provider credential은 Relay Host만 소유하며 caller에게 배포하지 않습니다.

Provider-neutral 구조와 향후 메신저 확장 원칙은 [`docs/NOTIFICATION_RELAY.md`](docs/NOTIFICATION_RELAY.md)를 참고하세요.

---

## 기존 완료 통합의 동작 요약

일반 메시지 `notify`는 아래 로컬 경로를 사용하지 않습니다. 다음 내용은 아직 유지 중인 `ai-task-complete` / Cursor 완료 compatibility 경로에만 해당합니다.

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
- 기존 `ai-task-complete` compatibility 경로의 Discord Webhook은 `%LOCALAPPDATA%`의 DPAPI 파일에 저장합니다. Headless Relay는 provider credential과 relay token을 owner-only 파일로 보관합니다.
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
