import importlib.util
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("performance_sample", Path(__file__).with_name("performance-sample.py"))
perf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(perf)


def sample(cpu, awake, wall=None, identity=(100, 10), locked=False):
    return {"run": "a", "at": "2026-11-13T09:00:00+09:00", "awake_s": awake,
            "wall_s": awake if wall is None else wall, "locked": locked,
            "processes": {"collector": {"identity": identity, "tree_cpu_s": cpu,
                "self_cpu_s": cpu, "footprint_mb": 100, "largest_child_footprint_mb": 500}}}


class AccountingTests(unittest.TestCase):
    def test_startup_baseline_excludes_existing_cpu(self):
        result = perf.interval(sample(1000, 100), sample(1000.15, 105), "collector")
        self.assertAlmostEqual(result["cpu_s"], .15)
        self.assertAlmostEqual(result["cpu_s"] / result["awake_s"] * 100, 3)

    def test_sleep_does_not_dilute_cpu_or_count_as_locked_idle(self):
        result = perf.interval(sample(2, 100, 100, locked=True), sample(2.2, 105, 7305, locked=True), "collector")
        self.assertEqual(result["awake_s"], 5)
        self.assertTrue(result["sleep_between"])
        self.assertFalse(result["locked"])

    def test_restarts_missing_process_and_delayed_sampler_are_gaps(self):
        a = sample(2, 100)
        b = sample(1, 105, identity=(100, 20))  # reused PID
        self.assertEqual(perf.interval(a, b, "collector")["error"], "process_restarted")
        b["processes"]["collector"] = {"error": "unreadable"}
        self.assertEqual(perf.interval(a, b, "collector")["error"], "missing_process")
        self.assertEqual(perf.interval(a, sample(3, 130), "collector")["error"], "sampler_gap_or_clock_change")
        self.assertEqual(perf.interval(a, sample(1, 105), "collector")["error"], "counter_regressed")

    def test_summary_distinguishes_unknown_zero_and_locked_collector_self(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            a, b = sample(10, 100, locked=True), sample(11, 105, locked=True)
            a["type"] = b["type"] = "sample"
            a["processes"]["collector"]["self_cpu_s"] = 3
            b["processes"]["collector"]["self_cpu_s"] = 3.025
            for row in [a, b]: perf.append(folder / "cpu-2026-11-13.jsonl", row)
            r = perf.report(folder, "2026-11-13")
            self.assertAlmostEqual(r["roles"]["collector"]["cpu_percent_one_core"], 20)
            self.assertAlmostEqual(r["roles"]["collector"]["locked_self_cpu_percent"], .5)
            self.assertIsNone(r["roles"]["hub"]["cpu_percent_one_core"])
            self.assertIsNone(r["models"])
            self.assertFalse(r["normal_day_candidate"])

    @unittest.skipUnless(sys.platform == "darwin", "macOS kernel counters")
    def test_kernel_cpu_units_match_getrusage(self):
        n = perf.Native()
        v = n.usage(os.getpid())
        expected = resource.getrusage(resource.RUSAGE_SELF)
        self.assertAlmostEqual(v["self_cpu_s"], expected.ru_utime + expected.ru_stime, delta=.03)

    @unittest.skipUnless(sys.platform == "darwin", "macOS process tree")
    def test_short_child_and_grandchild_cpu_survive_reap_without_double_count(self):
        n = perf.Native()
        before = n.tree(os.getpid())["tree_cpu_s"]
        child = "import time,resource;t=time.process_time();\nwhile time.process_time()-t<0.15: pass\nprint(resource.getrusage(0).ru_utime+resource.getrusage(0).ru_stime)"
        parent = "import subprocess,sys;subprocess.run([sys.executable,'-c'," + repr(child) + "])"
        r = subprocess.run([sys.executable, "-c", parent], capture_output=True, text=True, check=True)
        expected = float(r.stdout)
        after = n.tree(os.getpid())["tree_cpu_s"]
        self.assertGreater(after - before, expected * .95)
        self.assertLess(after - before, expected * 1.9)  # parent overhead allowed, grandchild not counted twice

    @unittest.skipUnless(sys.platform == "darwin", "macOS process tree")
    def test_live_child_cpu_transfers_to_reaped_counter(self):
        n = perf.Native()
        child = "import time,sys;t=time.process_time();\nwhile time.process_time()-t<0.2: pass\nprint('ready',flush=True);sys.stdin.readline()"
        p = subprocess.Popen([sys.executable, "-c", child], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(p.stdout.readline().strip(), "ready")
            live = n.tree(os.getpid())
            self.assertGreaterEqual(live["live_processes"], 2)
            p.communicate("exit\n", timeout=5)
            reaped = n.tree(os.getpid())
            self.assertGreaterEqual(reaped["tree_cpu_s"], live["tree_cpu_s"])
            self.assertLess(reaped["tree_cpu_s"] - live["tree_cpu_s"], .15)
        finally:
            if p.poll() is None: p.kill(); p.wait()
            p.stdin.close(); p.stdout.close()


if __name__ == "__main__":
    unittest.main()
