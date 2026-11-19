import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class UninstallTests(unittest.TestCase):
    def test_removes_snapshot_when_history_is_kept(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = root / "home"
            data = home / "Library/Application Support/record-anything"
            widget = data / "widget"
            widget.mkdir(parents=True)
            (widget / "today.json").write_text('{"day":"2026-01-15"}')
            history = data / "history-fixture"
            history.write_text("fictional history")

            script = root / "uninstall.sh"
            shutil.copyfile(Path(__file__).resolve().parent.parent / script.name, script)
            (root / "scripts").mkdir()
            # The uninstall script also scans /Applications. Never claim ownership of a real app.
            (root / "scripts/mac-app.sh").write_text("tacit_owns_bundle() { return 1; }\n")
            bin_dir = root / "bin"
            bin_dir.mkdir()
            for name in ("launchctl", "tccutil", "security"):
                command = bin_dir / name
                command.write_text("#!/bin/sh\nexit 0\n")
                command.chmod(0o700)
            env = dict(os.environ, HOME=str(home), PATH=f"{bin_dir}:/usr/bin:/bin", LC_ALL="C")
            result = subprocess.run(["/bin/sh", str(script)], env=env, start_new_session=True,
                                    capture_output=True, text=True, timeout=5)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(widget.exists())
            self.assertEqual(history.read_text(), "fictional history")
            self.assertIn(f"数据保留在 {data}（", result.stdout)


if __name__ == "__main__":
    unittest.main()
