from __future__ import annotations

import base64
import json
import os
import socket
import struct
import tempfile
import threading
import urllib.request
from pathlib import Path

from .common import FOCUS_SOCKET_PROTOCOL, canonical_chatgpt_url
from .server import BridgeHTTPServer
from .state import BridgeState


def _post_json(
    url: str,
    payload: dict[str, object],
    marker: str,
) -> tuple[int, dict[str, object] | None]:
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        method="POST",
        headers={
            "Content-Type": "application/json",
            "X-AIWorkerNotifier-Client": marker,
        },
    )
    with urllib.request.urlopen(request, timeout=2.0) as response:
        raw = response.read()
        decoded = json.loads(raw.decode("utf-8")) if raw else None
        return response.status, decoded


def _read_server_text_frame(sock: socket.socket) -> dict[str, object]:
    header = sock.recv(2)
    if len(header) != 2:
        raise AssertionError("WebSocket frame header was not received")
    length = header[1] & 0x7F
    if length == 126:
        raw = sock.recv(2)
        if len(raw) != 2:
            raise AssertionError("WebSocket extended length was not received")
        length = struct.unpack("!H", raw)[0]
    elif length == 127:
        raw = sock.recv(8)
        if len(raw) != 8:
            raise AssertionError("WebSocket extended length was not received")
        length = struct.unpack("!Q", raw)[0]
    payload = b""
    while len(payload) < length:
        chunk = sock.recv(length - len(payload))
        if not chunk:
            raise AssertionError("WebSocket payload was truncated")
        payload += chunk
    decoded = json.loads(payload.decode("utf-8"))
    if not isinstance(decoded, dict):
        raise AssertionError("WebSocket payload must be an object")
    return decoded


def run_self_test() -> int:
    assert canonical_chatgpt_url(
        "https://www.chatgpt.com/c/abc/?x=1#y"
    ) == "https://chatgpt.com/c/abc"
    assert canonical_chatgpt_url(
        "https://chat.openai.com/c/abc"
    ) == "https://chatgpt.com/c/abc"
    assert canonical_chatgpt_url("http://chatgpt.com/c/abc") == ""
    assert canonical_chatgpt_url("https://example.com/c/abc") == ""

    previous_local_app_data = os.environ.get("LOCALAPPDATA")
    with tempfile.TemporaryDirectory() as temp:
        os.environ["LOCALAPPDATA"] = temp
        repo_root = Path(temp) / "repo"
        (repo_root / "bin").mkdir(parents=True)
        state = BridgeState(repo_root, 0)
        server = BridgeHTTPServer(("127.0.0.1", 0), state)
        port = int(server.server_address[1])
        state.port = port
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        sock: socket.socket | None = None
        try:
            key = base64.b64encode(os.urandom(16)).decode("ascii")
            sock = socket.create_connection(("127.0.0.1", port), timeout=2.0)
            request = (
                f"GET /api/extension/socket?version=0.1.15 HTTP/1.1\r\n"
                f"Host: 127.0.0.1:{port}\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\n"
                "Sec-WebSocket-Version: 13\r\n"
                f"Sec-WebSocket-Protocol: {FOCUS_SOCKET_PROTOCOL}\r\n"
                "Origin: chrome-extension://abcdefghijklmnopabcdefghijklmnop\r\n"
                "\r\n"
            )
            sock.sendall(request.encode("ascii"))
            handshake = sock.recv(4096)
            assert b"101 Switching Protocols" in handshake

            status_code, focus = _post_json(
                f"http://127.0.0.1:{port}/api/tabs/focus",
                {
                    "tabId": "",
                    "url": "https://chatgpt.com/c/self-test",
                    "openIfMissing": True,
                },
                "flowduck-adapter",
            )
            assert status_code == 202
            assert focus is not None
            action = _read_server_text_frame(sock)
            assert action.get("type") == "focus-or-open"
            assert action.get("openIfMissing") is True
            assert action.get("targetUrl") == "https://chatgpt.com/c/self-test"
            request_id = str(focus.get("requestId") or "")
            assert request_id

            ack_status, _ = _post_json(
                f"http://127.0.0.1:{port}/api/tabs/focus-ack",
                {
                    "requestId": request_id,
                    "tabId": "chrome-99",
                    "url": "https://chatgpt.com/c/self-test",
                    "success": True,
                    "opened": True,
                    "error": "",
                },
                "chatgpt-extension",
            )
            assert ack_status == 204

            poll_status, focus_state = _post_json(
                f"http://127.0.0.1:{port}/api/tabs/focus-status",
                {"requestId": request_id},
                "flowduck-adapter",
            )
            assert poll_status == 200
            assert focus_state is not None
            assert focus_state.get("status") == "focused"

            with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/api/bridge/status",
                timeout=2.0,
            ) as response:
                identity = json.loads(response.read().decode("utf-8"))
            assert identity.get("implementation") == "python"
            assert identity.get("extensionConnected") is True
        finally:
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass
            server.shutdown()
            server.server_close()
            state.stop_event.set()
            for handler in list(state.logger.handlers):
                handler.close()
                state.logger.removeHandler(handler)

    if previous_local_app_data is None:
        os.environ.pop("LOCALAPPDATA", None)
    else:
        os.environ["LOCALAPPDATA"] = previous_local_app_data

    print("PASS: Python ChatGPT bridge self-test")
    return 0
