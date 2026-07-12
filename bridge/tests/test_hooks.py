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
            usage={"prompt_tokens": 50},
        )
        self.assertEqual(registry.get("s1")["compression_count"], 0)

        status_hooks.post_api_request(
            session_id="s1",
            model="m1",
            usage={"prompt_tokens": 25},
            compression_count=2,
        )
        self.assertEqual(registry.get("s1")["compression_count"], 2)

        status_hooks.post_api_request(
            session_id="s1",
            model="m1",
            usage={"prompt_tokens": 10},
        )
        self.assertEqual(registry.get("s1")["compression_count"], 2)

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
