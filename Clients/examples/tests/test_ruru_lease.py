"""Fault checks for the example's worker gate; no network or real credentials."""
import importlib.util
import pathlib
import threading
import time
import unittest
from unittest.mock import patch

with patch.dict("os.environ", {"RURU_ENDPOINT": "https://example.invalid", "RURU_CLUSTER": "test",
                              "RURU_NODE": "test", "RURU_TOKEN": "test-only"}):
    spec = importlib.util.spec_from_file_location("lease_example", pathlib.Path(__file__).parents[1] / "ruru_lease.py")
    example = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(example)


class WorkGateTests(unittest.TestCase):
    def test_expiry_stops_work_while_request_thread_is_blocked(self):
        stopped = threading.Event()
        with patch.object(example, "start_work"), patch.object(example, "stop_work", side_effect=stopped.set):
            work = example.WorkGate()
            try:
                work.grant(1, time.monotonic() + 0.05)
                # Simulate a socket stuck longer than the granted permission.
                time.sleep(0.15)
                self.assertTrue(stopped.is_set())
            finally:
                work.close()

    def test_renewal_updates_the_worker_deadline(self):
        stopped = threading.Event()
        with patch.object(example, "start_work") as start, patch.object(example, "stop_work", side_effect=stopped.set):
            work = example.WorkGate()
            try:
                work.grant(1, time.monotonic() + 0.1)
                work.grant(1, time.monotonic() + 0.4)
                self.assertEqual(start.call_count, 2)
                self.assertFalse(stopped.wait(0.15))
                self.assertTrue(stopped.wait(1))
            finally:
                work.close()

    def test_expired_response_cannot_start_work(self):
        with patch.object(example, "start_work") as start, patch.object(example, "stop_work"):
            work = example.WorkGate()
            try:
                with self.assertRaises(example.Lost):
                    work.grant(1, time.monotonic() - 1)
                start.assert_not_called()
            finally:
                work.close()

    def test_clean_shutdown_stops_work_and_joins_expiry_thread(self):
        with patch.object(example, "start_work"), patch.object(example, "stop_work") as stop:
            work = example.WorkGate()
            work.grant(1, time.monotonic() + 30)
            work.close()
            stop.assert_called_once()
            self.assertFalse(work.watcher.is_alive())


if __name__ == "__main__":
    unittest.main()
