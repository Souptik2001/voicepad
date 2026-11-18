from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ProfileChipStylingTests(unittest.TestCase):
    def test_chip_uses_executed_content_geometry_and_explicit_button_height(self):
        # Wiring guard only; Swift tests execute inset/height geometry.
        source = (ROOT / 'Sources/Voicepad/ActivityHUD.swift').read_text()
        self.assertIn('button.cell = ProfileChipCell(textCell: chip.title)', source)
        self.assertIn('ActivityHUDLayout.profileChipContentRect(in: controlView.bounds)', source)
        self.assertIn('button.heightAnchor.constraint(equalToConstant: ActivityHUDLayout.profileChipHeight)', source)
        self.assertIn('height: ActivityHUDLayout.cardHeight(profileRows: rows)', source)
        self.assertNotIn('button.contentInsets', source)
        self.assertNotIn('title: "  \\(chip.title)  "', source)


if __name__ == '__main__':
    unittest.main()
