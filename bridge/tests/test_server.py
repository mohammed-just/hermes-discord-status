import importlib.util
import json
import sys
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen


def load_plugin_package():
    root = Path(__file__).resolve().parents[1]
    name = "discord_status_testpkg"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(
        name,
        root / "__init__.py",
        submodule_search_locations=[str(root)],
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


pkg = load_plugin_package()
registry_mod = __import__(pkg.__name__ + ".registry", fromlist=["SessionRegistry"])
server_mod = __import__(pkg.__name__ + ".server", fromlist=["StatusServer"])
config_mod = __import__(pkg.__name__ + ".config", fromlist=["validate_port"])
SessionRegistry = registry_mod.SessionRegistry
StatusServer = server_mod.StatusServer
validate_port = config_mod.validate_port


class Resolver:
    def __init__(self, session_id="s1"):
        self.session_id = session_id

    def resolve(self, channel_id):
        return self.session_id


class CountingResolver:
    def __init__(self):
        self.calls = 0

    def resolve(self, channel_id):
        self.calls += 1
        return None


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.registry = SessionRegistry()
        self.registry.start_session("s1", "model")
        self.registry.update_context("s1", 10, context_max=100)
        self.server = StatusServer(
            registry=self.registry,
            resolver=Resolver(),
            token="secret",
            port=0,
            allowed_origins=("https://discord.com",),
        )
        self.server.start()
        self.base = f"http://127.0.0.1:{self.server.port}"

    def tearDown(self):
        self.server.stop()

    def request(self, path, token="secret", origin=None):
        headers = {}
        if token is not None:
            headers["Authorization"] = f"Bearer {token}"
        if origin:
            headers["Origin"] = origin
        req = Request(self.base + path, headers=headers)
        with urlopen(req, timeout=2) as resp:
            return resp.status, dict(resp.headers), json.loads(resp.read().decode("utf-8"))

    def test_health_requires_auth_and_no_store(self):
        status, headers, body = self.request("/v1/health")
        self.assertEqual(status, 200)
        self.assertEqual(body, {"ok": True})
        self.assertEqual(headers.get("Cache-Control"), "no-store")

        with self.assertRaises(HTTPError) as ctx:
            self.request("/v1/health", token=None)
        self.assertEqual(ctx.exception.code, 401)

    def test_status_success_and_cors(self):
        status, headers, body = self.request(
            "/v1/status/discord/12345678901234567",
            origin="https://discord.com",
        )
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Access-Control-Allow-Origin"), "https://discord.com")
        self.assertEqual(body["session_id"], "s1")
        self.assertEqual(body["context_used"], 10)
        self.assertEqual(body["compression_count"], 0)
        self.assertEqual(body["active_subagents"], 0)
        self.assertNotIn("active_background_subagents", body)
        self.assertFalse(body["yolo"])
        self.assertNotIn("assistant_response", body)
        self.assertNotIn("user_message", body)

    def test_known_route_without_live_turn_returns_idle_status(self):
        self.registry.reset("s1")
        status, _, body = self.request("/v1/status/discord/12345678901234567")
        self.assertEqual(status, 200)
        self.assertEqual(body["session_id"], "s1")
        self.assertEqual(body["model"], "Hermes")
        self.assertFalse(body["busy"])
        self.assertIsNone(body["context_used"])
        self.assertIsNone(body["total_processed_tokens"])
        self.assertEqual(body["compression_count"], 0)
        self.assertEqual(body["active_subagents"], 0)
        self.assertNotIn("active_background_subagents", body)
        self.assertFalse(body["yolo"])
        self.assertIsNone(self.registry.get("s1"))

    def test_rejects_invalid_snowflake(self):
        with self.assertRaises(HTTPError) as ctx:
            self.request("/v1/status/discord/not-a-snowflake")
        self.assertEqual(ctx.exception.code, 400)

    def test_rejects_forbidden_origin_preflight(self):
        req = Request(
            self.base + "/v1/status/discord/12345678901234567",
            method="OPTIONS",
            headers={"Origin": "https://evil.example"},
        )
        with self.assertRaises(HTTPError) as ctx:
            urlopen(req, timeout=2)
        self.assertEqual(ctx.exception.code, 403)

    def test_rejects_forbidden_origin_get(self):
        with self.assertRaises(HTTPError) as ctx:
            self.request("/v1/status/discord/12345678901234567", origin="https://evil.example")
        self.assertEqual(ctx.exception.code, 403)

    def test_non_loopback_bind_rejected(self):
        with self.assertRaises(ValueError):
            StatusServer(registry=self.registry, resolver=Resolver(), token="secret", host="0.0.0.0")

    def test_stale_cleanup_runs_even_when_route_resolution_fails(self):
        self.server.stop()
        clock_value = [1000.0]
        registry = SessionRegistry(stale_after_seconds=10, clock=lambda: clock_value[0])
        registry.start_session("stale", "model")
        clock_value[0] += 11
        resolver = CountingResolver()
        server = StatusServer(registry=registry, resolver=resolver, token="secret", port=0)
        server.start()
        self.server = server
        self.base = f"http://127.0.0.1:{server.port}"

        with self.assertRaises(HTTPError) as ctx:
            self.request("/v1/status/discord/12345678901234567")

        self.assertEqual(ctx.exception.code, 404)
        self.assertEqual(resolver.calls, 1)
        self.assertIsNone(registry.get("stale"))

    def test_validate_port_accepts_tcp_range_and_ephemeral_zero(self):
        self.assertEqual(validate_port("0"), 0)
        self.assertEqual(validate_port("8765"), 8765)

    def test_validate_port_rejects_invalid_values(self):
        for value in ("", "abc", "-1", "65536", "1.5"):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    validate_port(value)


if __name__ == "__main__":
    unittest.main()
