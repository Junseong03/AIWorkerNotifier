# ChatGPT 완료 알림 통합 (실험적)

ChatGPT 웹 브라우저에서 **응답 생성이 끝났는지 여부만** 감지해 기존 AIWorkerNotifier의 Discord 알림 파이프라인으로 전달합니다.

여러 ChatGPT 탭이 열려 있어도 각 탭을 별도로 식별합니다. 새로 감지된 탭은 기본적으로 알림이 활성화되며, 사용자가 관리 화면에서 **체크 해제한 탭만 알림 대상에서 제외**합니다.

응답 본문과 입력 프롬프트의 내용은 읽거나 저장하지 않습니다.

## 동작 구조

```text
여러 ChatGPT 탭
  -> Chrome 확장 content watcher
     - tab/window identity / title / URL
     - 생성 중 여부
     - 완료 signal
  -> Chrome 확장 service worker
     - 실제 열린 Chrome tab snapshot
     - background browser-action queue poll
     - exact existing tab 선택 / 필요 시 새 tab 생성
  -> localhost bridge (127.0.0.1:43127)
     - 체크 해제된 탭만 제외
     - generic completion metadata journal
     - generic ChatGPT focus-or-open broker
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

현재 focus-or-open 동작은 extension `0.1.13` 기준입니다.

## 탭 알림 기본값

탭 선택 모델은 whitelist가 아니라 **disabled list** 방식입니다.

- 새로 감지된 ChatGPT 탭: 기본 알림 ON
- 관리 화면에서 체크 해제: 해당 탭 알림 OFF
- 다시 체크: 해당 탭 알림 ON
- 체크 해제 상태 저장: `%LOCALAPPDATA%\AIWorkerNotifier\state\chatgpt-disabled-tabs.json`

Chrome 탭이 실제로 닫히거나 ChatGPT URL을 벗어나면 해당 탭 레코드는 제거됩니다. Chrome 확장 탭의 존재 여부는 짧은 heartbeat TTL로 삭제하지 않고 Chrome tab 이벤트와 비파괴 snapshot을 기준으로 유지합니다.

## 완료 감지 규칙

현재 Chrome watcher의 핵심 규칙은 다음과 같습니다.

- Stop 생성 컨트롤이 보이면 해당 턴에서 실제 생성 상태를 관찰한 것으로 기록
- 생성 중 사용자가 composer를 편집한 직후 Stop이 사라지면 그 소실을 완료로 사용하지 않음
- 오염되지 않은 Stop 소실은 연속 확인 후 완료 후보로 사용
- composer 변화로 Stop 소실이 오염되면 최신 assistant turn의 완료 후 Action UI까지 확인한 뒤 완료 처리
- 한 턴당 완료 이벤트는 한 번만 전송
- 턴마다 고유 `turnId`를 생성해 bridge의 dispatch ID에 포함
- 체크 해제된 탭의 완료 이벤트는 bridge에서 무시

일반 DOM 변경만으로 완료 이벤트를 만들지 않습니다. 입력 문자열과 응답 본문은 읽지 않습니다.

## Generic completion journal

선택된 ChatGPT 탭에서 완료 이벤트가 발생하면 bridge는 기존 Discord notification queue와 별도로 **generic completion metadata**를 로컬 journal에 기록합니다.

```text
%LOCALAPPDATA%\AIWorkerNotifier\state\chatgpt-completions\
```

Schema:

```text
ai-worker-notifier/chatgpt-completion/v1
```

저장 정보:

- stable event ID (`tabId + turnId`, turnId가 없으면 감지 시각 fallback)
- Chrome tab ID
- Chrome window ID (가능한 경우)
- 탭 제목
- ChatGPT URL
- turn ID
- 완료 감지 UTC 시각
- detection mode

journal은 최대 최근 500개 파일로 제한합니다. 동일 stable event ID의 파일이 이미 있으면 중복 기록하지 않습니다.

이 journal은 특정 Project 제품에 종속된 저장소가 아닙니다. 외부 local consumer가 완료 metadata를 읽을 수 있게 하는 Adapter seam이며 AIWorkerNotifier는 Project ID, Project 이름, unread count를 저장하거나 계산하지 않습니다.

## ChatGPT focus-or-open broker

Chrome 확장 `0.1.13`부터 local consumer는 현재 ChatGPT URL을 기준으로 **exact existing tab을 우선 재사용하고, 실제로 없을 때만 새 탭을 하나 여는** generic browser action을 요청할 수 있습니다.

Consumer request:

```json
{
  "tabId": "chrome-123",
  "url": "https://chatgpt.com/c/abc",
  "openIfMissing": true
}
```

중요한 원칙은 Bridge의 `$tabs` cache를 새 탭 생성 판단의 정본으로 사용하지 않는 것입니다.

```text
Bridge
→ request queue
→ extension background가 chrome.tabs.query({})로 실제 현재 탭 전체 조회
→ target과 각 tab URL canonicalize
→ exact match 존재
   → 새 tab 생성 금지
   → preferred tabId가 실제 exact match면 우선
   → 아니면 active/recent existing match 선택
→ exact match 없음
   → chrome.tabs.create() 정확히 한 번
→ 선택/생성 tab active
→ 최소화 window 복원
→ chrome.windows.update(windowId, {focused:true})
→ canonical target URL 포함 focus ack
```

Canonical 비교는 다음을 통합합니다.

- `chat.openai.com` / `www.chatgpt.com` → `chatgpt.com`
- query / fragment 제거
- trailing slash 정규화
- path 보존

같은 exact URL 탭이 이미 여러 개 있어도 새 탭을 추가하지 않습니다. 빠른 연속 요청에서도 첫 요청이 탭을 생성한 뒤 다음 actual query가 그 exact match를 보기 때문에 불필요한 중복 생성을 피합니다.

`tabId`는 preference hint입니다. 해당 ID가 실제로 target URL과 일치하지 않으면 버리고 다른 exact match를 사용합니다.

### Foreground 의미

`chrome.tabs.update(..., {active:true})`로 tab을 선택한 뒤 `chrome.windows.update(..., {focused:true})`로 Chrome window 자체를 foreground합니다. 최소화된 window는 먼저 normal 상태로 복원합니다.

기존 normal Chrome window가 없고 새 세션을 열어야 하는 경우에는 target URL을 가진 normal Chrome window를 새로 만들 수 있습니다.

### Delivery hardening

`0.1.11`은 target page heartbeat에 focus request 전달을 의존해 오래 숨겨진 페이지에서 timeout 가능성이 있었습니다.

`0.1.12`부터 background poll을 추가했고, `0.1.13`은 약 1초 간격 actual-tab snapshot 경로에서 focus-or-open request를 확인합니다. content watcher heartbeat는 생성 상태와 기존 fallback 경로로 남깁니다.

지원 endpoint:

```text
POST /api/tabs/focus
POST /api/tabs/focus-status
POST /api/tabs/focus-ack   # extension 전용
```

Consumer marker:

```text
X-AIWorkerNotifier-Client: flowduck-adapter
```

Broker는 ChatGPT canonical URL만 다루며 Project ID나 unread 의미를 알지 않습니다.

## 개인정보 및 데이터 경계

Chrome watcher와 bridge가 사용하는 정보는 다음 범위로 제한합니다.

- Chrome tab ID
- Chrome window ID
- 탭 제목
- ChatGPT URL
- 생성 중 여부
- 생성 완료 상태
- 로컬에서 생성한 turn ID
- 완료 감지 시각/mode

다음 항목은 읽거나 bridge로 전달하지 않습니다.

- 응답 본문 `textContent`
- 코드블록 내용
- 입력 프롬프트 내용
- 입력창에 작성 중인 문자열

입력창의 submit/click/Enter 이벤트는 새 턴 시작을 구분하기 위한 신호로만 사용하며 문자열 내용은 읽지 않습니다.

## 로컬 bridge 보안 경계

- `127.0.0.1`에만 바인딩
- 브라우저 API는 고정 client marker 요구
- 외부 consumer browser action API는 별도 `flowduck-adapter` marker 요구
- ChatGPT가 아닌 URL은 등록 및 focus-or-open 대상에서 거부
- snapshot 누락만으로 열린 Chrome 탭을 삭제하지 않음
- 새 탭 생성 여부는 stale bridge cache가 아니라 actual Chrome query로 결정
- Project mapping/unread 상태는 저장하지 않음
- 응답 내용과 프롬프트는 bridge로 보내지 않음
- Discord Webhook secret은 기존 DPAPI 저장소에만 유지

## 레거시 userscript

`integrations/chatgpt/chatgpt-completion-watcher.user.js`는 초기 실험 경로로 남아 있을 수 있지만, 현재 기본 통합 경로는 전용 Chrome 확장입니다.

## 현재 범위 밖

- ChatGPT 응답 본문 자동 추출
- 코드블록 자동 복사
- 프롬프트 내용 읽기/저장
- 프롬프트 자동 입력/전송
- Send 버튼 자동 클릭
- ChatGPT 내부 API 호출
- 외부 consumer의 Project mapping/unread 상태 관리

ChatGPT UI의 접근성 라벨이나 `data-testid`가 변경되면 Stop 생성 컨트롤 selector 갱신이 필요할 수 있습니다.
