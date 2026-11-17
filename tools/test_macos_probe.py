"""Format/fail-closed tests. Set WENCRYPT_MACOS_PROBE to a compiled probe on macOS."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.environ.get('WENCRYPT_MACOS_PROBE'), 'requires compiled macOS probe')
class MacProbeTests(unittest.TestCase):
    def test_missing_malformed_and_oversized_files_stay_locked(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'probe.json'
            for content in (None, b'{', b'{}', b'x' * 16385):
                with self.subTest(content_size=None if content is None else len(content)):
                    if content is not None:
                        path.write_bytes(content)
                    result = subprocess.run(
                        [os.environ['WENCRYPT_MACOS_PROBE'], 'unlockProbeNonInteractive'],
                        env=dict(os.environ, WENCRYPT_PROBE_FILE=str(path)),
                        capture_output=True, text=True, check=False)
                    output = json.loads(result.stdout)
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(output['status'], 'not_passed')
                    self.assertFalse(output['unlocked'])

    def test_reset_missing_file_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            for _ in range(2):
                result = subprocess.run(
                    [os.environ['WENCRYPT_MACOS_PROBE'], 'resetProbe'],
                    env=dict(os.environ, WENCRYPT_PROBE_FILE=str(Path(directory) / 'probe.json')),
                    capture_output=True, text=True, check=True)
                self.assertFalse(json.loads(result.stdout)['unlocked'])
