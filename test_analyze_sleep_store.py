import datetime as dt
import unittest

from tools.analyze_sleep_store import (
    APPLE_EPOCH,
    aggregate_candidates,
    load_archive_range,
)


def apple_seconds(year: int, month: int, day: int, hour: int, minute: int = 0, second: int = 0) -> float:
    value = dt.datetime(year, month, day, hour, minute, second, tzinfo=dt.timezone.utc)
    return (value - APPLE_EPOCH).total_seconds()


def flat_session(start: float, end: float, bpm: int = 52) -> dict:
    duration = int(end - start)
    return {
        "start": start,
        "end": end,
        "label": "resident journal",
        "points": [
            {"t": offset, "bpm": bpm}
            for offset in range(0, duration, 60)
        ],
    }


class AnalyzeSleepStoreMultiSessionTests(unittest.TestCase):
    def candidates(self, sessions: list[dict]) -> list[dict]:
        candidates, _ = aggregate_candidates(
            sessions,
            rest=50,
            max_hr=190,
            timezone="UTC",
            archive=load_archive_range(None),
        )
        return candidates

    def test_contiguous_rollover_sessions_are_one_ready_hr_only_window(self):
        start = apple_seconds(2026, 7, 19, 0)
        boundary = start + 3 * 60 * 60
        sessions = [
            flat_session(start, boundary),
            flat_session(boundary, start + 5 * 60 * 60),
        ]

        candidates = self.candidates(sessions)

        self.assertEqual(len(candidates), 1)
        candidate = candidates[0]
        self.assertEqual(candidate["sessions"], 2)
        self.assertEqual(candidate["duration"], 5 * 60 * 60)
        self.assertEqual(candidate["max_gap"], 0)
        self.assertEqual(candidate["fallback_source"], "hr_only_fragmented_sleep")
        self.assertTrue(candidate["ready"])
        self.assertEqual(candidate["blocker"], "none")

    def test_one_second_rollover_gap_remains_ready(self):
        start = apple_seconds(2026, 7, 19, 0)
        boundary = start + 3 * 60 * 60
        sessions = [
            flat_session(start, boundary),
            flat_session(boundary + 1, start + 5 * 60 * 60 + 1),
        ]

        candidate = self.candidates(sessions)[0]

        self.assertEqual(candidate["sessions"], 2)
        self.assertEqual(candidate["max_gap"], 1)
        self.assertTrue(candidate["ready"])

    def test_gap_above_continuity_limit_stays_fail_closed(self):
        start = apple_seconds(2026, 7, 19, 0)
        boundary = start + 3 * 60 * 60
        sessions = [
            flat_session(start, boundary),
            flat_session(boundary + 61, start + 5 * 60 * 60 + 61),
        ]

        candidate = self.candidates(sessions)[0]

        self.assertEqual(candidate["sessions"], 2)
        self.assertEqual(candidate["max_gap"], 61)
        self.assertFalse(candidate["ready"])

    def test_captured_duration_below_five_hours_stays_fail_closed(self):
        start = apple_seconds(2026, 7, 19, 0)
        boundary = start + 3 * 60 * 60
        sessions = [
            flat_session(start, boundary),
            flat_session(boundary, start + 5 * 60 * 60 - 1),
        ]

        candidate = self.candidates(sessions)[0]

        self.assertEqual(candidate["sessions"], 2)
        self.assertEqual(candidate["duration"], 5 * 60 * 60 - 1)
        self.assertFalse(candidate["ready"])


if __name__ == "__main__":
    unittest.main()
