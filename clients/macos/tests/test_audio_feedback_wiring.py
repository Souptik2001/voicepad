"""Native wiring guards, not substitutes for a real macOS audio test."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]

class AudioFeedbackWiringTests(unittest.TestCase):
    def test_cues_are_tied_to_capture_and_confirmed_paste_not_shortcut_events(self):
        source=(ROOT/'Sources/Voicepad/AppController.swift').read_text()
        self.assertIn('feedback.play(.recordingStarted)',source)
        self.assertLess(source.index('feedback.play(.recordingStarted)'),source.index('try self.recorder.start()'))
        self.assertIn('try await Task.sleep',source)
        self.assertIn('feedback.play(.recordingStopped)',source)
        self.assertIn('if result.confirmed { self.feedback.play(.pasted) }',source)
        self.assertIn('Sound Effects',source)
        self.assertIn('feedback.stop()',source)
    def test_player_is_local_and_notice_is_short_without_changing_clipboard_grace(self):
        player=(ROOT/'Sources/Voicepad/FeedbackPlayer.swift').read_text()
        self.assertIn('NSSound(data: cue.wavData())',player)
        self.assertNotIn('byReference:',player)
        self.assertIn('soundEffectsEnabled',player)
        hud=(ROOT/'Sources/Voicepad/ActivityHUD.swift').read_text()
        self.assertIn('dismiss(after: FeedbackTiming.pasteNoticeSeconds)',hud)
        coordinator=(ROOT/'Sources/VoicepadCore/PasteCoordinator.swift').read_text()
        self.assertIn('confirmationDeadline = environment.monotonicNow + 2',coordinator)
