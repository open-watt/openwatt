#!/usr/bin/env python3
"""Run from the repository root; extra arguments are passed to make."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

root = Path.cwd().resolve()
host = root / "obj" / "host"
host.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="binstats-test-", dir=host) as scratch:
    cache = Path(scratch) / ("binstats.exe" if os.name == "nt" else "binstats")
    assert cache.parent.resolve().parent == host
    target = cache.relative_to(root).as_posix()
    command = [os.environ.get("MAKE", "make"), "--no-print-directory", target,
               "BINSTATS=" + target, *sys.argv[1:]]
    for mode in ("-n", "-t"):
        firmware = cache.with_suffix(".firmware").relative_to(root).as_posix()
        dry_run = subprocess.run(command[:2] + [mode, "build", "TARGET=" + firmware] + command[3:],
                                 capture_output=True, text=True)
        if dry_run.returncode != 0 or cache.exists() or (mode == "-n" and cache.with_suffix(".firmware").exists()):
            sys.exit("cold " + mode + " executed the reporter sub-build: " + dry_run.stderr)
    logs = [open(Path(scratch) / f"build-{i}.log", "w+") for i in range(4)]
    jobs = []
    for log in logs:
        jobs.append(subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT))
        time.sleep(0.05)
    failures = []
    reads = 0
    while any(job.poll() is None for job in jobs):
        if cache.is_file():
            try:
                report = subprocess.run([str(cache), str(cache)], capture_output=True, text=True)
                if report.returncode == 0 and "flash" in report.stdout:
                    reads += 1
                else:
                    failures.append("published reporter failed: " + report.stderr.strip())
            except OSError as error:
                failures.append("published reporter could not execute: " + str(error))
        time.sleep(0.005)
    for job, log in zip(jobs, logs):
        if job.wait() != 0:
            log.seek(0)
            failures.append("parallel build failed:\n" + "\n".join(log.read().splitlines()[-8:]))
        log.close()
    if not failures:
        report = subprocess.run([str(cache), str(cache)], capture_output=True, text=True)
        if report.returncode != 0 or "flash" not in report.stdout:
            failures.append("final reporter failed: " + report.stderr.strip())
        incremental = subprocess.run(command[:2] + ["-q"] + command[2:], capture_output=True, text=True)
        if incremental.returncode != 0:
            failures.append("incremental make would rebuild the reporter")
    if failures:
        print("\n".join(failures[:5]), file=sys.stderr)
        sys.exit(1)
    print(f"4 cold-cache parallel builds passed; {reads} concurrent reads; incremental cache is current")
