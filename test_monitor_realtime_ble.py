#!/usr/bin/env python3
import unittest

from tools import monitor_realtime_ble


class MonitorRealtimeBLETests(unittest.TestCase):
    def test_delta_uses_counter_keys(self):
        previous = {
            "whoop.sample.rawNotifications": 10,
            "whoop.sample.acceptedSamples": 8,
            "whoop.link.disconnects": 2,
            "whoop.watchdog.hrContinuityCount": 1,
        }
        current = {
            "whoop.sample.rawNotifications": 15,
            "whoop.sample.acceptedSamples": 12,
            "whoop.link.disconnects": 3,
            "whoop.watchdog.hrContinuityCount": 1,
        }

        delta = monitor_realtime_ble.compute_delta(previous, current)

        self.assertEqual(delta["whoop.sample.rawNotifications"], 5)
        self.assertEqual(delta["whoop.sample.acceptedSamples"], 4)
        self.assertEqual(delta["whoop.link.disconnects"], 1)
        self.assertEqual(delta["whoop.watchdog.hrContinuityCount"], 0)

    def test_worn_sample_flags_silent_stall_and_zero_contact(self):
        delta = {key: 0 for key in monitor_realtime_ble.COUNTER_KEYS}
        current = {
            "whoop.sample.lastStatus": "zero_contact",
            "whoop.link.lastStatus": "connected",
        }

        flags = monitor_realtime_ble.evaluate_sample(delta, current, worn=True)

        self.assertIn("NO_NEW_DATA", flags)
        self.assertIn("ZERO_CONTACT", flags)

    def test_not_worn_sample_allows_zero_contact(self):
        delta = {key: 0 for key in monitor_realtime_ble.COUNTER_KEYS}
        current = {
            "whoop.sample.lastStatus": "zero_contact",
            "whoop.link.lastStatus": "connected",
        }

        flags = monitor_realtime_ble.evaluate_sample(delta, current, worn=False)

        self.assertNotIn("NO_NEW_DATA", flags)
        self.assertNotIn("ZERO_CONTACT", flags)

    def test_summary_fails_when_any_tick_flags(self):
        samples = [
            {
                "current": {"whoop.link.lastStatus": "connected"},
                "delta": {key: 0 for key in monitor_realtime_ble.COUNTER_KEYS},
                "flags": [],
            },
            {
                "current": {"whoop.link.lastStatus": "connected"},
                "delta": {
                    **{key: 0 for key in monitor_realtime_ble.COUNTER_KEYS},
                    "whoop.sample.rawNotifications": 0,
                    "whoop.link.disconnects": 0,
                    "whoop.watchdog.hrContinuityCount": 0,
                },
                "flags": ["NO_NEW_DATA"],
            },
        ]

        summary = monitor_realtime_ble.summarize(samples, worn=True)

        self.assertEqual(summary["status"], "fail")
        self.assertEqual(summary["flags"], ["NO_NEW_DATA"])

    def test_summary_passes_when_only_baseline_has_zero_delta(self):
        baseline_delta = {key: 0 for key in monitor_realtime_ble.COUNTER_KEYS}
        healthy_delta = {
            **{key: 0 for key in monitor_realtime_ble.COUNTER_KEYS},
            "whoop.sample.rawNotifications": 12,
            "whoop.sample.acceptedSamples": 12,
            "whoop.link.disconnects": 0,
            "whoop.watchdog.hrContinuityCount": 0,
        }
        samples = [
            {
                "current": {"whoop.sample.lastStatus": "accepted", "whoop.link.lastStatus": "connected"},
                "delta": baseline_delta,
                "flags": [],
            },
            {
                "current": {"whoop.sample.lastStatus": "accepted", "whoop.link.lastStatus": "connected"},
                "delta": healthy_delta,
                "flags": [],
            },
        ]

        summary = monitor_realtime_ble.summarize(samples, worn=True)

        self.assertEqual(summary["status"], "pass")
        self.assertEqual(summary["min_raw_notification_delta"], 12)


if __name__ == "__main__":
    unittest.main()
