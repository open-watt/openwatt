#!/usr/bin/env python3
"""Validate deployed profile readbacks and optionally exercise the two SOC writers.

Explicit --live is required. --exercise-reserves briefly requests 21% minimum
SOC and restores the owner's requested 20% in finally, verifying every write.
No grid protection, chemistry, network or dispatch settings are changed.
--watch-seconds records readbacks and reserve transitions without writing.
"""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import socket
import time
from types import SimpleNamespace
import urllib.request

from test_harness import OpenWattConsole


def run(args):
    reserves = ["cabin_solar.config.advanced.battery_function." + part + "_min_soc"
                for part in ("on_grid", "off_grid")]
    status = "cabin_solar.status.config_write."
    paths = reserves + [status + field for field in ("result", "pending", "address")]
    paths += [device + ".inverter.control." + field
              for device in ("cabin_solar", "goodwe_ems")
              for field in ("kind", "enable", "mode", "result")]
    paths += ["cabin_solar.config.advanced." + field for field in (
        "power_factor", "battery_function.charging_current", "battery_function.discharging_current",
        "safety.protection.over_voltage_level_1_phase", "safety.connection.connect_voltage_upper_limit")]
    paths += ["goodwe_ems.config.advanced.battery_function." + field
              for field in ("on_grid_min_soc", "off_grid_min_soc", "charging_current")]
    paths += ["cabin_solar." + field for field in (
        "status.time", "status.operating_mode", "status.diagnostics",
        "solar.meter.power", "battery.meter.voltage", "battery.meter.power", "battery.store.soc",
        "config.basic.working_mode.mode", "config.basic.battery_model.index",
        "config.basic.battery_model.protocol")]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("a", encoding="utf-8", buffering=1) as log:
        def record(event, **values):
            log.write(json.dumps(dict(time=datetime.now(timezone.utc).isoformat(), event=event, **values)) + "\n")

        def sample():
            request = urllib.request.Request(
                f"http://{args.pi}/api/get", data=json.dumps({"paths": paths}).encode(),
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=8) as response:
                data = json.load(response)
            record("sample", data=data)
            return {path: value.get("value") for path, value in data.items()}

        values = sample()
        if args.watch_seconds:
            previous = {path: values.get(path) for path in reserves}
            deadline = time.monotonic() + args.watch_seconds
            while time.monotonic() < deadline:
                time.sleep(min(5, max(0, deadline - time.monotonic())))
                try:
                    values = sample()
                except (OSError, TimeoutError) as error:
                    record("read_error", error=str(error))
                    continue
                for path in reserves:
                    value = values.get(path)
                    if value != previous[path]:
                        record("reserve_changed", path=path, previous=previous[path], value=value)
                        previous[path] = value
            record("watch_complete")
            return
        if not args.exercise_reserves:
            return
        if any(values.get(path) is None for path in reserves):
            raise RuntimeError("Reserve readbacks unavailable; refusing a blind write")
        if any(values.get(device + ".inverter.control.mode") != 1 for device in ("cabin_solar", "goodwe_ems")):
            raise RuntimeError("Both inverters must be confirmed in automatic mode")
        with socket.create_connection((args.pi, 23), timeout=8) as connection:
            connection.settimeout(None)
            reader = connection.makefile("r", encoding="utf-8", errors="replace")
            writer = connection.makefile("w", encoding="utf-8")
            console = OpenWattConsole(SimpleNamespace(stdin=writer, stdout=reader))

            def write(path, percent):
                command = f"/element/set element={path} value={percent}%"
                reply = console.send_command(command, read_delay=0.2, timeout=3)
                record("command", command=command, reply=reply)
                if any(error in reply for error in ("Cannot set", "not found", "Unknown", "read-only")):
                    raise RuntimeError(reply)
                deadline = time.monotonic() + 18
                while time.monotonic() < deadline:
                    values = sample()
                    if values.get(status + "pending") is False:
                        if values.get(status + "result") == "verified" and values.get(path) == percent:
                            record("verified", path=path, percent=percent)
                            return
                        raise RuntimeError(f"Write failed: {values.get(status + 'result')}")
                    time.sleep(0.3)
                raise RuntimeError("Verification timed out")

            touched = []
            try:
                for path in reserves:
                    touched.append(path)
                    write(path, 21)
                    write(path, 20)
            finally:
                errors = []
                try:
                    for path in touched:
                        try:
                            values = sample()
                            if values.get(path) != 20 or values.get(status + "pending") is not False or values.get(status + "result") != "verified":
                                write(path, 20)
                        except Exception as error:
                            errors.append(str(error))
                    record("cleanup", errors=errors, requested_min_soc=20)
                finally:
                    connection.shutdown(socket.SHUT_RDWR)
                    console.reader_thread.join(timeout=2)
                    writer.close()
                    reader.close()
                if errors:
                    raise RuntimeError("Reserve restoration requires attention: " + "; ".join(errors))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", required=True)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--exercise-reserves", action="store_true")
    mode.add_argument("--watch-seconds", type=float, default=0)
    parser.add_argument("--pi", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 0 <= args.watch_seconds <= 86400:
        parser.error("--watch-seconds must be between0 and86400")
    run(args)
