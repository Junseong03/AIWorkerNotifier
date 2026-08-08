# ChatGPT 완료 알림 통합 (실험적)

ChatGPT 웹 브라우저에서 **응답 생성이 끝났는지 여부만** 감지해 기존 AIWorkerNotifier의 Discord 알림 파이프라인으로 전달합니다.

여러 ChatGPT 탭이 열려 있어도 각 탭을 별도로 식별합니다. 새로 감지된 탭은 기본적으로 알림이 활성화되며, 사용자가 관리 화면에서 **체크 해제한 탭만 알림 대상에서 제외**합니다.

응답 본문과 입력 프롬프트의 내용은 읽거나 저장하지 않습니다.

## 동작 구조

```text
여러 ChatGPT 탭
  -> Chrome 확장 content watcher
     - tab title / URL
     - 생성 중 여부
     - Stop 생성 컨트롤의 등장/제거
  -> Chrome 확장 service worker
  -> localhost bridge (127.0.0.1:43127)
  -> 체크 해제된 탭만 제외
  -> 완료 이벤트를 ai-task-complete로 큐 등록
  -> 기존 inbox / notifier / Discord
```

Discord Webhook URL은 브라우저에 전달하지 않습니다. 기존 AIWorkerNotifier의 DPAPI 저장 및 전달기를 그대로 사용합니다.

## 설치 및 사용

### 1. AIWorkerNotifier 알림 전달 준비

기존 방식대로 Webhook을 설정하고 알림 전달을 ON으로 둡니다.

### 2. ChatGPT bridge 실행

설정 콘솔의 `ChatGPT 감시` 메뉴에서 bridge를 시작하는 방식을 권장합니다.

직접 실행하려면 저장소 루트에서:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\integrations\chatgpt\start-chatgpt-bridge.ps1
```

기본 포트는 `43127`이며 loopback(`127.0.0.1`)에만 바인딩됩니다.

관리 화면 주소:

```text
http://127.0.0.1:43127/
```

관리 화면 자체는 감시를 수행하지 않는 UI이므로 계속 열어둘 필요가 없습니다.

### 3. Chrome 확장 설치

Chrome `chrome://extensions`에서 개발자 모드를 켠 뒤 다음 디렉터리를 **압축해제된 확장 프로그램**으로 한 번 등록합니다.

```text
integrations/chatgpt/chrome-extension/
```

적용 대상은 다음 두 호스트입니다.

```text
https://chatgpt.com/*
https://chat.openai.com/*
```

확장 코드를 업데이트한 뒤에는 `chrome://extensions`에서 확장을 새로고침합니다.

## 탭 알림 기본값

탭 선택 모델은 whitelist가 아니라 **disabled list** 방식입니다.

- 새로 감지된 ChatGPT 탭: 기본 알림 ON
- 관리 화면에서 체크 해제: 해당 탭 알림 OFF
- 다시 체크: 해당 탭 알림 ON
- 체크 해제 상태 저장: `%LOCALAPPDATA%\AIWorkerNotifier\state\chatgpt-disabled-tabs.json`

이전의 `chatgpt-selected-tabs.json`은 현재 기본 ON 모델의 상태 파일로 사용하지 않습니다.

Chrome 탭이 실제로 닫히거나 ChatGPT URL을 벗어나면 해당 탭 레코드는 제거됩니다. Chrome 확장 탭의 존재 여부는 짧은 heartbeat TTL로 삭제하지 않고 Chrome tab 이벤트와 비파괴 snapshot을 기준으로 유지합니다.

## 완료 감지 규칙

현재 Chrome watcher의 핵심 규칙은 다음과 같습니다.

- Stop 생성 컨트롤이 보이면 해당 턴에서 실제 생성 상태를 관찰한 것으로 기록
- Stop 생성 컨트롤이 DOM에서 제거되거나 숨겨지면 완료 이벤트 전송
- Mutation을 놓친 경우에만 Stop 컨트롤이 연속 500ms 이상 보이지 않는지 확인 후 보조 완료 처리
- 한 턴당 완료 이벤트는 한 번만 전송
- 턴마다 고유 `turnId`를 생성해 bridge의 dispatch ID에 포함
- 체크 해제된 탭의 완료 이벤트는 bridge에서 무시

중요하게, **일반 DOM 변경은 완료 신호로 사용하지 않습니다.**

따라서 다음 변화만으로 완료 이벤트를 만들지 않습니다.

- 사용자가 입력창에 글자를 입력함
- 입력창 커서/레이아웃이 바뀜
- 기타 Stop 생성 컨트롤과 무관한 DOM 변화

이전의 `assistant` 메시지 컨테이너 개수 증가 fallback은 응답 시작 시점에도 조건이 성립할 수 있어 오탐 원인이 되었으므로 제거했습니다.

## 개인정보 및 데이터 경계

Chrome watcher와 bridge가 사용하는 정보는 다음 범위로 제한합니다.

- Chrome tab ID
- 탭 제목
- ChatGPT URL
- 생성 중 여부
- 생성 완료 상태
- 로컬에서 생성한 turn ID

다음 항목은 읽거나 bridge로 전달하지 않습니다.

- 응답 본문 `textContent`
- 코드블록 내용
- 입력 프롬프트 내용
- 입력창에 작성 중인 문자열

입력창의 submit/click/Enter 이벤트는 새 턴 시작을 구분하기 위한 신호로만 사용하며 문자열 내용은 읽지 않습니다.

## 로컬 bridge 보안 경계

- `127.0.0.1`에만 바인딩
- 브라우저 API는 고정 client marker 요구
- ChatGPT가 아닌 URL은 탭 등록 거부
- snapshot 누락만으로 열린 Chrome 탭을 삭제하지 않음
- 응답 내용과 프롬프트는 bridge로 보내지 않음
- Discord Webhook secret은 기존 DPAPI 저장소에만 유지

탭 제목은 사용자가 어떤 대화인지 구분하기 위한 표시와 Discord 완료 이벤트의 Task 이름에 사용합니다.

## 레거시 userscript

`integrations/chatgpt/chatgpt-completion-watcher.user.js`는 초기 실험 경로로 남아 있을 수 있지만, 현재 기본 통합 경로는 전용 Chrome 확장입니다.

## 현재 범위 밖

- ChatGPT 응답 본문 자동 추출
- 코드블록 자동 복사
- 프롬프트 내용 읽기/저장
- 프롬프트 자동 입력/전송
- Send 버튼 자동 클릭
- ChatGPT 내부 API 호출

ChatGPT UI의 접근성 라벨이나 `data-testid`가 변경되면 Stop 생성 컨트롤 selector 갱신이 필요할 수 있습니다.
