# Discord 설정

1. 개인 또는 개발용 Discord 서버에 `#ai-worker-notifications` 채널을 만듭니다.
2. 채널 설정 → 연동 → Webhook에서 새 Webhook을 만듭니다.
3. 이름을 `AI Worker Notifier`로 지정합니다.
4. Webhook URL을 복사합니다.
5. 저장소나 채팅에 붙이지 말고 다음 명령으로 저장합니다.

```powershell
.\scripts\set-discord-webhook.ps1
```

6. 휴대폰 Discord 앱에서 서버·채널 음소거를 해제하고 메시지 알림을 켭니다.
7. Notifier를 실행한 뒤 테스트 이벤트를 만듭니다.

```powershell
AIWorkerNotifier
```

다른 PowerShell:

```powershell
.\scripts\test-notification.ps1
```

Webhook 노출 시 Discord에서 즉시 삭제하고 새 Webhook으로 교체합니다.
