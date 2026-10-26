from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("chart_notify", Path(__file__).with_name("notify-lifecycle.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class NotificationTests(unittest.TestCase):
    def setUp(self):
        self.own = dict(id=100, status="in_progress", event="workflow_run", run_attempt=1,
            head_branch="main", head_sha="a" * 40, path=module.WORKFLOW,
            repository=dict(full_name=module.CHART), head_repository=dict(full_name=module.CHART))
        self.source = dict(self.own, id=90, status="completed", event="push", path=".github/workflows/verify.yml", conclusion="success")
        self.main = "a" * 40
        self.sent = []
        self.response = dict(workflow_run_id=200, run_url=f"https://api.github.com/repos/{module.INFRA}/actions/runs/200",
            html_url=f"https://github.com/{module.INFRA}/actions/runs/200")

    def get(self, path):
        if path == "actions/runs/100": return deepcopy(self.own)
        if path == "actions/runs/90": return deepcopy(self.source)
        if path == "git/ref/heads/main": return dict(object=dict(sha=self.main))
        raise AssertionError(path)

    def send(self, payload):
        self.sent.append(payload)
        return deepcopy(self.response)

    def notify(self):
        return module.notify(self.get, self.send, run_id="100", source_sha="a" * 40, source_run_id="90")

    def test_main_callback_forwards_only_actual_run_id_without_a_verdict_or_session(self):
        self.assertEqual(self.notify(), self.response)
        self.assertEqual(self.sent, [dict(ref="main", inputs=dict(chart_run_id="90"))])

    def test_review_event_and_failed_ci_are_hints_not_success_authority(self):
        self.source.update(event="pull_request_review", path=".github/workflows/chart-review-event.yml", conclusion="failure")
        self.assertEqual(self.notify(), self.response)
        self.assertNotIn("conclusion", self.sent[0]["inputs"])

    def test_fork_rerun_wrong_main_or_wrong_callback_path_cannot_send(self):
        original = deepcopy(self.own)
        for fields in (dict(run_attempt=2), dict(head_sha="b" * 40), dict(head_branch="release/branch"),
                       dict(event="pull_request_review"), dict(path=".github/workflows/verify.yml"),
                       dict(repository=dict(full_name="fork/chart")), dict(head_repository=dict(full_name="fork/chart"))):
            self.own = dict(original, **fields)
            with self.subTest(fields=fields), self.assertRaises(ValueError): self.notify()
        self.own = original
        self.main = "b" * 40
        with self.assertRaises(ValueError): self.notify()
        self.assertFalse(self.sent)

    def test_unrelated_fork_live_or_wrong_source_workflow_is_a_noop(self):
        original = deepcopy(self.source)
        for fields in (dict(status="in_progress"), dict(event="issue_comment"), dict(path=module.WORKFLOW),
                       dict(head_repository=dict(full_name="fork/chart")), dict(id=91), dict(run_attempt=0)):
            self.source = dict(original, **fields)
            self.assertEqual(self.notify(), dict(waiting="UNRELATED_CHART_RUN"))
        self.assertFalse(self.sent)

    def test_opaque_or_injected_ids_are_rejected_before_http(self):
        for value in ("", "0", "90?x=1", "90/../100", True, "9" * 21):
            with self.subTest(value=value), self.assertRaises(ValueError): module.number(value)

    def test_lost_post_or_unverified_response_is_never_retried(self):
        def lost(payload):
            self.sent.append(payload)
            raise TimeoutError("response lost")
        with self.assertRaises(TimeoutError): module.notify(self.get, lost, run_id="100", source_sha="a" * 40, source_run_id="90")
        self.assertEqual(len(self.sent), 1)
        self.response["html_url"] = "https://github.com/other/repo/actions/runs/200"
        with self.assertRaises(ValueError): self.notify()
        self.assertEqual(len(self.sent), 2)

    def test_http_is_fixed_origin_bounded_nonredirecting_and_single_post(self):
        class HTTP:
            status = 200
            headers = {}
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def read(self, size): return json.dumps(dict(ok=True)).encode()
        class Opener:
            def __init__(inner): inner.calls = []
            def open(inner, request, **kwargs):
                inner.calls.append((request, kwargs))
                return HTTP()
        opener = Opener()
        with patch.object(module, "build_opener", return_value=opener) as build:
            module.api(module.INFRA, "test-token", "actions/workflows/staging-orchestrate.yml/dispatches",
                dict(ref="main", inputs=dict(chart_run_id="90")))
            self.assertIsInstance(build.call_args.args[0], module.NoRedirect)
        request, options = opener.calls[0]
        self.assertEqual(request.full_url, f"https://api.github.com/repos/{module.INFRA}/actions/workflows/staging-orchestrate.yml/dispatches")
        self.assertEqual(request.method, "POST")
        self.assertEqual(options, dict(timeout=30))
        for repo, path in ((module.CHART, "actions/workflows/verify.yml/dispatches"),
                           (module.INFRA, "pulls/7/merge"), (module.INFRA, "../actions/workflows/staging-orchestrate.yml/dispatches")):
            with self.assertRaises(ValueError): module.api(repo, "test-token", path, {})

    def test_workflow_keeps_app_key_behind_main_only_environment_and_never_loads_pr_code(self):
        import yaml
        root = Path(__file__).parents[1]
        workflow = yaml.safe_load((root / ".github/workflows/post-deploy.yml").read_text())
        job = workflow["jobs"]["notify"]
        self.assertEqual(job["environment"], "staging-chart-notify")
        self.assertIn("github.ref == 'refs/heads/main'", job["if"])
        checkout = job["steps"][0]["with"]
        self.assertEqual(checkout["ref"], "${{ github.sha }}")
        self.assertFalse(checkout["persist-credentials"])
        app = next(step["with"] for step in job["steps"] if "create-github-app-token@" in step.get("uses", ""))
        self.assertEqual(app["repositories"], "techx-infra")
        self.assertEqual(app["permission-actions"], "write")
        self.assertFalse(any("download-artifact" in step.get("uses", "") for step in job["steps"]))
        review = yaml.safe_load((root / ".github/workflows/chart-review-event.yml").read_text())
        self.assertEqual(review["permissions"], {})
        self.assertFalse(any("uses" in step for step in review["jobs"]["observe"]["steps"]))


if __name__ == "__main__": unittest.main()
