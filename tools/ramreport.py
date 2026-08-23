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

def classify(section):
    s = section.lower()
    if "rodata" in s or "rel.ro" in s:
        return None
    parts = set(filter(None, re.split(r"[._]+", s)))
    if parts & {"bss", "sbss", "tbss", "noinit", "common"}:
        return "bss"
    if parts & {"data", "sdata", "tdata"}:
        return "data"
    return None


def symbols(binary, objdump):
    out = subprocess.run([objdump, "-t", binary],
                         capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        # addr flags... section size name
        f = line.split()
        if len(f) < 5 or not f[0][:1].isdigit() and not f[0][:1] in "abcdef":
            continue
        section, size, name = f[-3], f[-2], f[-1]
        kind = classify(section)
        if kind is None:
            continue
        try:
            sz = int(size, 16)
        except ValueError:
            continue
        if sz:
            yield sz, kind, section, name


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

    syms = [(sz, kind, sec, d_demangle(nm)) for sz, kind, sec, nm in symbols(args.binary, args.objdump)]
    if not syms:
        print("no RAM symbols found (stripped binary?)", file=sys.stderr)
        return 1

    total = sum(s[0] for s in syms)
    data = sum(s[0] for s in syms if s[1] == "data")
    bss = total - data
    print(f"static RAM in symbols: {total} bytes  (.data {data}, .bss {bss})")
    print()

    if args.module:
        agg = collections.defaultdict(lambda: [0, 0])
        for sz, kind, sec, name in syms:
            slot = agg[module_of(name)]
            slot[0] += sz
            if kind == "data":
                slot[1] += sz
        rows = sorted(agg.items(), key=lambda kv: kv[1][0], reverse=True)
        print(f"{'bytes':>9} {'of which .data':>14}  module")
        for mod, (sz, dsz) in rows[:args.top]:
            print(f"{sz:9} {dsz:14}  {mod}")
    else:
        print(f"{'bytes':>9} {'section':>12}  symbol")
        for sz, kind, sec, name in sorted(syms, key=lambda r: r[0], reverse=True)[:args.top]:
            print(f"{sz:9} {sec:>12}  {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
