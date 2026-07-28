# AI Worker Notifier

Windows에서 AI/자동화 작업이 끝나면 Discord로 알려 주는 작은 PowerShell 도구입니다.

작업 결과는 로컬에 먼저 쌓고, 백그라운드 전달기가 Discord Webhook으로 보냅니다. 알림이 실패해도 원래 작업·테스트·Git 결과는 바꾸지 않습니다.

| 구성 | 역할 |
|------|------|
| `ai-task-complete` | 작업 종료 이벤트를 로컬 inbox에 기록 |
| 알림 전달 (`AIWorkerNotifier`) | inbox를 감시해 Discord로 전송 |
| 설정 메뉴 (`AIWorkerNotifier-Setup.bat`) | Webhook·멘션·ON/OFF·테스트를 한곳에서 관리 |

요구 환경: **Windows**, **PowerShell 5.1+**

---

## 1분 시작

1. 이 저장소를 원하는 폴더에 둡니다. (예: `C:\dev\SW\AIWorkerNotifier`)
2. `AIWorkerNotifier-Setup.bat`를 실행합니다.
3. **Webhook 설정** → Discord Webhook URL 입력  
4. (선택) **역할 멘션 설정** → 역할 ID 저장  
5. **알림 전달 ON/OFF** → `ON` (초록)
6. **알림 테스트**로 Discord에 실제로 오는지 확인

메뉴 구성:

```text
알림 전달   ON / OFF
Webhook     연결됨 / 없음
역할 멘션   설정됨 / 없음

1. 알림 전달 ON/OFF
2. Webhook 설정
3. 역할 멘션 설정
4. 알림 테스트   (@역할 / @사용자 / @everyone)
5. 명령 등록
0. 나가기
```

명령 등록을 하면 새 터미널에서 `ai-task-complete`를 바로 쓸 수 있습니다. PATH 변경은 **새로 연** 터미널부터 적용됩니다.

---

## 사용 예

```powershell
ai-task-complete `
  -Task 'TEST-001' `
  -Status 'AUDIT_COMPLETE' `
  -Summary '설치 시험 완료' `
  -NextAction 'VERIFY_DISCORD'
```

한글 인수는 **PowerShell에서 직접** 넘기는 편이 안전합니다. CMD `%*` 경유는 환경에 따라 깨질 수 있습니다.

전송 없이 로컬 처리만 확인:

```powershell
AIWorkerNotifier -DryRun -Once -Backlog
```

스크립트로만 설정할 때:

```powershell
cd 'C:\dev\SW\AIWorkerNotifier'
.\scripts\install-user-path.ps1
.\scripts\set-discord-webhook.ps1
AIWorkerNotifier   # 또는 설정 메뉴에서 ON
```

---

## 동작 요약

1. `ai-task-complete`가 이벤트를 `%LOCALAPPDATA%\AIWorkerNotifier\inbox`에 `.tmp` → `.json`으로 원자적 기록합니다.
2. 알림 전달이 `ON`이면 inbox를 읽어 Discord로 보냅니다.
3. Webhook URL은 Windows **DPAPI**(현재 사용자)로 암호화해 로컬에만 둡니다. 저장소에 넣지 않습니다.
4. 역할 멘션이 설정돼 있으면 `<@&역할ID>` + `allowed_mentions.roles`로 실제 `@역할` 알림을 울립니다.

```text
%LOCALAPPDATA%\AIWorkerNotifier\
├─ inbox / processing / failed / history
├─ state\
│  ├─ discord-webhook.dpapi      # Webhook (암호화)
│  └─ discord-mention-role.id    # 역할 ID (숫자만)
└─ logs\
```

환경 변수 `AI_WORKER_NOTIFIER_WEBHOOK_URL`이 있으면 파일보다 우선합니다.

---

## 포함 / 미포함

**포함**

- 설정 메뉴(UTF-8 한글), 알림 전달 ON/OFF(백그라운드)
- Discord Webhook + `@역할` / `@사용자` / `@everyone` 테스트
- Git 프로젝트·branch·HEAD 자동 감지, UTF-8 한글 이벤트
- 중복 completion key 억제, 재시도·타임아웃, 런타임 정리
- 알림 실패 시에도 CLI 종료 코드 0 유지

**아직 없음**

- 트레이 UI, Credential Manager UI, 프로젝트별 Webhook 라우팅
- Orca 비정상 종료 감시

버전: `VERSION` 파일 참고 (현재 0.1.x MVP)

---

## 보안

- **Webhook URL·역할 ID를 Git에 커밋하지 마세요.**
- 이 프로젝트는 `.env`에 비밀을 두지 않습니다. 자격 증명은 `%LOCALAPPDATA%`의 DPAPI 파일(또는 사용자 환경 변수)을 씁니다.
- 공개 저장소에 올릴 때는 Webhook을 재발급하고, 히스토리에 비밀이 없는지 확인하세요.

자세한 정책: [`docs/SECURITY.md`](docs/SECURITY.md)

---

## 문서

| 문서 | 내용 |
|------|------|
| [`docs/DISCORD_SETUP.md`](docs/DISCORD_SETUP.md) | Discord Webhook·멘션 설정 |
| [`docs/AGENT_CONTRACT.md`](docs/AGENT_CONTRACT.md) | 에이전트 호출 계약 |
| [`docs/OPERATIONS.md`](docs/OPERATIONS.md) | 운영·장애 처리 |
| [`docs/SECURITY.md`](docs/SECURITY.md) | Secret·로그 정책 |
| [`docs/PROJECT_INTEGRATION.md`](docs/PROJECT_INTEGRATION.md) | 다른 프로젝트 연동 원칙 |

테스트: `.\tests\Test-AIWorkerNotifier.ps1`
