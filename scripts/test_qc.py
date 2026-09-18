import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch
import qc


class QCTests(unittest.TestCase):
    def test_empty_mix_suite_fails_but_rust_output_is_not_parsed_as_exunit(self):
        with tempfile.TemporaryDirectory(dir=qc.ROOT) as temp:
            root = Path(temp)
            with patch.object(qc, 'LOGS', root):
                for name, expected in [('mix', 'failed'), ('cargo', 'passed')]:
                    executable = root / name
                    executable.write_text('#!/bin/sh\necho "0 tests"\n')
                    executable.chmod(0o755)
                    gate = qc.run_gate('test_fixture', [str(executable), 'test'])
                    self.assertEqual(gate['status'], expected)

    def test_run_gate_reports_live_progress_without_streaming_command_output(self):
        with tempfile.TemporaryDirectory(dir=qc.ROOT) as temp:
            root = Path(temp)
            executable = root / "cargo"
            executable.write_text('#!/bin/sh\necho "internal command output"\n')
            executable.chmod(0o755)

            output = StringIO()
            with patch.object(qc, "LOGS", root), redirect_stdout(output):
                gate = qc.run_gate("progress_fixture", [str(executable), "check"])

            self.assertEqual(gate["status"], "passed")
            rendered = output.getvalue()
            self.assertIn("START progress_fixture", rendered)
            self.assertIn("PASS  progress_fixture", rendered)
            self.assertNotIn("internal command output", rendered)
            self.assertIn("internal command output", (root / "progress_fixture.log").read_text())


if __name__ == '__main__':
    unittest.main()
