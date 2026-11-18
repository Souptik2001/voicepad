"""Static native wiring guards only; portable Swift tests execute the policy.

These checks do NOT execute AVAudioRecorder or replace Mac SDK typechecking.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RecordingLimitsWiringTests(unittest.TestCase):
    def test_native_capture_uses_executed_shared_policy(self):
        source = (ROOT / 'Sources/Voicepad/AudioRecorder.swift').read_text()
        for wiring in [
            'import VoicepadCore',
            'static let maximumBytes = RecordingLimits.maximumBytes',
            'static let maximumSeconds = RecordingLimits.maximumSeconds',
            'audio.record(forDuration: RecordingLimits.captureSeconds)',
            'guard RecordingLimits.acceptsDuration(seconds) else',
            'guard bytes <= Self.maximumBytes else',
            'guard data.count <= Self.maximumBytes else',
            'defer { purge() }',
            'removeItem(at: temporaryDirectory)',
        ]:
            self.assertIn(wiring, source)
        controller = (ROOT / 'Sources/Voicepad/AppController.swift').read_text()
        self.assertIn('recorder.onDurationLimit = { [weak self] in self?.finishRecording() }', controller)
        self.assertIn('recorder.fileBytes > AudioRecorder.maximumBytes', controller)
        self.assertIn('seconds >= AudioRecorder.maximumSeconds', controller)
        # Failed-audio lifetime is NOT the capture limit. Retry cannot extend it.
        self.assertIn('guard pending == nil else { return }', controller)
        self.assertIn('Date().addingTimeInterval(120)', controller)
        self.assertIn('Task.sleep(nanoseconds: 120_000_000_000)', controller)
        self.assertIn('URLSessionConfiguration.ephemeral', controller)

    def test_native_network_budget_uses_shared_timeout_policy(self):
        source = (ROOT / 'Sources/Voicepad/AppController.swift').read_text()
        self.assertIn('configuration.timeoutIntervalForRequest = RecordingLimits.requestTimeout', source)
        self.assertIn('configuration.timeoutIntervalForResource = RecordingLimits.resourceTimeout', source)

    def test_native_errors_show_ten_minute_and_25_mib_limits(self):
        source = (ROOT / 'Sources/Voicepad/AudioRecorder.swift').read_text()
        self.assertIn('The audio exceeded 600 seconds (10 minutes) and was discarded.', source)
        self.assertIn('The recording exceeded the 25 MiB upload limit and was discarded.', source)


if __name__ == '__main__':
    unittest.main()
