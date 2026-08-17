from __future__ import annotations

import re
import urllib.parse
from datetime import datetime, timezone
from typing import Any

BRIDGE_VERSION = "python-v1"
STATUS_SCHEMA = "ai-worker-notifier/chatgpt-bridge-status/v1"
EVENT_SCHEMA = "ai-worker-notifier/chatgpt-completion/v1"
FOCUS_SOCKET_PROTOCOL = "ai-worker-notifier-chatgpt-v1"
FLOWDUCK_CLIENT = "flowduck-adapter"
EXTENSION_CLIENTS = {"chatgpt-userscript", "chatgpt-extension"}
ALLOWED_HOSTS = {"chatgpt.com", "www.chatgpt.com", "chat.openai.com"}
EXTENSION_ORIGIN_RE = re.compile(r"^chrome-extension://[a-p]{32}$")
CHROME_TAB_RE = re.compile(r"^chrome-\d+$")
COMPLETION_JOURNAL_LIMIT = 500
FOCUS_REQUEST_TTL_SECONDS = 15.0
FOCUS_KEEPALIVE_SECONDS = 20.0
FOCUS_DEBUG_LIMIT = 40
LEGACY_TAB_TTL_SECONDS = 30.0
MAX_BODY_BYTES = 65536


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def utc_iso() -> str:
    return utc_now().isoformat().replace("+00:00", "Z")


def limit_text(value: Any, max_length: int) -> str:
    if value is None:
        return ""
    clean = re.sub(r"[\r\n\t]+", " ", str(value)).strip()
    return clean[:max_length]


def canonical_chatgpt_url(raw: str) -> str:
    value = (raw or "").strip()
    if not value:
        return ""
    try:
        parsed = urllib.parse.urlsplit(value)
    except ValueError:
        return ""
    host = (parsed.hostname or "").lower()
    if parsed.scheme.lower() != "https" or host not in ALLOWED_HOSTS:
        return ""
    if parsed.username is not None or parsed.password is not None or parsed.port is not None:
        return ""
    if host in {"www.chatgpt.com", "chat.openai.com"}:
        host = "chatgpt.com"
    path = parsed.path or "/"
    if path != "/":
        path = path.rstrip("/") or "/"
    return urllib.parse.urlunsplit(("https", host, path, "", ""))
