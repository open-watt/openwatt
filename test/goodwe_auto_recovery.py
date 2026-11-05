#!/usr/bin/env python3
"""Bounded live diagnostic for a GoodWe that times out from automatic mode.

Requires the house surplus policy to be disabled. Holds native automatic mode
for at most five minutes, observes without writes, then requests automatic mode
once during cleanup. Uses no persistent automation objects.
"""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import socket
import time
from types import SimpleNamespace
import urllib.request

from test_harness import OpenWattConsole


def run(args):
    paths = ["goodwe_ems.inverter.control.mode", "goodwe_ems.inverter.mode",
             "goodwe_ems.battery.meter.current", "goodwe_ems.battery.meter.power",
             "goodwe_ems.battery.store.soc", "house_bms.connection.meter.current",
             "goodwe_meter.meter1.power"]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("a", encoding="utf-8", buffering=1) as log:
        def record(event, **data):
            log.write(json.dumps(dict(time=datetime.now(timezone.utc).isoformat(), event=event, **data)) + "\n")

        with socket.create_connection((args.pi, 23), timeout=8) as connection:
            connection.settimeout(None)
            reader = connection.makefile("r", encoding="utf-8", errors="replace")
            writer = connection.makefile("w", encoding="utf-8")
            console = OpenWattConsole(SimpleNamespace(stdin=writer, stdout=reader))

            def command(text):
                reply = console.send_command(text, read_delay=0.3, timeout=4)
                record("command", command=text, reply=reply)
                if any(error in reply for error in ("Exception response", "Unknown", "Error:", "not found")):
                    raise RuntimeError(reply)
                return reply

            def automatic():
                reply = command("/protocol/modbus/node/request/write client=mb slave=goodwe_ems reg-type=holding register=47511 values=1,0")
                if "2 written" not in reply:
                    raise RuntimeError("Automatic-mode write was not acknowledged")

            def sample(phase):
                request = urllib.request.Request(
                    f"http://{args.pi}/api/get", data=json.dumps({"paths": paths}).encode(),
                    headers={"Content-Type": "application/json"})
                with urllib.request.urlopen(request, timeout=8) as response:
                    record("sample", phase=phase, data=json.load(response))

            reply = command("/apps/energy/policy/get house_battery_surplus disabled")
            if not re.search(r"^true\s*$", reply, re.M):
                raise RuntimeError("House battery policy must be disabled before the diagnostic")
            try:
                record("hold_started", duration_seconds=args.hold_seconds)
                deadline = time.monotonic() + args.hold_seconds
                while time.monotonic() < deadline:
                    automatic()
                    sample("holding-auto")
                    time.sleep(min(5, max(0, deadline - time.monotonic())))
                record("quiet_observation_started", duration_seconds=args.observe_seconds)
                deadline = time.monotonic() + args.observe_seconds
                while time.monotonic() < deadline:
                    sample("quiet")
                    time.sleep(min(5, max(0, deadline - time.monotonic())))
            finally:
                try:
                    automatic()
                    record("cleanup", automatic_requested=True)
                finally:
                    connection.shutdown(socket.SHUT_RDWR)
                    console.reader_thread.join(timeout=2)
                    writer.close()
                    reader.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", required=True, action="store_true")
    parser.add_argument("--pi", required=True)
    parser.add_argument("--hold-seconds", type=float, default=180)
    parser.add_argument("--observe-seconds", type=float, default=60)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not 0 < args.hold_seconds <= 300 or not 0 <= args.observe_seconds <= 120:
        parser.error("Hold must be between 0 and 300 seconds, observation between 0 and 120 seconds")
    run(args)
