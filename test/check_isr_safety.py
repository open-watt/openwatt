#!/usr/bin/env python3
"""Verify that our interrupt-context code never calls into demand-paged code.

Functions marked @critical land in a resident section (.iram0.* on Espressif,
.ramfunc elsewhere). Calling out of one into a flash-mapped section links fine
and works right up until the call happens with the instruction cache disabled,
which is precisely when an ISR runs during a flash write.

Scope is our own code, not the whole resident image: roots are OpenWatt/uRT
symbols in resident sections, and the check walks the direct-call graph from
there. ESP-IDF places plenty of its own code in IRAM that legitimately calls
flash routines from cache-enabled contexts; policing that is not our business.

DIRECT calls only. Indirect calls through function pointers are not statically
decidable here; those are covered at the registration site, where the link
fabric's isr_task requires the @isr_safe attribute.

  python3 test/check_isr_safety.py <elf> --objdump <path-to-objdump>
"""

import argparse
import re
import subprocess
import sys

RESIDENT_HINTS = ("iram", "ramfunc", "rtc_text", "rtc.text")
# D mangling for urt.driver.*/driver.boards.*, the C shim entry points, and
# the synthesized reflex NMI vector.
ROOT_PATTERNS = (
    re.compile(r"^_D3urt6driver"),
    re.compile(r"^_D6driver"),
    re.compile(r"^ow_"),
    re.compile(r"^xt_nmi$"),
)

SECTION_RE = re.compile(r"^\s*\d+\s+(\S+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+", re.IGNORECASE)
FUNC_RE = re.compile(r"^([0-9a-f]+) <([^>]+)>:")
INSN_RE = re.compile(r"^\s*([0-9a-f]+):\s+[0-9a-f ]+\s+(\S+)\s*(.*)$", re.IGNORECASE)
TARGET_RE = re.compile(r"\b([0-9a-f]{6,16})\s+<([^>+]+)(?:\+0x[0-9a-f]+)?>", re.IGNORECASE)
L32R_RE = re.compile(r"^l32r\s+(a\d+),", re.IGNORECASE)
CALLX_RE = re.compile(r"^callx\d+\s+(a\d+)$", re.IGNORECASE)
CALL_PREFIXES = ("call", "j", "bl")


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"FAILED: {' '.join(cmd)}\n{r.stderr.strip()}")
    return r.stdout


def sections(objdump, elf):
    found = []
    for line in run([objdump, "-h", elf]).splitlines():
        m = SECTION_RE.match(line)
        if m and int(m.group(2), 16):
            vma = int(m.group(3), 16)
            found.append((m.group(1), vma, vma + int(m.group(2), 16)))
    return found


def classify(addr, secs):
    for name, lo, hi in secs:
        if lo <= addr < hi:
            return name
    return None


def resident(section):
    return section is not None and any(h in section.lower() for h in RESIDENT_HINTS)


def target_ref(operands):
    matches = TARGET_RE.findall(operands)
    if matches:
        address, name = matches[-1]
        return name, int(address, 16)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("elf")
    ap.add_argument("--objdump", required=True)
    args = ap.parse_args()

    secs = sections(args.objdump, args.elf)
    resident_secs = [s for s in secs if resident(s[0])]
    if not resident_secs:
        sys.exit("no resident code sections found; the ELF or section names are unexpected")

    # caller -> {(callee_name, callee_addr)} across all resident code
    graph, roots = {}, set()
    for name, _, _ in resident_secs:
        current = None
        registers = {}
        literal_end = 0
        first_instruction = False
        for line in run([args.objdump, "-d", "-j", name, args.elf]).splitlines():
            head = FUNC_RE.match(line)
            if head:
                current = head.group(2)
                graph.setdefault(current, set())
                if any(p.match(current) for p in ROOT_PATTERNS):
                    roots.add(current)
                registers = {}
                literal_end = 0
                first_instruction = True
                continue
            if current is None:
                continue
            insn = INSN_RE.match(line)
            if not insn:
                continue
            address = int(insn.group(1), 16)
            opcode = insn.group(2).lower()
            operands = insn.group(3)
            if first_instruction:
                first_instruction = False
                target = target_ref(operands) if opcode == "j" else None
                if target and target[1] > address:
                    literal_end = target[1]
                    continue
            if address < literal_end:
                continue
            load = L32R_RE.match(f"{opcode} {operands}")
            if load:
                target = target_ref(operands)
                if target:
                    registers[load.group(1)] = target
                continue
            callx = CALLX_RE.match(f"{opcode} {operands}")
            if callx:
                target = registers.get(callx.group(1))
                if target:
                    graph[current].add(target)
                continue
            if opcode.startswith(CALL_PREFIXES):
                target = target_ref(operands)
                if target:
                    graph[current].add(target)

    if not graph:
        sys.exit("disassembled no functions; the checker is not doing its job")
    if not roots:
        sys.exit("found no OpenWatt/uRT symbols in resident sections; nothing was actually checked")

    seen, queue, violations, edges = set(roots), list(roots), [], 0
    while queue:
        caller = queue.pop()
        for callee, addr in graph.get(caller, ()):
            edges += 1
            section = classify(addr, secs)
            if section is not None and not resident(section):
                violations.append((caller, callee, section, addr))
            elif callee not in seen:
                seen.add(callee)
                queue.append(callee)

    print(f"resident sections: {', '.join(s[0] for s in resident_secs)}")
    print(f"roots: {len(roots)}   reachable functions: {len(seen)}   direct calls: {edges}")
    if violations:
        print(f"\n{len(violations)} call(s) leave resident memory:\n")
        for caller, callee, section, addr in violations:
            print(f"  {caller}\n      -> {callee}  [{section} @ 0x{addr:08x}]")
        return 1
    print("OK: no interrupt-context code reaches demand-paged sections")
    return 0


if __name__ == "__main__":
    sys.exit(main())
