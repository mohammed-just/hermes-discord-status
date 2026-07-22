import importlib
import importlib.util
import sys
import unittest
from pathlib import Path


def load_plugin_modules():
    root = Path(__file__).resolve().parents[1]
    name = "discord_status_hooks_testpkg"
    spec = importlib.util.spec_from_file_location(
        name,
        root / "__init__.py",
        submodule_search_locations=[str(root)],
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    hooks_module = __import__(name + ".hooks", fromlist=["StatusHooks"])
    registry_module = __import__(name + ".registry", fromlist=["SessionRegistry"])
    return hooks_module, registry_module.SessionRegistry


hooks, SessionRegistry = load_plugin_modules()
MAX_SAFE_WIRE_INTEGER = 2**53 - 1


class FakeClock:
    def __init__(self, value=1000.0):
        self.value = value

    def __call__(self):
        return self.value


class HookTests(unittest.TestCase):
    def test_codex_oauth_context_uses_hermes_canonical_limit(self):
        try:
            importlib.import_module("agent.model_metadata")
        except ImportError:
            self.skipTest("Hermes source is unavailable; canonical context resolver cannot be asserted")
        self.assertEqual(
            hooks.resolve_context_max("gpt-5.6-sol", "openai-codex"),
            272000,
        )

    def test_codex_only_model_infers_oauth_provider_when_hook_omits_it(self):
        try:
            importlib.import_module("agent.model_metadata")
        except ImportError:
            self.skipTest("Hermes source is unavailable; canonical context resolver cannot be asserted")
        self.assertEqual(hooks.resolve_context_max("gpt-5.6-sol"), 272000)

    def test_provider_error_details_are_not_retained(self):
        registry = SessionRegistry(clock=FakeClock())
        status_hooks = hooks.StatusHooks(registry)
        status_hooks.on_session_start(session_id="s1", model="m1")

        secret = "provider rejected api_key=sk-secret-value prompt=private request"
        status_hooks.api_request_error(session_id="s1", error={"message": secret})

        error = registry.get("s1")["error"]
        self.assertEqual(error, "API request failed")
        self.assertNotIn("sk-secret-value", error)
        self.assertNotIn("private request", error)

    def test_repeated_pre_hooks_preserve_current_turn_start(self):
        clock = FakeClock()
        registry = SessionRegistry(clock=clock)
        status_hooks = hooks.StatusHooks(registry)
        status_hooks.on_session_start(session_id="s1", model="m1")
        status_hooks.pre_llm_call(session_id="s1", model="m1")
        started_at = registry.get("s1")["turn_started_at"]

        clock.value += 10
        status_hooks.pre_api_request(session_id="s1", model="m1")
        clock.value += 10
        status_hooks.pre_llm_call(session_id="s1", model="m1")

        self.assertEqual(registry.get("s1")["turn_started_at"], started_at)

    def test_pre_llm_call_requires_existing_session_before_and_after_reset(self):
        registry = SessionRegistry(clock=FakeClock())
        status_hooks = hooks.StatusHooks(registry)

        status_hooks.pre_llm_call(session_id="s1", model="m1")
        self.assertIsNone(registry.get("s1"))

        status_hooks.on_session_start(session_id="s1", model="m1")
        status_hooks.pre_llm_call(session_id="s1", model="m1")
        self.assertTrue(registry.get("s1")["busy"])

        status_hooks.on_session_reset(session_id="s1")
        status_hooks.pre_llm_call(session_id="s1", model="m1")
        self.assertIsNone(registry.get("s1"))

    def test_late_non_session_start_hooks_do_not_create_missing_session(self):
        registry = SessionRegistry(clock=FakeClock())
        status_hooks = hooks.StatusHooks(registry)

        late_hooks = (
            lambda: status_hooks.on_session_end(session_id="missing"),
            lambda: status_hooks.on_session_finalize(session_id="missing"),
            lambda: status_hooks.on_session_reset(session_id="missing"),
            lambda: status_hooks.pre_llm_call(session_id="missing", model="m1"),
            lambda: status_hooks.post_llm_call(session_id="missing"),
            lambda: status_hooks.pre_api_request(session_id="missing", model="m1", api_request_id="r1", turn_id="t1", approx_input_tokens=5),
            lambda: status_hooks.post_api_request(session_id="missing", model="m1", api_request_id="r1", turn_id="t1", usage={"prompt_tokens": 5, "total_tokens": 5}),
            lambda: status_hooks.api_request_error(session_id="missing", api_request_id="r1", turn_id="t1"),
            lambda: status_hooks.pre_tool_call(session_id="missing", tool_name="shell_exec", tool_call_id="tool-1"),
            lambda: status_hooks.post_tool_call(session_id="missing", tool_name="shell_exec", tool_call_id="tool-1"),
            lambda: status_hooks.subagent_start(parent_session_id="missing"),
            lambda: status_hooks.subagent_stop(parent_session_id="missing"),
        )
        for late_hook in late_hooks:
            late_hook()
            self.assertIsNone(registry.get("missing"))

    def test_post_llm_call_does_not_finish_outer_turn(self):
        registry = SessionRegistry(clock=FakeClock())
        status_hooks = hooks.StatusHooks(registry)
        status_hooks.on_session_start(session_id="s1", model="m1")
        status_hooks.pre_llm_call(session_id="s1", model="m1")
        started_at = registry.get("s1")["turn_started_at"]

        status_hooks.post_llm_call(session_id="s1")

        state = registry.get("s1")
        self.assertTrue(state["busy"])
        self.assertEqual(state["turn_started_at"], started_at)

        status_hooks.on_session_end(session_id="s1")
        state = registry.get("s1")
        assert state is not None
        self.assertFalse(state["busy"])
        self.assertIsNone(state["turn_started_at"])

    def test_tool_hooks_pass_stable_tool_call_id(self):
        registry = SessionRegistry(clock=FakeClock())
        status_hooks = hooks.StatusHooks(registry)
        status_hooks.on_session_start(session_id="s1", model="m1")

        status_hooks.pre_tool_call(session_id="s1", tool_name="shell_exec", tool_call_id="a")
        status_hooks.pre_tool_call(session_id="s1", tool_name="shell_exec", tool_call_id="b")
        status_hooks.post_tool_call(session_id="s1", tool_name="shell_exec", tool_call_id="a")

        state = registry.get("s1")
        self.assertEqual(state["active_tool_calls"], 1)
        self.assertEqual(state["active_tool"], "shell_exec")

    def test_post_api_request_does_not_fabricate_missing_compression_count(self):
        registry = SessionRegistry(clock=FakeClock())
        status_hooks = hooks.StatusHooks(registry)
        status_hooks.on_session_start(session_id="s1", model="m1")

        status_hooks.post_api_request(
            session_id="s1",
            model="m1",
            api_request_id="r1",
            turn_id="t1",
            usage={"prompt_tokens": 50},
        )
        self.assertEqual(registry.get("s1")["compression_count"], 0)

        status_hooks.pre_api_request(session_id="s1", model="m1", api_request_id="r2", turn_id="t1")
        status_hooks.post_api_request(
            session_id="s1",
            model="m1",
            api_request_id="r2",
            turn_id="t1",
            usage={"prompt_tokens": 25},
            compression_count=2,
        )
        self.assertEqual(registry.get("s1")["compression_count"], 2)

        status_hooks.post_api_request(
            session_id="s1",
            model="m1",
            api_request_id="missing",
            turn_id="t1",
            usage={"prompt_tokens": 10},
        )
        self.assertEqual(registry.get("s1")["compression_count"], 2)

    def test_post_api_request_accumulates_matched_canonical_total_and_keeps_latest_context(self):
        registry = SessionRegistry(clock=FakeClock())
        status_hooks = hooks.StatusHooks(registry)
        status_hooks.on_session_start(session_id="s1", model="m1")

        status_hooks.pre_api_request(session_id="s1", model="m1", api_request_id="r1", turn_id="t1")
        status_hooks.post_api_request(
            session_id="s1",
            model="m1",
            api_request_id="r1",
            turn_id="t1",
            usage={"prompt_tokens": 100, "completion_tokens": 20, "total_tokens": 120},
        )
        status_hooks.pre_api_request(session_id="s1", model="m1", api_request_id="r2", turn_id="t1")
        status_hooks.post_api_request(
            session_id="s1",
            model="m1",
            api_request_id="r2",
            turn_id="t1",
            usage={"prompt_tokens": 75, "completion_tokens": 10, "total_tokens": 85},
        )

        state = registry.get("s1")
        self.assertEqual(state["context_used"], 75)
        self.assertEqual(state["total_processed_tokens"], 205)

    def test_post_api_request_invalid_total_tokens_mark_unknown(self):
        registry = SessionRegistry(clock=FakeClock())
        status_hooks = hooks.StatusHooks(registry)
        status_hooks.on_session_start(session_id="s1", model="m1")

        status_hooks.pre_api_request(session_id="s1", model="m1", api_request_id="r1", turn_id="t1")
        status_hooks.post_api_request(
            session_id="s1",
            model="m1",
            api_request_id="r1",
            turn_id="t1",
            usage={"prompt_tokens": 10, "total_tokens": 25},
        )
        for index, invalid in enumerate((None, -1, "12", 1.5, True, False, MAX_SAFE_WIRE_INTEGER + 1), start=2):
            status_hooks.on_session_start(session_id="s1", model="m1")
            status_hooks.pre_api_request(session_id="s1", model="m1", api_request_id=f"r{index}", turn_id="t1")
            status_hooks.post_api_request(
                session_id="s1",
                model="m1",
                api_request_id=f"r{index}",
                turn_id="t1",
                usage={"prompt_tokens": 10, "total_tokens": invalid},
            )
            self.assertIsNone(registry.get("s1")["total_processed_tokens"])

    def test_pre_api_request_missing_identity_marks_unknown_but_absent_session_is_noop(self):
        registry = SessionRegistry(clock=FakeClock())
        status_hooks = hooks.StatusHooks(registry)

        status_hooks.pre_api_request(session_id="missing", model="m1", api_request_id=None, turn_id="t1")
        self.assertIsNone(registry.get("missing"))

        status_hooks.on_session_start(session_id="s1", model="m1")
        status_hooks.pre_api_request(session_id="s1", model="m1", api_request_id="seed", turn_id="turn")
        status_hooks.post_api_request(session_id="s1", model="m1", api_request_id="seed", turn_id="turn", usage={"total_tokens": 10})
        status_hooks.pre_api_request(session_id="s1", model="m1", api_request_id=None, turn_id="turn")

        self.assertIsNone(registry.get("s1")["total_processed_tokens"])

    def test_post_api_request_unmatched_completion_does_not_update_context_or_compression(self):
        registry = SessionRegistry(clock=FakeClock())
        status_hooks = hooks.StatusHooks(registry)
        status_hooks.on_session_start(session_id="s1", model="m1")
        registry.update_context("s1", 10)
        registry.update_compression_count("s1", 1)

        status_hooks.post_api_request(
            session_id="s1",
            model="m1",
            api_request_id="missing",
            turn_id="t1",
            usage={"prompt_tokens": 99, "total_tokens": 99},
            compression_count=4,
        )

        state = registry.get("s1")
        self.assertEqual(state["context_used"], 10)
        self.assertEqual(state["compression_count"], 1)
        self.assertIsNone(state["total_processed_tokens"])

    def test_subagent_and_yolo_fields_are_real_event_derived(self):
        registry = SessionRegistry(clock=FakeClock())
        status_hooks = hooks.StatusHooks(registry)
        status_hooks.on_session_start(session_id="s1", model="m1", yolo=True)
        status_hooks.subagent_start(parent_session_id="s1")

        state = registry.get("s1")
        self.assertTrue(state["yolo"])
        self.assertEqual(state["active_subagents"], 1)

        status_hooks.subagent_stop(parent_session_id="s1")
        self.assertEqual(registry.get("s1")["active_subagents"], 0)

    def test_subagent_hooks_require_public_parent_session_id(self):
        registry = SessionRegistry(clock=FakeClock())
        status_hooks = hooks.StatusHooks(registry)
        status_hooks.on_session_start(session_id="parent", model="m1")

        status_hooks.subagent_start(session_id="child", child_session_id="child")

        self.assertEqual(registry.get("parent")["active_subagents"], 0)
        self.assertIsNone(registry.get("child"))


if __name__ == "__main__":
    unittest.main()
