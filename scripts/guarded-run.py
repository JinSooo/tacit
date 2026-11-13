#!/usr/bin/env python3
"""Run development checks with a wall-time and whole-process-tree memory budget (macOS)."""
import argparse
import ctypes as C
import json
import os
import signal
import subprocess
import sys
import time


class Usage(C.Structure):
    _fields_ = [("uuid", C.c_ubyte * 16)] + [(name, C.c_uint64) for name in
        "user system idle interrupt pageins wired resident footprint start exit child_user child_system child_idle child_interrupt child_pageins child_elapsed read written".split()]


class Processes:
    def __init__(self):
        self.lib = C.CDLL("/usr/lib/libproc.dylib")
        self.lib.proc_pid_rusage.argtypes = [C.c_int, C.c_int, C.c_void_p]
        self.lib.proc_listchildpids.argtypes = [C.c_int, C.c_void_p, C.c_int]

    def usage(self, pid):
        result = Usage()
        return result if self.lib.proc_pid_rusage(pid, 2, C.byref(result)) == 0 else None

    def tree(self, root):
        found, todo = {}, [root]
        while todo:
            pid = todo.pop()
            if pid in found:
                continue
            usage = self.usage(pid)
            if usage is None:
                continue
            found[pid] = usage
            buf = (C.c_int * 8192)()
            count = self.lib.proc_listchildpids(pid, buf, C.sizeof(buf))
            if count < 0 or count >= len(buf):
                raise RuntimeError("incomplete process inventory")
            todo.extend(int(p) for p in buf[:count] if p > 0)
        return found


def run(command, memory_mb=1536, seconds=180):
    processes = Processes()
    child = subprocess.Popen(command, start_new_session=True)
    started, peak, reason, known = time.monotonic(), 0, None, {}
    def stop():
        # Detached test helpers can leave the parent's process group; remember their start identity.
        for pid, old in known.items():
            now = processes.usage(pid)
            if now is not None and now.start == old.start:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
    try:
        while child.poll() is None:
            current = processes.tree(child.pid)
            known.update(current)
            # phys_footprint includes compressed memory; RSS alone misses the exact failure this guards.
            total = sum(v.footprint for v in current.values()) / 1048576
            peak = max(peak, total)
            if total > memory_mb:
                reason = "memory_limit"
            elif time.monotonic() - started > seconds:
                reason = "time_limit"
            if reason:
                stop()
                break
            time.sleep(0.1)
    except BaseException:
        stop()
        raise
    print(json.dumps({"guard": reason or "completed", "peak_tree_mib": round(peak, 1),
                      "seconds": round(time.monotonic() - started, 2)}), file=sys.stderr)
    return 124 if reason else child.returncode


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--memory-mb", type=int, default=1536)
    parser.add_argument("--seconds", type=int, default=180)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or args.memory_mb < 32 or args.seconds < 1:
        parser.error("command and positive resource budgets are required")
    sys.exit(run(command, args.memory_mb, args.seconds))
