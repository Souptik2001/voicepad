"""Bounded numeric usage aggregates; never stores audio, transcript or identity."""
import copy
import json
import math
import os
import tempfile
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path

RETENTION_DAYS = 366


def empty():
    return {'requests': 0, 'successful': 0, 'failed': 0, 'provider_calls': 0,
            'submitted_audio_seconds': 0.0, 'successful_audio_seconds': 0.0,
            'successful_processing_seconds': 0.0, 'max_processing_seconds': 0.0,
            'last_request_at': None}


class UsageMetrics:
    def __init__(self, path, clock=None):
        self.path = Path(path)
        self.clock = clock or (lambda: datetime.now(timezone.utc))
        self.lock = threading.Lock()
        self.healthy = True
        self.note = 'Numeric aggregates only. No recordings or transcript history.'
        now = self.clock()
        self.data = {'version': 1, 'tracking_since': now.isoformat(), 'totals': empty(), 'days': {}}
        if self.path.exists():
            try:
                if self.path.stat().st_size > 1_000_000:
                    raise ValueError('Metrics file exceeds bounded size')
                saved = json.loads(self.path.read_text())
                if saved['version'] != 1 or not isinstance(saved['days'], dict):
                    raise ValueError('Invalid metrics structure')
                for record in [saved['totals'], *saved['days'].values()]:
                    if set(record) != set(empty()):
                        raise ValueError('Unexpected metrics fields')
                    if any(not isinstance(record[key], (int, float)) or not math.isfinite(record[key]) or record[key] < 0
                           for key in empty() if key != 'last_request_at'):
                        raise ValueError('Invalid metrics values')
                self.data = saved
            except (OSError, ValueError, KeyError, TypeError):
                # Never overwrite unreadable historical usage with a plausible zero.
                self.healthy = False
                self.note = 'Saved metrics could not be read; totals are unavailable. Tracking disabled until repaired.'
        with self.lock:
            self.prune()
            if not self.path.exists():
                self.persist()

    def prune(self):
        cutoff = (self.clock().date() - timedelta(days=RETENTION_DAYS - 1)).isoformat()
        self.data['days'] = {day: value for day, value in self.data['days'].items() if day >= cutoff}

    def persist(self):
        if not self.healthy:
            return
        name = None
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            descriptor, name = tempfile.mkstemp(prefix='.metrics-', dir=self.path.parent)
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, 'w') as output:
                json.dump(self.data, output, separators=(',', ':'), allow_nan=False)
                output.flush()
                os.fsync(output.fileno())
            os.replace(name, self.path)
        except OSError:
            self.healthy = False
            self.note = 'Metrics could not be saved; displayed counters may be incomplete. Transcription is unaffected.'
        finally:
            if name and os.path.exists(name):
                os.unlink(name)

    def records(self):
        now = self.clock()
        self.prune()
        return [self.data['totals'], self.data['days'].setdefault(now.date().isoformat(), empty())], now.isoformat()

    def attempt(self, audio_seconds):
        if not math.isfinite(audio_seconds) or audio_seconds < 0:
            raise ValueError('Invalid audio duration')
        with self.lock:
            if not self.healthy:
                return
            records, _ = self.records()
            for record in records:
                record['provider_calls'] += 1
                record['submitted_audio_seconds'] += audio_seconds
            self.persist()

    def finish(self, *, success, audio_seconds=0.0, elapsed=0.0):
        if any(not math.isfinite(value) or value < 0 for value in [audio_seconds, elapsed]):
            raise ValueError('Invalid request measurement')
        with self.lock:
            if not self.healthy:
                return
            records, now = self.records()
            for record in records:
                record['requests'] += 1
                record['successful' if success else 'failed'] += 1
                record['last_request_at'] = now
                if success:
                    record['successful_audio_seconds'] += audio_seconds
                    record['successful_processing_seconds'] += elapsed
                    record['max_processing_seconds'] = max(record['max_processing_seconds'], elapsed)
            self.persist()

    def snapshot(self):
        with self.lock:
            self.prune()
            today = self.clock().date().isoformat()
            data = copy.deepcopy(self.data)
            recent_cutoff = (self.clock().date() - timedelta(days=29)).isoformat()
            return {'tracking_since': data['tracking_since'], 'timezone': 'UTC',
                    'quota': {'tokens': None, 'subscription_percent': None, 'cost_usd': None,
                              'note': 'OpenAI does not report token, subscription quota or cost usage for this endpoint.'},
                    'totals': data['totals'], 'today': data['days'].get(today, empty()),
                    'days': [{'date': day, **record} for day, record in sorted(data['days'].items(), reverse=True) if recent_cutoff <= day <= today][:30],
                    'retention_days': RETENTION_DAYS,
                    'storage': {'healthy': self.healthy, 'note': self.note}}
