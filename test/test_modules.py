#!/usr/bin/env python3
"""Run from the repository root; extra arguments are passed to make. Checks module resolution."""
import os
import subprocess
import sys

make = [os.environ.get("MAKE", "make"), "--no-print-directory", "-s", *sys.argv[1:]]
failures = []


def explain(*args):
    result = subprocess.run(make + list(args) + ["explain-modules"], capture_output=True, text=True)
    lines = result.stdout.splitlines()
    modules = {line.split()[0]: line for line in lines if line and not line.startswith("builds as")}
    builds = next((line for line in lines if line.startswith("builds as")), "")
    return result.returncode, modules, builds, result.stderr


def expect(step, args, has=(), lacks=(), builds=(), error=None):
    code, modules, line, err = explain(*args)
    if error:
        if code == 0 or error not in err:
            failures.append(f"{step}: expected an error containing {error!r}, got {code}: {err.strip()[-300:]}")
        return
    if code != 0:
        failures.append(f"{step}: make failed: {err.strip()[-300:]}")
        return
    failures.extend(f"{step}: {m} missing" for m in has if m not in modules)
    failures.extend(f"{step}: {m} present: {modules[m]}" for m in lacks if m in modules)
    failures.extend(f"{step}: not built as {b}: {line}" for b in builds if b not in line.split())


expect("default", [], has=["full", "mqtt", "tcp", "shell"], builds=["FEATURES=full", "HEADLESS=0"])
expect("closure", ["MODULES=mqtt"], has=["mqtt", "tcp", "inet", "ip_stack", "profile"], lacks=["http_server"],
       builds=["FEATURES=full", "HEADLESS=1"])
expect("chain", ["MODULES=mqtt"], has=["inet"])
if "inet <- tcp <- mqtt (MODULES)" not in explain("MODULES=mqtt")[1].get("inet", ""):
    failures.append("chain: inet is not explained through tcp and mqtt")
expect("tier", ["MODULES=l2 ip dhcp_client"], has=["bridge", "udp"], lacks=["inet6", "ip_forward"],
       builds=["FEATURES=switch-ip", "IPV6=0", "GATEWAY=0"])
expect("umbrella drops", ["MODULES=ip", "WITHOUT=tcp"], has=["inet", "udp"], lacks=["ip", "tcp"])
expect("weak require", ["MODULES=gateway", "WITHOUT=inet6"], has=["ip_forward", "dhcp_server"], lacks=["ipv6_ra"])
expect("weak require taken", ["MODULES=gateway ipv6"], has=["ipv6_ra"])
expect("with", ["WITH=sfp", "WITHOUT=rdp"], has=["sfp"], lacks=["rdp"], builds=["SFP=1", "RDP=0"])
expect("without required", ["MODULES=mqtt", "WITHOUT=tcp"], error="WITHOUT=tcp: required by mqtt (MODULES)")
expect("unknown", ["WITH=ipp"], error="unknown module 'ipp'; did you mean ip?")
expect("legacy", ["FEATURES=switch-http", "MODBUS=0", "TINY=1"], has=["http_server"], lacks=["modbus", "ip_forward"],
       builds=["FEATURES=switch-http", "MODBUS=0", "GATEWAY=0"])
expect("legacy with", ["FEATURES=switch", "WITH=mqtt"], has=["mqtt"], builds=["FEATURES=full"])
expect("legacy conflict", ["FEATURES=switch", "MODULES=l2"], error="MODULES replaces FEATURES")

if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
print("modules: closure, chains, tiers, umbrellas, weak requires, WITH/WITHOUT, errors and legacy shims all correct")
