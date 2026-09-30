# Notification Relay Architecture

## 목적

AI Worker Notifier의 Headless Relay는 여러 작업환경이 사용자 알림을 보내기 위해 Discord, Slack, Telegram 같은 메신저의 자격 증명과 전송 규칙을 직접 알 필요가 없도록 하는 공용 알림 계층입니다.

외부 계약은 **Notification API**이고, 메신저별 구현은 Relay 내부의 **Provider Adapter**입니다.

```text
Agent / CI / Script / App
        │
        │ POST /api/v1/notifications
        ▼
Notification Relay
        │
        ├─ 인증
        ├─ 입력 검증 / redaction
        ├─ rate limit
        └─ provider 선택
                │
                ├─ Discord Adapter   ← 현재 구현
                ├─ Slack Adapter     ← 향후
                ├─ Telegram Adapter  ← 향후
                ├─ Teams Adapter     ← 향후
                └─ 기타 Messenger Adapter
```

## 핵심 원칙

### 1. API가 정본 인터페이스다

작업환경은 메신저를 직접 호출하지 않습니다.

호출자가 알아야 하는 것은 Relay URL, Relay Bearer Token, Notification payload뿐입니다. `ai-notify-remote.py` 같은 CLI는 편의 wrapper일 뿐이며 별도 정본 계약을 만들지 않습니다.

### 2. Provider는 Relay 내부 구현이다

현재 V1 provider는 Discord Webhook입니다. 외부 요청 payload는 Discord 용어를 사용하지 않습니다.

```json
{
  "message": "실기기 확인이 필요합니다.",
  "title": "사용자 확인 필요",
  "project": "AudioHub",
  "agent": "dogfood-actual",
  "severity": "warning",
  "source": "chatgpt"
}
```

이 요청을 Discord 메시지로 변환하는 책임은 Discord Adapter에 있습니다. 향후 Slack, Telegram, Teams 등을 추가해도 기존 caller와 API 계약은 그대로 유지하는 것을 기본 원칙으로 합니다.

### 3. Provider credential은 Relay Host만 소유한다

Discord Webhook, Slack token, Telegram bot token 같은 provider credential은 Agent나 각 개발 PC에 배포하지 않습니다.

```text
Caller
  └─ Relay Token만 보유

Relay Host
  ├─ Relay Token 검증 정보
  └─ Provider Credential
```

따라서 provider를 변경하거나 credential을 회전해도 각 작업환경을 다시 설정할 필요가 없도록 합니다.

### 4. Transport와 Provider를 분리한다

- **Transport**: Tailnet HTTPS, HTTP API, Bearer 인증
- **Notification Contract**: message/title/project/agent/severity/source
- **Provider**: Discord/Slack/Telegram/Teams별 payload와 credential
- **Client**: curl, Python, PowerShell, CI, Agent, FlowDuck

한 영역의 변경이 다른 영역에 전파되지 않도록 유지합니다.

## V1 API

```text
GET  /health
GET  /api/v1/status
POST /api/v1/notifications
```

`POST /api/v1/notifications`의 필수 필드는 `message` 하나입니다. 선택 필드는 `title`, `project`, `agent`, `severity`, `source`입니다.

현재 severity는 `info`, `warning`, `error`입니다. Provider-specific 필드는 V1 공용 API에 넣지 않습니다.

## 현재 배포 모델

```text
Tailnet Client
      │
      │ HTTPS
      ▼
Tailscale Serve :8771
      │
      ▼
127.0.0.1:8771
AIWorkerNotifier Headless Relay
      │
      ▼
Discord Provider Adapter
      │
      ▼
Discord
```

Backend는 loopback에만 bind합니다. Public Funnel을 기본 경로로 사용하지 않습니다.

## Provider 확장 방식

새 메신저를 추가할 때는 공용 Relay API를 확장하기보다 provider adapter를 추가하는 것을 우선합니다.

Provider가 최소한 만족해야 할 책임:

1. provider credential 로드
2. 공용 NotificationRequest를 provider payload로 변환
3. 안전한 mention/formatting 정책 적용
4. bounded timeout/retry
5. 성공 또는 provider delivery failure 반환
6. secret을 response/log에 노출하지 않음

공용 Relay Service는 provider의 세부 credential 형식이나 webhook URL 구조를 알지 않도록 유지합니다.

## 다중 Provider에 대한 향후 방향

초기 확장은 두 단계로 생각합니다.

### 단계 A — 서버 설정으로 provider 하나 선택

```text
Notification API
    ↓
Configured Provider
    ↓
Discord 또는 Slack 또는 Telegram
```

외부 API 변화가 없어 가장 단순합니다.

### 단계 B — 정책 기반 다중 전달

실제 필요가 생겼을 때만 도입합니다.

```text
warning/error → Discord + Telegram
info          → Discord
project=A     → Slack channel A
```

이 경우에도 caller가 provider 이름을 직접 지정하는 방식보다 Relay의 routing policy가 결정하도록 하는 것을 우선합니다. 이는 Agent가 특정 메신저 구조에 결합되는 것을 막기 위함입니다.

## 하지 않는 것

V1에서는 범용 메시지 큐, 장기 알림 히스토리 저장소, public internet notification gateway, Agent의 provider credential 직접 보유, caller의 provider별 payload 작성, 복잡한 routing DSL을 목표로 하지 않습니다.

필요가 실제로 생기기 전까지 Relay를 작고 독립적으로 유지합니다.

## 구현 언어

현재 Headless Relay는 Python 표준 라이브러리 기반입니다. 현재 규모에서는 낮은 idle footprint와 외부 dependency 0이라는 장점이 충분합니다. 향후 Rust 등으로 내부 구현을 교체하더라도 HTTP API 계약을 유지하면 caller 변경 없이 전환할 수 있습니다.
