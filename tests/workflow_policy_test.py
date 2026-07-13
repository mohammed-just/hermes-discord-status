from copy import deepcopy
from pathlib import Path
import sys

import yaml


REPO_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "ci.yml"

PINNED_ACTIONS = {
    "actions/checkout": ("v7", "9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0"),
    "actions/setup-python": ("v6", "ece7cb06caefa5fff74198d8649806c4678c61a1"),
    "actions/setup-node": ("v6", "48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e"),
    "pnpm/action-setup": ("v6", "b0f76dfb45f55f8421693e4803ac7bb65143bd34"),
}
EXPECTED_USES_COUNTS = {
    "actions/checkout": 4,
    "actions/setup-python": 1,
    "actions/setup-node": 1,
    "pnpm/action-setup": 1,
}
VENCORD_COMMIT = "94cc541e38905063988094249a40e618f83a12e4"
STATUS_TEST_COMMAND = "pnpm exec tsx src/userplugins/hermesStatus/tests/statusLogic.test.ts"
PYTEST_INSTALL_COMMAND = "python -m pip install pytest==9.1.1 PyYAML==6.0.3"


class PolicyError(AssertionError):
    pass


def load_workflow(path=WORKFLOW):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def iter_dicts(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from iter_dicts(child)
    elif isinstance(value, list):
        for child in value:
            yield from iter_dicts(child)


def iter_steps(workflow):
    for job_name, job in workflow.get("jobs", {}).items():
        for index, step in enumerate(job.get("steps", [])):
            if isinstance(step, dict):
                yield job_name, index, step


def validate_permissions(workflow, failures):
    permissions = workflow.get("permissions")
    if permissions != {"contents": "read"}:
        failures.append("workflow top-level permissions must be exactly {contents: read}")
    for mapping in iter_dicts(workflow):
        if mapping.get("permissions") == "write-all":
            failures.append("workflow and job permissions must not use write-all")
        mapping_permissions = mapping.get("permissions")
        if isinstance(mapping_permissions, dict):
            for key, value in mapping_permissions.items():
                if value == "write":
                    failures.append(f"permission {key} must not be write")


def validate_uses(workflow, failures):
    seen = {action: 0 for action in PINNED_ACTIONS}
    allowed_step_ids = {id(step) for _, _, step in iter_steps(workflow)}
    for mapping in iter_dicts(workflow):
        if "uses" in mapping and id(mapping) not in allowed_step_ids:
            failures.append("uses is allowed only on allowlisted steps; reusable workflows are forbidden")
    for job_name, index, step in iter_steps(workflow):
        if "uses" not in step:
            continue
        uses = step["uses"]
        if isinstance(uses, dict):
            failures.append(f"{job_name} step {index} uses must be a scalar, not an inline mapping")
            continue
        if isinstance(uses, str) and uses.startswith("docker://"):
            failures.append(f"docker actions are forbidden: {uses}")
            continue
        if not isinstance(uses, str) or "@" not in uses:
            failures.append(f"{job_name} step {index} has malformed uses value")
            continue
        action, ref = uses.rsplit("@", 1)
        if action not in PINNED_ACTIONS:
            failures.append(f"unexpected action download: {uses}")
            continue
        expected_version, expected_sha = PINNED_ACTIONS[action]
        if ref != expected_sha:
            failures.append(f"{action} must be pinned to {expected_sha}, got {ref}")
        if len(ref) != 40 or any(char not in "0123456789abcdef" for char in ref):
            failures.append(f"{action} ref must be an immutable lowercase 40-hex SHA")
        seen[action] += 1

    for action, count in EXPECTED_USES_COUNTS.items():
        if seen[action] != count:
            failures.append(f"{action} occurrence count must be {count}, got {seen[action]}")


def validate_commands(workflow, failures):
    run_values = [step.get("run", "") for _, _, step in iter_steps(workflow)]
    if PYTEST_INSTALL_COMMAND not in run_values:
        failures.append("workflow must pin pytest and PyYAML test dependencies in one install command")
    if "python -m pip install pytest==9.1.1" in run_values:
        failures.append("workflow must install pinned PyYAML with pytest")
    if STATUS_TEST_COMMAND not in run_values:
        failures.append("workflow must run the standalone tsx status test command")
    if "pnpm exec vitest run src/userplugins/hermesStatus/tests/statusLogic.test.ts" in run_values:
        failures.append("workflow must not run the status test through vitest")

    checkout_refs = []
    for _, _, step in iter_steps(workflow):
        uses = step.get("uses", "")
        if isinstance(uses, str) and uses.startswith("actions/checkout@"):
            with_block = step.get("with") or {}
            if with_block.get("repository") == "Vendicated/Vencord":
                checkout_refs.append(with_block.get("ref"))
    if checkout_refs != [VENCORD_COMMIT]:
        failures.append("workflow pins the wrong Vencord commit")


def validate_workflow(workflow):
    failures = []
    validate_permissions(workflow, failures)
    validate_uses(workflow, failures)
    validate_commands(workflow, failures)
    if failures:
        raise PolicyError("\n".join(failures))


def expect_policy_failure(workflow, expected_text):
    try:
        validate_workflow(workflow)
    except PolicyError as exc:
        if expected_text not in str(exc):
            raise AssertionError(f"expected mutation failure containing {expected_text!r}, got {exc}") from exc
        return
    raise AssertionError(f"mutation unexpectedly passed: {expected_text}")


def run_mutation_tests(workflow):
    mutated = deepcopy(workflow)
    mutated["permissions"] = {"contents": "write"}
    expect_policy_failure(mutated, "contents")

    mutated = deepcopy(workflow)
    del mutated["permissions"]
    expect_policy_failure(mutated, "top-level permissions")

    mutated = deepcopy(workflow)
    mutated["permissions"] = {"contents": "read", "actions": "read"}
    expect_policy_failure(mutated, "top-level permissions")

    mutated = deepcopy(workflow)
    first_job = next(iter(mutated["jobs"].values()))
    first_job["permissions"] = "write-all"
    expect_policy_failure(mutated, "write-all")

    mutated = deepcopy(workflow)
    first_job_name = next(iter(mutated["jobs"]))
    mutated["jobs"][first_job_name] = {
        "uses": "evil/reusable/.github/workflows/pwn.yml@0123456789abcdef0123456789abcdef01234567"
    }
    expect_policy_failure(mutated, "reusable workflows")

    mutated = deepcopy(workflow)
    next(iter_steps(mutated))[2]["uses"] = "actions/checkout@v7"
    expect_policy_failure(mutated, "40-hex")

    mutated = deepcopy(workflow)
    next(iter_steps(mutated))[2]["uses"] = {"actions/checkout": PINNED_ACTIONS["actions/checkout"][1]}
    expect_policy_failure(mutated, "inline mapping")

    mutated = deepcopy(workflow)
    next(iter_steps(mutated))[2]["uses"] = "docker://alpine:3.20"
    expect_policy_failure(mutated, "docker actions")

    mutated = deepcopy(workflow)
    next(iter_steps(mutated))[2]["uses"] = "evil/action@0123456789abcdef0123456789abcdef01234567"
    expect_policy_failure(mutated, "unexpected action")

    mutated = deepcopy(workflow)
    for _, _, step in iter_steps(mutated):
        if step.get("uses", "").startswith("actions/checkout@") and (step.get("with") or {}).get("repository") == "Vendicated/Vencord":
            step["with"]["ref"] = "main"
            break
    expect_policy_failure(mutated, "wrong Vencord commit")

    mutated = deepcopy(workflow)
    for _, _, step in iter_steps(mutated):
        if step.get("run") == STATUS_TEST_COMMAND:
            step["run"] = "pnpm exec vitest run src/userplugins/hermesStatus/tests/statusLogic.test.ts"
            break
    expect_policy_failure(mutated, "standalone tsx")


def main():
    workflow = load_workflow()
    try:
        validate_workflow(workflow)
        run_mutation_tests(workflow)
    except PolicyError as exc:
        for failure in str(exc).splitlines():
            print(f"FAIL: {failure}")
        return 1
    print("PASS: workflow policy")
    return 0


if __name__ == "__main__":
    sys.exit(main())
