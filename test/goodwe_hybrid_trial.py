#!/usr/bin/env python3
"""Bounded live ES mode-2/3 characterization using the existing leased control.

Explicit --live is required. Wait for real PV, suspend the cabin surplus policy,
sample both AC ports and battery/PV telemetry, then restore automatic operation.
The GoodWe binding remains running so loss of this process expires its override.
This characterizes native ceilings; it does not assert linear target tracking.
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
    fields = (
        "solar.meter.power", "battery.meter.voltage", "battery.meter.current",
        "battery.meter.power", "battery.store.soc", "battery.store.mode",
        "battery.store.max_charge_current", "battery.store.max_discharge_current",
        "grid.meter.power", "backup.meter.power", "inverter.load.power",
        "inverter.control.kind", "inverter.control.enable", "inverter.control.available",
        "inverter.control.setpoint", "inverter.control.applied",
        "inverter.control.mode", "inverter.control.result",
        "status.operating_mode", "status.diagnostics",
        "config.advanced.battery_function.on_grid_min_soc",
        "config.advanced.battery_function.off_grid_min_soc",
    )
    paths = ["cabin_solar." + field for field in fields]
    paths += ["cabin_meter.meter_1.power", "goodwe_meter.meter1.power"]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("a", encoding="utf-8", buffering=1) as log:
        def record(event, **data):
            row = dict(time=datetime.now(timezone.utc).isoformat(), event=event, **data)
            log.write(json.dumps(row) + "\n")
            return row

        def sample(phase):
            req = urllib.request.Request(
                f"http://{args.pi}/api/get", data=json.dumps({"paths": paths}).encode(),
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=8) as response:
                data = json.load(response)
            record("sample", phase=phase, data=data)
            return {path: entry.get("value") for path, entry in data.items()}

        record("waiting_for_pv", min_pv_watts=args.min_pv, timeout_seconds=args.wait_timeout)
        deadline = time.monotonic() + args.wait_timeout
        while True:
            if time.monotonic() >= deadline:
                record("wait_expired")
                return
            try:
                values = sample("waiting")
                if ((values.get("cabin_solar.solar.meter.power") or 0) >= args.min_pv
                        and values.get("cabin_solar.inverter.control.available") is True):
                    break
            except (OSError, TimeoutError) as error:
                record("wait_error", error=str(error))
            time.sleep(30)
        with socket.create_connection((args.pi, 23), timeout=8) as conn:
            conn.settimeout(None)
            reader = conn.makefile("r", encoding="utf-8", errors="replace")
            writer = conn.makefile("w", encoding="utf-8")
            console = OpenWattConsole(SimpleNamespace(stdin=writer, stdout=reader))

            def command(text):
                reply = console.send_command(text, read_delay=0.4, timeout=3)
                record("command", command=text, reply=reply)
                if any(e in reply for e in ("not found", "Invalid value", "Unknown command", "failed:")):
                    raise RuntimeError(reply)
                return reply

            policy = "cabin_battery_surplus"
            restore_policy = None
            owns_override = False
            try:
                reply = command(f"/apps/energy/policy/get {policy} disabled")
                lines = [line.strip() for line in reply.splitlines()]
                if "false" in lines:
                    restore_policy = False
                elif "true" in lines:
                    restore_policy = True
                else:
                    raise RuntimeError("Cannot establish original policy state")
                command(f"/apps/energy/policy/set {policy} disabled=true")
                # Let the allocator release its own lease. An override that
                # remains afterward belongs to another actor, not this trial.
                for _ in range(5):
                    time.sleep(1)
                    values = sample("acquiring")
                    if values.get("cabin_solar.inverter.control.kind") in ("autonomous", 0):
                        break
                else:
                    raise RuntimeError("Existing manual override; refusing to take ownership")
                if values.get("cabin_solar.inverter.control.enable") is not True:
                    raise RuntimeError("Inverter explicitly stopped; refusing to enable it")
                owns_override = True
                record("trial_started", interpretation="Native ceilings, charge-positive; no PV-specific limit writes")
                for watts in (0, 1, 500, 1000, 0, -500, 0):
                    values = sample(f"before-{watts}")
                    soc = values.get("cabin_solar.battery.store.soc")
                    if watts < 0 and (soc is None or soc <= 22):
                        record("phase_skipped", watts=watts, reason="SOC margin")
                        continue
                    command(f"/element/set element=cabin_solar.inverter.control.setpoint value={watts}W")
                    command("/element/set element=cabin_solar.inverter.control.kind value=continuous")
                    for index in range(15):
                        if index and index % 5 == 0:
                            command(f"/element/set element=cabin_solar.inverter.control.setpoint value={watts}W")
                        time.sleep(1)
                        values = sample(str(watts))
                        if values.get("cabin_solar.inverter.control.available") is not True:
                            raise RuntimeError("Inverter became unavailable")
                        voltage = values.get("cabin_solar.battery.meter.voltage")
                        if voltage is None or not 44 <= voltage <= 57.5:
                            raise RuntimeError("Battery telemetry outside trial bounds")
                record("trial_finished")
                command("/element/set element=cabin_solar.inverter.control.kind value=autonomous")
                for _ in range(15):
                    time.sleep(1)
                    values = sample("confirming-auto")
                    if values.get("cabin_solar.inverter.control.mode") == 1:
                        break
                else:
                    raise RuntimeError("Automatic mode readback not confirmed before observation")
                record("automatic_observation_started", seconds=args.observe_auto_seconds)
                deadline = time.monotonic() + args.observe_auto_seconds
                while time.monotonic() < deadline:
                    time.sleep(min(5, max(0, deadline - time.monotonic())))
                    sample("observing-auto")
            finally:
                errors = []
                try:
                    if owns_override:
                        try:
                            command("/element/set element=cabin_solar.inverter.control.kind value=autonomous")
                            for _ in range(10):
                                time.sleep(1)
                                values = sample("restoring-auto")
                                if values.get("cabin_solar.inverter.control.mode") == 1:
                                    break
                            else:
                                errors.append("Automatic mode readback not confirmed")
                        except Exception as error:
                            errors.append(str(error))
                    if restore_policy is not None:
                        try:
                            command(f"/apps/energy/policy/set {policy} disabled={'true' if restore_policy else 'false'}")
                        except Exception as error:
                            errors.append(str(error))
                    record("cleanup_complete", errors=errors)
                finally:
                    conn.shutdown(socket.SHUT_RDWR)
                    console.reader_thread.join(timeout=2)
                    writer.close()
                    reader.close()
                if errors:
                    raise RuntimeError("; ".join(errors))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", required=True)
    parser.add_argument("--pi", required=True)
    parser.add_argument("--min-pv", type=float, default=300)
    parser.add_argument("--wait-timeout", type=float, default=8 * 3600)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--observe-auto-seconds", type=float, default=30)
    args = parser.parse_args()
    if args.min_pv <= 0 or not 0 < args.wait_timeout <= 8 * 3600:
        parser.error("Require positive PV threshold and wait timeout <=8 hours")
    if not 0 <= args.observe_auto_seconds <= 300:
        parser.error("Require automatic-mode observation between0 and300 seconds")
    run(args)
