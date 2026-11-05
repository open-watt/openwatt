#!/usr/bin/env python3
"""Validate catalogue conversion against the captured native low745 selection."""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from goodwe_battery_catalogue import console_script, selection_fields


class BatteryCatalogueTest(unittest.TestCase):
    def setUp(self):
        self.entry = dict(protocolCode=4, capacity="200", chargeVoltage="53.2", chargeCurrent="100",
                          dischargeVoltage="45", dischargeCurrent="100", dischargeDepthGrid="80",
                          dischargeDepthOffGrid="80", strongSocStart="14", strongSocEnd="19",
                          indexCode=116, currentCoefficient="1")

    def test_captured_entry(self):
        fields = selection_fields(self.entry)
        self.assertEqual(fields[0:3], [("single_battery_mode", "1"), ("protocol", "4"), ("capacity", "200Ah")])
        self.assertEqual(dict(fields)["on_grid_min_soc"], "20%")
        self.assertEqual(dict(fields)["off_grid_min_soc"], "20%")
        self.assertEqual(dict(fields)["current_coefficient_raw"], "100")
        script = console_script(self.entry, "native", 7).splitlines()
        self.assertEqual(len(script), 15)
        self.assertEqual(script[-1], "/element/set element=native.config.basic.battery_model.selection.apply value=7")

    def test_invalid_coupled_values(self):
        for field, value in (("dischargeDepthGrid", "101"), ("strongSocEnd", "5"),
                             ("dischargeVoltage", "60"), ("chargeVoltage", "NaN")):
            with self.subTest(field=field), self.assertRaises(ValueError):
                selection_fields(dict(self.entry, **{field: value}))

    def test_console_identifiers(self):
        for device, apply in (("native; /system/reset", 1), ("native", 0), ("native", 2**32)):
            with self.assertRaises(ValueError):
                console_script(self.entry, device, apply)


if __name__ == "__main__":
    unittest.main()
