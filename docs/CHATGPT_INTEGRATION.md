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
     - localhost WebSocket browser-control channel
     - exact existing tab 선택 / 필요 시 새 tab 생성
     - browser action 직렬화
  <-> localhost bridge (127.0.0.1:43127)
     - 체크 해제된 탭만 제외
     - generic completion metadata journal
     - generic ChatGPT focus-or-open broker
     - WebSocket keepalive / action push
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

관리 화면에서는 탭 목록 외에 browser-control channel 상태도 확인할 수 있습니다.

```text
브라우저 제어 채널: 연결됨 (extension 0.1.14)
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

현재 focus-or-open/browser-control 동작은 extension `0.1.14` 기준이며 최소 Chrome 버전은 116입니다.

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

`0.1.14`부터 이 browser action의 전달은 service-worker timer polling이 아니라 localhost WebSocket push를 primary로 사용합니다.

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
→ WebSocket으로 extension에 focus-or-open 즉시 push
→ extension이 chrome.tabs.query({})로 실제 현재 탭 전체 조회
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

같은 exact URL 탭이 이미 여러 개 있어도 새 탭을 추가하지 않습니다.

빠른 연속 요청은 extension의 `browserActionChain`에서 직렬화됩니다. 첫 요청의 query→focus/create가 끝난 뒤 다음 요청이 새 `chrome.tabs.query({})`를 수행하므로 두 요청이 동시에 `탭 없음`을 보고 각각 새 탭을 만드는 race를 방지합니다.

동일 request ID가 WebSocket push와 snapshot fallback 양쪽으로 전달되는 경우도 `queuedFocusRequestIds`로 한 번만 실행합니다.

`tabId`는 preference hint입니다. 해당 ID가 실제로 target URL과 일치하지 않으면 버리고 다른 exact match를 사용합니다.

### Foreground 의미

`chrome.tabs.update(..., {active:true})`로 tab을 선택한 뒤 `chrome.windows.update(..., {focused:true})`로 Chrome window 자체를 foreground합니다. 최소화된 window는 먼저 normal 상태로 복원합니다.

기존 normal Chrome window가 없고 새 세션을 열어야 하는 경우에는 target URL을 가진 normal Chrome window를 새로 만들 수 있습니다.

### WebSocket control channel

```text
ws://127.0.0.1:43127/api/extension/socket?version=0.1.14
Sec-WebSocket-Protocol: ai-worker-notifier-chatgpt-v1
```

Bridge는 extension WebSocket Origin과 전용 subprotocol을 검증합니다. 연결이 유지되는 동안 약 20초 간격의 keepalive message를 extension에 보내 browser-control service worker가 idle timer에만 의존하지 않게 합니다.

Control channel이 없으면 consumer의 focus-or-open 요청을 pending timeout으로 방치하지 않습니다.

```text
HTTP 503
EXTENSION_CHANNEL_UNAVAILABLE
```

이 경우 extension `0.1.14` 새로고침 및 Bridge 재시작 여부를 바로 진단할 수 있습니다.

### Delivery history

- `0.1.11`: target page heartbeat 의존 → hidden page timeout 가능.
- `0.1.12`: extension background polling 보강.
- `0.1.13`: 약 1초 snapshot polling으로 focus-or-open까지 전달했지만 Manifest V3 service worker lifetime에 primary delivery가 의존.
- `0.1.14`: localhost WebSocket push + keepalive를 primary browser-control transport로 전환.

Snapshot response는 compatibility fallback으로 유지합니다. content watcher heartbeat는 생성 상태 및 legacy focus-only fallback으로 남깁니다.

지원 endpoint:

```text
POST /api/tabs/focus
POST /api/tabs/focus-status
POST /api/tabs/focus-ack   # extension 전용
GET  /api/extension/socket # extension WebSocket upgrade
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
- 브라우저 HTTP API는 고정 client marker 요구
- WebSocket은 extension Origin + 전용 subprotocol 검증
- 외부 consumer browser action API는 별도 `flowduck-adapter` marker 요구
- ChatGPT가 아닌 URL은 등록 및 focus-or-open 대상에서 거부
- snapshot 누락만으로 열린 Chrome 탭을 삭제하지 않음
- 새 탭 생성 여부는 stale bridge cache가 아니라 actual Chrome query로 결정
- browser action은 직렬화해 duplicate create race 방지
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
