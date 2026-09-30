#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from typing import List, Optional
from pathlib import Path


def _read_token() -> str:
    direct = os.environ.get("AI_WORKER_NOTIFIER_RELAY_TOKEN", "").strip()
    if direct:
        return direct
    path = os.environ.get("AI_WORKER_NOTIFIER_RELAY_TOKEN_FILE", "").strip()
    if path:
        return Path(path).expanduser().read_text(encoding="utf-8").strip()
    raise RuntimeError("relay token is not configured")


def _git_project() -> str:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        if result.returncode == 0 and result.stdout.strip():
            return Path(result.stdout.strip()).name
    except (OSError, subprocess.SubprocessError):
        pass
    return Path.cwd().name
def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Send an AIWorkerNotifier message through the shared relay")
    parser.add_argument("message")
    parser.add_argument("--title", default="")
    parser.add_argument("--project", default="")
    parser.add_argument("--agent", default="")
    parser.add_argument("--severity", choices=("info", "warning", "error"), default="info")
    parser.add_argument("--source", default="agent-cli")
    parser.add_argument("--url", default=os.environ.get("AI_WORKER_NOTIFIER_RELAY_URL", ""))
    args = parser.parse_args(argv)

    try:
        if not args.url.strip():
            raise RuntimeError("AI_WORKER_NOTIFIER_RELAY_URL is not configured")
        token = _read_token()
        payload = {
            "message": args.message,
            "title": args.title,
            "project": args.project or _git_project(),
            "agent": args.agent,
            "severity": args.severity,
            "source": args.source,
        }
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(
            args.url.rstrip("/") + "/api/v1/notifications",
            data=body,
            method="POST",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json; charset=utf-8",
            },
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            result = json.loads(response.read().decode("utf-8"))
        notification_id = str(result.get("notificationId") or "")
        print(f"AI Worker remote message delivered: {notification_id}")
    except (OSError, RuntimeError, ValueError, urllib.error.URLError, json.JSONDecodeError) as exc:
        # Notification transport is non-blocking for the caller's original task.
        print(f"WARNING: AI Worker remote message was not delivered: {exc}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
