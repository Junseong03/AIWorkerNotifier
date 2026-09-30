# 보안

- Discord Webhook을 포함한 provider credential은 Secret입니다.
- Windows Desktop 기본 Discord Webhook 저장은 현재 사용자 DPAPI 암호화 파일입니다.
- Headless POSIX Relay는 provider credential과 relay token을 owner-only 파일(`0600`)로 저장하고 config directory는 `0700`으로 유지합니다.
- 향후 Slack token, Telegram bot token 등 다른 provider credential을 추가해도 동일한 경계를 적용합니다.
- Headless Relay backend는 loopback에만 bind하고, 원격 노출은 Tailscale Serve 같은 private ingress를 사용합니다.
- `status`와 `notifications` API는 별도 relay bearer token을 요구합니다.
- Discord 멘션 역할 ID는 Secret이 아니지만 Git에 넣지 않고
  `%LOCALAPPDATA%\AIWorkerNotifier\state\discord-mention-role.id`에만 둡니다.
- `AI_WORKER_NOTIFIER_WEBHOOK_URL` 환경 변수도 지원하지만 프로세스 덤프나 환경 출력에 노출될 수 있습니다.
- 이벤트에는 전체 로그, diff, 파일 내용, DB/Sync payload, EPUB 제목·본문, 사용자 데이터, 절대경로를 넣지 않습니다.
- Notifier는 일반적인 token/secret/webhook/절대경로 패턴을 제거하지만 완벽한 탐지기는 아닙니다.
- 오류 메시지에 Webhook URL을 직접 출력하지 않습니다.
- 역할 멘션은 `allowed_mentions.parse=[]`와 허용 role ID 목록만 사용해
  Summary 안의 `@everyone` / `@here` / 다른 멘션을 활성화하지 않습니다.
- runtime 전체는 기본 최대 25MB로 제한합니다.
