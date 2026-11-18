"""Static guard for the Mac recovery panel's Voicepad visual treatment."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class TranscriptPanelStylingTests(unittest.TestCase):
    def test_recovery_panel_uses_warm_palette_spacing_and_styled_copy_button(self):
        source = (ROOT / 'Sources/Voicepad/Presentation.swift').read_text()
        for marker in [
            'VoicepadPanelPalette.paper',
            'VoicepadPanelPalette.ivory',
            'VoicepadPanelPalette.terracotta',
            'panel.isOpaque = false',
            'textView.textContainerInset = NSSize(width: 16, height: 14)',
            'let copy = NSButton(title: "  Copy  "',
            'copy.contentTintColor = VoicepadPanelPalette.ivory',
            'copy.layer?.cornerRadius = 8',
            'copy.widthAnchor.constraint(equalToConstant: 92)',
        ]:
            self.assertIn(marker, source)
        self.assertNotIn('scroll.borderType = .bezelBorder', source)


if __name__ == '__main__':
    unittest.main()
