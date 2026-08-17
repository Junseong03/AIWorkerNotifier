from __future__ import annotations

import socket
import struct
import threading
import time
from dataclasses import dataclass


@dataclass
class TabRecord:
    tab_id: str
    window_id: int | None
    title: str
    url: str
    generating: bool = False
    last_seen: float = 0.0


@dataclass
class FocusStatus:
    request_id: str
    tab_id: str
    target_url: str
    open_if_missing: bool
    status: str = "pending"
    error: str = ""
    created_at: float = 0.0


class WebSocketPeer:
    def __init__(self, sock: socket.socket, version: str) -> None:
        self.sock = sock
        self.version = version
        self.send_lock = threading.Lock()
        self.closed = False
        self.last_write = time.monotonic()

    def send_text(self, text: str) -> bool:
        payload = text.encode("utf-8")
        if len(payload) > 65535:
            raise ValueError("WebSocket payload too large")
        if len(payload) <= 125:
            header = bytes((0x81, len(payload)))
        else:
            header = bytes((0x81, 126)) + struct.pack("!H", len(payload))
        try:
            with self.send_lock:
                if self.closed:
                    return False
                self.sock.sendall(header + payload)
                self.last_write = time.monotonic()
            return True
        except OSError:
            self.close()
            return False

    def send_pong(self, payload: bytes) -> None:
        if len(payload) > 125:
            return
        try:
            with self.send_lock:
                if not self.closed:
                    self.sock.sendall(bytes((0x8A, len(payload))) + payload)
        except OSError:
            self.close()

    def close(self) -> None:
        with self.send_lock:
            if self.closed:
                return
            self.closed = True
            try:
                self.sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                self.sock.close()
            except OSError:
                pass
