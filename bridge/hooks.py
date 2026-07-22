"""Hermes hook callbacks for live status tracking."""

from __future__ import annotations

from typing import Any

from .registry import MAX_SAFE_WIRE_INTEGER, SessionRegistry


PUBLIC_API_ERROR = "API request failed"


def _positive_int(value: Any) -> int | None:
    try:
        number = int(value)
    except (TypeError, ValueError):
        return None
    return number if number >= 0 else None


def _usage_prompt_tokens(usage: Any) -> int | None:
    if not isinstance(usage, dict):
        return None
    for key in ("prompt_tokens", "input_tokens"):
        value = _positive_int(usage.get(key))
        if value is not None:
            return value
    details = usage.get("input_token_details")
    if isinstance(details, dict):
        return _positive_int(details.get("total_tokens"))
    return None


def _usage_total_tokens(usage: Any) -> int | None:
    if not isinstance(usage, dict):
        return None
    value = usage.get("total_tokens")
    if not isinstance(value, int) or isinstance(value, bool) or value < 0 or value > MAX_SAFE_WIRE_INTEGER:
        return None
    return value


def resolve_context_max(model: str, provider: str | None = None, base_url: str | None = None) -> int | None:
    """Resolve context max without falling back to broad default guesses."""
    model = model or ""
    provider = provider or (
        "openai-codex"
        if model in {"gpt-5.5", "gpt-5.6-sol", "gpt-5.6-terra"}
        else ""
    )
    if not model:
        return None
    if provider:
        try:
            # Keep status-bar accounting identical to Hermes' provider-aware
            # resolver. In particular, Codex OAuth limits differ from direct
            # OpenAI API catalog values for the same model slug.
            from agent.model_metadata import get_model_context_length

            ctx = get_model_context_length(
                model,
                base_url=base_url or "",
                provider=provider,
            )
            if isinstance(ctx, int) and ctx > 0:
                return ctx
        except Exception:
            pass
    try:
        from agent.models_dev import lookup_models_dev_context

        ctx = lookup_models_dev_context(provider, model)
        if isinstance(ctx, int) and ctx > 0:
            return ctx
    except Exception:
        pass
    return None


class StatusHooks:
    def __init__(self, registry: SessionRegistry):
        self.registry = registry

    def callbacks(self):
        return {
            "on_session_start": self.on_session_start,
            "on_session_end": self.on_session_end,
            "on_session_finalize": self.on_session_finalize,
            "on_session_reset": self.on_session_reset,
            "pre_llm_call": self.pre_llm_call,
            "post_llm_call": self.post_llm_call,
            "pre_api_request": self.pre_api_request,
            "post_api_request": self.post_api_request,
            "api_request_error": self.api_request_error,
            "pre_tool_call": self.pre_tool_call,
            "post_tool_call": self.post_tool_call,
            "subagent_start": self.subagent_start,
            "subagent_stop": self.subagent_stop,
        }

    def _yolo_active(self, session_id: str, payload_value: Any = None) -> bool | None:
        if payload_value is not None:
            return bool(payload_value)
        try:
            from tools.approval import _YOLO_MODE_FROZEN, is_session_yolo_enabled

            if _YOLO_MODE_FROZEN:
                return True
            if session_id:
                return bool(is_session_yolo_enabled(session_id))
        except Exception:
            pass
        return None

    def on_session_start(self, **kw) -> None:
        session_id = kw.get("session_id") or ""
        self.registry.start_session(
            session_id,
            kw.get("model") or "",
            context_max=resolve_context_max(kw.get("model") or "", kw.get("provider"), kw.get("base_url")),
            yolo=self._yolo_active(session_id, kw.get("yolo")),
        )

    def on_session_end(self, **kw) -> None:
        self.registry.finish_turn(kw.get("session_id") or "")

    def on_session_finalize(self, **kw) -> None:
        self.registry.finish_turn(kw.get("session_id") or "")

    def on_session_reset(self, **kw) -> None:
        old_session_id = kw.get("old_session_id")
        new_session_id = kw.get("new_session_id") or kw.get("session_id")
        if old_session_id and old_session_id != new_session_id:
            self.registry.reset(str(old_session_id))
            return
        self.registry.reset(str(new_session_id) if new_session_id else None)

    def pre_llm_call(self, **kw) -> None:
        session_id = kw.get("session_id") or ""
        self.registry.start_turn(
            session_id,
            kw.get("model") or "",
            context_max=resolve_context_max(kw.get("model") or "", kw.get("provider"), kw.get("base_url")),
            yolo=self._yolo_active(session_id, kw.get("yolo")),
        )

    def post_llm_call(self, **kw) -> None:
        # An LLM response can be followed by tools and another LLM/API cycle.
        # The outer session lifecycle owns the current-turn boundary.
        return None

    def pre_api_request(self, **kw) -> None:
        session_id = kw.get("session_id") or ""
        if not self.registry.has_session(session_id):
            return
        approx = _positive_int(kw.get("approx_input_tokens"))
        self.registry.start_turn(
            session_id,
            kw.get("model") or "",
            context_max=resolve_context_max(kw.get("model") or "", kw.get("provider"), kw.get("base_url")),
            yolo=self._yolo_active(session_id, kw.get("yolo")),
        )
        self.registry.track_api_request_start(session_id, kw.get("api_request_id"), kw.get("turn_id"))
        self.registry.update_context(session_id, approx)

    def post_api_request(self, **kw) -> None:
        session_id = kw.get("session_id") or ""
        total_tokens = _usage_total_tokens(kw.get("usage"))
        completion = self.registry.complete_api_request(
            session_id,
            kw.get("api_request_id"),
            kw.get("turn_id"),
            total_tokens,
        )
        if completion != "accepted":
            return None
        used = _usage_prompt_tokens(kw.get("usage"))
        self.registry.update_context(
            session_id,
            used,
            context_max=resolve_context_max(kw.get("model") or "", kw.get("provider"), kw.get("base_url")),
        )
        # Public post_api_request hooks do not always include compression_count.
        # Keep the registry's explicit zero/last-known value unless Hermes
        # supplies a concrete count; never infer it from usage or lifecycle events.
        count = _positive_int(kw.get("compression_count"))
        if count is not None:
            self.registry.update_compression_count(session_id, count)

    def api_request_error(self, **kw) -> None:
        # Provider errors may contain prompts, request details, or credentials.
        # Publish only this fixed allow-listed message and retain the outer turn.
        session_id = kw.get("session_id") or ""
        self.registry.mark_api_request_error(session_id, kw.get("api_request_id"), kw.get("turn_id"))
        self.registry.set_error(session_id, PUBLIC_API_ERROR)

    def pre_tool_call(self, **kw) -> None:
        self.registry.tool_start(
            kw.get("session_id") or kw.get("task_id") or "",
            kw.get("tool_name"),
            tool_call_id=kw.get("tool_call_id"),
        )

    def post_tool_call(self, **kw) -> None:
        self.registry.tool_end(
            kw.get("session_id") or kw.get("task_id") or "",
            kw.get("tool_name"),
            tool_call_id=kw.get("tool_call_id"),
        )

    def subagent_start(self, **kw) -> None:
        self.registry.update_subagents(kw.get("parent_session_id") or "", 1)

    def subagent_stop(self, **kw) -> None:
        self.registry.update_subagents(kw.get("parent_session_id") or "", -1)
