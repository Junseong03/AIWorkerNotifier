from __future__ import annotations

import hmac
import json
import re
import time
import urllib.error
import urllib.request
import uuid
from collections import OrderedDict, deque
from dataclasses import dataclass
from typing import Callable, Mapping, Optional


MAX_MESSAGE_LENGTH = 1400
MAX_TITLE_LENGTH = 120
MAX_PROJECT_LENGTH = 120
MAX_AGENT_LENGTH = 80
MAX_SOURCE_LENGTH = 80
ALLOWED_SEVERITIES = {"info", "warning", "error"}


class RelayValidationError(ValueError):
    pass


class ProviderDeliveryError(RuntimeError):
    pass


class RelayRateLimitError(RuntimeError):
    pass
_SECRET_PATTERNS = (
    re.compile(r"(?i)Authorization\s*:\s*\S+"),
    re.compile(r"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"),
    re.compile(r"(?i)(token|secret|pepper|password|private\s+key)\s*[:=]\s*\S+"),
    re.compile(r"(?i)https://[^\s/]+/api/webhooks/\S+"),
    re.compile(r"(?i)[A-Za-z]:\\[^\s]+"),
)


def _bounded_inline(value: object, limit: int) -> str:
    text = "" if value is None else str(value)
    text = re.sub(r"[\r\n\t]+", " ", text).strip()
    return _redact(text)[:limit]


def _bounded_message(value: object, limit: int = MAX_MESSAGE_LENGTH) -> str:
    text = "" if value is None else str(value)
    text = text.replace("\r\n", "\n").replace("\r", "\n").strip()
    return _redact(text)[:limit]


def _redact(text: str) -> str:
    result = text
    for pattern in _SECRET_PATTERNS:
        result = pattern.sub("[REDACTED]", result)
    return result
@dataclass(frozen=True)
class NotificationRequest:
    message: str
    title: str = ""
    project: str = ""
    agent: str = ""
    severity: str = "info"
    source: str = "agent-api"

    @classmethod
    def from_mapping(cls, payload: Mapping[str, object]) -> "NotificationRequest":
        message = _bounded_message(payload.get("message"))
        if not message:
            raise RelayValidationError("message is required")

        severity = _bounded_inline(payload.get("severity", "info"), 16).lower()
        if severity not in ALLOWED_SEVERITIES:
            raise RelayValidationError("severity must be info, warning, or error")

        return cls(
            message=message,
            title=_bounded_inline(payload.get("title"), MAX_TITLE_LENGTH),
            project=_bounded_inline(payload.get("project"), MAX_PROJECT_LENGTH),
            agent=_bounded_inline(payload.get("agent"), MAX_AGENT_LENGTH),
            severity=severity,
            source=_bounded_inline(payload.get("source", "agent-api"), MAX_SOURCE_LENGTH) or "agent-api",
        )
class SlidingWindowRateLimiter:
    def __init__(self, *, limit: int = 30, window_seconds: float = 60.0, max_keys: int = 128, clock: Callable[[], float] = time.monotonic) -> None:
        self._limit = max(1, int(limit))
        self._window_seconds = max(1.0, float(window_seconds))
        self._max_keys = max(1, int(max_keys))
        self._clock = clock
        self._events: OrderedDict[str, deque[float]] = OrderedDict()

    def allow(self, key: str) -> bool:
        now = self._clock()
        cutoff = now - self._window_seconds
        events = self._events.get(key)
        if events is None:
            while len(self._events) >= self._max_keys:
                self._events.popitem(last=False)
            events = deque()
            self._events[key] = events
        else:
            self._events.move_to_end(key)
        while events and events[0] <= cutoff:
            events.popleft()
        if len(events) >= self._limit:
            return False
        events.append(now)
        return True

    def retained_keys(self) -> int:
        return len(self._events)


class DiscordWebhookProvider:
    name = "discord"

    def __init__(
        self,
        *,
        webhook_url: str,
        role_id: str = "",
        timeout_seconds: float = 8.0,
        max_attempts: int = 2,
        opener: Callable[..., object] = urllib.request.urlopen,
        sleeper: Callable[[float], None] = time.sleep,
    ) -> None:
        self._webhook_url = webhook_url.strip()
        self._role_id = role_id.strip()
        self._timeout_seconds = max(1.0, float(timeout_seconds))
        self._max_attempts = max(1, min(int(max_attempts), 3))
        self._opener = opener
        self._sleeper = sleeper

    @property
    def configured(self) -> bool:
        return bool(self._webhook_url)

    @staticmethod
    def _message_text(notification: NotificationRequest) -> str:
        lines: list[str] = []
        if notification.title:
            lines.extend((f"**{notification.title}**", ""))
        lines.append(notification.message)
        if notification.project or notification.agent:
            lines.extend(("", "```text"))
            if notification.project:
                lines.append(f"Project: {notification.project.replace('`', chr(39))}")
            if notification.agent:
                lines.append(f"Agent: {notification.agent.replace('`', chr(39))}")
            lines.append("```")
        return "\n".join(lines)
    def build_payload(self, notification: NotificationRequest) -> dict[str, object]:
        message = self._message_text(notification)
        payload: dict[str, object] = {
            "content": message,
            "username": "AI Worker Notifier",
            "allowed_mentions": {"parse": []},
        }
        if self._role_id:
            if not re.fullmatch(r"[0-9]{5,32}", self._role_id):
                raise ProviderDeliveryError("Discord role ID is invalid")
            payload["content"] = f"<@&{self._role_id}>\n\n{message}"
            payload["allowed_mentions"] = {
                "parse": [],
                "roles": [self._role_id],
            }
        return payload

    def send(self, notification: NotificationRequest) -> None:
        if not self.configured:
            raise ProviderDeliveryError("Discord provider is not configured")
        body = json.dumps(
            self.build_payload(notification),
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        last_error: Optional[Exception] = None
        for attempt in range(1, self._max_attempts + 1):
            request = urllib.request.Request(
                self._webhook_url,
                data=body,
                method="POST",
                headers={"Content-Type": "application/json; charset=utf-8"},
            )
            try:
                with self._opener(request, timeout=self._timeout_seconds) as response:
                    status = int(getattr(response, "status", 204))
                if 200 <= status < 300:
                    return
                last_error = RuntimeError(f"unexpected HTTP status {status}")
            except (urllib.error.URLError, TimeoutError, OSError, RuntimeError) as exc:
                last_error = exc
            if attempt < self._max_attempts:
                self._sleeper(2.0)
        raise ProviderDeliveryError(
            f"Discord send failed after {self._max_attempts} attempt(s)"
        ) from last_error
class RelayService:
    def __init__(
        self,
        *,
        relay_token: str,
        provider: object,
        rate_limiter: Optional[SlidingWindowRateLimiter] = None,
        recent_limit: int = 20,
        clock_utc: Callable[[], float] = time.time,
    ) -> None:
        token = relay_token.strip()
        if len(token) < 24:
            raise ValueError("relay token must contain at least 24 characters")
        self._relay_token = token
        self._provider = provider
        self._rate_limiter = rate_limiter or SlidingWindowRateLimiter()
        self._recent: deque[dict[str, object]] = deque(maxlen=max(1, min(recent_limit, 100)))
        self._clock_utc = clock_utc
        self._accepted = 0
        self._delivered = 0
        self._failed = 0
        self._rate_limited = 0

    @property
    def ready(self) -> bool:
        return bool(getattr(self._provider, "configured", False))

    def authenticate(self, authorization: Optional[str]) -> bool:
        if not authorization or not authorization.startswith("Bearer "):
            return False
        candidate = authorization[7:].strip()
        return bool(candidate) and hmac.compare_digest(candidate, self._relay_token)

    def status(self) -> dict[str, object]:
        return {
            "service": "ai-worker-notifier-relay",
            "ready": self.ready,
            "provider": str(getattr(self._provider, "name", "unknown")),
            "accepted": self._accepted,
            "delivered": self._delivered,
            "failed": self._failed,
            "rateLimited": self._rate_limited,
            "recent": list(self._recent),
        }
    def deliver(self, payload: Mapping[str, object], *, remote_addr: str) -> dict[str, object]:
        if not self._rate_limiter.allow(remote_addr or "unknown"):
            self._rate_limited += 1
            raise RelayRateLimitError("rate limit exceeded")
        if not self.ready:
            raise ProviderDeliveryError("notification provider is not configured")

        notification = NotificationRequest.from_mapping(payload)
        notification_id = uuid.uuid4().hex
        self._accepted += 1
        started = self._clock_utc()
        try:
            getattr(self._provider, "send")(notification)
        except Exception as exc:
            self._failed += 1
            self._recent.appendleft(
                {
                    "notificationId": notification_id,
                    "status": "failed",
                    "atUtc": started,
                    "project": notification.project,
                    "agent": notification.agent,
                    "severity": notification.severity,
                    "error": _bounded_inline(str(exc), 160),
                }
            )
            if isinstance(exc, ProviderDeliveryError):
                raise
            raise ProviderDeliveryError("notification provider failed") from exc

        self._delivered += 1
        self._recent.appendleft(
            {
                "notificationId": notification_id,
                "status": "delivered",
                "atUtc": started,
                "project": notification.project,
                "agent": notification.agent,
                "severity": notification.severity,
            }
        )
        return {
            "accepted": True,
            "delivered": True,
            "notificationId": notification_id,
        }
