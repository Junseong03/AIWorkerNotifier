# 운영

## 실시간 모드

```powershell
AIWorkerNotifier
```

Notifier 시작 시각보다 오래된 이벤트는 startup grace 범위를 제외하고 stale 처리합니다.

## backlog 모드

```powershell
AIWorkerNotifier -Backlog
```

기존 inbox 이벤트도 처리합니다.

## 한 번만 처리

```powershell
AIWorkerNotifier -Once -Backlog
```

## Provider 전송 없이 시험

```powershell
AIWorkerNotifier -DryRun -Once -Backlog
```

이 DryRun은 아직 남아 있는 `ai-task-complete` compatibility 경로의 provider 전송을 생략하는 시험입니다.

## 런타임 초기화

```powershell
.\scripts\reset-runtime.ps1 -KeepWebhook
```

## Headless Relay 운영

Linux/OCI에서는 저장소 루트에서 다음 설치 스크립트를 사용합니다.

```bash
sh scripts/install-headless-relay-systemd.sh
```

기본 backend는 `127.0.0.1:8771`이고 user systemd service `ai-worker-notifier-relay.service`로 실행됩니다. `~/.config/ai-worker-notifier/relay-token`은 자동 생성됩니다. 현재 Discord provider의 credential은 `~/.config/ai-worker-notifier/discord-webhook.url`에 owner-only 권한으로 둡니다.

원격 client는 Tailnet 연결과 Relay Bearer Token이 모두 필요합니다. Provider credential은 원격 client에 배포하지 않습니다.

상태 확인:

```bash
systemctl --user status ai-worker-notifier-relay.service
curl http://127.0.0.1:8771/health
```

## 장애 확인

- `%LOCALAPPDATA%\AIWorkerNotifier\failed`
- `%LOCALAPPDATA%\AIWorkerNotifier\logs\notifier.log`
- Headless Relay: `systemctl --user status ai-worker-notifier-relay.service`

알림 장애는 프로젝트의 작업 결과를 변경하지 않습니다.
