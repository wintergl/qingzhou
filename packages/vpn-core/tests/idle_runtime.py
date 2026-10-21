#!/usr/bin/env python3
"""Measure stopped stdio backends in temporary, isolated data directories.

No VPN, controller, system route, DNS or user settings are accessed. CPU time is
diagnostic only, not a battery estimate. Optional --baseline compares a prior core.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import queue
import resource
import subprocess
import sys
import tempfile
import threading
import time


def wakeups(pid):
    if sys.platform != "darwin":
        return None
    # Stable RUSAGE_INFO_V0 layout from the macOS SDK's sys/resource.h.
    class Usage(ctypes.Structure):
        _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
            "user", "system", "packageIdle", "interrupt", "pageins", "wired", "resident",
            "footprint", "start", "exit")]
    try:
        library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        library.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        library.proc_pid_rusage.restype = ctypes.c_int
        usage = Usage()
        if library.proc_pid_rusage(pid, 0, ctypes.byref(usage)) != 0:
            return None
        return {"packageIdle": usage.packageIdle, "interrupt": usage.interrupt}
    except OSError:
        return None


def measure(binary, seconds):
    with tempfile.TemporaryDirectory(prefix="qingzhou-idle-") as directory:
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        process = subprocess.Popen(
            [str(Path(binary).resolve())], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True,
            env={**os.environ, "SPLITVPN_ISOLATED": "1", "SPLITVPN_DATA_DIR": directory},
        )
        lines = queue.Queue()
        def read():
            for line in process.stdout:
                lines.put(json.loads(line))
        reader = threading.Thread(target=read, daemon=True)
        reader.start()
        try:
            process.stdin.write(json.dumps({"id": "idle-check", "channel": "core:capabilities"}) + "\n")
            process.stdin.flush()
            reply = lines.get(timeout=10)
            assert reply.get("id") == "idle-check" and reply.get("ok"), reply
            start = time.monotonic()
            initial_wakeups = wakeups(process.pid)
            deadline = start + seconds
            events = {}
            while time.monotonic() < deadline:
                try:
                    value = lines.get(timeout=max(0.001, deadline - time.monotonic()))
                    if "event" in value:
                        events[value["event"]] = events.get(value["event"], 0) + 1
                except queue.Empty:
                    break
            final_wakeups = wakeups(process.pid)
            process.stdin.close()
            closing = time.monotonic()
            process.wait(timeout=3)
            exit_seconds = time.monotonic() - closing
            reader.join(timeout=1)
            assert process.returncode == 0, process.stderr.read()
            after = resource.getrusage(resource.RUSAGE_CHILDREN)
            return {"isolated": True, "vpnStarted": False, "sampleSeconds": seconds,
                    "events": events, "exitSeconds": round(exit_seconds, 4),
                    "macOSWakeupsDuringSample": {key: final_wakeups[key] - initial_wakeups[key]
                        for key in initial_wakeups} if initial_wakeups is not None and final_wakeups is not None else None,
                    "cpuSecondsIncludingStartupAndExit": round(
                        after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime, 6)}
        finally:
            if process.poll() is None:
                process.kill(); process.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core", default=str(Path(__file__).resolve().parents[1] / "target/debug/splitvpn-core"))
    parser.add_argument("--baseline")
    parser.add_argument("--seconds", type=float, default=15)
    args = parser.parse_args()
    assert 2 <= args.seconds <= 120
    result = {}
    if args.baseline:
        result["baseline"] = measure(args.baseline, args.seconds)
    result["current"] = measure(args.core, args.seconds)
    assert sum(result["current"]["events"].values()) <= 2, "Stopped backend repeatedly emits unchanged state"
    print(json.dumps(result, ensure_ascii=False, indent=2))
