# ChatGPT 완료 알림 통합 (실험적)

ChatGPT 웹 브라우저에서 응답 생성이 끝났는지만 감지해 기존 AIWorkerNotifier의 Discord 알림 파이프라인으로 전달합니다.

이 통합은 **응답 본문을 읽거나 저장하지 않습니다.** DOM에서는 생성 중에 나타나는 중지 컨트롤의 존재 여부만 확인합니다.

## 동작 구조

```text
ChatGPT 웹
  -> userscript가 생성 중/완료 상태만 관찰
  -> localhost bridge (127.0.0.1:43127)
  -> ai-task-complete
  -> 기존 inbox / notifier / Discord
```

Discord Webhook URL은 브라우저에 전달하지 않습니다. 기존 AIWorkerNotifier의 DPAPI 저장 및 전달기를 그대로 사용합니다.

## 설치

### 1. AIWorkerNotifier 알림 전달 준비

기존 방식대로 Webhook을 설정하고 알림 전달을 ON으로 둡니다.

### 2. 로컬 bridge 실행

저장소 루트에서:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\integrations\chatgpt\start-chatgpt-bridge.ps1
```

기본 포트는 `43127`이며 loopback(`127.0.0.1`)에만 바인딩됩니다.

### 3. userscript 설치

Tampermonkey 같은 userscript 관리 확장에 아래 파일 내용을 새 스크립트로 등록합니다.

```text
integrations/chatgpt/chatgpt-completion-watcher.user.js
```

적용 대상은 `https://chatgpt.com/*` 및 이전 호스트 호환용 `https://chat.openai.com/*`입니다.

## 감지 규칙

- 중지 컨트롤이 보이면 `GENERATING`
- 이전에 `GENERATING`을 관찰한 뒤 중지 컨트롤이 사라지고 약 1.2초 안정되면 `COMPLETE`
- 한 턴당 완료 이벤트는 한 번만 전송
- assistant 메시지의 `textContent`, 코드블록, 대화 제목 등은 읽지 않음

ChatGPT UI의 접근성 라벨이나 `data-testid`가 변경되면 selector 갱신이 필요할 수 있습니다.

## 로컬 bridge 보안 경계

- `127.0.0.1`에만 바인딩
- 허용 Origin: `https://chatgpt.com`, `https://chat.openai.com`
- 허용 endpoint: `POST /ai-worker-notifier/chatgpt/completed`
- 허용 body: `response-complete` 고정 문자열
- ChatGPT 응답 내용은 bridge로 보내지 않음
- Discord Webhook secret은 기존 DPAPI 저장소에만 유지

## 현재 범위 밖

- ChatGPT 응답 본문 자동 추출
- 코드블록 자동 복사
- 프롬프트 자동 입력/전송
- Send 버튼 자동 클릭
- ChatGPT 내부 API 호출
- 설치 메뉴에 ChatGPT 통합 항목 추가

첫 단계에서는 완료 알림만 검증한 뒤 후속 기능을 별도 작업으로 확장합니다.
