import argparse
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import release


class ReleaseTests(unittest.TestCase):
    def test_stage_rejects_mismatched_version(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(release, 'STAGE_BASE', Path(temp)):
            self.assertNotEqual(release.command_stage(argparse.Namespace(version='9.9.9')), 0)

    def test_stage_has_no_dependency_overrides_or_generated_files(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(release, 'STAGE_BASE', Path(temp)):
            self.assertEqual(release.command_stage(argparse.Namespace(version='0.1.0')), 0)
            for package in release.TOPOLOGICAL_ORDER:
                root = Path(temp) / '0.1.0' / package
                self.assertNotIn('path:', (root / 'mix.exs').read_text())
                self.assertFalse((root / 'priv/autonomic_launcher').exists())
                self.assertFalse((root / 'var').exists())

            typesafe_mix = (Path(temp) / '0.1.0' / 'autonomic_typesafe' / 'mix.exs').read_text()
            self.assertIn('{:typesafe_sdk, "~> 0.4.0"}', typesafe_mix)
            self.assertNotIn('TYPESAFE_SDK_PATH', typesafe_mix)


if __name__ == '__main__':
    unittest.main()
