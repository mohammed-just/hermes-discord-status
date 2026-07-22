import importlib.util
import sys
import unittest
from pathlib import Path


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
SessionRegistry = __import__(pkg.__name__ + ".registry", fromlist=["SessionRegistry"]).SessionRegistry
StatusHooks = __import__(pkg.__name__ + ".hooks", fromlist=["StatusHooks"]).StatusHooks
MAX_SAFE_WIRE_INTEGER = 2**53 - 1


class FakeClock:
    def __init__(self, value=1000.0):
        self.value = value

    def __call__(self):
        return self.value


class RegistryTests(unittest.TestCase):
    def test_schema_and_latest_prompt_usage_only(self):
        clock = FakeClock()
        registry = SessionRegistry(clock=clock)
        hooks = StatusHooks(registry)

        hooks.on_session_start(session_id="s1", model="m1")
        hooks.pre_api_request(session_id="s1", model="m1", approx_input_tokens=100, api_request_id="r1", turn_id="t1")
        hooks.post_api_request(
            session_id="s1",
            model="m1",
            api_request_id="r1",
            turn_id="t1",
            usage={"prompt_tokens": 123, "completion_tokens": 50, "total_tokens": 173},
        )

        state = registry.get("s1")
        self.assertEqual(
            set(state),
            {
                "schema_version",
                "session_id",
                "model",
                "context_used",
                "context_max",
                "context_percent",
                "total_processed_tokens",
                "session_started_at",
                "turn_started_at",
                "busy",
                "active_tool",
                "tool_calls",
                "active_tool_calls",
                "compression_count",
                "active_subagents",
                "yolo",
                "updated_at",
                "error",
            },
        )
        self.assertEqual(state["schema_version"], 1)
        self.assertEqual(state["context_used"], 123)
        self.assertEqual(state["total_processed_tokens"], 173)
        self.assertEqual(state["compression_count"], 0)
        self.assertEqual(state["active_subagents"], 0)
        self.assertFalse(state["yolo"])
        self.assertIsNone(state["context_max"])
        self.assertIsNone(state["context_percent"])
        self.assertIsInstance(state["session_started_at"], float)
        self.assertIsInstance(state["turn_started_at"], float)
        self.assertIsInstance(state["updated_at"], float)
        self.assertTrue(state["busy"])

    def test_safe_tool_transitions(self):
        registry = SessionRegistry(clock=FakeClock())
        registry.start_session("s1", "m1", context_max=1000)
        self.assertIsNone(registry.get("s1")["total_processed_tokens"])
        registry.update_context("s1", 250)
        registry.tool_start("s1", "shell_exec")
        state = registry.get("s1")
        self.assertTrue(state["busy"])
        self.assertEqual(state["active_tool"], "shell_exec")
        self.assertEqual(state["tool_calls"], 1)
        self.assertEqual(state["active_tool_calls"], 1)
        self.assertEqual(state["context_percent"], 25.0)

        registry.tool_end("s1", "shell_exec")
        registry.finish_turn("s1")
        state = registry.get("s1")
        self.assertFalse(state["busy"])
        self.assertIsNone(state["active_tool"])
        self.assertEqual(state["active_tool_calls"], 0)
        self.assertIsNone(state["turn_started_at"])

    def test_overlapping_tool_calls_use_stable_ids_and_duplicate_names(self):
        registry = SessionRegistry(clock=FakeClock())
        registry.start_session("s1", "m1")

        registry.tool_start("s1", "shell_exec", tool_call_id="call-a")
        registry.tool_start("s1", "shell_exec", tool_call_id="call-b")
        registry.tool_start("s1", "read_file", tool_call_id="call-c")
        self.assertEqual(registry.get("s1")["active_tool_calls"], 3)

        registry.tool_end("s1", "shell_exec", tool_call_id="call-a")
        state = registry.get("s1")
        self.assertEqual(state["active_tool_calls"], 2)
        self.assertIn(state["active_tool"], {"shell_exec", "read_file"})

        registry.tool_end("s1", "shell_exec", tool_call_id="call-b")
        state = registry.get("s1")
        self.assertEqual(state["active_tool_calls"], 1)
        self.assertEqual(state["active_tool"], "read_file")

    def test_missing_tool_ids_do_not_collide(self):
        registry = SessionRegistry(clock=FakeClock())
        registry.start_session("s1", "m1")

        registry.tool_start("s1", "dup")
        registry.tool_start("s1", "dup")
        self.assertEqual(registry.get("s1")["active_tool_calls"], 2)

        registry.tool_end("s1", "dup")
        state = registry.get("s1")
        self.assertEqual(state["active_tool_calls"], 1)
        self.assertEqual(state["active_tool"], "dup")

    def test_context_percent_clamped(self):
        registry = SessionRegistry(clock=FakeClock())
        registry.start_session("s1", "m1", context_max=100)
        registry.update_context("s1", 150)
        self.assertEqual(registry.get("s1")["context_percent"], 100.0)

        registry.update_context("s1", 50, context_max=100)
        self.assertEqual(registry.get("s1")["context_percent"], 50.0)

    def test_session_reset_removes_old_session_when_payload_has_old_and_new_ids(self):
        registry = SessionRegistry(clock=FakeClock())
        hooks = StatusHooks(registry)
        registry.start_session("old", "m1")
        registry.start_session("new", "m1")

        hooks.on_session_reset(session_id="new", old_session_id="old", new_session_id="new")

        self.assertIsNone(registry.get("old"))
        self.assertIsNotNone(registry.get("new"))

    def test_session_reset_legacy_payload_removes_session_id(self):
        registry = SessionRegistry(clock=FakeClock())
        hooks = StatusHooks(registry)
        registry.start_session("legacy", "m1")

        hooks.on_session_reset(session_id="legacy")

        self.assertIsNone(registry.get("legacy"))

    def test_stale_cleanup(self):
        clock = FakeClock()
        registry = SessionRegistry(stale_after_seconds=10, clock=clock)
        registry.start_session("old", "m")
        clock.value += 11
        registry.start_session("new", "m")
        self.assertEqual(registry.cleanup_stale(), 1)
        self.assertIsNone(registry.get("old"))
        self.assertIsNotNone(registry.get("new"))

    def test_registry_growth_is_bounded_by_oldest_update(self):
        clock = FakeClock()
        registry = SessionRegistry(max_sessions=2, clock=clock)
        registry.start_session("oldest", "m")
        clock.value += 1
        registry.start_session("middle", "m")
        clock.value += 1
        registry.start_session("newest", "m")

        self.assertIsNone(registry.get("oldest"))
        self.assertIsNotNone(registry.get("middle"))
        self.assertIsNotNone(registry.get("newest"))

    def test_missing_session_start_turn_does_not_create_or_trim(self):
        clock = FakeClock(1000.0)
        registry = SessionRegistry(max_sessions=1, clock=clock)
        registry.start_session("existing", "m")
        clock.value = 999.0

        registry.start_turn("new", "m")

        self.assertIsNotNone(registry.get("existing"))
        self.assertIsNone(registry.get("new"))

    def test_missing_session_update_context_does_not_create_or_trim(self):
        clock = FakeClock(1000.0)
        registry = SessionRegistry(max_sessions=1, clock=clock)
        registry.start_session("existing", "m")
        clock.value = 999.0

        registry.update_context("new", 5)

        self.assertIsNotNone(registry.get("existing"))
        self.assertIsNone(registry.get("new"))

    def test_missing_session_registry_mutators_do_not_create_state(self):
        registry = SessionRegistry(clock=FakeClock())

        registry.tool_start("missing", "shell_exec", tool_call_id="tool-1")
        registry.update_compression_count("missing", 1)
        registry.update_compression_count("missing", increment=1)
        registry.update_subagents("missing", 1)
        registry.update_background_subagents("missing", 1)
        registry.set_yolo("missing", True)

        self.assertIsNone(registry.get("missing"))

    def test_total_processed_tokens_accumulates_only_matched_current_requests(self):
        registry = SessionRegistry(clock=FakeClock())
        hooks = StatusHooks(registry)
        hooks.on_session_start(session_id="s1", model="m1")

        hooks.pre_api_request(session_id="s1", model="m1", api_request_id="r1", turn_id="t1")
        hooks.post_api_request(session_id="s1", model="m1", api_request_id="r1", turn_id="t1", usage={"total_tokens": 173})
        hooks.pre_api_request(session_id="s1", model="m1", api_request_id="r2", turn_id="t1")
        hooks.post_api_request(session_id="s1", model="m1", api_request_id="r2", turn_id="t1", usage={"total_tokens": 25})

        self.assertEqual(registry.get("s1")["total_processed_tokens"], 198)

    def test_duplicate_completed_api_request_does_not_double_count(self):
        registry = SessionRegistry(clock=FakeClock())
        hooks = StatusHooks(registry)
        hooks.on_session_start(session_id="s1", model="m1")

        hooks.pre_api_request(session_id="s1", model="m1", api_request_id="r1", turn_id="t1")
        hooks.post_api_request(session_id="s1", model="m1", api_request_id="r1", turn_id="t1", usage={"total_tokens": 173})
        hooks.post_api_request(session_id="s1", model="m1", api_request_id="r1", turn_id="t1", usage={"total_tokens": 173})

        self.assertEqual(registry.get("s1")["total_processed_tokens"], 173)

    def test_reset_clears_memory_and_late_pre_post_do_not_recreate_state(self):
        registry = SessionRegistry(clock=FakeClock())
        hooks = StatusHooks(registry)
        hooks.on_session_start(session_id="s1", model="m1")
        hooks.pre_api_request(session_id="s1", model="m1", api_request_id="r1", turn_id="t1")

        hooks.on_session_reset(session_id="s1")
        hooks.pre_api_request(session_id="s1", model="m1", api_request_id="late", turn_id="t1")
        hooks.post_api_request(session_id="s1", model="m1", api_request_id="r1", turn_id="t1", usage={"total_tokens": 173})

        self.assertIsNone(registry.get("s1"))

        hooks.on_session_start(session_id="s1", model="m1")
        self.assertIsNone(registry.get("s1")["total_processed_tokens"])
        hooks.pre_api_request(session_id="s1", model="m1", api_request_id="r2", turn_id="t2")
        hooks.post_api_request(session_id="s1", model="m1", api_request_id="r2", turn_id="t2", usage={"total_tokens": 25})

        self.assertEqual(registry.get("s1")["total_processed_tokens"], 25)

    def test_unmatched_completion_marks_lifecycle_unknown_until_new_session_start(self):
        registry = SessionRegistry(clock=FakeClock())
        hooks = StatusHooks(registry)
        hooks.on_session_start(session_id="s1", model="m1")
        hooks.pre_api_request(session_id="s1", model="m1", api_request_id="r1", turn_id="t1")
        hooks.post_api_request(session_id="s1", model="m1", api_request_id="r1", turn_id="t1", usage={"total_tokens": 173})

        hooks.post_api_request(session_id="s1", model="m1", api_request_id="missing", turn_id="t1", usage={"total_tokens": 25})
        hooks.pre_api_request(session_id="s1", model="m1", api_request_id="r2", turn_id="t1")
        hooks.post_api_request(session_id="s1", model="m1", api_request_id="r2", turn_id="t1", usage={"total_tokens": 25})

        self.assertIsNone(registry.get("s1")["total_processed_tokens"])

        hooks.on_session_start(session_id="s1", model="m1")
        hooks.pre_api_request(session_id="s1", model="m1", api_request_id="r3", turn_id="t2")
        hooks.post_api_request(session_id="s1", model="m1", api_request_id="r3", turn_id="t2", usage={"total_tokens": 10})

        self.assertEqual(registry.get("s1")["total_processed_tokens"], 10)

    def test_api_request_identity_match_is_exact_without_whitespace_normalization(self):
        registry = SessionRegistry(clock=FakeClock())
        hooks = StatusHooks(registry)

        hooks.on_session_start(session_id="s1", model="m1")
        hooks.pre_api_request(session_id="s1", model="m1", api_request_id=" r1 ", turn_id=" t1 ")
        hooks.post_api_request(session_id="s1", model="m1", api_request_id="r1", turn_id="t1", usage={"total_tokens": 7})
        self.assertIsNone(registry.get("s1")["total_processed_tokens"])

        hooks.on_session_start(session_id="s1", model="m1")
        hooks.pre_api_request(session_id="s1", model="m1", api_request_id="r2", turn_id="t2")
        hooks.post_api_request(session_id="s1", model="m1", api_request_id=" r2 ", turn_id=" t2 ", usage={"total_tokens": 7})
        self.assertIsNone(registry.get("s1")["total_processed_tokens"])

    def test_invalid_pre_request_identity_marks_existing_lifecycle_unknown(self):
        registry = SessionRegistry(clock=FakeClock())
        hooks = StatusHooks(registry)
        hooks.on_session_start(session_id="s1", model="m1")
        hooks.pre_api_request(session_id="s1", model="m1", api_request_id="r1", turn_id="t1")
        hooks.post_api_request(session_id="s1", model="m1", api_request_id="r1", turn_id="t1", usage={"total_tokens": 10})

        for api_request_id, turn_id in (("", "t2"), ("  ", "t2"), ("r2", ""), ("r2", "  "), (0, "t2"), ("r2", 0), (False, "t2"), ("r2", False)):
            hooks.pre_api_request(session_id="s1", model="m1", api_request_id=api_request_id, turn_id=turn_id)
            self.assertIsNone(registry.get("s1")["total_processed_tokens"])
            hooks.on_session_start(session_id="s1", model="m1")
            hooks.pre_api_request(session_id="s1", model="m1", api_request_id="seed", turn_id="turn")
            hooks.post_api_request(session_id="s1", model="m1", api_request_id="seed", turn_id="turn", usage={"total_tokens": 10})

    def test_invalid_and_unmatched_completion_identities_mark_existing_lifecycle_unknown(self):
        registry = SessionRegistry(clock=FakeClock())
        hooks = StatusHooks(registry)
        hooks.on_session_start(session_id="s1", model="m1")
        hooks.pre_api_request(session_id="s1", model="m1", api_request_id="seed", turn_id="turn")
        hooks.post_api_request(session_id="s1", model="m1", api_request_id="seed", turn_id="turn", usage={"total_tokens": 10})

        for api_request_id, turn_id in ((None, "t1"), ("r1", None), (0, "t1"), ("r1", 0), (False, "t1"), ("r1", False), ("missing", "turn")):
            hooks.post_api_request(session_id="s1", model="m1", api_request_id=api_request_id, turn_id=turn_id, usage={"total_tokens": 5})
            self.assertIsNone(registry.get("s1")["total_processed_tokens"])
            hooks.on_session_start(session_id="s1", model="m1")
            hooks.pre_api_request(session_id="s1", model="m1", api_request_id="seed", turn_id="turn")
            hooks.post_api_request(session_id="s1", model="m1", api_request_id="seed", turn_id="turn", usage={"total_tokens": 10})

    def test_invalid_and_unmatched_error_identities_mark_existing_lifecycle_unknown(self):
        registry = SessionRegistry(clock=FakeClock())
        hooks = StatusHooks(registry)
        hooks.on_session_start(session_id="s1", model="m1")
        hooks.pre_api_request(session_id="s1", model="m1", api_request_id="seed", turn_id="turn")
        hooks.post_api_request(session_id="s1", model="m1", api_request_id="seed", turn_id="turn", usage={"total_tokens": 10})

        for api_request_id, turn_id in ((None, "t1"), ("r1", None), (0, "t1"), ("r1", 0), (False, "t1"), ("r1", False), ("missing", "turn")):
            hooks.api_request_error(session_id="s1", api_request_id=api_request_id, turn_id=turn_id)
            self.assertIsNone(registry.get("s1")["total_processed_tokens"])
            hooks.on_session_start(session_id="s1", model="m1")
            hooks.pre_api_request(session_id="s1", model="m1", api_request_id="seed", turn_id="turn")
            hooks.post_api_request(session_id="s1", model="m1", api_request_id="seed", turn_id="turn", usage={"total_tokens": 10})

    def test_pending_api_request_capacity_marks_unknown_without_retaining_overflow(self):
        registry = SessionRegistry(clock=FakeClock(), max_pending_api_requests=1)
        hooks = StatusHooks(registry)
        hooks.on_session_start(session_id="s1", model="m1")

        hooks.pre_api_request(session_id="s1", model="m1", api_request_id="r1", turn_id="t1")
        hooks.pre_api_request(session_id="s1", model="m1", api_request_id="r2", turn_id="t1")

        self.assertIsNone(registry.get("s1")["total_processed_tokens"])
        self.assertEqual(len(registry._pending_api_requests["s1"]), 1)
        self.assertNotIn(("r2", "t1"), registry._pending_api_requests["s1"])

    def test_completed_api_request_capacity_marks_unknown_without_evicting_retained_duplicates(self):
        registry = SessionRegistry(clock=FakeClock(), max_completed_api_requests=1)
        hooks = StatusHooks(registry)
        hooks.on_session_start(session_id="s1", model="m1")

        hooks.pre_api_request(session_id="s1", model="m1", api_request_id="r1", turn_id="t1")
        hooks.post_api_request(session_id="s1", model="m1", api_request_id="r1", turn_id="t1", usage={"total_tokens": 10})
        hooks.post_api_request(session_id="s1", model="m1", api_request_id="r1", turn_id="t1", usage={"total_tokens": 10})
        self.assertEqual(registry.get("s1")["total_processed_tokens"], 10)

        hooks.pre_api_request(session_id="s1", model="m1", api_request_id="r2", turn_id="t1")
        hooks.post_api_request(session_id="s1", model="m1", api_request_id="r2", turn_id="t1", usage={"total_tokens": 5})
        self.assertIsNone(registry.get("s1")["total_processed_tokens"])

        hooks.post_api_request(session_id="s1", model="m1", api_request_id="r2", turn_id="t1", usage={"total_tokens": 5})
        self.assertIsNone(registry.get("s1")["total_processed_tokens"])

    def test_invalid_total_and_error_for_matching_pending_request_mark_unknown(self):
        registry = SessionRegistry(clock=FakeClock())
        hooks = StatusHooks(registry)
        hooks.on_session_start(session_id="s1", model="m1")
        hooks.pre_api_request(session_id="s1", model="m1", api_request_id="r1", turn_id="t1")
        hooks.post_api_request(session_id="s1", model="m1", api_request_id="r1", turn_id="t1", usage={"total_tokens": 25})
        hooks.pre_api_request(session_id="s1", model="m1", api_request_id="bad", turn_id="t1")
        hooks.post_api_request(session_id="s1", model="m1", api_request_id="bad", turn_id="t1", usage={"total_tokens": "26"})

        self.assertIsNone(registry.get("s1")["total_processed_tokens"])

        hooks.on_session_start(session_id="s2", model="m1")
        hooks.pre_api_request(session_id="s2", model="m1", api_request_id="err", turn_id="t1")
        hooks.api_request_error(session_id="s2", api_request_id="err", turn_id="t1", error={"message": "boom"})

        self.assertIsNone(registry.get("s2")["total_processed_tokens"])

    def test_total_processed_tokens_wire_overflow_marks_unknown(self):
        registry = SessionRegistry(clock=FakeClock())
        hooks = StatusHooks(registry)
        hooks.on_session_start(session_id="s1", model="m1")
        hooks.pre_api_request(session_id="s1", model="m1", api_request_id="r1", turn_id="t1")
        hooks.post_api_request(
            session_id="s1",
            model="m1",
            api_request_id="r1",
            turn_id="t1",
            usage={"total_tokens": MAX_SAFE_WIRE_INTEGER - 5},
        )
        hooks.pre_api_request(session_id="s1", model="m1", api_request_id="r2", turn_id="t1")
        hooks.post_api_request(session_id="s1", model="m1", api_request_id="r2", turn_id="t1", usage={"total_tokens": 6})

        self.assertIsNone(registry.get("s1")["total_processed_tokens"])


if __name__ == "__main__":
    unittest.main()
