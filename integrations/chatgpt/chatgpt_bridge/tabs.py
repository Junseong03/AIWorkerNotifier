from __future__ import annotations

import json
import os
import time
from datetime import datetime
from typing import Any

from .common import LEGACY_TAB_TTL_SECONDS, canonical_chatgpt_url, limit_text
from .models import TabRecord


class TabStateMixin:
    def add_debug(self, message: str) -> None:
        line = f"[{datetime.now().strftime('%H:%M:%S.%f')[:-3]}] {limit_text(message, 2000)}"
        with self.lock:
            self.focus_debug.append(line)
        self.logger.info(line)

    def _load_disabled_tabs(self) -> set[str]:
        try:
            raw = json.loads(self.disabled_tabs_path.read_text(encoding="utf-8-sig"))
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            return set()
        if not isinstance(raw, list):
            return set()
        return {limit_text(item, 100) for item in raw if limit_text(item, 100)}

    def save_disabled_tabs(self) -> None:
        temp = self.disabled_tabs_path.with_suffix(".json.tmp")
        temp.write_text(
            json.dumps(sorted(self.disabled_tabs), ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        os.replace(temp, self.disabled_tabs_path)

    def upsert_tab(
        self,
        tab_id: str,
        title: str,
        url: str,
        *,
        window_id: int | None = None,
        generating: bool | None = None,
    ) -> TabRecord | None:
        tab_id = limit_text(tab_id, 100)
        title = limit_text(title, 200)
        url = limit_text(url, 2048)
        if not tab_id or not canonical_chatgpt_url(url):
            return None
        with self.lock:
            old = self.tabs.get(tab_id)
            record = TabRecord(
                tab_id=tab_id,
                window_id=window_id if window_id is not None else (old.window_id if old else None),
                title=title or (old.title if old else "ChatGPT"),
                url=url,
                generating=(
                    bool(generating)
                    if generating is not None
                    else (old.generating if old else False)
                ),
                last_seen=time.monotonic(),
            )
            self.tabs[tab_id] = record
            return record

    def apply_snapshot(self, items: Any) -> None:
        if not isinstance(items, list):
            return
        for item in items:
            if not isinstance(item, dict):
                continue
            self.upsert_tab(
                str(item.get("tabId") or ""),
                str(item.get("title") or ""),
                str(item.get("url") or ""),
                window_id=(
                    item.get("windowId")
                    if isinstance(item.get("windowId"), int)
                    else None
                ),
            )

    def remove_tab(self, tab_id: str) -> None:
        tab_id = limit_text(tab_id, 100)
        with self.lock:
            self.tabs.pop(tab_id, None)
            request_id = self.focus_requests_by_tab.pop(tab_id, "")
            if request_id and request_id in self.focus_status_by_id:
                status = self.focus_status_by_id[request_id]
                status.status = "failed"
                status.error = "Chrome tab was closed before focus."
            if tab_id in self.disabled_tabs:
                self.disabled_tabs.remove(tab_id)
                self.save_disabled_tabs()

    def remove_stale(self) -> None:
        cutoff = time.monotonic() - LEGACY_TAB_TTL_SECONDS
        with self.lock:
            stale = [
                tab_id
                for tab_id, tab in self.tabs.items()
                if not tab_id.startswith("chrome-") and tab.last_seen < cutoff
            ]
            changed = False
            for tab_id in stale:
                self.tabs.pop(tab_id, None)
                if tab_id in self.disabled_tabs:
                    self.disabled_tabs.remove(tab_id)
                    changed = True
            if changed:
                self.save_disabled_tabs()
