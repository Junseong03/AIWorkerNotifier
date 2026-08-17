from __future__ import annotations

import hashlib
import html
import json
import os
import subprocess
import time
from typing import Any

from .common import (
    BRIDGE_VERSION,
    COMPLETION_JOURNAL_LIMIT,
    EVENT_SCHEMA,
    STATUS_SCHEMA,
    limit_text,
    utc_iso,
)
from .models import TabRecord


class PersistenceMixin:
    def write_completion_journal(
        self,
        tab: TabRecord,
        data: dict[str, Any],
    ) -> None:
        turn_id = limit_text(data.get("turnId"), 80)
        detected_at = limit_text(data.get("detectedAtUtc"), 80) or utc_iso()
        event_id = f"{tab.tab_id}:{turn_id or detected_at}"
        event = {
            "schema": EVENT_SCHEMA,
            "eventId": event_id,
            "tabId": tab.tab_id,
            "windowId": tab.window_id,
            "title": limit_text(tab.title, 200),
            "url": limit_text(tab.url, 2048),
            "turnId": turn_id,
            "detectedAtUtc": detected_at,
            "detectionMode": limit_text(data.get("detectionMode"), 80),
        }
        filename = hashlib.sha256(event_id.encode("utf-8")).hexdigest() + ".json"
        final_path = self.completion_journal_root / filename
        if final_path.exists():
            return

        temp_path = final_path.with_name(
            final_path.name + f".tmp-{os.getpid()}-{time.time_ns()}"
        )
        try:
            temp_path.write_text(
                json.dumps(event, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
            os.replace(temp_path, final_path)
        finally:
            try:
                temp_path.unlink(missing_ok=True)
            except OSError:
                pass

        files = sorted(
            self.completion_journal_root.glob("*.json"),
            key=lambda path: path.stat().st_mtime_ns,
            reverse=True,
        )
        for old in files[COMPLETION_JOURNAL_LIMIT:]:
            try:
                old.unlink()
            except OSError:
                pass

    def queue_notification(self, tab: TabRecord, turn_id: str) -> None:
        if not self.ai_task_complete.is_file():
            self.logger.warning(
                "ai-task-complete entrypoint missing: %s",
                self.ai_task_complete,
            )
            return

        dispatch_id = f"{tab.tab_id}:{turn_id}" if turn_id else tab.tab_id
        command = [
            "powershell.exe",
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(self.ai_task_complete),
            "-Task",
            limit_text(tab.title, 160),
            "-Status",
            "RESPONSE_COMPLETE",
            "-Summary",
            "선택한 ChatGPT 탭의 응답 생성이 완료되었습니다.",
            "-NextAction",
            "REVIEW_RESPONSE",
            "-AgentRole",
            "ChatGPT Classic",
            "-Source",
            "chatgpt-web-dom",
            "-Scope",
            "local_phase",
            "-Outcome",
            "success",
            "-Project",
            "ChatGPT",
            "-DispatchId",
            dispatch_id,
        ]
        try:
            result = subprocess.run(
                command,
                cwd=str(self.repo_root),
                timeout=15,
                check=False,
            )
            if result.returncode != 0:
                self.logger.warning(
                    "ai-task-complete returned exit=%s",
                    result.returncode,
                )
        except (OSError, subprocess.TimeoutExpired) as exc:
            self.logger.warning("ai-task-complete failed: %s", exc)

    def management_html(self) -> str:
        self.remove_stale()
        with self.lock:
            tabs = sorted(
                self.tabs.values(),
                key=lambda tab: (tab.title.lower(), tab.url.lower()),
            )
            disabled = set(self.disabled_tabs)
            peer = self.focus_socket
            debug = list(self.focus_debug)

        rows: list[str] = []
        for tab in tabs:
            checked = " checked" if tab.tab_id not in disabled else ""
            state = "응답 생성 중" if tab.generating else "대기 중"
            rows.append(
                '<label class="tab-row">'
                f'<input type="checkbox" name="tabId" value="{html.escape(tab.tab_id)}"{checked}>'
                '<span class="tab-main">'
                f'<strong>{html.escape(tab.title)}</strong>'
                f'<small>{html.escape(tab.url)}</small>'
                '</span>'
                f'<span class="state">{html.escape(state)}</span>'
                f'<code>{html.escape(tab.tab_id[:12])}</code>'
                '</label>'
            )

        list_html = "\n".join(rows)
        if not list_html:
            list_html = (
                '<p class="empty">현재 감지된 ChatGPT 탭이 없습니다. '
                'Chrome 확장 프로그램이 설치·활성화되어 있는지 확인하세요.</p>'
            )
        socket_state = (
            f"연결됨 (extension {peer.version})"
            if peer and not peer.closed
            else "연결 안 됨"
        )
        debug_text = (
            "\n".join(debug)
            if debug
            else "아직 browser-control 요청이 없습니다."
        )

        return f'''<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="5">
<title>AIWorkerNotifier - ChatGPT 탭</title>
<style>
body{{font-family:Segoe UI,Malgun Gothic,sans-serif;max-width:980px;margin:40px auto;padding:0 20px;color:#202124;background:#f7f8fa}}
h1{{margin-bottom:8px}}.hint{{color:#5f6368;margin-top:0}}.panel{{background:white;border:1px solid #dadce0;border-radius:12px;padding:18px}}
.tab-row{{display:grid;grid-template-columns:28px 1fr 110px 110px;gap:12px;align-items:center;padding:14px 8px;border-bottom:1px solid #eee}}
.tab-row:last-child{{border-bottom:0}}.tab-main{{min-width:0}}.tab-main strong,.tab-main small{{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}
.tab-main small{{color:#70757a;margin-top:4px}}.state{{font-size:13px;color:#5f6368}}.actions{{margin-top:18px;display:flex;gap:10px;align-items:center}}
button{{border:0;border-radius:8px;padding:10px 16px;font-weight:600;cursor:pointer}}button.primary{{background:#1a73e8;color:white}}
.empty{{color:#70757a;padding:12px}}.privacy{{font-size:13px;color:#70757a;margin-top:18px}}code{{font-size:12px}}.diag{{margin-top:18px}}
.diag pre{{white-space:pre-wrap;word-break:break-all;background:#111827;color:#e5e7eb;border-radius:8px;padding:12px;max-height:320px;overflow:auto;font:12px/1.5 Consolas,monospace}}
</style>
</head>
<body>
<h1>ChatGPT 탭 감시</h1>
<p class="hint">새로 감지된 ChatGPT 탭은 기본적으로 알림 ON입니다. 알림을 받지 않을 탭만 체크 해제하세요. 목록은 약 5초마다 갱신됩니다.</p>
<p class="hint">Bridge: Python · PID {os.getpid()} · 브라우저 제어 채널: {html.escape(socket_state)}</p>
<form method="POST" action="/manage/select" class="panel">
{list_html}
<div class="actions"><button class="primary" type="submit">선택 저장</button><span>체크 해제한 탭의 완료 이벤트만 무시됩니다.</span></div>
</form>
<section class="panel diag"><strong>최근 browser-control 진단</strong><pre>{html.escape(debug_text)}</pre></section>
<p class="privacy">탭 목록은 Chrome의 탭 이벤트와 snapshot으로 유지합니다. 응답 본문과 입력 프롬프트는 읽지 않습니다.</p>
</body>
</html>'''

    def status_payload(self) -> dict[str, Any]:
        with self.lock:
            peer = self.focus_socket
        return {
            "schema": STATUS_SCHEMA,
            "service": "ai-worker-notifier-chatgpt-bridge",
            "implementation": "python",
            "bridgeVersion": BRIDGE_VERSION,
            "pid": os.getpid(),
            "port": self.port,
            "extensionConnected": bool(peer and not peer.closed),
            "extensionVersion": (
                peer.version if peer and not peer.closed else ""
            ),
        }
