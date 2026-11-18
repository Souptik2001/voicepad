"""Static import wiring guard, not a replacement for Mac SDK typechecking."""
from pathlib import Path
import unittest

class PlatformImportTests(unittest.TestCase):
    def test_geometry_file_explicitly_imports_apple_overlay(self):
        root = Path(__file__).resolve().parents[1]
        source = (root / 'Sources/VoicepadCore/ActivityHUDContent.swift').read_text()
        self.assertIn('#if canImport(CoreGraphics)\nimport CoreGraphics\n#endif', source)

if __name__ == '__main__':
    unittest.main()
