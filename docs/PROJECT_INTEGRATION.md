# 프로젝트 연결 원칙

Notifier 자체를 먼저 독립적으로 검증한 뒤 프로젝트 workflow를 별도 커밋으로 수정합니다.

권장 순서:

1. Notifier 설치 및 수동 Discord 시험
2. 프로젝트의 현재 TASK/HotFix 감사 완료
3. workflow 문서에 notification 계약 추가
4. Cursor LOCAL_COORDINATOR 종료 알림 시험
5. Orca wrapper 종료 알림 시험
6. workflow-only 커밋

Epub Viewer 후보 파일:

- `ai-workflow/CONFIG.md`
- `ai-workflow/CURSOR_COORDINATOR_RULES.md`
- `ai-workflow/CODEX_RULES.md`
- `ai-workflow/COORDINATOR_HANDOFF.md`
- `ai-workflow/ORCA_INTEGRATION.md`
- `ai-workflow/scripts/run-cursor-worker.ps1`
- 운영 Runbook

`WORKFLOW_IMPROVEMENTS.md`는 기록용이며 기능 정본으로 사용하지 않습니다.

호출 소유권:

- 수동 Cursor LOCAL_COORDINATOR: 반환 직전 Cursor가 호출
- MAIN_COORDINATOR/CODEX_DIRECT: 최종 dispatch 반환 직전 담당 coordinator가 호출
- Orca one-shot worker: wrapper가 호출하고 worker 프롬프트에서는 호출 금지
