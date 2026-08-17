# ChatGPT 완료 알림 통합 (실험적)

ChatGPT 웹에서 **응답 생성이 끝났는지 여부와 generic tab/browser metadata만** 감지해 AIWorkerNotifier 알림 파이프라인과 local consumer Adapter에 전달합니다.

응답 본문과 입력 프롬프트 내용은 읽거나 저장하지 않습니다.

## 동작 구조

```text
ChatGPT tabs
  → content watcher
     - 생성 중/완료 signal
     - tab/window identity는 background가 보강
  → extension service worker
     - actual Chrome tabs query
     - localhost WebSocket browser-control channel
     - exact existing-first focus-or-open
     - serialized browser action
  ⇅ localhost Python Bridge 127.0.0.1:43127
     - disabled-tab selection
     - completion metadata journal
     - generic focus-or-open broker
     - WebSocket keepalive/action push
     - bounded browser-control diagnostics
  → 기존 notification queue / Discord

FlowDuck 같은 local consumer
  → current ChatGPT URL + openIfMissing=true
  → Bridge
```

AIWorkerNotifier는 FlowDuck Project ID, Project 이름, unread count를 알지 않습니다.

## Runtime 요구사항

AIWorkerNotifier 기본 알림·Discord·Cursor 기능의 최소 요구사항은 기존처럼 **Windows + PowerShell 5.1+**입니다.

ChatGPT Bridge 기능은 현재 **Python 3.10+**를 추가로 사용합니다. 서버 구현은 Python 표준 라이브러리만 사용하므로 별도 `pip install`은 필요하지 않습니다.

Python 탐색 순서:

1. `AI_WORKER_NOTIFIER_PYTHON`
2. `py.exe -3`
3. `python.exe`

`start-chatgpt-bridge.ps1`은 서버 구현이 아니라 Python Bridge를 시작하고 수명을 연결하는 얇은 compatibility launcher입니다. 기존 설정 콘솔과 FlowDuck Adapter는 이 launcher 진입점을 계속 사용할 수 있습니다.

## 설치와 실행

Bridge는 설정 콘솔의 `ChatGPT 감시` 메뉴로 시작하는 방식을 권장합니다. 이 경우 별도 PowerShell 창을 계속 열어둘 필요가 없습니다.

직접 실행:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\integrations\chatgpt\start-chatgpt-bridge.ps1
```

관리 화면:

```text
http://127.0.0.1:43127/
```

Bridge identity/status:

```text
GET http://127.0.0.1:43127/api/bridge/status
```

정상 Python Bridge 예시 의미:

```json
{
  "schema": "ai-worker-notifier/chatgpt-bridge-status/v1",
  "service": "ai-worker-notifier-chatgpt-bridge",
  "implementation": "python",
  "bridgeVersion": "python-v1",
  "pid": 1234,
  "port": 43127,
  "extensionConnected": true,
  "extensionVersion": "0.1.15"
}
```

Chrome unpacked extension 경로:

```text
integrations/chatgpt/chrome-extension/
```

현재 browser-control revision은 **0.1.15**, 최소 Chrome 버전은 116입니다. 확장 코드를 갱신한 뒤 `chrome://extensions`에서 확장을 Reload합니다.

PowerShell 구현에서 Python Bridge로 갱신한 최초 한 번은 실행 중 legacy Bridge를 종료한 뒤 다시 시작해야 합니다. 이후에는 기존 ON/OFF 관리 경로를 그대로 사용합니다.

## Launcher 수명 계약

설정 콘솔과 FlowDuck은 기존 `start-chatgpt-bridge.ps1` lifecycle을 유지합니다.

```text
start-chatgpt-bridge.ps1
→ python -m chatgpt_bridge.main --parent-pid <launcher-pid>
```

Python Bridge는 Windows에서 launcher PID를 감시합니다. 기존 관리 경로가 launcher를 종료하면 Python child도 함께 종료되므로 orphan Bridge가 43127을 계속 점유하지 않습니다.

이미 새 Python Bridge가 실행 중인 상태에서 launcher를 한 번 더 실행하면 새 Python 프로세스는 `/api/bridge/status`로 기존 Bridge identity를 확인하고 중복 서버를 만들지 않고 정상 종료합니다.

## 탭 알림 기본값

Disabled-list 모델입니다.

- 새 ChatGPT 탭 → 알림 ON
- 관리 화면에서 체크 해제 → 해당 탭만 OFF
- 상태 파일 → `%LOCALAPPDATA%\AIWorkerNotifier\state\chatgpt-disabled-tabs.json`

Chrome tab 존재 여부는 실제 tab 이벤트와 non-destructive snapshot으로 유지합니다.

## 완료 감지

- Stop 생성 control을 관찰하면 실제 생성 상태를 본 것으로 기록
- 생성 중 composer edit 직후 Stop 소실은 완료로 사용하지 않음
- 오염되지 않은 Stop 소실은 짧게 재확인 후 완료
- composer 영향으로 오염되면 최신 assistant final-action UI까지 확인
- 한 turn당 완료 이벤트 1회
- turn마다 local `turnId`
- prompt/response 문자열 미수집

## Completion journal

```text
%LOCALAPPDATA%\AIWorkerNotifier\state\chatgpt-completions\
```

Schema:

```text
ai-worker-notifier/chatgpt-completion/v1
```

저장 정보:

- stable event ID
- tab ID
- optional window ID
- title
- ChatGPT URL
- turn ID
- detected UTC
- detection mode

최대 최근 500개 파일로 제한하며 temp write 후 atomic replace를 사용합니다.

## Focus-or-open broker

Consumer request:

```json
{
  "tabId": "chrome-123",
  "url": "https://chatgpt.com/c/abc",
  "openIfMissing": true
}
```

원칙:

```text
Bridge request
→ WebSocket push
→ extension이 chrome.tabs.query({})
→ target/tab URL canonicalize
→ exact match 있음
   → existing tab 재사용
→ exact match 없음 + openIfMissing=true
   → 새 tab 정확히 1개 생성
→ tab active
→ minimized window restore
→ chrome.windows.update(focused=true)
→ canonical target 포함 ACK
```

Bridge의 tab registry는 관리 UI와 preferred hint 용도이며 새 탭 생성 여부의 정본이 아닙니다.

같은 exact URL tab이 이미 여러 개 있어도 추가 tab을 만들지 않습니다. preferred tabId가 actual exact match일 때 우선하고, 아니면 active/recent match를 사용합니다.

Browser actions는 extension의 `browserActionChain`으로 직렬화하여 빠른 연속 요청의 duplicate-create race를 막습니다. 동일 request ID가 push/fallback으로 중복 전달되어도 한 번만 실행합니다.

## WebSocket control channel

```text
ws://127.0.0.1:43127/api/extension/socket?version=0.1.15
Sec-WebSocket-Protocol: ai-worker-notifier-chatgpt-v1
```

- loopback only
- extension Origin 검증
- 전용 subprotocol 검증
- Bridge keepalive 약 20초
- focus-or-open은 service-worker timer polling 없이 push
- socket 없음 → `EXTENSION_CHANNEL_UNAVAILABLE`
- snapshot response는 compatibility fallback

## 0.1.15 reload recovery

Unpacked extension Reload는 열린 ChatGPT page 자체를 Reload하지 않습니다. 이전 content script가 invalidated extension context를 가진 채 살아 있을 수 있고 실제 Windows에서 다음 오류가 확인됐습니다.

```text
TypeError: Cannot read properties of undefined (reading 'sendMessage')
```

0.1.15:

- `sendMessage` 전 `chrome.runtime.sendMessage` availability 확인
- invalidated context 감지 시 stale watcher self-stop
- 새 watcher injection은 기존 active watcher를 교체
- WebSocket open에서 열린 ChatGPT tabs에 watcher 재주입
- ChatGPT tab activation에서도 watcher 재주입
- browser focus-or-open 자체는 content heartbeat에 의존하지 않음

## Structured errors

```text
INVALID_TARGET_URL
→ consumer가 전달한 current URL을 ChatGPT canonical URL로 해석할 수 없음

TAB_NOT_FOUND
→ focus-only 요청이고 exact tab이 없으며 create가 요청되지 않음

EXTENSION_CHANNEL_UNAVAILABLE
→ Bridge↔extension browser-control channel 없음

FOCUS_TIMEOUT
→ focus request queue 이후 ACK 미수신
```

`openIfMissing=true` 요청에서 valid target임에도 `TAB_NOT_FOUND`가 나오면 정상 계약 위반입니다. Bridge diagnostics의 실제 `openIfMissing`을 확인합니다.

## 진단

Python Bridge 로그:

```text
%LOCALAPPDATA%\AIWorkerNotifier\logs\chatgpt-bridge.log
```

최대 약 1 MB 로그와 2개 backup을 사용합니다. 관리 화면에도 최근 browser-control 진단 40개를 표시합니다.

```text
http://127.0.0.1:43127/
→ Python Bridge PID
→ 브라우저 제어 채널 상태
→ 최근 browser-control 진단
```

포함 정보:

- incoming tab hint
- raw URL / canonical URL
- `openIfMissing`
- socket connected
- request ID
- push result
- ACK receive/accept/reject
- timeout

Extension service-worker DevTools에는 다음 prefix를 사용합니다.

```text
[AIWorkerNotifier][browser-control]
```

진단 로그에도 prompt/response 본문은 포함하지 않습니다.

## Privacy / security

- Bridge는 `127.0.0.1`에만 bind
- HTTP API는 client marker 사용
- WebSocket은 extension Origin + subprotocol 검증
- arbitrary non-ChatGPT URL 거부
- actual tab query가 create 판단 정본
- Project mapping/unread 저장 금지
- prompt/response text 미수집
- Discord Webhook secret은 기존 DPAPI 저장소 유지

## Contract test

```text
tests/Test-ChatGptProjectInboxBridge.ps1
```

검증:

- thin PowerShell launcher parse/entrypoint
- Python 3.10+ resolver
- Python Bridge module import
- localhost HTTP + WebSocket 101 round-trip
- `openIfMissing=true` focus push
- ACK → focus-status `focused`
- Bridge identity/status endpoint
- completion journal/schema/diagnostics contract
- actual `chrome.tabs.query({})`
- exact existing-first / no-match create
- action serialization / request dedupe
- foreground window
- extension 0.1.15
- stale content context guard / reinjection markers

## 범위 밖

- response body extraction
- prompt text read/store
- automatic prompt submission
- ChatGPT internal API call
- Project mapping/unread ownership
