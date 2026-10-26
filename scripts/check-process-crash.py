#!/usr/bin/env python3
"""Verify Linux SIGKILL and scoped ENOSPC recovery with a synthetic Swift probe."""

import argparse
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile


READY = "PECHPECH_PROCESS_PROBE_READY\n"
ROOT = Path(__file__).resolve().parents[1]


def kill_at_barrier(probe: Path, mode: str, database: Path, timeout: float) -> None:
    process = subprocess.Popen(
        [str(probe), mode, str(database)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True)
    try:
        readable, _, _ = select.select([process.stdout], [], [], timeout)
        if not readable or process.stdout.readline() != READY:
            raise RuntimeError(f"{mode} did not reach its durable/transaction barrier")
        expected = str(database.resolve())
        open_database = False
        for descriptor in (Path("/proc") / str(process.pid) / "fd").iterdir():
            try:
                target = os.readlink(descriptor)
            except FileNotFoundError:
                continue
            if target in (expected, expected + "-wal"):
                open_database = True
                break
        if not open_database:
            raise RuntimeError(f"{mode} closed SQLite before the abrupt process-kill barrier")
        process.kill()
        _, errors = process.communicate(timeout=timeout)
        if process.returncode != -signal.SIGKILL:
            raise RuntimeError(f"{mode} did not exit through SIGKILL: {errors.strip()}")
    finally:
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=timeout)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, required=True,
                        help="Built PechPechProcessCrashProbe executable")
    parser.add_argument("--timeout", type=float, default=20,
                        help="Maximum seconds per barrier or verification (default: 20)")
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"),
                        help="C compiler for the scoped ENOSPC interceptor (defaults to CC or cc)")
    options = parser.parse_args()
    if sys.platform != "linux":
        parser.error("This qualification harness is restricted to Linux")
    if not 0 < options.timeout <= 60:
        parser.error("Timeout must be greater than zero and at most 60 seconds")
    probe = options.probe.resolve()
    if not probe.is_file() or not os.access(probe, os.X_OK):
        parser.error("--probe must name a built executable")
    scenarios = (
        ("queue-committed", "check-queue"),
        ("receipt-committed", "check-delivered"),
        ("inbox-committed", "check-inbox"),
        ("inbox-uncommitted", "check-empty"),
    )
    with tempfile.TemporaryDirectory(prefix="pechpech-process-crash-") as directory:
        for writer, verifier in scenarios:
            database = Path(directory) / writer / "synthetic.sqlite"
            kill_at_barrier(probe, writer, database, options.timeout)
            result = subprocess.run([str(probe), verifier, str(database)], check=True,
                                    capture_output=True, text=True, timeout=options.timeout)
            if result.stdout.strip() != f"PASS: {verifier}":
                raise RuntimeError(f"Unexpected verification result for {writer}")
            print(f"PASS: SIGKILL {writer} -> {verifier}")
        interceptor = Path(directory) / "synthetic_enospc.so"
        subprocess.run([options.cc, "-shared", "-fPIC", "-O2", "-Wall", "-Wextra", "-Werror",
                        str(ROOT / "scripts/linux/disk_full.c"), "-o", str(interceptor)], check=True,
                       timeout=options.timeout)
        for writer, verifier in (("full-queue", "check-queue"), ("full-inbox", "check-inbox"),
                                  ("full-receipt", "check-delivered")):
            database = (Path(directory) / writer / "synthetic.sqlite").resolve()
            marker = Path(directory) / f"{writer}.faults"
            environment = os.environ.copy()
            environment.pop("PECHPECH_PROBE_ENOSPC", None)
            environment["LD_PRELOAD"] = str(interceptor) + (
                ":" + environment["LD_PRELOAD"] if environment.get("LD_PRELOAD") else "")
            environment["PECHPECH_PROBE_DB"] = str(database)
            environment["PECHPECH_PROBE_FAULT_MARKER"] = str(marker)
            result = subprocess.run([str(probe), writer, str(database)], check=True, capture_output=True,
                                    text=True, env=environment, timeout=options.timeout)
            if result.stdout.strip() != f"PASS: {writer}" or not marker.is_file() or not marker.read_text():
                raise RuntimeError(f"The scoped ENOSPC fault was not exercised for {writer}")
            subprocess.run([str(probe), verifier, str(database)], check=True, capture_output=True,
                           text=True, timeout=options.timeout)
            print(f"PASS: ENOSPC -> SQLITE_FULL {writer}: atomic rollback, retry and reopen")
    print("PASS: Linux SIGKILL recovery at four SQLite boundaries and scoped ENOSPC/SQLITE_FULL recovery "
          "at three write boundaries; synthetic temporary stores only. "
          "These are injected process/storage failures, not power-loss or physical-device qualification.")


if __name__ == "__main__":
    main()
