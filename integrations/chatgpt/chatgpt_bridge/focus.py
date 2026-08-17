from __future__ import annotations

import json
import time
import uuid
from typing import Any

from .common import CHROME_TAB_RE, FOCUS_REQUEST_TTL_SECONDS, canonical_chatgpt_url, limit_text
from .models import FocusStatus, TabRecord, WebSocketPeer


class FocusStateMixin:
    def expire_focus_requests(self) -> None:
        cutoff = time.monotonic() - FOCUS_REQUEST_TTL_SECONDS
        timed_out: list[FocusStatus] = []
        with self.lock:
            for status in self.focus_status_by_id.values():
                if status.status == "pending" and status.created_at < cutoff:
                    status.status = "timeout"
                    status.error = "Chrome tab focus acknowledgement timed out."
                    timed_out.append(status)
            stale_tabs = [
                tab_id
                for tab_id, request_id in self.focus_requests_by_tab.items()
                if request_id not in self.focus_status_by_id
                or self.focus_status_by_id[request_id].status != "pending"
            ]
            for tab_id in stale_tabs:
                self.focus_requests_by_tab.pop(tab_id, None)
        for status in timed_out:
            self.add_debug(f"focus timeout request={status.request_id} target={status.target_url}")

    def find_focus_tab(self, tab_id: str, canonical_url: str) -> TabRecord | None:
        with self.lock:
            candidate = self.tabs.get(limit_text(tab_id, 100))
            if candidate and canonical_chatgpt_url(candidate.url) == canonical_url:
                return candidate
            matches = [
                tab
                for tab in self.tabs.values()
                if canonical_chatgpt_url(tab.url) == canonical_url
            ]
            if not matches:
                return None
            matches.sort(key=lambda tab: tab.last_seen, reverse=True)
            return matches[0]

    def queue_focus(
        self,
        tab_id: str,
        raw_url: str,
        open_if_missing: bool,
    ) -> FocusStatus | None:
        self.expire_focus_requests()
        canonical = canonical_chatgpt_url(raw_url)
        if not canonical:
            return None
        tab = self.find_focus_tab(tab_id, canonical)
        if tab is None and not open_if_missing:
            return None
        status = FocusStatus(
            request_id=str(uuid.uuid4()),
            tab_id=tab.tab_id if tab else limit_text(tab_id, 100),
            target_url=canonical,
            open_if_missing=open_if_missing,
            created_at=time.monotonic(),
        )
        with self.lock:
            self.focus_status_by_id[status.request_id] = status
            if not open_if_missing and tab is not None:
                self.focus_requests_by_tab[tab.tab_id] = status.request_id
        return status

    def pending_open_focus(self) -> FocusStatus | None:
        self.expire_focus_requests()
        with self.lock:
            pending = [
                status
                for status in self.focus_status_by_id.values()
                if status.status == "pending" and status.open_if_missing
            ]
            return min(pending, key=lambda item: item.created_at) if pending else None

    @staticmethod
    def focus_action(status: FocusStatus) -> dict[str, Any]:
        return {
            "type": "focus-or-open",
            "focusRequestId": status.request_id,
            "preferredTabId": status.tab_id,
            "targetUrl": status.target_url,
            "openIfMissing": status.open_if_missing,
        }

    def push_focus(self, status: FocusStatus) -> bool:
        with self.lock:
            peer = self.focus_socket
        if peer is None or peer.closed:
            self.add_debug("socket push skipped: extension channel is not connected")
            return False
        payload = json.dumps(
            self.focus_action(status),
            ensure_ascii=False,
            separators=(",", ":"),
        )
        if peer.send_text(payload):
            return True
        with self.lock:
            if self.focus_socket is peer:
                self.focus_socket = None
        return False

    def complete_focus(
        self,
        request_id: str,
        tab_id: str,
        url: str,
        success: bool,
        error: str,
    ) -> bool:
        request_id = limit_text(request_id, 100)
        tab_id = limit_text(tab_id, 100)
        ack_url = canonical_chatgpt_url(url)
        with self.lock:
            status = self.focus_status_by_id.get(request_id)
            if status is None:
                reason = f"focus ACK rejected unknown request={request_id}"
            elif status.status != "pending":
                reason = f"focus ACK rejected request={request_id} status={status.status}"
            elif status.open_if_missing and ack_url != status.target_url:
                reason = (
                    f"focus ACK rejected request={request_id} url-mismatch "
                    f"expected={status.target_url} actual={ack_url}"
                )
            elif status.open_if_missing and success and not CHROME_TAB_RE.fullmatch(tab_id):
                reason = f"focus ACK rejected request={request_id} invalid-tab={tab_id}"
            elif not status.open_if_missing and status.tab_id != tab_id:
                reason = (
                    f"focus ACK rejected request={request_id} tab-mismatch "
                    f"expected={status.tab_id} actual={tab_id}"
                )
            else:
                if success and status.open_if_missing:
                    status.tab_id = tab_id
                status.status = "focused" if success else "failed"
                status.error = "" if success else limit_text(error, 300)
                for key in [
                    key
                    for key, value in self.focus_requests_by_tab.items()
                    if value == request_id
                ]:
                    self.focus_requests_by_tab.pop(key, None)
                reason = ""
        if reason:
            self.add_debug(reason)
            return False
        self.add_debug(
            f"focus ACK accepted request={request_id} success={success} "
            f"tab={tab_id} target={status.target_url} error={status.error}"
        )
        return True

    def register_socket(self, peer: WebSocketPeer) -> None:
        with self.lock:
            old = self.focus_socket
            self.focus_socket = peer
        if old is not None and old is not peer:
            old.close()
        self.add_debug(
            f"Chrome extension browser-control channel connected: {peer.version}"
        )
        pending = self.pending_open_focus()
        if pending is not None:
            self.push_focus(pending)

    def clear_socket(self, peer: WebSocketPeer) -> None:
        with self.lock:
            if self.focus_socket is peer:
                self.focus_socket = None
        peer.close()
