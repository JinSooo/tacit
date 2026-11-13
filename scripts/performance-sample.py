#!/usr/bin/env python3
"""独立的 macOS 试用采样器：CPU/内存/锁屏状态与模型计量，不采正文。"""
from __future__ import annotations

import argparse
import ctypes as C
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

FIELDS = "user_time system_time pkg_idle_wkups interrupt_wkups pageins wired_size resident_size phys_footprint proc_start_abstime proc_exit_abstime child_user_time child_system_time child_pkg_idle_wkups child_interrupt_wkups child_pageins child_elapsed_abstime diskio_bytesread diskio_byteswritten".split()


class Usage(C.Structure):
    _fields_ = [("uuid", C.c_ubyte * 16)] + [(name, C.c_uint64) for name in FIELDS]


class Timebase(C.Structure):
    _fields_ = [("numer", C.c_uint32), ("denom", C.c_uint32)]


class Native:
    def __init__(self):
        self.proc = C.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.proc.proc_pid_rusage.argtypes = [C.c_int, C.c_int, C.c_void_p]
        self.proc.proc_listchildpids.argtypes = [C.c_int, C.c_void_p, C.c_int]
        self.proc.proc_listallpids.argtypes = [C.c_void_p, C.c_int]
        self.proc.proc_pidpath.argtypes = [C.c_int, C.c_void_p, C.c_uint32]
        self.system = C.CDLL("/usr/lib/libSystem.B.dylib")
        self.system.mach_absolute_time.restype = C.c_uint64
        base = Timebase()
        if self.system.mach_timebase_info(C.byref(base)) != 0 or not base.denom:
            raise RuntimeError("timebase unavailable")
        self.scale = base.numer / base.denom / 1e9
        self.cg = C.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        self.cf = C.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        self.cg.CGSessionCopyCurrentDictionary.restype = C.c_void_p
        self.cf.CFStringCreateWithCString.argtypes = [C.c_void_p, C.c_char_p, C.c_uint32]
        self.cf.CFStringCreateWithCString.restype = C.c_void_p
        self.cf.CFDictionaryGetValue.argtypes = [C.c_void_p, C.c_void_p]
        self.cf.CFDictionaryGetValue.restype = C.c_void_p
        self.cf.CFBooleanGetValue.argtypes = [C.c_void_p]
        self.cf.CFBooleanGetValue.restype = C.c_bool
        self.cf.CFRelease.argtypes = [C.c_void_p]
        self.lock_key = self.cf.CFStringCreateWithCString(None, b"CGSSessionScreenIsLocked", 0x08000100)

    def awake(self):
        # mach_absolute_time excludes sleep; time.monotonic on Python versions may not.
        return self.system.mach_absolute_time() * self.scale

    def usage(self, pid):
        value = Usage()
        if self.proc.proc_pid_rusage(pid, 2, C.byref(value)) != 0:
            return None
        return {"pid": pid, "start": value.proc_start_abstime,
                "self_cpu_s": (value.user_time + value.system_time) * self.scale,
                "reaped_cpu_s": (value.child_user_time + value.child_system_time) * self.scale,
                "footprint_mb": value.phys_footprint / 1048576}

    def children(self, pid):
        # This API returns the number of PIDs, although its buffer size is in bytes.
        buf = (C.c_int * 8192)()
        count = self.proc.proc_listchildpids(pid, buf, C.sizeof(buf))
        if count < 0 or count >= len(buf):
            raise RuntimeError("incomplete child inventory")
        return {int(buf[i]) for i in range(count) if buf[i] > 0}

    def path(self, pid):
        buf = C.create_string_buffer(4096)
        return buf.value.decode("utf8", "replace") if self.proc.proc_pidpath(pid, buf, len(buf)) > 0 else ""

    def core_audio_pid(self):
        buf = (C.c_int * 32768)()
        count = self.proc.proc_listallpids(buf, C.sizeof(buf))
        for pid in buf[:max(0, min(count, len(buf)))]:
            if pid > 0 and self.path(pid) == "/usr/sbin/coreaudiod":
                return pid
        return None

    def locked(self):
        state = self.cg.CGSessionCopyCurrentDictionary()
        if not state:
            return None
        try:
            value = self.cf.CFDictionaryGetValue(state, self.lock_key)
            return bool(self.cf.CFBooleanGetValue(value)) if value else False
        finally:
            self.cf.CFRelease(state)

    def inventory(self, root):
        todo, found = [root], set()
        while todo:
            pid = todo.pop()
            if pid in found:
                continue
            found.add(pid)
            todo.extend(self.children(pid))
        return found

    def tree(self, root):
        if not root:
            return {"error": "not_running"}
        # Child exit/reap transfers its CPU to its parent. Retry if the live set changes
        # while sampling, so the same child isn't counted on both sides of that transfer.
        for _ in range(3):
            before = self.inventory(root)
            values = [self.usage(pid) for pid in sorted(before)]
            if None in values or before != self.inventory(root):
                continue
            owner = next(v for v in values if v["pid"] == root)
            return {"identity": [root, owner["start"]], "self_cpu_s": owner["self_cpu_s"],
                    "tree_cpu_s": sum(v["self_cpu_s"] + v["reaped_cpu_s"] for v in values),
                    "footprint_mb": owner["footprint_mb"], "live_processes": len(values),
                    "live_children_footprint_mb": sum(v["footprint_mb"] for v in values if v["pid"] != root),
                    "largest_child_footprint_mb": max([v["footprint_mb"] for v in values if v["pid"] != root] or [0])}
        return {"error": "process_tree_changed_or_unreadable"}


def roots():
    result = subprocess.run(["/bin/launchctl", "list"], capture_output=True, text=True, timeout=5)
    if result.returncode:
        raise RuntimeError("launchctl unavailable")
    found = {}
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2] in {"dev.record-anything." + n for n in ("collector", "hub", "distill")}:
            found[parts[2].rsplit(".", 1)[1]] = int(parts[0]) if parts[0].isdigit() else None
    return found


def local_now():
    return dt.datetime.now().astimezone()


def append(path, value):
    with path.open("a", encoding="utf8") as stream:
        stream.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")


def interval(previous, current, role):
    elapsed = current["awake_s"] - previous["awake_s"]
    wall = current["wall_s"] - previous["wall_s"]
    if elapsed <= 0 or elapsed > 20 or wall < 0:
        return {"error": "sampler_gap_or_clock_change", "awake_s": max(0, elapsed)}
    a, b = previous["processes"].get(role, {}), current["processes"].get(role, {})
    if "identity" not in a or "identity" not in b:
        return {"error": "missing_process", "awake_s": elapsed}
    if a["identity"] != b["identity"]:
        return {"error": "process_restarted", "awake_s": elapsed}
    cpu = b["tree_cpu_s"] - a["tree_cpu_s"]
    own = b["self_cpu_s"] - a["self_cpu_s"]
    if cpu < 0 or own < 0:
        return {"error": "counter_regressed", "awake_s": elapsed}
    return {"awake_s": elapsed, "cpu_s": cpu, "self_cpu_s": own,
            "sleep_between": wall - elapsed > 10,
            "locked": previous["locked"] is True and current["locked"] is True and wall - elapsed < 10}


def report(directory, date):
    path = directory / ("cpu-" + date + ".jsonl")
    rows = []
    for line in path.read_text().splitlines() if path.exists() else []:
        try:
            value = json.loads(line)
            if value.get("type") == "sample": rows.append(value)
        except ValueError:
            pass  # An interrupted final write cannot turn into a zero-CPU sample.
    result = {"date": date, "samples": len(rows), "first": rows[0]["at"] if rows else None,
              "last": rows[-1]["at"] if rows else None, "roles": {},
              "note": "单核CPU；按有效醒着采样时间计算。coreaudiod为全系统总量，不能归因本应用。内存是采样到的物理占用峰值，短命进程真实峰值可能更高。"}
    for role in ("collector", "hub", "distill", "coreaudiod", "sampler"):
        summary = {"cpu_s": 0.0, "awake_s": 0.0, "invalid_intervals": 0, "missing_awake_s": 0.0,
                   "peak_footprint_mb": 0.0, "peak_child_footprint_mb": 0.0, "locked_cpu_s": 0.0, "locked_awake_s": 0.0,
                   "longest_locked_awake_s": 0.0}
        locked_run = 0.0
        for row in rows:
            process = row["processes"].get(role, {})
            summary["peak_footprint_mb"] = max(summary["peak_footprint_mb"], process.get("footprint_mb", 0))
            summary["peak_child_footprint_mb"] = max(summary["peak_child_footprint_mb"], process.get("largest_child_footprint_mb", 0))
        for previous, current in zip(rows, rows[1:]):
            item = interval(previous, current, role)
            if previous["run"] != current["run"]:
                item = {"error": "sampler_restarted", "awake_s": max(0, current["awake_s"]-previous["awake_s"])}
            if "error" in item:
                summary["invalid_intervals"] += 1; summary["missing_awake_s"] += item["awake_s"]; locked_run = 0; continue
            summary["cpu_s"] += item["cpu_s"]; summary["awake_s"] += item["awake_s"]
            if item["locked"]:
                # The lock-screen requirement is Collector itself, not its child workers.
                summary["locked_cpu_s"] += item["self_cpu_s"]
                summary["locked_awake_s"] += item["awake_s"]; locked_run += item["awake_s"]
                summary["longest_locked_awake_s"] = max(summary["longest_locked_awake_s"], locked_run)
            else: locked_run = 0
        summary["cpu_percent_one_core"] = 100 * summary["cpu_s"] / summary["awake_s"] if summary["awake_s"] else None
        summary["locked_self_cpu_percent"] = 100 * summary["locked_cpu_s"] / summary["locked_awake_s"] if summary["locked_awake_s"] else None
        result["roles"][role] = summary
    models = directory / ("models-" + date + ".jsonl")
    latest = None
    if models.exists():
        for line in models.read_text().splitlines():
            try: latest = json.loads(line)
            except ValueError: pass
    result["models"] = latest
    result["normal_day_candidate"] = bool(rows and rows[0]["at"][11:16] < "00:02" and rows[-1]["at"][11:16] > "23:58" and result["roles"]["collector"]["invalid_intervals"] == 0)
    return result


def run(directory, data_dir):
    import uuid
    native = Native()
    run_id = uuid.uuid4().hex
    targets, last_roots, last_models = {}, -1e20, -1e20
    core_pid = native.core_audio_pid()
    alive = True
    def stop(*_):
        nonlocal alive
        alive = False
    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
    append(directory / "sessions.jsonl", {"type": "start", "at": local_now().isoformat(), "run": run_id,
        "sample_seconds": 5, "model_seconds": 300, "startup_day_partial": True,
        "timebase_seconds_per_tick": native.scale})
    while alive:
        started = native.awake()
        try:
            if started - last_roots >= 60 or any(not native.usage(p) for p in targets.values() if p):
                targets = roots(); last_roots = started
            processes = {name: native.tree(targets.get(name)) for name in ("collector", "hub", "distill")}
            processes["sampler"] = native.tree(os.getpid())
            processes["coreaudiod"] = native.tree(core_pid)
            now = local_now()
            append(directory / ("cpu-" + now.date().isoformat() + ".jsonl"), {"type": "sample", "at": now.isoformat(),
                "wall_s": time.time(), "awake_s": native.awake(), "run": run_id, "locked": native.locked(), "processes": processes})
            if started - last_models >= 300:
                last_models = started
                bun = Path.home() / ".bun/bin/bun"
                completed = subprocess.run([str(bun), str(Path(__file__).with_name("performance-usage.ts")), str(data_dir)], capture_output=True, text=True, timeout=20)
                if completed.returncode != 0:
                    raise RuntimeError("usage_snapshot_failed")
                snapshot = json.loads(completed.stdout)
                for date, tasks in snapshot["days"].items():
                    append(directory / ("models-" + date + ".jsonl"), {"at": snapshot["at"], "timezone": snapshot["timezone"], "date": date, "tasks": tasks})
        except Exception as error:
            # Never log subprocess stderr or exception text: these may contain paths/content.
            append(directory / "errors.jsonl", {"at": local_now().isoformat(), "type": type(error).__name__})
        time.sleep(max(0.1, 5 - (native.awake() - started)))
    append(directory / "sessions.jsonl", {"type": "stop", "at": local_now().isoformat(), "run": run_id})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", metavar="YYYY-MM-DD")
    args = parser.parse_args()
    data_dir = Path.home() / "Library/Application Support/record-anything"
    directory = data_dir / "performance"
    os.umask(0o077); directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if args.report:
        dt.date.fromisoformat(args.report)
        print(json.dumps(report(directory, args.report), ensure_ascii=False, indent=2))
    else:
        with (directory / "sampler.lock").open("w") as lock:
            try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError: return
            run(directory, data_dir)


if __name__ == "__main__":
    main()
