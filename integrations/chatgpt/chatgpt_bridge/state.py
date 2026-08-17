from __future__ import annotations

import logging
import os
import sys
import threading
from collections import deque
from logging.handlers import RotatingFileHandler
from pathlib import Path

from .common import FOCUS_DEBUG_LIMIT
from .focus import FocusStateMixin
from .models import FocusStatus, TabRecord, WebSocketPeer
from .persistence import PersistenceMixin
from .tabs import TabStateMixin


class BridgeState(TabStateMixin, FocusStateMixin, PersistenceMixin):
    def __init__(self, repo_root: Path, port: int) -> None:
        self.repo_root = repo_root
        self.port = port
        local_app_data = Path(
            os.environ.get("LOCALAPPDATA")
            or (Path.home() / "AppData" / "Local")
        )
        self.runtime_root = local_app_data / "AIWorkerNotifier"
        self.state_root = self.runtime_root / "state"
        self.log_root = self.runtime_root / "logs"
        self.disabled_tabs_path = self.state_root / "chatgpt-disabled-tabs.json"
        self.completion_journal_root = self.state_root / "chatgpt-completions"
        self.ai_task_complete = repo_root / "bin" / "ai-task-complete.internal.ps1"
        self.state_root.mkdir(parents=True, exist_ok=True)
        self.log_root.mkdir(parents=True, exist_ok=True)
        self.completion_journal_root.mkdir(parents=True, exist_ok=True)

        self.logger = logging.getLogger("chatgpt_bridge")
        self.logger.setLevel(logging.INFO)
        self.logger.handlers.clear()
        self.logger.propagate = False
        formatter = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
        file_handler = RotatingFileHandler(
            self.log_root / "chatgpt-bridge.log",
            maxBytes=1_000_000,
            backupCount=2,
            encoding="utf-8",
        )
        file_handler.setFormatter(formatter)
        self.logger.addHandler(file_handler)
        console_handler = logging.StreamHandler(sys.stdout)
        console_handler.setFormatter(logging.Formatter("%(message)s"))
        self.logger.addHandler(console_handler)

        self.lock = threading.RLock()
        self.tabs: dict[str, TabRecord] = {}
        self.disabled_tabs = self._load_disabled_tabs()
        self.focus_requests_by_tab: dict[str, str] = {}
        self.focus_status_by_id: dict[str, FocusStatus] = {}
        self.focus_debug: deque[str] = deque(maxlen=FOCUS_DEBUG_LIMIT)
        self.focus_socket: WebSocketPeer | None = None
        self.stop_event = threading.Event()
