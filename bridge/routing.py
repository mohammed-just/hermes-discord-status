"""Resolve Discord snowflakes to Hermes session ids."""

from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any

SNOWFLAKE_RE = re.compile(r"^[1-9][0-9]{16,19}$")
DEFAULT_ROUTE_TTL_SECONDS = 30 * 24 * 60 * 60


def is_snowflake(value: str) -> bool:
    return bool(SNOWFLAKE_RE.fullmatch(str(value or "")))


def _origin(entry: dict[str, Any]) -> dict[str, Any]:
    origin = entry.get("origin")
    if isinstance(origin, dict):
        return origin
    origin_json = entry.get("origin_json")
    if isinstance(origin_json, str):
        try:
            parsed = json.loads(origin_json)
            if isinstance(parsed, dict):
                return parsed
        except ValueError:
            return {}
    return {}


def _entry_updated_ts(entry: dict[str, Any]) -> float | None:
    for key in ("last_active", "updated_at", "started_at"):
        value = entry.get(key)
        if isinstance(value, (int, float)):
            return float(value)
        if isinstance(value, str) and value:
            try:
                from datetime import datetime

                return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
            except ValueError:
                continue
    return None


def _entry_session_id(entry: dict[str, Any]) -> str:
    """Return the session identifier from JSON routing entries or state.db rows."""
    return str(entry.get("session_id") or entry.get("id") or "").strip()


def _matches_discord_channel(entry: dict[str, Any], channel_id: str, *, now: float, ttl: float) -> bool:
    origin = _origin(entry)
    platform = str(entry.get("platform") or entry.get("source") or origin.get("platform") or "").lower()
    if platform != "discord":
        return False
    thread_id = str(entry.get("thread_id") or origin.get("thread_id") or "")
    if thread_id:
        candidates = {thread_id}
    else:
        candidates = {
            str(entry.get("chat_id") or ""),
            str(origin.get("chat_id") or ""),
        }
    if channel_id not in candidates:
        return False
    route_ids = [value for value in candidates if value]
    if any(not is_snowflake(value) for value in route_ids):
        return False
    updated = _entry_updated_ts(entry)
    if updated is not None and ttl > 0 and updated < now - ttl:
        return False
    return bool(_entry_session_id(entry))


class DiscordRouteResolver:
    def __init__(self, *, route_ttl_seconds: float = DEFAULT_ROUTE_TTL_SECONDS, hermes_home: Path | None = None):
        self.route_ttl_seconds = route_ttl_seconds
        self.hermes_home = hermes_home

    def resolve(self, channel_id: str) -> str | None:
        if not is_snowflake(channel_id):
            return None
        now = time.time()
        for entry in self._newest_matching_entries(self._load_db_entries(), channel_id, now):
            if _matches_discord_channel(entry, channel_id, now=now, ttl=self.route_ttl_seconds):
                return _entry_session_id(entry)
        for entry in self._newest_matching_entries(self._load_json_entries(), channel_id, now):
            if _matches_discord_channel(entry, channel_id, now=now, ttl=self.route_ttl_seconds):
                return _entry_session_id(entry)
        return None

    def _newest_matching_entries(self, entries: list[dict[str, Any]], channel_id: str, now: float) -> list[dict[str, Any]]:
        matches = [
            entry
            for entry in entries
            if _matches_discord_channel(entry, channel_id, now=now, ttl=self.route_ttl_seconds)
        ]
        return sorted(matches, key=lambda entry: _entry_updated_ts(entry) or 0.0, reverse=True)

    def _load_db_entries(self) -> list[dict[str, Any]]:
        try:
            from hermes_state import SessionDB

            db = SessionDB()
        except Exception:
            return []
        try:
            lister = getattr(db, "list_gateway_sessions", None)
            rows = lister(active_only=True) if callable(lister) else []
            return [dict(row) for row in rows if isinstance(row, dict)]
        except Exception:
            return []
        finally:
            try:
                db.close()
            except Exception:
                pass

    def _sessions_json_path(self) -> Path:
        if self.hermes_home is not None:
            return self.hermes_home / "sessions" / "sessions.json"
        try:
            from hermes_constants import get_hermes_home

            return get_hermes_home() / "sessions" / "sessions.json"
        except Exception:
            return Path.home() / ".hermes" / "sessions" / "sessions.json"

    def _load_json_entries(self) -> list[dict[str, Any]]:
        path = self._sessions_json_path()
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            return []
        if not isinstance(data, dict):
            return []
        return [
            dict(value)
            for key, value in data.items()
            if not str(key).startswith("_") and isinstance(value, dict)
        ]
