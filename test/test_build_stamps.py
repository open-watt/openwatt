#!/usr/bin/env python3
"""Run from the repository root; extra arguments are passed to make. Builds with a stub compiler."""
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path.cwd().resolve()
(root / "obj").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="stamps-test-", dir=root / "obj") as scratch:
    scratch = Path(scratch)
    rel = scratch.relative_to(root).as_posix()
    log = scratch / "compiles.log"
    stub = scratch / "stub-dc.sh"
    stub.write_text("#!/bin/sh\nfor a in \"$@\"; do case \"$a\" in -of*) out=\"${a#-of}\";; esac; done\n"
                    "[ -n \"$out\" ] || exit 0\n"
                    f"echo x >> \"{log.as_posix()}\"; mkdir -p \"$(dirname \"$out\")\"; touch \"$out\"\n"
                    "[ -z \"$STUB_FAIL\" ]\n", newline="\n")
    stub.chmod(0o755)
    probe = root / "src" / "manager" / "zz_stamps_probe.d"
    make = [os.environ.get("MAKE", "make"), "--no-print-directory", "DC=" + stub.as_posix(), "BINSTATS=true",
            "OBJDIR=" + rel + "/obj", "TARGETDIR=" + rel + "/bin", *sys.argv[1:]]
    failures = []
    version = subprocess.run([make[0], "--version"], capture_output=True, text=True).stdout
    # Native Windows make 3.81 runs no piped $(shell) under -n, so its dry run sees no sources at all.
    dry_run_ok = not ("3.81" in version and "mingw32" in version)
    if not dry_run_ok:
        print("skipping make -n checks: native Windows make 3.81 drops $(shell) output under -n")

    def compiles():
        return len(log.read_text().splitlines()) if log.exists() else 0

    def run(*args, env=None):
        return subprocess.run(make + list(args), capture_output=True, text=True, env=env)

    def stale(step, *args):
        if run("-q", *args).returncode == 0:
            failures.append(f"{step}: make -q reports a stale tree current")

    def build(step, *args, expect):
        before = compiles()
        result = run(*args)
        if result.returncode != 0:
            failures.append(f"{step}: make failed: {result.stderr.strip()[-400:]}")
        elif compiles() - before != expect:
            failures.append(f"{step}: {compiles() - before} compiles, expected {expect}")

    def warm(step, *args):
        stamps = {p: p.stat().st_mtime_ns for p in (scratch / "obj").glob("*") if p.is_file()}
        if run("-q", *args).returncode != 0:
            failures.append(f"{step}: make -q reports a warm tree out of date")
        dry = run("-n", *args) if dry_run_ok else None
        if dry and (stub.as_posix() in dry.stdout or "mktemp" in dry.stdout):
            failures.append(f"{step}: make -n rehearses work on a warm tree:\n{dry.stdout[-400:]}")
        if {p: p.stat().st_mtime_ns for p in stamps} != stamps:
            failures.append(f"{step}: a query or dry run touched a stamp")

    def concurrent(step, *args, jobs=4):
        procs = [subprocess.Popen(make + list(args), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                 for _ in range(jobs)]
        for proc in procs:
            out = proc.communicate()[0]
            if proc.returncode != 0:
                failures.append(f"{step}: concurrent build failed:\n{out[-400:]}")
        leftovers = [p.name for p in (scratch / "obj").glob("*") if re.search(r"\.(stamp|rsp)\.", p.name)]
        if leftovers:
            failures.append(f"{step}: temporary stamps left behind: {leftovers}")

    try:
        build("cold", expect=1)
        warm("warm")
        build("no-op", expect=0)
        concurrent("concurrent warm")
        if compiles() != 1:
            failures.append(f"concurrent warm: {compiles() - 1} compiles, expected 0")
        build("flag change", "FEATURES=switch", expect=1)
        warm("flags warm", "FEATURES=switch")
        concurrent("concurrent flag change")
        warm("after concurrent flag change")
        probe.write_text("module manager.zz_stamps_probe;\n")
        build("source added", expect=1)
        probe.unlink()
        build("source deleted", expect=1)
        warm("after delete")
        quoted, requoted = 'DFLAGS=-J"two  spaces"', 'DFLAGS=-J"two spaces"'
        build("quoted flags", quoted, expect=1)
        warm("quoted flags warm", quoted)
        stale("quoted whitespace change", requoted)
        build("quoted whitespace change", requoted, expect=1)
        hashes = r'DFLAGS=-J"a\#b" -J"c\\#d" -J"e#f$$g"'
        build("backslash before hash", hashes, expect=1)
        warm("backslash before hash warm", hashes)
        build("restore", expect=1)
        if run("FEATURES=switch", env=dict(os.environ, STUB_FAIL="1")).returncode == 0:
            failures.append("failed build: make succeeded with a failing compiler")
        stale("after a failed build that replaced the target")
        build("after a failed build", expect=1)
        warm("after recovery")
    finally:
        if probe.exists():
            probe.unlink()
    if failures:
        print("\n".join(failures), file=sys.stderr)
        sys.exit(1)
    print("stamps: cold, warm -q/-n, concurrent, flag change, quoted whitespace, source add/delete and failed builds all correct")
