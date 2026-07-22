import importlib.util
import json
import sys
import time
import types
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory


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
routing = __import__(pkg.__name__ + ".routing", fromlist=["DiscordRouteResolver", "is_snowflake"])
DiscordRouteResolver = routing.DiscordRouteResolver
is_snowflake = routing.is_snowflake


class RoutingTests(unittest.TestCase):
    def test_snowflake_validation(self):
        self.assertTrue(is_snowflake("12345678901234567"))
        self.assertFalse(is_snowflake("01234567890123456"))
        self.assertFalse(is_snowflake("abc"))
        self.assertFalse(is_snowflake("123/45678901234567"))

    def test_sessions_json_fallback_resolves_thread(self):
        with TemporaryDirectory() as td:
            home = Path(td)
            sessions = home / "sessions"
            sessions.mkdir()
            (sessions / "sessions.json").write_text(
                json.dumps(
                    {
                        "agent:main:discord:thread:12345678901234567": {
                            "session_id": "session-db-id",
                            "platform": "discord",
                            "origin": {
                                "platform": "discord",
                                "chat_id": "22345678901234567",
                                "thread_id": "12345678901234567",
                            },
                            "updated_at": "2999-01-01T00:00:00Z",
                        },
                        "_README": "ignored",
                    }
                ),
                encoding="utf-8",
            )
            resolver = DiscordRouteResolver(hermes_home=home)
            self.assertEqual(resolver.resolve("12345678901234567"), "session-db-id")

    def test_state_db_rows_use_id_as_session_identifier(self):
        class FakeDB:
            def list_gateway_sessions(self, active_only=True):
                return [
                    {
                        "id": "canonical-db-session",
                        "source": "discord",
                        "chat_id": "12345678901234567",
                        "thread_id": "12345678901234567",
                        "origin_json": json.dumps(
                            {
                                "platform": "discord",
                                "chat_id": "12345678901234567",
                                "thread_id": "12345678901234567",
                            }
                        ),
                        "last_active": time.time(),
                    }
                ]

            def close(self):
                pass

        original = sys.modules.get("hermes_state")
        sys.modules["hermes_state"] = types.SimpleNamespace(SessionDB=FakeDB)
        try:
            with TemporaryDirectory() as td:
                resolver = DiscordRouteResolver(hermes_home=Path(td))
                self.assertEqual(
                    resolver.resolve("12345678901234567"),
                    "canonical-db-session",
                )
        finally:
            if original is None:
                sys.modules.pop("hermes_state", None)
            else:
                sys.modules["hermes_state"] = original

    def test_parent_channel_does_not_resolve_child_thread_session(self):
        with TemporaryDirectory() as td:
            home = Path(td)
            sessions = home / "sessions"
            sessions.mkdir()
            (sessions / "sessions.json").write_text(
                json.dumps(
                    {
                        "old-parent": {
                            "session_id": "old-parent-session",
                            "platform": "discord",
                            "origin": {
                                "platform": "discord",
                                "chat_id": "12345678901234567",
                            },
                            "updated_at": "2999-01-01T00:00:00Z",
                        },
                        "new-child": {
                            "session_id": "new-child-session",
                            "platform": "discord",
                            "origin": {
                                "platform": "discord",
                                "chat_id": "22345678901234567",
                                "thread_id": "22345678901234567",
                                "parent_chat_id": "12345678901234567",
                            },
                            "updated_at": "2999-01-02T00:00:00Z",
                        },
                    }
                ),
                encoding="utf-8",
            )
            resolver = DiscordRouteResolver(hermes_home=home)
            self.assertEqual(resolver.resolve("12345678901234567"), "old-parent-session")
            self.assertEqual(resolver.resolve("22345678901234567"), "new-child-session")

    def test_thread_route_never_matches_parent_chat_id_when_parent_has_no_entry(self):
        with TemporaryDirectory() as td:
            home = Path(td)
            sessions = home / "sessions"
            sessions.mkdir()
            (sessions / "sessions.json").write_text(
                json.dumps(
                    {
                        "child": {
                            "session_id": "child-session",
                            "platform": "discord",
                            "origin": {
                                "platform": "discord",
                                "chat_id": "12345678901234567",
                                "thread_id": "22345678901234567",
                            },
                            "updated_at": "2999-01-01T00:00:00Z",
                        },
                    }
                ),
                encoding="utf-8",
            )
            resolver = DiscordRouteResolver(hermes_home=home)
            self.assertIsNone(resolver.resolve("12345678901234567"))
            self.assertEqual(resolver.resolve("22345678901234567"), "child-session")

    def test_prefers_newest_exact_db_route_before_json_fallback(self):
        class FakeDB:
            def list_gateway_sessions(self, active_only=True):
                return [
                    {
                        "session_id": "older-db",
                        "platform": "discord",
                        "origin": {"platform": "discord", "chat_id": "12345678901234567"},
                        "updated_at": "2999-01-01T00:00:00Z",
                    },
                    {
                        "session_id": "newer-db",
                        "platform": "discord",
                        "origin": {"platform": "discord", "chat_id": "12345678901234567"},
                        "updated_at": "2999-01-02T00:00:00Z",
                    },
                ]

            def close(self):
                pass

        original = sys.modules.get("hermes_state")
        sys.modules["hermes_state"] = types.SimpleNamespace(SessionDB=FakeDB)
        try:
            with TemporaryDirectory() as td:
                home = Path(td)
                sessions = home / "sessions"
                sessions.mkdir()
                (sessions / "sessions.json").write_text(
                    json.dumps(
                        {
                            "json": {
                                "session_id": "json-newest",
                                "platform": "discord",
                                "origin": {"platform": "discord", "chat_id": "12345678901234567"},
                                "updated_at": 300,
                            }
                        }
                    ),
                    encoding="utf-8",
                )
                resolver = DiscordRouteResolver(hermes_home=home)
                self.assertEqual(resolver.resolve("12345678901234567"), "newer-db")
        finally:
            if original is None:
                sys.modules.pop("hermes_state", None)
            else:
                sys.modules["hermes_state"] = original

    def test_rejects_stale_and_malformed_routes(self):
        with TemporaryDirectory() as td:
            home = Path(td)
            sessions = home / "sessions"
            sessions.mkdir()
            stale = time.time() - 1000
            (sessions / "sessions.json").write_text(
                json.dumps(
                    {
                        "stale": {
                            "session_id": "stale-session",
                            "platform": "discord",
                            "origin": {"platform": "discord", "chat_id": "12345678901234567"},
                            "last_active": stale,
                        },
                        "malformed": {
                            "session_id": "bad-session",
                            "platform": "discord",
                            "origin": {"platform": "discord", "chat_id": "12345678901234567", "thread_id": "not-a-snowflake"},
                            "updated_at": "2999-01-01T00:00:00Z",
                        },
                    }
                ),
                encoding="utf-8",
            )
            resolver = DiscordRouteResolver(route_ttl_seconds=10, hermes_home=home)
            self.assertIsNone(resolver.resolve("12345678901234567"))


if __name__ == "__main__":
    unittest.main()
