"""Configuration for the Discord status plugin."""

from __future__ import annotations

import os
from dataclasses import dataclass


def _truthy(value: str | None) -> bool:
    return str(value or "").strip().lower() in {"1", "true", "yes", "on"}


def validate_port(value: object) -> int:
    """Return a TCP port number, accepting 0 for OS-assigned test ports."""
    try:
        text = str(value).strip()
        if not text or any(ch not in "0123456789" for ch in text):
            raise ValueError
        port = int(text)
    except (TypeError, ValueError):
        raise ValueError("Hermes Discord status port must be an integer from 0 to 65535") from None
    if port < 0 or port > 65535:
        raise ValueError("Hermes Discord status port must be between 0 and 65535")
    return port


def _port_from_env_or_config(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None:
        raw = default
    return validate_port(raw)


def _config_get(*path: str, default=None):
    try:
        from hermes_cli.config import cfg_get, load_config

        return cfg_get(load_config() or {}, *path, default=default)
    except Exception:
        return default


@dataclass(frozen=True)
class PluginConfig:
    enabled: bool
    token: str
    host: str = "127.0.0.1"
    port: int = 8765
    allowed_origins: tuple[str, ...] = ("https://discord.com", "https://canary.discord.com", "https://ptb.discord.com")

    @classmethod
    def from_environment(cls) -> "PluginConfig":
        token = (
            os.getenv("HERMES_DISCORD_STATUS_TOKEN")
            or _config_get("plugins", "entries", "discord-status", "token", default="")
            or ""
        ).strip()
        explicit_enabled = os.getenv("HERMES_DISCORD_STATUS_ENABLED")
        enabled = _truthy(explicit_enabled) if explicit_enabled is not None else bool(token)
        port = _port_from_env_or_config(
            "HERMES_DISCORD_STATUS_PORT",
            _config_get("plugins", "entries", "discord-status", "port", default=8765) or 8765,
        )
        origins = os.getenv("HERMES_DISCORD_STATUS_ALLOWED_ORIGINS")
        if origins:
            allowed = tuple(o.strip() for o in origins.split(",") if o.strip())
        else:
            configured = _config_get(
                "plugins", "entries", "discord-status", "allowed_origins", default=None
            )
            allowed = tuple(configured) if isinstance(configured, list) else cls.allowed_origins
        return cls(enabled=enabled and bool(token), token=token, port=port, allowed_origins=allowed)
