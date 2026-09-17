import tempfile
import unittest
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


if __name__ == '__main__':
    unittest.main()
