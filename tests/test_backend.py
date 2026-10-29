import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("backend", Path(__file__).parents[1] / "ai-quota/backend.py")
backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend)


class SafetyTests(unittest.TestCase):
    def fixture(self):
        return {"providers": [
            {"providerId": pid, "okAtMs": 1000000, "rows": [
                {"type": "quota", "window": "five_hour", "percentRemaining": 34},
                {"type": "quota", "window": "week", "percentRemaining": 78},
                {"type": "quota", "window": "month", "percentRemaining": 55},
            ]} for pid, _, _ in backend.PROVIDERS]}

    def test_requested_windows_and_remaining_not_used(self):
        result = backend.normalize(self.fixture(), now=1001)
        self.assertTrue(result["ok"])
        self.assertEqual([p["remaining"] for p in result["providers"]], [34, 34, 55])
        self.assertEqual([p["window"] for p in result["providers"]], ["five_hour", "five_hour", "month"])

    def test_old_and_error_data_are_stale(self):
        raw = self.fixture()
        raw["providers"][0]["error"] = {"detail": "SECRET must not be shown"}
        result = backend.normalize(raw, now=1001)
        self.assertTrue(result["providers"][0]["stale"])
        self.assertNotIn("SECRET", str(result))
        self.assertFalse(result["ok"])
        old = backend.normalize(self.fixture(), now=2000)
        self.assertTrue(all(p["stale"] for p in old["providers"]))

    def test_missing_provider_and_missing_window(self):
        raw = self.fixture()
        raw["providers"].pop()
        raw["providers"][0]["rows"] = []
        result = backend.normalize(raw, now=1001)
        self.assertIsNone(result["providers"][0]["remaining"])
        self.assertIsNone(result["providers"][2]["remaining"])
        self.assertFalse(result["ok"])

    def test_expired_window_is_not_assumed_refilled(self):
        raw = self.fixture()
        raw["providers"][0]["rows"][0]["resetsAt"] = "1970-01-01T00:10:00Z"
        result = backend.normalize(raw, now=1001)
        self.assertEqual(result["providers"][0]["remaining"], 34)
        self.assertTrue(result["providers"][0]["stale"])

    def test_multiple_accounts_use_lowest_not_sum(self):
        raw = self.fixture()
        raw["providers"][0]["rows"].append({"type": "quota", "window": "five_hour", "percentRemaining": 12})
        self.assertEqual(backend.normalize(raw, now=1001)["providers"][0]["remaining"], 12)

    def test_only_public_quota_fields_leave_backend(self):
        raw = self.fixture()
        raw["settings"] = {"private": "SECRET"}
        raw["providers"][0]["rows"][0]["account"] = "SECRET@example.com"
        raw["providers"][0]["label"] = "SECRET"
        self.assertNotIn("SECRET", json.dumps(backend.normalize(raw, now=1001)))

    def test_bad_reset_is_ignored_without_inventing_a_date(self):
        raw = self.fixture()
        raw["providers"][0]["rows"][0]["resetsAt"] = "not a date"
        result = backend.normalize(raw, now=1001)
        self.assertIsNone(result["providers"][0]["resets_at"])

    def test_invalid_payload(self):
        for bad in ({}, None, {"providers": "bad"}):
            with self.assertRaises(ValueError):
                backend.normalize(bad)

    def test_cli_failure_does_not_leak_stderr(self):
        with patch.object(backend, "fetch", side_effect=RuntimeError("SECRET")):
            result = backend.snapshot()
            self.assertFalse(result["ok"])
            self.assertNotIn("SECRET", str(result))

    def test_fetch_uses_authenticated_cli_and_rate_limited_poll(self):
        expected = self.fixture()
        response = subprocess.CompletedProcess([], 0, stdout=json.dumps({"output": {"snapshot": expected}}))
        with patch.object(backend, "executable", return_value="/bin/opencode"), \
             patch.object(backend.subprocess, "run", return_value=response) as run:
            self.assertEqual(backend.fetch(), expected)
            args, kwargs = run.call_args
            command = args[0]
            self.assertIn("rpcID=slkiser.opencode-quota", command)
            self.assertIn("method=refresh", command)
            payload = json.loads(command[-1])
            self.assertEqual(payload["input"]["reason"], "poll")
            self.assertEqual(payload["input"]["providerIds"], ["openai", "anthropic", "opencode-go"])
            self.assertEqual(kwargs["timeout"], 90)
            self.assertTrue(kwargs["check"])

    def test_timeout_retains_last_data_but_never_marks_it_fresh(self):
        previous = backend.normalize(self.fixture(), now=1001)
        with patch.object(backend, "fetch", side_effect=subprocess.TimeoutExpired("opencode", 35)):
            result = backend.snapshot(previous)
            self.assertFalse(result["ok"])
            self.assertEqual(result["providers"][0]["remaining"], 34)
            self.assertTrue(result["providers"][0]["stale"])

    def test_serve_heartbeats_do_not_poll_providers_each_time(self):
        clock = [0]
        sleeps = []

        def sleep(seconds):
            sleeps.append(seconds)
            clock[0] += seconds
            if clock[0] > 60:
                raise KeyboardInterrupt

        with patch.object(backend.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(backend.time, "sleep", side_effect=sleep), \
             patch.object(backend, "snapshot", return_value={"ok": True, "providers": []}) as snapshot, \
             patch("builtins.print") as output:
            with self.assertRaises(KeyboardInterrupt):
                backend.serve(60)
            self.assertEqual(snapshot.call_count, 2)
            self.assertEqual(output.call_count, 5)
            self.assertEqual(sleeps, [15] * 5)

    def test_percentages(self):
        for bad in (None, True, "34", float("nan"), float("inf"), 10**400):
            self.assertIsNone(backend.percentage(bad))
        self.assertEqual(backend.percentage(-1), 0)
        self.assertEqual(backend.percentage(110), 100)
        self.assertEqual(backend.percentage(34.5), 34.5)

    def test_heartbeat_ages_data_and_marks_reset_without_poll(self):
        value = backend.normalize(self.fixture(), now=1001)
        result = backend.age_snapshot(value, now=2000)
        self.assertFalse(result["ok"])
        self.assertTrue(all(p["stale"] for p in result["providers"]))
        self.assertTrue(value["ok"])
        value["providers"][0]["resets_at"] = "1970-01-01T00:17:00Z"
        self.assertTrue(backend.age_snapshot(value, now=1021)["providers"][0]["stale"])

    def test_updated_at_tracks_actual_read_not_poll_time(self):
        self.assertEqual(backend.normalize(self.fixture(), now=1001)["updated_at"], 1000)

    def test_initial_failure_is_not_zero_quota(self):
        result = backend.failed_snapshot()
        self.assertFalse(result["ok"])
        self.assertEqual(len(result["providers"]), 3)
        self.assertTrue(all(p["remaining"] is None and p["stale"] for p in result["providers"]))

    def test_failure_preserves_but_marks_last_data(self):
        previous = backend.failed_snapshot()
        previous["ok"] = True
        previous["updated_at"] = 123
        previous["providers"][0].update(remaining=34, stale=False)
        result = backend.failed_snapshot(previous)
        self.assertEqual(result["providers"][0]["remaining"], 34)
        self.assertEqual(result["updated_at"], 123)
        self.assertTrue(result["providers"][0]["stale"])
        self.assertFalse(previous["providers"][0]["stale"])


if __name__ == "__main__":
    unittest.main()
