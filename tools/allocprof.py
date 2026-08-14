#!/usr/bin/env python3
"""Replay an OpenWatt allocation event stream.

The target logs one event per allocation and keeps almost nothing in RAM
(see third_party/urt/src/urt/mem/profile.d). All the analysis lives here,
where the ELF and its symbols already are.

    A <ms> <size> <ptr> <pc>...    allocation, with captured call frames
    F <ms> <size> <ptr>            free
    R <ms> <size> <ptr> [old_ptr]  realloc
    M <ms> <label>                 marker

Usage:
    allocprof.py <logfile> [--elf BINARY] [--addr2line TOOL]
                 [--hot-ms N] [--top N] [--split-at LABEL]

Lifetime classes, matching the vocabulary the tool was built around:
    transient   freed within --hot-ms
    long-lived  outlived that, allocated after --split-at
    immortal    outlived that, allocated before --split-at (never freed
                during the capture)
"""

import argparse
import collections
import re
import shutil
import subprocess
import sys

EVENT = re.compile(r"\bap ([AFRMB]) ([0-9a-f]+) (.*)$")


def find_slide(path, elf, nm="nm"):
    """Recover the PIE/ASLR load slide from the stream's B event.

    The target emits the runtime address of one named symbol; the same
    symbol's link-time address comes out of the ELF, and the difference is
    what the loader applied to every other address in the stream. Targets
    that execute in place report a slide of zero.
    """
    runtime = symbol = None
    for kind, _, f in parse(path):
        if kind == "B" and len(f) >= 2:
            runtime, symbol = int(f[0], 16), f[1]
            break
    if runtime is None or not elf or not shutil.which(nm):
        return 0

    try:
        out = subprocess.run([nm, elf], capture_output=True, text=True,
                             check=True).stdout
    except subprocess.CalledProcessError:
        return 0

    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3 and symbol in parts[-1]:
            return runtime - int(parts[0], 16)

    print(f"warning: symbol {symbol} not found in {elf}; assuming no slide",
          file=sys.stderr)
    return 0


class Alloc:
    __slots__ = ("size", "t_alloc", "frames", "freed_at")

    def __init__(self, size, t_alloc, frames):
        self.size = size
        self.t_alloc = t_alloc
        self.frames = frames
        self.freed_at = None


def parse(path):
    """Yield (kind, ms, fields) for each event line in the log."""
    with open(path, "r", errors="replace") as f:
        for line in f:
            m = EVENT.search(line)
            if not m:
                continue
            kind, ms, rest = m.group(1), int(m.group(2), 16), m.group(3).split()
            yield kind, ms, rest


def replay(path):
    live = {}                 # ptr -> Alloc
    done = []                 # completed Allocs
    marks = []                # (ms, label)
    peak_bytes = peak_at = 0
    cur_bytes = 0
    unmatched_frees = 0

    for kind, ms, f in parse(path):
        if kind == "M":
            marks.append((ms, " ".join(f)))
            continue
        if kind == "B":
            continue

        if kind == "A":
            size = int(f[0], 16)
            ptr = f[1]
            frames = f[2:]
            # A repeated pointer means we missed the free (log truncated at
            # the front, or the stream was toggled off); retire the old one.
            if ptr in live:
                done.append(live.pop(ptr))
            live[ptr] = Alloc(size, ms, frames)
            cur_bytes += size

        elif kind == "R":
            size = int(f[0], 16)
            ptr = f[1]
            old = f[2] if len(f) > 2 else ptr
            prev = live.pop(old, None)
            if prev:
                cur_bytes -= prev.size
            # A moved block keeps its identity, so the original call site
            # follows it rather than reading as churn.
            live[ptr] = Alloc(size, prev.t_alloc if prev else ms,
                              prev.frames if prev else [])
            cur_bytes += size

        elif kind == "F":
            size = int(f[0], 16)
            ptr = f[1]
            a = live.pop(ptr, None)
            if a is None:
                unmatched_frees += 1
                continue
            a.freed_at = ms
            cur_bytes -= a.size
            done.append(a)

        if cur_bytes > peak_bytes:
            peak_bytes, peak_at = cur_bytes, ms

    return live, done, marks, peak_bytes, peak_at, unmatched_frees


def resolve(addrs, elf, tool, slide=0):
    """Batch-resolve addresses to symbols. One addr2line call, not N."""
    if not addrs or not elf:
        return {}
    if not shutil.which(tool):
        print(f"warning: {tool} not found, leaving addresses raw",
              file=sys.stderr)
        return {}
    static = [f"{int(a, 16) - slide:x}" for a in addrs]
    try:
        out = subprocess.run([tool, "-f", "-C", "-e", elf] + static,
                             capture_output=True, text=True, check=True).stdout
    except subprocess.CalledProcessError as e:
        print(f"warning: {tool} failed: {e}", file=sys.stderr)
        return {}

    lines = out.splitlines()
    syms = {}
    for i, addr in enumerate(addrs):
        fn = lines[2 * i] if 2 * i < len(lines) else "??"
        loc = lines[2 * i + 1] if 2 * i + 1 < len(lines) else "??"
        syms[addr] = (fn, loc)
    return syms


# Frames inside the allocator itself say nothing about who wanted the
# memory. Skipping them here means the target never needed symbols.
WRAPPER = ("urt.mem.", "_d_new", "_d_array", "_D3urt3mem", "alloc", "malloc",
           "realloc", "emplace", "urt.array", "urt.string", "urt.map")


def blame(frames, syms):
    """First frame that isn't allocator plumbing.

    If every frame is plumbing the trace was too shallow to reach the
    caller. Say so rather than blaming the deepest wrapper, which looks
    like a real answer and is not.
    """
    for a in frames:
        fn, loc = syms.get(a, ("", ""))
        if not fn or fn == "??":
            return a, fn, loc          # unresolved: assume it's user code
        if not any(fn.startswith(w) or fn == w for w in WRAPPER):
            return a, fn, loc
    if not frames:
        return "?", "", ""
    return frames[-1], "(trace too shallow -- raise trace_depth)", ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("logfile")
    ap.add_argument("--elf", help="binary to resolve call sites against")
    ap.add_argument("--addr2line", default="addr2line")
    ap.add_argument("--hot-ms", type=int, default=1000,
                    help="freed within this many ms counts as transient")
    ap.add_argument("--top", type=int, default=15)
    ap.add_argument("--split-at", default="boot-complete",
                    help="marker splitting immortal from long-lived")
    args = ap.parse_args()

    live, done, marks, peak_bytes, peak_at, unmatched = replay(args.logfile)

    split_ms = None
    for ms, label in marks:
        if label == args.split_at:
            split_ms = ms
            break

    transient, long_lived, immortal = [], [], []
    for a in done:
        if a.freed_at is not None and a.freed_at - a.t_alloc < args.hot_ms:
            transient.append(a)
        elif split_ms is not None and a.t_alloc <= split_ms:
            immortal.append(a)
        else:
            long_lived.append(a)
    # Still live at the end of the capture: never freed at all.
    for a in live.values():
        if split_ms is not None and a.t_alloc <= split_ms:
            immortal.append(a)
        else:
            long_lived.append(a)

    # Transient headroom: peak bytes held by allocations that turned out to
    # be transient, plus the largest single one. This is what the heap must
    # keep free, and it is the number a target cannot compute for itself.
    deltas = []
    for a in transient:
        deltas.append((a.t_alloc, a.size))
        deltas.append((a.freed_at, -a.size))
    deltas.sort()
    cur = hwm = 0
    for _, d in deltas:
        cur += d
        hwm = max(hwm, cur)

    def total(xs):
        return sum(a.size for a in xs)

    print(f"Events: {len(done) + len(live)} allocations "
          f"({len(live)} still live at end of capture)")
    if marks:
        print("Markers: " + ", ".join(f"{l}@{ms}ms" for ms, l in marks))
    if split_ms is None:
        print(f"  (no '{args.split_at}' marker: nothing counted as immortal)")
    if unmatched:
        print(f"  ({unmatched} frees with no matching alloc -- log truncated?)")
    print()
    print(f"immortal:   {len(immortal):6} allocs, {total(immortal):9} bytes")
    print(f"long-lived: {len(long_lived):6} allocs, {total(long_lived):9} bytes")
    print(f"transient:  {len(transient):6} allocs, {total(transient):9} bytes")
    print()
    print(f"Peak live bytes:          {peak_bytes} (at {peak_at}ms)")
    print(f"Transient high-water:     {hwm}")
    print(f"Largest single transient: {max((a.size for a in transient), default=0)}")
    print(f"Largest single alloc:     {max((a.size for a in done + list(live.values())), default=0)}")

    # Never freed during the capture. This is the leak set, and it is what
    # the in-RAM recorder existed to produce -- the replay gets it for free.
    never = list(live.values())
    after = [a for a in never if split_ms is not None and a.t_alloc > split_ms]
    print(f"\nNever freed during capture: {len(never)} allocs, "
          f"{total(never)} bytes ({len(after)} of them after '{args.split_at}')")

    every = {a for grp in (immortal, long_lived, transient) for x in grp
             for a in x.frames}
    slide = find_slide(args.logfile, args.elf)
    if slide:
        print(f"\n(load slide 0x{slide:x} recovered from the stream)")
    syms = resolve(sorted(every), args.elf, args.addr2line, slide)

    for name, group in (("immortal", immortal), ("long-lived", long_lived),
                        ("transient", transient)):
        if not group:
            continue
        sites = collections.defaultdict(lambda: [0, 0, 0])  # count, bytes, max
        for a in group:
            key = blame(a.frames, syms)
            s = sites[key]
            s[0] += 1
            s[1] += a.size
            s[2] = max(s[2], a.size)

        print(f"\n{name} by call site (top {args.top} of {len(sites)}):")
        ranked = sorted(sites.items(), key=lambda kv: kv[1][1], reverse=True)
        for (addr, fn, loc), (count, byts, mx) in ranked[:args.top]:
            where = f"{fn} [{loc}]" if fn else f"0x{addr}"
            print(f"  {byts:9} bytes  {count:5} allocs  (largest {mx:6})  {where}")


if __name__ == "__main__":
    main()
