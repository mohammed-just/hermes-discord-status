"""Loopback HTTP service for Discord status lookups."""

from __future__ import annotations

import hmac
import json
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlparse

from .routing import is_snowflake


class _LoopbackHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, server_address, handler_cls, *, registry, resolver, token: str, allowed_origins):
        super().__init__(server_address, handler_cls)
        self.registry = registry
        self.resolver = resolver
        self.token = token
        self.allowed_origins = set(allowed_origins or ())


class StatusServer:
    def __init__(self, *, registry, resolver, token: str, host: str = "127.0.0.1", port: int = 8765, allowed_origins=()):
        if host != "127.0.0.1":
            raise ValueError("StatusServer only supports 127.0.0.1 binding")
        if not token:
            raise ValueError("StatusServer requires a bearer token")
        self.host = host
        self.port = port
        self._httpd = _LoopbackHTTPServer(
            (host, port),
            _Handler,
            registry=registry,
            resolver=resolver,
            token=token,
            allowed_origins=allowed_origins,
        )
        self.port = int(self._httpd.server_address[1])
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._httpd.serve_forever, name="hermes-discord-status", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._httpd.shutdown()
        self._httpd.server_close()
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None


class _Handler(BaseHTTPRequestHandler):
    server: _LoopbackHTTPServer

    def log_message(self, fmt, *args):  # pragma: no cover - avoid stderr noise
        return

    def do_OPTIONS(self) -> None:
        if not self._origin_allowed():
            self._send_json(HTTPStatus.FORBIDDEN, {"error": "origin forbidden"})
            return
        self.send_response(HTTPStatus.NO_CONTENT)
        self._send_common_headers()
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization")
        self.end_headers()

    def do_GET(self) -> None:
        if not self._origin_allowed():
            self._send_json(HTTPStatus.FORBIDDEN, {"error": "origin forbidden"})
            return

        parsed = urlparse(self.path)
        if parsed.path == "/v1/health":
            if not self._authorized():
                self._send_json(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
                return
            self._send_json(HTTPStatus.OK, {"ok": True})
            return

        prefix = "/v1/status/discord/"
        if parsed.path.startswith(prefix):
            if not self._authorized():
                self._send_json(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
                return
            channel_id = parsed.path[len(prefix) :]
            if "/" in channel_id or not is_snowflake(channel_id):
                self._send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid discord snowflake"})
                return
            self.server.registry.cleanup_stale()
            session_id = self.server.resolver.resolve(channel_id)
            if not session_id:
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "route not found"})
                return
            state = self.server.registry.get(session_id)
            if state is None:
                # Historic Discord routes survive gateway restarts, while live
                # hook state is intentionally in-memory. Return a neutral,
                # non-sensitive idle snapshot without seeding the registry;
                # the next real turn must establish the actual session timer.
                now = time.time()
                state = {
                    "schema_version": 1,
                    "session_id": session_id,
                    "model": "Hermes",
                    "context_used": None,
                    "context_max": None,
                    "context_percent": None,
                    "session_started_at": now,
                    "turn_started_at": None,
                    "busy": False,
                    "active_tool": None,
                    "tool_calls": 0,
                    "active_tool_calls": 0,
                    "compression_count": 0,
                    "active_subagents": 0,
                    "yolo": False,
                    "updated_at": now,
                    "error": None,
                }
            self._send_json(HTTPStatus.OK, state)
            return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def _authorized(self) -> bool:
        expected = f"Bearer {self.server.token}"
        actual = self.headers.get("Authorization") or ""
        return hmac.compare_digest(actual, expected)

    def _origin_allowed(self) -> bool:
        origin = self.headers.get("Origin")
        return origin is None or origin in self.server.allowed_origins

    def _send_common_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Type", "application/json")
        origin = self.headers.get("Origin")
        if origin in self.server.allowed_origins:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")

    def _send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
        self.send_response(int(status))
        self._send_common_headers()
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
