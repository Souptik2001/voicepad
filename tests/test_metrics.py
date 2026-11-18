import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

class MetricsTests(unittest.TestCase):
    def test_records_attempts_separately_from_successful_requests_and_persists(self):
        from metrics import UsageMetrics
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'metrics.json'
            metrics = UsageMetrics(path)
            metrics.attempt(12.5)
            metrics.attempt(12.5)
            metrics.finish(success=True, audio_seconds=12.5, elapsed=1.2)
            metrics.attempt(8)
            metrics.finish(success=False, audio_seconds=8, elapsed=3)
            snapshot = UsageMetrics(path).snapshot()
            totals = snapshot['totals']
            self.assertEqual(totals['requests'], 2)
            self.assertEqual(totals['successful'], 1)
            self.assertEqual(totals['failed'], 1)
            self.assertEqual(totals['provider_calls'], 3)
            self.assertEqual(totals['submitted_audio_seconds'], 33)
            self.assertEqual(totals['successful_audio_seconds'], 12.5)
            self.assertEqual(totals['successful_processing_seconds'], 1.2)
            self.assertEqual(totals['max_processing_seconds'], 1.2)
            self.assertIsNone(snapshot['quota']['tokens'])
            self.assertIsNone(snapshot['quota']['subscription_percent'])
            self.assertIsNone(snapshot['quota']['cost_usd'])
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertNotIn('transcript', path.read_text())

    def test_daily_retention_bounds_storage_without_losing_lifetime_totals(self):
        from metrics import UsageMetrics
        from datetime import timedelta
        with tempfile.TemporaryDirectory() as directory:
            current = [datetime(2026, 1, 1, tzinfo=timezone.utc)]
            metrics = UsageMetrics(Path(directory) / 'metrics.json', clock=lambda: current[0])
            for _ in range(400):
                metrics.attempt(10)
                metrics.finish(success=True, audio_seconds=10, elapsed=1)
                current[0] += timedelta(days=1)
            snapshot = metrics.snapshot()
            self.assertEqual(snapshot['totals']['successful'], 400)
            self.assertEqual(snapshot['today']['requests'], 0)
            self.assertLessEqual(len(metrics.data['days']), 366)
            self.assertLessEqual(len(snapshot['days']), 30)
            self.assertLess(metrics.path.stat().st_size, 200000)

    def test_storage_write_failure_is_visible_and_does_not_raise(self):
        from metrics import UsageMetrics
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            metrics = UsageMetrics(Path(directory) / 'metrics.json')
            with patch('metrics.os.replace', side_effect=OSError('disk full')):
                metrics.attempt(1)
            metrics.finish(success=True, audio_seconds=1, elapsed=0.5)
            self.assertFalse(metrics.snapshot()['storage']['healthy'])
            self.assertEqual(list(Path(directory).glob('.metrics-*')), [])

    def test_invalid_saved_metrics_are_not_silently_reset(self):
        from metrics import UsageMetrics
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'metrics.json'
            path.write_text('broken')
            metrics = UsageMetrics(path)
            metrics.attempt(5)
            metrics.finish(success=True, audio_seconds=5, elapsed=1)
            self.assertFalse(metrics.snapshot()['storage']['healthy'])
            self.assertEqual(path.read_text(), 'broken')

if __name__ == '__main__':
    unittest.main()
