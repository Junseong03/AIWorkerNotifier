# ChatGPT 완료 알림 통합 (실험적)

ChatGPT 웹 브라우저에서 응답 생성이 끝났는지만 감지해 기존 AIWorkerNotifier의 Discord 알림 파이프라인으로 전달합니다.

여러 ChatGPT 탭이 열려 있어도 각 탭을 별도로 식별하며, 사용자가 **어떤 탭의 완료 알림을 받을지 직접 선택**합니다. 응답 본문과 프롬프트는 읽거나 저장하지 않습니다.

## 동작 구조

```text
여러 ChatGPT 탭
  -> 각 userscript가 tabId + 제목 + URL + 생성 상태 heartbeat
  -> localhost bridge (127.0.0.1:43127)
  -> 로컬 관리 화면에서 감시 탭 선택
  -> 선택된 탭의 COMPLETE만 ai-task-complete
  -> 기존 inbox / notifier / Discord
```

Discord Webhook URL은 브라우저에 전달하지 않습니다. 기존 AIWorkerNotifier의 DPAPI 저장 및 전달기를 그대로 사용합니다.

## 설치 및 사용

### 1. AIWorkerNotifier 알림 전달 준비

기존 방식대로 Webhook을 설정하고 알림 전달을 ON으로 둡니다.

### 2. 로컬 bridge 실행

저장소 루트에서:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\integrations\chatgpt\start-chatgpt-bridge.ps1
```

기본 포트는 `43127`이며 loopback(`127.0.0.1`)에만 바인딩됩니다.

브리지가 실행되면 콘솔에 관리 주소가 표시됩니다.

```text
http://127.0.0.1:43127/
```

이 화면에서 현재 감지된 ChatGPT 탭의 제목, URL, 생성 상태를 확인하고 완료 알림을 받을 탭을 체크한 뒤 **선택 저장**을 누릅니다. 여러 탭을 동시에 선택할 수 있습니다.

탭은 약 3초마다 heartbeat를 보내며, 약 10초 이상 heartbeat가 없는 탭은 열린 탭 목록에서 제거됩니다. 선택 상태 자체는 `%LOCALAPPDATA%\AIWorkerNotifier\state\chatgpt-selected-tabs.json`에 저장됩니다.

### 3. userscript 설치

Tampermonkey 같은 userscript 관리 확장에 아래 파일 내용을 새 스크립트로 등록합니다.

```text
integrations/chatgpt/chatgpt-completion-watcher.user.js
```

적용 대상은 `https://chatgpt.com/*` 및 이전 호스트 호환용 `https://chat.openai.com/*`입니다.

각 브라우저 탭은 `sessionStorage`에 고유 `tabId`를 만들어 같은 대화가 여러 탭에서 열려 있어도 별개의 탭으로 취급합니다.

## 감지 규칙

- 중지 컨트롤이 보이면 `GENERATING`
- 이전에 `GENERATING`을 관찰한 뒤 중지 컨트롤이 사라지고 약 1.2초 안정되면 `COMPLETE`
- 한 턴당 완료 이벤트는 한 번만 전송
- 완료 시점에 해당 탭이 감시 대상으로 선택되어 있을 때만 알림 생성
- assistant 메시지의 `textContent`, 코드블록, 프롬프트 본문은 읽지 않음

ChatGPT UI의 접근성 라벨이나 `data-testid`가 변경되면 selector 갱신이 필요할 수 있습니다.

## 로컬 bridge 보안 경계

- `127.0.0.1`에만 바인딩
- userscript API는 고정 client marker를 요구
- heartbeat 입력은 tabId, 탭 제목, ChatGPT URL, 생성 여부로 제한
- ChatGPT가 아닌 URL은 탭 등록 거부
- 응답 내용과 프롬프트는 bridge로 보내지 않음
- Discord Webhook secret은 기존 DPAPI 저장소에만 유지

탭 제목은 브라우저가 표시하는 `document.title`을 사용합니다. 사용자가 어떤 대화인지 구분하기 위한 표시용이며 Discord 완료 이벤트의 Task 이름에도 사용됩니다.

## 현재 범위 밖

- ChatGPT 응답 본문 자동 추출
- 코드블록 자동 복사
- 프롬프트 자동 입력/전송
- Send 버튼 자동 클릭
- ChatGPT 내부 API 호출
- 설치 메뉴에 ChatGPT 통합 항목 추가

첫 단계에서는 다중 탭 감지와 선택적 완료 알림을 실제 브라우저에서 검증한 뒤 후속 기능을 별도 작업으로 확장합니다.
