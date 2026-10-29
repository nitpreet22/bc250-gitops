"""Tests for scripts/pod-requests.py's side-effect-free parts: the decision rules, the rendered
component and the overlay edits. Run on a machine with Python 3.10+ and PyYAML (bc250-2):

    python3 -m unittest tests/test_pod_requests.py
"""

import importlib.util
import unittest
from pathlib import Path

import yaml

_spec = importlib.util.spec_from_file_location(
    "pod_requests", Path(__file__).resolve().parent.parent / "scripts/pod-requests.py")
pr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pr)

GiB = 2**30


def facts(**overrides):
    defaults = dict(project="my-project", existing_env_names={"REPO_URL", "REPO_DIR"},
                    uses_agent_image=True, running=True,
                    current_cpu_milli=4000, current_memory_bytes=3 * GiB,
                    quota_hard_cpu_milli=14000, quota_used_cpu_milli=4200,
                    quota_hard_memory_bytes=10 * GiB, quota_used_memory_bytes=3 * GiB + 256 * 2**20)
    defaults.update(overrides)
    return pr.PodFacts(**defaults)


class QuantityParsing(unittest.TestCase):
    def test_cpu_in_cores_and_millicores(self):
        self.assertEqual(pr.cpu_milli("6"), 6000)
        self.assertEqual(pr.cpu_milli(6), 6000)
        self.assertEqual(pr.cpu_milli("500m"), 500)
        self.assertEqual(pr.cpu_milli("1.5"), 1500)

    def test_memory_in_binary_and_decimal_units(self):
        self.assertEqual(pr.memory_bytes("8Gi"), 8 * GiB)
        self.assertEqual(pr.memory_bytes("512Mi"), 512 * 2**20)
        self.assertEqual(pr.memory_bytes("1G"), 10**9)
        self.assertEqual(pr.memory_bytes(3221225472), 3 * GiB)

    def test_garbage_is_rejected(self):
        for value in ("lots", "8 GiB", "-1", ""):
            with self.assertRaises(ValueError, msg=value):
                pr.parse_quantity(value)


class SafeRequestsAreApplied(unittest.TestCase):
    def test_packages_cpu_memory_and_env_within_the_rules(self):
        decision = pr.evaluate_request({"packages": ["postgresql-server", "redis"], "cpu": "6",
                                        "memory": "6Gi", "env": {"LOG_LEVEL": "debug", "N": 3}},
                                       facts())
        self.assertTrue(decision.apply, decision.reasons)
        self.assertEqual(decision.packages, ["postgresql-server", "redis"])
        self.assertEqual(decision.env, {"LOG_LEVEL": "debug", "N": "3"})

    def test_the_ceilings_themselves_are_allowed(self):
        decision = pr.evaluate_request({"cpu": 8, "memory": "8Gi"},
                                       facts(quota_hard_memory_bytes=20 * GiB))
        self.assertTrue(decision.apply, decision.reasons)

    def test_an_empty_request_means_defaults(self):
        decision = pr.evaluate_request({}, facts())
        self.assertTrue(decision.apply)
        self.assertTrue(pr.is_empty(decision))


class UnsafeRequestsWaitForTheOwner(unittest.TestCase):
    def assert_review(self, request, expected_reason, **fact_overrides):
        decision = pr.evaluate_request(request, facts(**fact_overrides))
        self.assertFalse(decision.apply)
        self.assertTrue(any(expected_reason in reason for reason in decision.reasons),
                        decision.reasons)

    def test_above_the_cpu_ceiling(self):
        self.assert_review({"cpu": "9"}, "above the ceiling")

    def test_above_the_memory_ceiling(self):
        self.assert_review({"memory": "9Gi"}, "above the ceiling")

    def test_fields_outside_the_schema(self):
        # A NetworkPolicy, Secret or hostPath can't be asked for: unknown fields need the owner.
        self.assert_review({"egress": ["192.168.1.0/24"]}, "unknown field 'egress'")

    def test_secret_looking_env_names(self):
        self.assert_review({"env": {"BINANCE_API_KEY": "x"}}, "looks like a secret")

    def test_env_set_by_the_platform_or_overlay(self):
        self.assert_review({"env": {"REPO_DIR": "/tmp"}}, "set by the platform")
        self.assert_review({"env": {"CLAUDE_CODE_OAUTH_TOKEN": "x"}}, "looks like a secret")
        self.assert_review({"env": {"PATH": "/x"}}, "set by the platform")

    def test_multiline_env_values(self):
        self.assert_review({"env": {"BANNER": "a\nb"}}, "one line")

    def test_packages_on_a_pod_with_its_own_image(self):
        self.assert_review({"packages": ["htop"]}, "own image", uses_agent_image=False)

    def test_package_names_that_could_inject_shell(self):
        self.assert_review({"packages": ["htop; curl evil"]}, "not a package name")

    def test_a_running_pod_that_would_exceed_the_namespace_quota(self):
        # 10 GiB quota, 3.25 GiB used of which 3 GiB is this pod: 8 GiB leaves 8.25 GiB... fits;
        # another pod using 3 GiB more doesn't.
        self.assert_review({"memory": "8Gi"}, "namespace quota",
                           quota_used_memory_bytes=6 * GiB + 256 * 2**20)


class StoppedPods(unittest.TestCase):
    def test_a_stopped_pod_over_the_quota_is_applied_with_a_note(self):
        decision = pr.evaluate_request({"memory": "8Gi"},
                                       facts(running=False, quota_used_memory_bytes=6 * GiB))
        self.assertTrue(decision.apply, decision.reasons)
        self.assertTrue(any("won't start until there is room" in n for n in decision.notes))


class EnvAddedByAnEarlierRequest(unittest.TestCase):
    def test_changing_a_variable_the_request_added_earlier_is_allowed(self):
        # gather_facts leaves the request's own names out of existing_env_names.
        decision = pr.evaluate_request({"env": {"LOG_LEVEL": "info"}},
                                       facts(existing_env_names={"REPO_URL"}))
        self.assertTrue(decision.apply, decision.reasons)


class Rendering(unittest.TestCase):
    def test_component_patches_only_the_agent_container(self):
        decision = pr.evaluate_request({"cpu": "6", "env": {"A": "1"}}, facts())
        text = pr.render_component(decision, "abc123", "registry.homelab.lan/pod-x:t", "r@s:f")
        component = yaml.safe_load(text)
        self.assertEqual(component["kind"], "Component")
        merge = yaml.safe_load(component["patches"][0]["patch"])
        container = merge["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(container, {"name": "agent", "image": "registry.homelab.lan/pod-x:t",
                                     "resources": {"limits": {"cpu": "6"}}})
        self.assertEqual(merge["spec"]["template"]["metadata"]["annotations"],
                         {"homelab.lan/pod-request": "abc123"})

    def test_env_is_appended_so_the_overlays_positional_patches_still_hit(self):
        decision = pr.evaluate_request({"env": {"B": "2", "A": "1"}}, facts())
        component = yaml.safe_load(pr.render_component(decision, "f", None, "r@s:f"))
        appends = yaml.safe_load(component["patches"][1]["patch"])
        self.assertEqual([op["path"] for op in appends],
                         ["/spec/template/spec/containers/0/env/-"] * 2)
        self.assertEqual([op["value"]["name"] for op in appends], ["A", "B"])

    def test_env_names_are_read_back_from_an_earlier_component(self):
        import tempfile
        decision = pr.evaluate_request({"env": {"LOG_LEVEL": "debug"}}, facts())
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / "kustomization.yaml").write_text(
                pr.render_component(decision, "f", None, "r@s:f"))
            self.assertEqual(pr.component_env_names(Path(folder)), {"LOG_LEVEL"})

    def test_fingerprint_ignores_the_base_image_without_packages(self):
        decision = pr.evaluate_request({"cpu": "6"}, facts())
        self.assertEqual(pr.request_fingerprint(decision, "2026-11-04.1"),
                         pr.request_fingerprint(decision, "2026-12-01.1"))

    def test_project_image_tag_follows_base_and_packages(self):
        name, tag = pr.project_image("my-project", ["redis"], "2026-11-04.1")
        self.assertEqual(name, "pod-my-project")
        self.assertTrue(tag.startswith("2026-11-04.1-"))
        self.assertNotEqual(tag, pr.project_image("my-project", ["htop"], "2026-11-04.1")[1])


class OverlayEdits(unittest.TestCase):
    OVERLAY = ("# A comment that must survive\nresources:\n  - ../../../templates/agent\n"
               "components:\n  - ../../../templates/agent/components/job-runner\n"
               "patches:\n  - target: {kind: Deployment, name: agent}\n")

    def test_component_goes_last_in_an_existing_list(self):
        text = pr.add_component_to_overlay(self.OVERLAY)
        components = yaml.safe_load(text)["components"]
        self.assertEqual(components[-1], "pod-request")
        self.assertIn("# A comment that must survive", text)

    def test_component_list_is_created_when_missing(self):
        text = pr.add_component_to_overlay("resources:\n  - ../../../templates/agent\n")
        self.assertEqual(yaml.safe_load(text)["components"], ["pod-request"])

    def test_adding_twice_changes_nothing(self):
        once = pr.add_component_to_overlay(self.OVERLAY)
        self.assertEqual(pr.add_component_to_overlay(once), once)

    def test_removing_restores_the_original(self):
        for original in (self.OVERLAY, "resources:\n  - ../../../templates/agent\n"):
            added = pr.add_component_to_overlay(original)
            self.assertEqual(pr.remove_component_from_overlay(added), original)


class AgentBusy(unittest.TestCase):
    """`hc get --json` records of a project's terminals, as agent_is_busy reads them."""

    @staticmethod
    def terminal(state=None):
        return {"address": "t7", "status": {"app": "claude-code", "state": state} if state else None}

    def test_working_or_blocked_waits(self):
        for state in ("working", "blocked"):
            self.assertTrue(pr.any_terminal_busy([self.terminal("idle"), self.terminal(state)]), state)

    def test_idle_done_or_no_status_applies(self):
        for state in ("idle", "done", "error", None):
            self.assertFalse(pr.any_terminal_busy([self.terminal(state)]), state)

    def test_no_terminal_applies(self):
        self.assertFalse(pr.any_terminal_busy([]))


if __name__ == "__main__":
    unittest.main()
