# 보안

- Webhook URL은 Secret입니다.
- 기본 저장은 현재 Windows 사용자 DPAPI 암호화 파일입니다.
- `AI_WORKER_NOTIFIER_WEBHOOK_URL` 환경 변수도 지원하지만 프로세스 덤프나 환경 출력에 노출될 수 있습니다.
- 이벤트에는 전체 로그, diff, 파일 내용, DB/Sync payload, EPUB 제목·본문, 사용자 데이터, 절대경로를 넣지 않습니다.
- Notifier는 일반적인 token/secret/webhook/절대경로 패턴을 제거하지만 완벽한 탐지기는 아닙니다.
- 오류 메시지에 Webhook URL을 직접 출력하지 않습니다.
- runtime 전체는 기본 최대 25MB로 제한합니다.
