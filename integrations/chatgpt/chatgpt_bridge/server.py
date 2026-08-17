from __future__ import annotations

import base64
import hashlib
import json
import struct
import urllib.parse
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from .common import (
    EXTENSION_CLIENTS,
    EXTENSION_ORIGIN_RE,
    FLOWDUCK_CLIENT,
    FOCUS_SOCKET_PROTOCOL,
    MAX_BODY_BYTES,
    canonical_chatgpt_url,
    limit_text,
)
from .models import WebSocketPeer
from .state import BridgeState


class BridgeHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, address: tuple[str, int], state: BridgeState) -> None:
        super().__init__(address, BridgeHandler)
        self.state = state


class BridgeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "AIWorkerNotifierChatGPTBridge/1"

    @property
    def state(self) -> BridgeState:
        return self.server.state  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args: Any) -> None:
        return

    def _send(
        self,
        status: int,
        body: bytes = b"",
        content_type: str = "text/plain; charset=utf-8",
        headers: dict[str, str] | None = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if body:
            self.wfile.write(body)
        self.close_connection = True

    def _json(self, status: int, payload: Any) -> None:
        body = json.dumps(
            payload,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        self._send(status, body, "application/json; charset=utf-8")

    def _read_body(self) -> bytes:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise ValueError("invalid Content-Length") from exc
        if length < 0 or length > MAX_BODY_BYTES:
            raise ValueError("request body too large")
        return self.rfile.read(length) if length else b""

    def _read_json(self) -> dict[str, Any]:
        try:
            value = json.loads(self._read_body().decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValueError("invalid JSON body") from exc
        if not isinstance(value, dict):
            raise ValueError("JSON body must be an object")
        return value

    def do_GET(self) -> None:
        try:
            parsed = urllib.parse.urlsplit(self.path)
            if parsed.path == "/api/extension/socket":
                self._handle_websocket(parsed)
            elif parsed.path in {"/", "/manage"}:
                self._send(
                    200,
                    self.state.management_html().encode("utf-8"),
                    "text/html; charset=utf-8",
                )
            elif parsed.path == "/api/bridge/status":
                self._json(200, self.state.status_payload())
            else:
                self._send(404)
        except Exception as exc:
            self.state.logger.warning("GET %s failed: %s", self.path, exc)
            try:
                self._send(500)
            except OSError:
                pass

    def do_POST(self) -> None:
        try:
            path = urllib.parse.urlsplit(self.path).path
            if path == "/manage/select":
                self._handle_manage_select()
                return

            marker = self.headers.get("X-AIWorkerNotifier-Client", "")
            if marker == FLOWDUCK_CLIENT:
                self._handle_flowduck(path)
            elif marker in EXTENSION_CLIENTS:
                self._handle_extension(path)
            else:
                self._send(403)
        except ValueError as exc:
            self.state.logger.warning("POST %s rejected: %s", self.path, exc)
            self._send(400)
        except Exception as exc:
            self.state.logger.exception("POST %s failed: %s", self.path, exc)
            self._send(500)

    def _handle_manage_select(self) -> None:
        form = urllib.parse.parse_qs(
            self._read_body().decode("utf-8", errors="replace"),
            keep_blank_values=True,
        )
        enabled = set(form.get("tabId", []))
        with self.state.lock:
            self.state.disabled_tabs = {
                tab_id for tab_id in self.state.tabs if tab_id not in enabled
            }
            self.state.save_disabled_tabs()
        self._send(303, headers={"Location": "/"})

    def _handle_flowduck(self, path: str) -> None:
        if path == "/api/tabs/focus":
            data = self._read_json()
            raw_tab_id = limit_text(data.get("tabId"), 100)
            raw_url = limit_text(data.get("url"), 2048)
            canonical = canonical_chatgpt_url(raw_url)
            open_if_missing = data.get("openIfMissing") is True
            with self.state.lock:
                peer = self.state.focus_socket
                socket_ready = bool(peer and not peer.closed)

            self.state.add_debug(
                f"focus request tab={raw_tab_id} raw={raw_url} "
                f"canonical={canonical} openIfMissing={open_if_missing} "
                f"socket={socket_ready}"
            )
            if not canonical:
                self.state.add_debug(
                    f"focus rejected INVALID_TARGET_URL raw={raw_url}"
                )
                self._json(
                    400,
                    {
                        "code": "INVALID_TARGET_URL",
                        "message": "FlowDuck이 전달한 현재 GPT 세션 URL을 ChatGPT URL로 해석하지 못했습니다.",
                    },
                )
                return

            status = self.state.queue_focus(
                raw_tab_id,
                canonical,
                open_if_missing,
            )
            if status is None:
                self.state.add_debug(
                    f"focus rejected TAB_NOT_FOUND target={canonical} "
                    f"openIfMissing={open_if_missing}"
                )
                self._json(
                    404,
                    {
                        "code": "TAB_NOT_FOUND",
                        "message": "Matching Chrome tab was not found and tab creation was not requested.",
                    },
                )
                return

            self.state.add_debug(
                f"focus queued request={status.request_id} "
                f"preferred={status.tab_id} target={status.target_url} "
                f"openIfMissing={status.open_if_missing}"
            )
            if status.open_if_missing:
                pushed = self.state.push_focus(status)
                self.state.add_debug(
                    f"focus push request={status.request_id} pushed={pushed}"
                )
                if not pushed:
                    status.status = "failed"
                    status.error = (
                        "Chrome extension browser-control channel is unavailable."
                    )
                    self._json(
                        503,
                        {
                            "code": "EXTENSION_CHANNEL_UNAVAILABLE",
                            "message": "Chrome 확장 제어 채널이 연결되지 않았습니다. AIWorkerNotifier ChatGPT Watcher 0.1.15를 새로고침한 뒤 다시 시도하세요.",
                        },
                    )
                    return

            self._json(
                202,
                {
                    "requestId": status.request_id,
                    "tabId": status.tab_id,
                    "targetUrl": status.target_url,
                    "openIfMissing": status.open_if_missing,
                    "status": status.status,
                },
            )
            return

        if path == "/api/tabs/focus-status":
            self.state.expire_focus_requests()
            request_id = limit_text(self._read_json().get("requestId"), 100)
            with self.state.lock:
                status = self.state.focus_status_by_id.get(request_id)
            if status is None:
                self._json(404, {"code": "FOCUS_REQUEST_NOT_FOUND"})
            else:
                self._json(
                    200,
                    {
                        "requestId": status.request_id,
                        "tabId": status.tab_id,
                        "status": status.status,
                        "error": status.error,
                    },
                )
            return

        self._send(404)

    def _handle_extension(self, path: str) -> None:
        if path == "/api/tabs/snapshot":
            data = self._read_json()
            self.state.apply_snapshot(data.get("tabs"))
            pending = self.state.pending_open_focus()
            if pending is None:
                self._send(204)
            else:
                self._json(200, self.state.focus_action(pending))
            return

        if path == "/api/tabs/remove":
            self.state.remove_tab(
                str(self._read_json().get("tabId") or "")
            )
            self._send(204)
            return

        if path == "/api/tabs/heartbeat":
            self.state.expire_focus_requests()
            data = self._read_json()
            tab_id = limit_text(data.get("tabId"), 100)
            url = limit_text(data.get("url"), 2048)
            if not tab_id or not canonical_chatgpt_url(url):
                self._send(400)
                return
            self.state.upsert_tab(
                tab_id,
                str(data.get("title") or ""),
                url,
                window_id=(
                    data.get("windowId")
                    if isinstance(data.get("windowId"), int)
                    else None
                ),
                generating=bool(data.get("generating")),
            )
            with self.state.lock:
                focus_id = self.state.focus_requests_by_tab.get(tab_id, "")
                selected = tab_id not in self.state.disabled_tabs
            self._json(
                200,
                {
                    "selected": selected,
                    "focusRequestId": focus_id,
                },
            )
            return

        if path == "/api/tabs/focus-ack":
            data = self._read_json()
            self.state.add_debug(
                "focus ACK received request={0} tab={1} url={2} success={3} "
                "opened={4} error={5}".format(
                    data.get("requestId") or "",
                    data.get("tabId") or "",
                    data.get("url") or "",
                    data.get("success") is True,
                    data.get("opened") is True,
                    data.get("error") or "",
                )
            )
            accepted = self.state.complete_focus(
                str(data.get("requestId") or ""),
                str(data.get("tabId") or ""),
                str(data.get("url") or ""),
                data.get("success") is True,
                str(data.get("error") or ""),
            )
            self._send(204 if accepted else 404)
            return

        if path == "/api/tabs/completed":
            data = self._read_json()
            tab_id = limit_text(data.get("tabId"), 100)
            tab = self.state.upsert_tab(
                tab_id,
                str(data.get("title") or ""),
                str(data.get("url") or ""),
                window_id=(
                    data.get("windowId")
                    if isinstance(data.get("windowId"), int)
                    else None
                ),
            )
            with self.state.lock:
                disabled = tab_id in self.state.disabled_tabs
            if tab is None or disabled:
                self._send(204)
                return
            self.state.write_completion_journal(tab, data)
            self.state.queue_notification(
                tab,
                limit_text(data.get("turnId"), 80),
            )
            self._send(204)
            self.state.logger.info(
                "[%s] 활성 탭 완료 알림 큐 등록: %s",
                datetime.now().strftime("%H:%M:%S"),
                tab.title,
            )
            return

        self._send(404)

    def _handle_websocket(
        self,
        parsed: urllib.parse.SplitResult,
    ) -> None:
        version = limit_text(
            (urllib.parse.parse_qs(parsed.query).get("version") or [""])[0],
            40,
        )
        key = self.headers.get("Sec-WebSocket-Key", "").strip()
        origin = self.headers.get("Origin", "").strip()
        protocols = [
            item.strip()
            for item in self.headers.get(
                "Sec-WebSocket-Protocol",
                "",
            ).split(",")
        ]
        if (
            not version
            or self.headers.get("Upgrade", "").lower() != "websocket"
            or not key
            or not EXTENSION_ORIGIN_RE.fullmatch(origin)
            or FOCUS_SOCKET_PROTOCOL not in protocols
        ):
            self._send(400)
            return

        accept_source = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        accept_value = base64.b64encode(
            hashlib.sha1(accept_source.encode("ascii")).digest()
        ).decode("ascii")
        self.send_response_only(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept_value)
        self.send_header(
            "Sec-WebSocket-Protocol",
            FOCUS_SOCKET_PROTOCOL,
        )
        self.end_headers()
        self.wfile.flush()
        self.close_connection = False

        peer = WebSocketPeer(self.connection, version)
        self.state.register_socket(peer)
        try:
            self.connection.settimeout(None)
            while not peer.closed and not self.state.stop_event.is_set():
                frame = self._read_ws_frame()
                if frame is None:
                    break
                opcode, payload = frame
                if opcode == 0x8:
                    break
                if opcode == 0x9:
                    peer.send_pong(payload)
        except OSError:
            pass
        finally:
            self.state.clear_socket(peer)

    def _read_ws_frame(self) -> tuple[int, bytes] | None:
        first = self.rfile.read(2)
        if len(first) < 2:
            return None
        opcode = first[0] & 0x0F
        masked = bool(first[1] & 0x80)
        length = first[1] & 0x7F
        if length == 126:
            raw = self.rfile.read(2)
            if len(raw) != 2:
                return None
            length = struct.unpack("!H", raw)[0]
        elif length == 127:
            raw = self.rfile.read(8)
            if len(raw) != 8:
                return None
            length = struct.unpack("!Q", raw)[0]
        if length > MAX_BODY_BYTES:
            return None
        mask = self.rfile.read(4) if masked else b""
        payload = self.rfile.read(length) if length else b""
        if len(payload) != length:
            return None
        if masked and len(mask) == 4:
            payload = bytes(
                value ^ mask[index % 4]
                for index, value in enumerate(payload)
            )
        return opcode, payload
