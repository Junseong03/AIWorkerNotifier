from __future__ import annotations

import json
import threading
import unittest
import urllib.error
import urllib.request
from typing import Dict, Optional

from relay.core import (
    DiscordWebhookProvider,
    NotificationRequest,
    ProviderDeliveryError,
    RelayRateLimitError,
    RelayService,
    RelayValidationError,
    SlidingWindowRateLimiter,
)
from relay.server import RelayHTTPServer


class FakeProvider:
    name = "fake"
    configured = True

    def __init__(self) -> None:
        self.sent: list[NotificationRequest] = []

    def send(self, notification: NotificationRequest) -> None:
        self.sent.append(notification)


class FailingProvider(FakeProvider):
    def send(self, notification: NotificationRequest) -> None:
        raise ProviderDeliveryError("provider failed")
class NotificationRelayCoreTests(unittest.TestCase):
    def test_notification_request_bounds_and_redacts(self) -> None:
        request = NotificationRequest.from_mapping(
            {
                "message": "line 1\nBearer abcdefghijklmnopqrstuvwxyz\nline 3",
                "title": "hello",
                "project": "FlowDeck",
                "agent": "ChatGPT",
                "severity": "warning",
            }
        )
        self.assertIn("[REDACTED]", request.message)
        self.assertNotIn("abcdefghijklmnopqrstuvwxyz", request.message)
        self.assertEqual(request.project, "FlowDeck")
        self.assertEqual(request.severity, "warning")

    def test_invalid_severity_is_rejected(self) -> None:
        with self.assertRaises(RelayValidationError):
            NotificationRequest.from_mapping({"message": "x", "severity": "critical"})

    def test_discord_payload_disables_mentions_by_default(self) -> None:
        provider = DiscordWebhookProvider(
            webhook_url="https://discord.invalid/api/webhooks/redacted",
        )
        payload = provider.build_payload(NotificationRequest(message="@everyone hello"))
        self.assertEqual(payload["allowed_mentions"], {"parse": []})

    def test_discord_role_payload_allows_only_exact_role(self) -> None:
        provider = DiscordWebhookProvider(
            webhook_url="https://discord.invalid/api/webhooks/redacted",
            role_id="123456789012345678",
        )
        payload = provider.build_payload(NotificationRequest(message="hello"))
        self.assertEqual(payload["allowed_mentions"], {"parse": [], "roles": ["123456789012345678"]})
        self.assertTrue(str(payload["content"]).startswith("<@&123456789012345678>"))

    def test_relay_authentication_is_explicit(self) -> None:
        service = RelayService(relay_token="r" * 32, provider=FakeProvider())
        self.assertFalse(service.authenticate(None))
        self.assertFalse(service.authenticate("Bearer wrong"))
        self.assertTrue(service.authenticate("Bearer " + "r" * 32))
    def test_rate_limiter_bounds_source_keys(self) -> None:
        limiter = SlidingWindowRateLimiter(limit=5, max_keys=3, clock=lambda: 100.0)
        for index in range(10):
            self.assertTrue(limiter.allow(f"100.64.0.{index}"))
        self.assertEqual(limiter.retained_keys(), 3)

    def test_rate_limiter_rejects_burst(self) -> None:
        limiter = SlidingWindowRateLimiter(limit=2, window_seconds=60, clock=lambda: 100.0)
        self.assertTrue(limiter.allow("100.64.0.1"))
        self.assertTrue(limiter.allow("100.64.0.1"))
        self.assertFalse(limiter.allow("100.64.0.1"))

    def test_relay_recent_outcomes_are_bounded(self) -> None:
        provider = FakeProvider()
        service = RelayService(relay_token="r" * 32, provider=provider, recent_limit=3)
        for index in range(8):
            service.deliver({"message": f"message {index}"}, remote_addr="100.64.0.1")
        status = service.status()
        self.assertEqual(status["accepted"], 8)
        self.assertEqual(status["delivered"], 8)
        self.assertEqual(len(status["recent"]), 3)

    def test_relay_provider_failure_does_not_echo_secret(self) -> None:
        service = RelayService(relay_token="r" * 32, provider=FailingProvider())
        with self.assertRaises(ProviderDeliveryError):
            service.deliver({"message": "notify"}, remote_addr="100.64.0.1")
        status = service.status()
        self.assertEqual(status["failed"], 1)
        self.assertNotIn("webhook", json.dumps(status).lower())
class NotificationRelayHTTPTests(unittest.TestCase):
    def setUp(self) -> None:
        self.provider = FakeProvider()
        self.service = RelayService(
            relay_token="t" * 32,
            provider=self.provider,
            rate_limiter=SlidingWindowRateLimiter(limit=2, window_seconds=60),
        )
        self.server = RelayHTTPServer(("127.0.0.1", 0), self.service)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def _request(self, path: str, *, body: Optional[Dict[str, object]] = None, token: str | None = None):
        data = None if body is None else json.dumps(body).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(
            self.base + path,
            data=data,
            method="POST" if body is not None else "GET",
            headers=headers,
        )
        return urllib.request.urlopen(request, timeout=3)
    def test_health_is_public_but_status_requires_auth(self) -> None:
        with self._request("/health") as response:
            payload = json.loads(response.read().decode("utf-8"))
        self.assertEqual(response.status, 200)
        self.assertTrue(payload["ready"])
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self._request("/api/v1/status")
        self.assertEqual(caught.exception.code, 401)

    def test_notification_requires_auth_and_delivers(self) -> None:
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self._request("/api/v1/notifications", body={"message": "hello"})
        self.assertEqual(caught.exception.code, 401)

        with self._request(
            "/api/v1/notifications",
            body={"message": "hello", "project": "FlowDeck", "agent": "ChatGPT"},
            token="t" * 32,
        ) as response:
            payload = json.loads(response.read().decode("utf-8"))
        self.assertEqual(response.status, 200)
        self.assertTrue(payload["delivered"])
        self.assertEqual(self.provider.sent[0].project, "FlowDeck")

    def test_rate_limit_is_http_429(self) -> None:
        for index in range(2):
            with self._request(
                "/api/v1/notifications",
                body={"message": f"hello {index}"},
                token="t" * 32,
            ):
                pass
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self._request(
                "/api/v1/notifications",
                body={"message": "too many"},
                token="t" * 32,
            )
        self.assertEqual(caught.exception.code, 429)


if __name__ == "__main__":
    unittest.main()
