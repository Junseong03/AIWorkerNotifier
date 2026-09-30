# Agent Notification Contract

알림 경계는 한 번의 dispatch가 반환하는 terminal outcome입니다.

최종 `STATUS`, `OWNER`, `NEXT_ACTION`과 필요한 문서·Git 결과를 모두 확정한 뒤 사용자에게 반환하기 직전에 `ai-task-complete`을 정확히 한 번 호출합니다.

```powershell
ai-task-complete `
  -Task 'READER-P1-A' `
  -Status 'COMMITTED_DEVICE_VERIFIED' `
  -Summary 'Windows anchor restore 검증과 후속 커밋 완료' `
  -NextAction 'AUDIT_GIT_STATE_TASK_INDEX' `
  -Tests 'pagination 44, escape 8, android 10 passed' `
  -AgentRole 'LOCAL_COORDINATOR' `
  -Source 'cursor-cli' `
  -Scope 'local_phase'
```

Cursor GUI의 자동 완료 알림은 사용자 전역 `stop` Hook이 소유합니다.
자세한 설치·모드는 [`CURSOR_INTEGRATION.md`](CURSOR_INTEGRATION.md)를 봅니다.

## 작업 중 사용자 메시지

완료 상태가 아니라 작업 도중 사용자의 확인·입력·주의가 필요할 때는 `notify`를 사용합니다. `notify`는 로컬 inbox를 거치지 않고 공용 Notification Relay API를 호출합니다.

```powershell
notify '지금 5초 내로 실기기에서 Pair 버튼을 눌러 주세요.' -Agent ChatGPT
```

- 에이전트가 쓴 `Message` 본문을 최우선으로 그대로 표시하고 줄바꿈도 보존합니다.
- 기본 제목/상태 아이콘을 자동으로 앞에 붙이지 않습니다. `-Title`은 사람이 읽을 제목이 실제로 필요할 때만 사용합니다.
- `Project`, `Agent`는 provider가 표시용 metadata로 사용할 수 있습니다.
- 에이전트는 가능하면 `ChatGPT`, `Cursor`처럼 자신을 식별해 전달합니다.
- `Project`를 생략하면 현재 Git 저장소 이름을 자동 감지합니다.
- `Severity`는 `info | warning | error` metadata로 전달합니다.
- 메신저별 mention·formatting은 Relay의 Provider Adapter 책임이며 Agent 계약에 포함하지 않습니다.
- 알림 전달 실패는 현재 Agent 작업의 성공/실패를 바꾸지 않습니다.

## 필수 규칙

- `ai-task-complete` 호출 후에는 현재 dispatch의 코드·테스트·문서·Git 결과를 다시 변경하지 않습니다. `notify`는 작업 중 전달용이므로 이 종료 규칙의 대상이 아닙니다.
- 별도의 다음 dispatch 또는 다음 TASK 진행은 허용합니다.
- 명령 부재, non-zero, timeout, Notifier 비활성은 원래 작업 상태를 바꾸지 않습니다.
- Secret, 사용자 데이터, 전체 로그, diff 원문, 로컬 절대경로를 전달하지 않습니다.
- Orca wrapper가 `worker_process` 알림을 담당하는 실행에서는 worker가 직접 호출하지 않습니다.
- `workflowStatus`는 기존 워크플로 상태 문자열을 그대로 사용합니다.
- `APPROVED`, `DATA_SAFE`, `PRODUCTION_READY`를 로컬 agent가 임의로 만들지 않습니다.
