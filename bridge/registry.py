"""Thread-safe live session registry."""

from __future__ import annotations

import copy
import threading
import time
from dataclasses import asdict, dataclass
from typing import Any


MAX_SAFE_WIRE_INTEGER = 2**53 - 1


def unix_now(ts: float | None = None) -> float:
    return float(time.time() if ts is None else ts)


def _percent(used: int | None, max_tokens: int | None) -> float | None:
    if used is None or not max_tokens:
        return None
    return max(0.0, min(100.0, round((used / max_tokens) * 100.0, 2)))


@dataclass
class SessionState:
    schema_version: int
    session_id: str
    model: str
    context_used: int | None
    context_max: int | None
    context_percent: float | None
    total_processed_tokens: int
    session_started_at: float
    turn_started_at: float | None
    busy: bool
    active_tool: str | None
    tool_calls: int
    active_tool_calls: int
    compression_count: int
    active_subagents: int
    yolo: bool
    updated_at: float
    error: str | None


class SessionRegistry:
    def __init__(self, *, stale_after_seconds: float = 6 * 60 * 60, max_sessions: int = 512, clock=time.time):
        self._states: dict[str, SessionState] = {}
        self._active_tools: dict[str, dict[str, str]] = {}
        self._anon_tool_seq = 0
        self._lock = threading.RLock()
        self._stale_after = stale_after_seconds
        self._max_sessions = max(1, int(max_sessions))
        self._clock = clock

    def _trim_locked(self, protected_session_id: str | None = None) -> None:
        overflow = len(self._states) - self._max_sessions
        if overflow <= 0:
            return
        candidates = (
            item
            for item in self._states.items()
            if item[0] != protected_session_id
        )
        oldest = sorted(candidates, key=lambda item: float(item[1].updated_at or 0))[:overflow]
        for session_id, _state in oldest:
            self._states.pop(session_id, None)
            self._active_tools.pop(session_id, None)

    def _upsert_session_locked(
        self,
        session_id: str,
        model: str,
        *,
        now: float,
        context_max: int | None = None,
        yolo: bool | None = None,
    ) -> SessionState:
        existing = self._states.get(session_id)
        active_tools = self._active_tools.get(session_id, {})
        next_context_max = context_max if context_max is not None else (existing.context_max if existing else None)
        self._states[session_id] = SessionState(
            schema_version=1,
            session_id=session_id,
            model=model or (existing.model if existing else ""),
            context_used=existing.context_used if existing else None,
            context_max=next_context_max,
            context_percent=_percent(existing.context_used, next_context_max) if existing else None,
            total_processed_tokens=existing.total_processed_tokens if existing else 0,
            session_started_at=existing.session_started_at if existing else unix_now(now),
            turn_started_at=existing.turn_started_at if existing else None,
            busy=existing.busy if existing else False,
            active_tool=next(reversed(active_tools.values()), None) if active_tools else (existing.active_tool if existing else None),
            tool_calls=existing.tool_calls if existing else 0,
            active_tool_calls=len(active_tools),
            compression_count=existing.compression_count if existing else 0,
            active_subagents=existing.active_subagents if existing else 0,
            yolo=bool(yolo) if yolo is not None else (existing.yolo if existing else False),
            updated_at=unix_now(now),
            error=None,
        )
        self._trim_locked(protected_session_id=session_id)
        return self._states[session_id]

    def start_session(self, session_id: str, model: str, *, context_max: int | None = None, yolo: bool | None = None) -> None:
        if not session_id:
            return
        now = self._clock()
        with self._lock:
            self._upsert_session_locked(session_id, model, now=now, context_max=context_max, yolo=yolo)

    def start_turn(self, session_id: str, model: str, *, context_max: int | None = None, yolo: bool | None = None) -> None:
        if not session_id:
            return
        now = self._clock()
        with self._lock:
            state = self._upsert_session_locked(session_id, model, now=now, context_max=context_max, yolo=yolo)
            state.model = model or state.model
            if yolo is not None:
                state.yolo = bool(yolo)
            if context_max is not None:
                state.context_max = context_max
                state.context_percent = _percent(state.context_used, state.context_max)
            if state.turn_started_at is None:
                state.turn_started_at = unix_now(now)
            state.busy = True
            state.updated_at = unix_now(now)
            state.error = None

    def update_context(self, session_id: str, used: int | None, *, context_max: int | None = None) -> None:
        if not session_id:
            return
        with self._lock:
            state = self._states.get(session_id)
            if state is None:
                state = self._upsert_session_locked(session_id, "", now=self._clock(), context_max=context_max)
            if used is not None and used >= 0:
                state.context_used = int(used)
            if context_max is not None:
                state.context_max = int(context_max)
            state.context_percent = _percent(state.context_used, state.context_max)
            state.updated_at = unix_now(self._clock())

    def add_total_processed_tokens(self, session_id: str, delta: int) -> None:
        if not session_id or not isinstance(delta, int) or isinstance(delta, bool) or delta < 0 or delta > MAX_SAFE_WIRE_INTEGER:
            return
        with self._lock:
            state = self._states.get(session_id)
            if state is None:
                state = self._upsert_session_locked(session_id, "", now=self._clock())
            if state.total_processed_tokens > MAX_SAFE_WIRE_INTEGER - delta:
                return
            state.total_processed_tokens += delta
            state.updated_at = unix_now(self._clock())

    def _tool_key(self, tool_call_id: str | None) -> str:
        tool_call_id = str(tool_call_id or "").strip()
        if tool_call_id:
            return tool_call_id
        self._anon_tool_seq += 1
        return f"anon-{self._anon_tool_seq}"

    def _refresh_tool_state_locked(self, state: SessionState) -> None:
        active = self._active_tools.get(state.session_id, {})
        state.active_tool_calls = len(active)
        state.active_tool = next(reversed(active.values()), None) if active else None

    def tool_start(self, session_id: str, tool_name: str | None, *, tool_call_id: str | None = None) -> None:
        if not session_id:
            return
        with self._lock:
            state = self._states.get(session_id)
            if state is None:
                state = self._upsert_session_locked(session_id, "", now=self._clock())
            tool_name = str(tool_name or "") or "tool"
            self._active_tools.setdefault(session_id, {})[self._tool_key(tool_call_id)] = tool_name
            state.busy = True
            state.tool_calls += 1
            self._refresh_tool_state_locked(state)
            state.updated_at = unix_now(self._clock())

    def tool_end(self, session_id: str, tool_name: str | None = None, *, tool_call_id: str | None = None) -> None:
        if not session_id:
            return
        with self._lock:
            state = self._states.get(session_id)
            if state is None:
                return
            active = self._active_tools.setdefault(session_id, {})
            key = str(tool_call_id or "").strip()
            if key:
                active.pop(key, None)
            elif tool_name is None and active:
                active.pop(next(iter(active)), None)
            else:
                for active_key, active_name in list(active.items()):
                    if active_name == tool_name:
                        active.pop(active_key, None)
                        break
            if not active:
                self._active_tools.pop(session_id, None)
            self._refresh_tool_state_locked(state)
            state.updated_at = unix_now(self._clock())

    def finish_turn(self, session_id: str, *, error: str | None = None) -> None:
        if not session_id:
            return
        with self._lock:
            state = self._states.get(session_id)
            if state is None:
                return
            state.busy = False
            self._active_tools.pop(session_id, None)
            self._refresh_tool_state_locked(state)
            state.turn_started_at = None
            state.error = error
            state.updated_at = unix_now(self._clock())

    def update_compression_count(self, session_id: str, count: int | None = None, *, increment: int = 0) -> None:
        if not session_id:
            return
        with self._lock:
            state = self._states.get(session_id)
            if state is None:
                state = self._upsert_session_locked(session_id, "", now=self._clock())
            if count is not None and count >= 0:
                state.compression_count = int(count)
            elif increment:
                state.compression_count = max(0, state.compression_count + int(increment))
            state.updated_at = unix_now(self._clock())

    def update_subagents(self, session_id: str, delta: int) -> None:
        if not session_id:
            return
        with self._lock:
            state = self._states.get(session_id)
            if state is None:
                state = self._upsert_session_locked(session_id, "", now=self._clock())
            state.active_subagents = max(0, state.active_subagents + int(delta))
            state.updated_at = unix_now(self._clock())

    def update_background_subagents(self, session_id: str, delta: int) -> None:
        self.update_subagents(session_id, delta)

    def set_yolo(self, session_id: str, active: bool) -> None:
        if not session_id:
            return
        with self._lock:
            state = self._states.get(session_id)
            if state is None:
                state = self._upsert_session_locked(session_id, "", now=self._clock())
            state.yolo = bool(active)
            state.updated_at = unix_now(self._clock())

    def set_error(self, session_id: str, error: str) -> None:
        if not session_id:
            return
        with self._lock:
            state = self._states.get(session_id)
            if state is None:
                return
            state.error = error
            state.updated_at = unix_now(self._clock())

    def reset(self, session_id: str | None = None) -> None:
        with self._lock:
            if session_id:
                self._states.pop(session_id, None)
                self._active_tools.pop(session_id, None)
            else:
                self._states.clear()
                self._active_tools.clear()

    def get(self, session_id: str) -> dict[str, Any] | None:
        with self._lock:
            state = self._states.get(session_id)
            return copy.deepcopy(asdict(state)) if state else None

    def cleanup_stale(self) -> int:
        cutoff = self._clock() - self._stale_after
        removed = 0
        with self._lock:
            for sid, state in list(self._states.items()):
                updated = float(state.updated_at or 0)
                if updated < cutoff:
                    self._states.pop(sid, None)
                    self._active_tools.pop(sid, None)
                    removed += 1
        return removed
