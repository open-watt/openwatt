#!/usr/bin/env python3
"""Rank the static RAM a binary costs, by symbol.

Heap allocations show up in the allocation profiler; this covers the other
half, the globals the linker places in .data and .bss. On an embedded target
.data is the worse of the two: it occupies RAM *and* carries an initialiser
image in flash that gets copied at startup, so a global that only looks
zero-initialised is paying twice.

    ramreport.py <binary> [--nm nm] [--top N] [--module]
"""

import argparse
import collections
import re
import subprocess
import sys

# Section names, not nm's type letters: those cannot tell .data from
# .data.rel.ro, and conflating them reports flash as RAM. Anything holding a
# Type.init blob or a vtable lands in the latter and is flash on a target
# that executes in place.
RAM_SECTIONS = (".bss", ".data", ".tbss", ".tdata", ".sbss", ".sdata")
DATA_SECTIONS = (".data", ".tdata", ".sdata")


def symbols(binary, objdump):
    out = subprocess.run([objdump, "-t", binary],
                         capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        # addr flags... section size name
        f = line.split()
        if len(f) < 5 or not f[0][:1].isdigit() and not f[0][:1] in "abcdef":
            continue
        section, size, name = f[-3], f[-2], f[-1]
        if section not in RAM_SECTIONS:
            continue
        try:
            sz = int(size, 16)
        except ValueError:
            continue
        if sz:
            yield sz, section, name


def demangle(names, nm_cxxfilt="c++filt"):
    if not names:
        return {}
    try:
        out = subprocess.run([nm_cxxfilt], input="\n".join(names),
                             capture_output=True, text=True, check=True).stdout
        return dict(zip(names, out.splitlines()))
    except (subprocess.CalledProcessError, FileNotFoundError):
        return {}


# _D3urt3mem7profile9_countersS... -> urt.mem.profile._counters
DMANGLE = re.compile(r"^_D((?:\d+[A-Za-z0-9_]+)+)")


def d_demangle(name):
    m = DMANGLE.match(name)
    if not m:
        return name
    rest, parts = m.group(1), []
    while rest:
        n = re.match(r"(\d+)", rest)
        if not n:
            break
        ln = int(n.group(1))
        start = n.end()
        parts.append(rest[start:start + ln])
        rest = rest[start + ln:]
    return ".".join(parts) if parts else name


def module_of(pretty):
    # urt.mem.profile._counters -> urt.mem.profile
    return pretty.rsplit(".", 1)[0] if "." in pretty else "(none)"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binary")
    ap.add_argument("--objdump", default="objdump")
    ap.add_argument("--top", type=int, default=30)
    ap.add_argument("--module", action="store_true",
                    help="aggregate by module instead of listing symbols")
    args = ap.parse_args()

    syms = [(sz, typ, d_demangle(nm)) for sz, typ, nm in symbols(args.binary, args.objdump)]
    if not syms:
        print("no RAM symbols found (stripped binary?)", file=sys.stderr)
        return 1

    total = sum(s[0] for s in syms)
    data = sum(s[0] for s in syms if s[1] in DATA_SECTIONS)
    bss = total - data
    print(f"static RAM in symbols: {total} bytes  (.data {data}, .bss {bss})")
    print()

    if args.module:
        agg = collections.defaultdict(lambda: [0, 0])
        for sz, typ, name in syms:
            slot = agg[module_of(name)]
            slot[0] += sz
            if typ in DATA_SECTIONS:
                slot[1] += sz
        rows = sorted(agg.items(), key=lambda kv: kv[1][0], reverse=True)
        print(f"{'bytes':>9} {'of which .data':>14}  module")
        for mod, (sz, dsz) in rows[:args.top]:
            print(f"{sz:9} {dsz:14}  {mod}")
    else:
        print(f"{'bytes':>9} {'sec':>5}  symbol")
        for sz, typ, name in sorted(syms, reverse=True)[:args.top]:
            sec = typ
            print(f"{sz:9} {sec:>5}  {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
