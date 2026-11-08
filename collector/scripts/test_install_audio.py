"""离线验证下载的校验、原子替换和失败清理；只用合成资源。"""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPERS = (ROOT / 'install.sh').read_text().split('# 音频资源辅助函数：', 1)[1]
HELPERS = HELPERS[HELPERS.index('\naudio_sha_ok()'):HELPERS.index('\ninstall_audio_resources()')]


class AudioDownloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.payload = self.root / 'payload'
        self.payload.write_bytes(b'synthetic audio model\x00\x01')
        self.sha = hashlib.sha256(self.payload.read_bytes()).hexdigest()
        self.target = self.root / 'models' / 'vad.onnx'
        self.target.parent.mkdir()
        self.target.write_bytes(b'old model')
        stub = self.root / 'curl'
        stub.write_text('''#!/bin/sh
printf x >> "$CALLS"
[ "${FAIL_DOWNLOAD:-0}" = 0 ] || exit 22
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then cp "$PAYLOAD" "$2"; exit; fi
  shift
done
exit 1
''')
        stub.chmod(0o700)
        self.env = dict(os.environ, PATH=str(self.root) + ':' + os.environ['PATH'],
                        PAYLOAD=str(self.payload), CALLS=str(self.root / 'calls'))

    def download(self, sha=None, fail=False):
        env = dict(self.env, FAIL_DOWNLOAD='1' if fail else '0')
        return subprocess.run(['sh', '-c', HELPERS + '\naudio_download "$1" "$2" https://synthetic.invalid/model',
                               'check', str(self.target), sha or self.sha], env=env, capture_output=True)

    def test_verified_replacement_and_repeat_skips_download(self):
        self.assertEqual(self.download().returncode, 0)
        self.assertEqual(self.target.read_bytes(), self.payload.read_bytes())
        self.assertEqual(self.download().returncode, 0)
        self.assertEqual((self.root / 'calls').read_text(), 'x')
        self.assertEqual(list(self.target.parent.glob('*.download.*')), [])

    def test_wrong_hash_keeps_existing_file_and_removes_temporary(self):
        self.assertNotEqual(self.download('0' * 64).returncode, 0)
        self.assertEqual(self.target.read_bytes(), b'old model')
        self.assertEqual(list(self.target.parent.glob('*.download.*')), [])

    def test_network_failure_keeps_existing_file_and_removes_temporary(self):
        self.assertNotEqual(self.download(fail=True).returncode, 0)
        self.assertEqual(self.target.read_bytes(), b'old model')
        self.assertEqual(list(self.target.parent.glob('*.download.*')), [])


if __name__ == '__main__':
    unittest.main()
