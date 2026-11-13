import json
from pathlib import Path
import subprocess
import sys
import unittest


class GuardTests(unittest.TestCase):
    def invoke(self, code, memory=64, seconds=5):
        return subprocess.run([sys.executable, str(Path(__file__).with_name("guarded-run.py")),
                               "--memory-mb", str(memory), "--seconds", str(seconds), "--",
                               sys.executable, "-c", code], capture_output=True, text=True, timeout=10)

    def test_normal_exit_is_preserved(self):
        result = self.invoke("raise SystemExit(3)")
        self.assertEqual(result.returncode, 3)
        self.assertEqual(json.loads(result.stderr)["guard"], "completed")

    def test_child_memory_is_bounded(self):
        result = self.invoke('import subprocess,sys,time; subprocess.Popen([sys.executable,"-c","import time; x=bytearray(96*1024*1024); time.sleep(10)"]); time.sleep(10)')
        self.assertEqual(result.returncode, 124)
        data = json.loads(result.stderr)
        self.assertEqual(data["guard"], "memory_limit")
        self.assertLess(data["seconds"], 3)

    def test_exited_child_does_not_hide_guard_result_on_group_permission_race(self):
        script = Path(__file__).with_name("guarded-run.py")
        code = f"import runpy,unittest.mock as m; g=runpy.run_path({str(script)!r}); patch=m.patch('os.killpg',side_effect=PermissionError(1,'Operation not permitted')); patch.start(); raise SystemExit(g['run']([{sys.executable!r},'-c','import time; time.sleep(10)'],seconds=0.2))"
        result = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertEqual(json.loads(result.stderr)["guard"], "time_limit")

    def test_hung_command_is_stopped(self):
        result = self.invoke("import time; time.sleep(10)", seconds=1)
        self.assertEqual(result.returncode, 124)
        self.assertEqual(json.loads(result.stderr)["guard"], "time_limit")


if __name__ == "__main__":
    unittest.main()
