#!/usr/bin/env python3
"""List low745 catalogue entries or emit a staged native battery-selection script."""

import argparse
from decimal import Decimal
import json
from pathlib import Path
import re
import sys


def selections(catalogue):
    """Keep the supplied catalogue authoritative; do not substitute bundled data."""
    return [battery for group in catalogue["data"]["low745"] for battery in group["batterys"]]


def selection_fields(entry):
    def number(name):
        value = Decimal(str(entry[name]))
        if not value.is_finite() or value < 0:
            raise ValueError(f"Invalid catalogue {name}")
        return value

    def scaled(name, scale=1):
        value = number(name) * scale
        raw = int(value)
        if value != raw or not 0 <= raw <= 65535:
            raise ValueError(f"Catalogue {name} is outside its wire encoding")
        return raw

    charge_v = scaled("chargeVoltage", 10)
    discharge_v = scaled("dischargeVoltage", 10)
    grid_dod = scaled("dischargeDepthGrid")
    offgrid_dod = scaled("dischargeDepthOffGrid")
    start_soc = scaled("strongSocStart", 10)
    end_soc = scaled("strongSocEnd", 10)
    if not 0 < discharge_v <= charge_v or grid_dod > 100 or offgrid_dod > 100:
        raise ValueError("Invalid catalogue voltage or depth of discharge")
    if not start_soc <= end_soc <= 1000:
        raise ValueError("Invalid catalogue forced-charge SOC thresholds")
    return [
        ("single_battery_mode", "1"),
        ("protocol", str(scaled("protocolCode"))),
        ("capacity", f'{scaled("capacity")}Ah'),
        ("charge_voltage", f"{Decimal(charge_v) / 10}V"),
        ("charge_current", f'{Decimal(scaled("chargeCurrent", 10)) / 10}A'),
        ("discharge_voltage", f"{Decimal(discharge_v) / 10}V"),
        ("discharge_current", f'{Decimal(scaled("dischargeCurrent", 10)) / 10}A'),
        ("on_grid_min_soc", f"{100 - grid_dod}%"),
        ("off_grid_discharge_voltage", f"{Decimal(discharge_v) / 10}V"),
        ("off_grid_min_soc", f"{100 - offgrid_dod}%"),
        ("forced_charge_start_soc", f"{Decimal(start_soc) / 10}%"),
        ("forced_charge_end_soc", f"{Decimal(end_soc) / 10}%"),
        ("catalogue_index", str(scaled("indexCode"))),
        ("current_coefficient_raw", str(scaled("currentCoefficient", 100))),
    ]


def console_script(entry, device, apply):
    if not re.fullmatch(r"[A-Za-z0-9_-]+", device) or not 1 <= apply <= 0xFFFFFFFF:
        raise ValueError("Device must be a simple identifier and apply a nonzero U32 counter")
    path = f"{device}.config.basic.battery_model.selection"
    lines = [f"/element/set element={path}.{field} value={value}" for field, value in selection_fields(entry)]
    lines.append(f"/element/set element={path}.apply value={apply}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalogue", type=Path, help="Explicit SolarGo BatteryListNew/cache JSON; low745 schema")
    parser.add_argument("--index", type=int, help="Emit this catalogue index; omit to list entries")
    parser.add_argument("--device", default="inverter")
    parser.add_argument("--apply", type=int, default=1, help="Apply counter different from the current element value")
    args = parser.parse_args()
    try:
        entries = selections(json.loads(args.catalogue.read_text(encoding="utf-8")))
        if args.index is None:
            for entry in entries:
                print(f'{entry["indexCode"]}\t{entry["model"]}')
        else:
            matches = [entry for entry in entries if int(entry["indexCode"]) == args.index]
            if len(matches) != 1:
                raise ValueError("Catalogue index must identify exactly one entry")
            print(console_script(matches[0], args.device, args.apply))
    except (KeyError, ValueError, ArithmeticError, OSError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    main()
