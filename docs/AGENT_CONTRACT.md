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
## 필수 규칙

- 알림 호출 후 현재 dispatch의 코드·테스트·문서·Git 결과를 다시 변경하지 않습니다.
- 별도의 다음 dispatch 또는 다음 TASK 진행은 허용합니다.
- 명령 부재, non-zero, timeout, Notifier 비활성은 원래 작업 상태를 바꾸지 않습니다.
- Secret, 사용자 데이터, 전체 로그, diff 원문, 로컬 절대경로를 전달하지 않습니다.
- Orca wrapper가 `worker_process` 알림을 담당하는 실행에서는 worker가 직접 호출하지 않습니다.
- `workflowStatus`는 기존 워크플로 상태 문자열을 그대로 사용합니다.
- `APPROVED`, `DATA_SAFE`, `PRODUCTION_READY`를 로컬 agent가 임의로 만들지 않습니다.
