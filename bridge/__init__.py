"""Hermes Discord status plugin entry point."""

from .config import PluginConfig
from .hooks import StatusHooks
from .registry import SessionRegistry
from .routing import DiscordRouteResolver
from .server import StatusServer

_registry = SessionRegistry()
_server = None


def register(ctx):
    """Register Hermes hooks and start the optional loopback HTTP service."""
    global _server

    cfg = PluginConfig.from_environment()
    hooks = StatusHooks(_registry)
    for name, callback in hooks.callbacks().items():
        ctx.register_hook(name, callback)

    if cfg.enabled:
        resolver = DiscordRouteResolver()
        _server = StatusServer(
            registry=_registry,
            resolver=resolver,
            token=cfg.token,
            host=cfg.host,
            port=cfg.port,
            allowed_origins=cfg.allowed_origins,
        )
        _server.start()


def shutdown():
    """Test/helper shutdown hook; Hermes may unload by process exit."""
    global _server
    if _server is not None:
        _server.stop()
        _server = None
