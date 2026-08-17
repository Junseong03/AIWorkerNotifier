from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
import urllib.request
from pathlib import Path
from typing import Any

from .common import (
    FOCUS_KEEPALIVE_SECONDS,
    STATUS_SCHEMA,
    canonical_chatgpt_url,
    utc_iso,
)
from .server import BridgeHTTPServer
from .state import BridgeState


def keepalive_loop(state: BridgeState) -> None:
    while not state.stop_event.wait(2.0):
        state.expire_focus_requests()
        with state.lock:
            peer = state.focus_socket
        if (
            peer
            and not peer.closed
            and time.monotonic() - peer.last_write >= FOCUS_KEEPALIVE_SECONDS
        ):
            payload = json.dumps(
                {"type": "keepalive", "sentAtUtc": utc_iso()},
                separators=(",", ":"),
            )
            if not peer.send_text(payload):
                state.clear_socket(peer)


def probe_existing_bridge(port: int) -> dict[str, Any] | None:
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/api/bridge/status",
            timeout=0.8,
        ) as response:
            payload = (
                json.loads(response.read().decode("utf-8"))
                if response.status == 200
                else None
            )
    except Exception:
        return None
    if (
        isinstance(payload, dict)
        and payload.get("schema") == STATUS_SCHEMA
        and payload.get("service") == "ai-worker-notifier-chatgpt-bridge"
        and payload.get("implementation") == "python"
    ):
        return payload
    return None


def self_test() -> int:
    assert canonical_chatgpt_url(
        "https://www.chatgpt.com/c/abc/?x=1#y"
    ) == "https://chatgpt.com/c/abc"
    assert canonical_chatgpt_url(
        "https://chat.openai.com/c/abc"
    ) == "https://chatgpt.com/c/abc"
    assert canonical_chatgpt_url("http://chatgpt.com/c/abc") == ""
    assert canonical_chatgpt_url("https://example.com/c/abc") == ""
    print("PASS: Python ChatGPT bridge self-test")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="AIWorkerNotifier ChatGPT localhost bridge"
    )
    parser.add_argument("--port", type=int, default=43127)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    if sys.version_info < (3, 10):
        print("ChatGPT bridge requires Python 3.10+.", file=sys.stderr)
        return 2
    if not 1024 <= args.port <= 65535:
        print("Port must be between 1024 and 65535.", file=sys.stderr)
        return 2

    repo_root = Path(__file__).resolve().parents[3]
    state = BridgeState(repo_root, args.port)
    state.logger.info(
        "ChatGPT tab manager: http://127.0.0.1:%s/",
        args.port,
    )
    state.logger.info(
        "Bridge implementation: Python %s · PID %s",
        sys.version.split()[0],
        os.getpid(),
    )
    state.logger.info(
        "Browser focus/open uses the Chrome extension WebSocket push channel."
    )
    state.logger.info(
        "Prompt and response bodies are not collected. Stop: Ctrl+C"
    )

    try:
        server = BridgeHTTPServer(("127.0.0.1", args.port), state)
    except OSError as exc:
        existing = probe_existing_bridge(args.port)
        if existing:
            print(
                "ChatGPT bridge already running: "
                f"PID {existing.get('pid')} · "
                f"{existing.get('implementation')} · port {args.port}"
            )
            return 0
        print(
            f"ChatGPT bridge could not bind 127.0.0.1:{args.port}: {exc}",
            file=sys.stderr,
        )
        return 3

    threading.Thread(
        target=keepalive_loop,
        args=(state,),
        daemon=True,
        name="chatgpt-bridge-keepalive",
    ).start()
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        state.stop_event.set()
        with state.lock:
            peer = state.focus_socket
        if peer:
            state.clear_socket(peer)
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
