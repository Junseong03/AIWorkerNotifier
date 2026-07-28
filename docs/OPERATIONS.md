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

## Discord 없이 시험

```powershell
AIWorkerNotifier -DryRun -Once -Backlog
```

## 런타임 초기화

```powershell
.\scripts\reset-runtime.ps1 -KeepWebhook
```

## 장애 확인

- `%LOCALAPPDATA%\AIWorkerNotifier\failed`
- `%LOCALAPPDATA%\AIWorkerNotifier\logs\notifier.log`

알림 장애는 프로젝트의 작업 결과를 변경하지 않습니다.
