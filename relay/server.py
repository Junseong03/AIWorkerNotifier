from __future__ import annotations

import argparse
import json
import os
import stat
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import List, Mapping, Optional

from .core import (
    DiscordWebhookProvider,
    ProviderDeliveryError,
    RelayRateLimitError,
    RelayService,
    RelayValidationError,
    SlidingWindowRateLimiter,
)

MAX_BODY_BYTES = 16 * 1024


def _read_secret_file(path: Path) -> str:
    if os.name != "nt":
        mode = stat.S_IMODE(path.stat().st_mode)
        if mode & 0o077:
            raise RuntimeError(f"secret file permissions must be 0600: {path}")
    value = path.read_text(encoding="utf-8").strip()
    if not value:
        raise RuntimeError(f"secret file is empty: {path}")
    return value
def _secret_from_environment(
    environment: Mapping[str, str],
    *,
    value_name: str,
    file_name: str,
    required: bool,
) -> str:
    direct = environment.get(value_name, "").strip()
    if direct:
        return direct
    file_value = environment.get(file_name, "").strip()
    if file_value:
        return _read_secret_file(Path(file_value).expanduser())
    if required:
        raise RuntimeError(f"{value_name} or {file_name} is required")
    return ""


def _plain_value_from_environment(
    environment: Mapping[str, str], *, value_name: str, file_name: str
) -> str:
    direct = environment.get(value_name, "").strip()
    if direct:
        return direct
    file_value = environment.get(file_name, "").strip()
    if not file_value:
        return ""
    return Path(file_value).expanduser().read_text(encoding="utf-8").strip()
class RelayHTTPServer(HTTPServer):
    def __init__(self, server_address: tuple[str, int], service: RelayService) -> None:
        super().__init__(server_address, RelayRequestHandler)
        self.relay_service = service


class RelayRequestHandler(BaseHTTPRequestHandler):
    server: RelayHTTPServer
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:
        # Never include request body or Authorization header in normal logs.
        sys.stderr.write(
            "%s relay_http %s\n" % (self.log_date_time_string(), format % args)
        )

    def _json_response(self, status: int, payload: Mapping[str, object]) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _authenticated(self) -> bool:
        return self.server.relay_service.authenticate(self.headers.get("Authorization"))

    def _require_auth(self) -> bool:
        if self._authenticated():
            return True
        self._json_response(401, {"error": "UNAUTHORIZED"})
        return False
    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self._json_response(
                200,
                {
                    "service": "ai-worker-notifier-relay",
                    "status": "ok",
                    "ready": self.server.relay_service.ready,
                },
            )
            return
        if self.path == "/api/v1/status":
            if not self._require_auth():
                return
            self._json_response(200, self.server.relay_service.status())
            return
        self._json_response(404, {"error": "NOT_FOUND"})

    def _read_json_body(self) -> Mapping[str, object]:
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise RelayValidationError("Content-Length is required")
        try:
            length = int(raw_length)
        except ValueError as exc:
            raise RelayValidationError("Content-Length is invalid") from exc
        if length < 0 or length > MAX_BODY_BYTES:
            raise OverflowError("request body is too large")
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise RelayValidationError("request body must be UTF-8 JSON") from exc
        if not isinstance(payload, dict):
            raise RelayValidationError("request body must be a JSON object")
        return payload
    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/api/v1/notifications":
            self._json_response(404, {"error": "NOT_FOUND"})
            return
        if not self._require_auth():
            return
        try:
            payload = self._read_json_body()
            result = self.server.relay_service.deliver(
                payload,
                remote_addr=str(self.client_address[0]),
            )
        except OverflowError:
            self._json_response(413, {"error": "PAYLOAD_TOO_LARGE"})
            return
        except RelayRateLimitError:
            self._json_response(429, {"error": "RATE_LIMITED"})
            return
        except RelayValidationError as exc:
            self._json_response(400, {"error": "INVALID_REQUEST", "detail": str(exc)})
            return
        except ProviderDeliveryError:
            self._json_response(502, {"error": "DELIVERY_FAILED"})
            return
        except Exception:
            self._json_response(500, {"error": "INTERNAL_ERROR"})
            return
        self._json_response(200, result)
def build_service(environment: Optional[Mapping[str, str]] = None) -> RelayService:
    env = dict(environment or os.environ)
    relay_token = _secret_from_environment(
        env,
        value_name="AI_WORKER_NOTIFIER_RELAY_TOKEN",
        file_name="AI_WORKER_NOTIFIER_RELAY_TOKEN_FILE",
        required=True,
    )
    webhook = _secret_from_environment(
        env,
        value_name="AI_WORKER_NOTIFIER_WEBHOOK_URL",
        file_name="AI_WORKER_NOTIFIER_WEBHOOK_FILE",
        required=False,
    )
    role_id = _plain_value_from_environment(
        env,
        value_name="AI_WORKER_NOTIFIER_MENTION_ROLE_ID",
        file_name="AI_WORKER_NOTIFIER_MENTION_ROLE_FILE",
    )
    provider = DiscordWebhookProvider(
        webhook_url=webhook,
        role_id=role_id,
        timeout_seconds=float(env.get("AI_WORKER_NOTIFIER_REQUEST_TIMEOUT_SECONDS", "8")),
        max_attempts=int(env.get("AI_WORKER_NOTIFIER_MAX_SEND_ATTEMPTS", "2")),
    )
    limiter = SlidingWindowRateLimiter(
        limit=int(env.get("AI_WORKER_NOTIFIER_RELAY_RATE_LIMIT", "30")),
        window_seconds=float(env.get("AI_WORKER_NOTIFIER_RELAY_RATE_WINDOW_SECONDS", "60")),
        max_keys=int(env.get("AI_WORKER_NOTIFIER_RELAY_RATE_KEYS", "128")),
    )
    return RelayService(relay_token=relay_token, provider=provider, rate_limiter=limiter)
def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="AIWorkerNotifier headless notification relay")
    parser.add_argument("--bind", default=os.environ.get("AI_WORKER_NOTIFIER_RELAY_BIND", "127.0.0.1"))
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("AI_WORKER_NOTIFIER_RELAY_PORT", "8771")),
    )
    args = parser.parse_args(argv)

    service = build_service()
    server = RelayHTTPServer((args.bind, args.port), service)
    print(
        f"AIWorkerNotifier relay listening on {args.bind}:{args.port}; "
        f"provider={service.status()['provider']}; ready={service.ready}",
        flush=True,
    )
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
