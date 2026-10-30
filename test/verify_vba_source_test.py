"""Run with the Python environment containing oletools==0.60.2."""

import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / 'tool' / 'verify_vba_source.py'
PROJECT = ROOT / 'assets' / 'vba' / 'vbaProject.bin'


class VbaSourceVerificationTests(unittest.TestCase):
    def run_script(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *map(str, args)],
                              text=True, capture_output=True, check=False)

    def test_reviewed_project_and_candidate(self):
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.run_script(PROJECT).returncode, 0)

    def test_rejects_unexpected_arguments(self):
        result = self.run_script(PROJECT, PROJECT)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unrecognized arguments', result.stderr)

    def test_rejects_source_and_altered_ole_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = pathlib.Path(temporary) / 'source.bas'
            source.write_text('Sub Test()\nEnd Sub\n', encoding='utf-8')
            result = self.run_script(source)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('OLE compound file', result.stderr)
            changed = bytearray(PROJECT.read_bytes())
            changed[-1] ^= 1
            candidate = pathlib.Path(temporary) / 'altered.bin'
            candidate.write_bytes(changed)
            result = self.run_script(candidate)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('SHA-256', result.stderr)


if __name__ == '__main__':
    unittest.main()
