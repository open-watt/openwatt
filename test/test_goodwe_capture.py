"""Validate capture classification using real SolarGo/inverter wire evidence."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("goodwe_capture", ROOT / "tools/goodwe_capture.py")
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


class GoodWeCaptureTest(unittest.TestCase):
    def test_module_length_and_version_are_distinct_from_crc(self):
        decoded = capture.classify(bytes.fromhex("5a5a0181000956312e312e332e3134a199"))
        self.assertTrue(decoded["valid"])
        self.assertEqual((decoded["function"], decoded["declared_length"]), (129, 9))
        for body, field in ((bytes.fromhex("5a5a01020001"), "length_valid"),
                            (bytes.fromhex("5a5a03010000"), "recognized_version")):
            decoded = capture.classify(body + capture.crc16(body).to_bytes(2, "little"))
            self.assertTrue(decoded["crc_valid"])
            self.assertFalse(decoded[field])
            self.assertFalse(decoded["valid"])

    def test_control_write_and_echo_shapes(self):
        request = capture.classify(bytes.fromhex("f710056e0002040002007bb733"))
        self.assertEqual((request["kind"], request["register"], request["count"]),
                         ("write-multiple-request", 1390, 2))
        self.assertTrue(request["valid"])
        response = capture.classify(bytes.fromhex("aa55f710056e0002344f"))
        self.assertEqual((response["register"], response["count"]), (1390, 2))
        body = bytes.fromhex("f710056e0002040002")
        self.assertFalse(capture.classify(body + capture.crc16(body).to_bytes(2, "little"))["valid"])

    def test_probe03_lengths_and_overlapping_registers(self):
        evidence = json.loads((ROOT / "docs/GOODWE_READ_PROBE_03.json").read_text())
        bank = {}
        short = []
        for row in evidence["results"]:
            if not row["response"]:
                continue
            request = bytes.fromhex(row["request"])
            decoded = capture.classify(bytes.fromhex(row["response"]))
            self.assertTrue(decoded["valid"])
            payload = bytes.fromhex(decoded["payload"])
            if request[:2] == b"\xaa\x55":
                if len(payload) != request[9] * 2:
                    short.append(payload.hex())
                continue
            count = int.from_bytes(request[4:6], "big")
            self.assertEqual(len(payload), count * 2)
            start = int.from_bytes(request[2:4], "big")
            for index in range(count):
                key = request[0], start + index
                value = int.from_bytes(payload[2 * index:2 * index + 2], "big")
                if key in bank:
                    self.assertEqual(bank[key], value, key)
                bank[key] = value
        self.assertEqual(short, ["15", "15"])
        self.assertEqual(len(bank), 147)

    def test_alarm_screenshot_matches_wire(self):
        evidence = json.loads((ROOT / "docs/GOODWE_OBSERVATIONS.json").read_text())
        alarm = next(x for x in evidence["observations"] if x["request"] == "f703d6d80043a8de")
        payload = bytes.fromhex(alarm["response"])[5:-2]
        visible = {512: (192, 4, 1, 43), 515: (256, 3, 0, 12), 517: (256, 3, 0, 11)}
        found = {}
        for offset in range(2, 130, 16):
            record = payload[offset:offset + 16]
            identity = int.from_bytes(record[14:16], "big")
            if identity in visible:
                found[identity] = (int.from_bytes(record[6:10], "big"), record[10], record[11], record[13])
        self.assertEqual(found, visible)

    def test_recorded_responses(self):
        evidence = json.loads((ROOT / "docs/GOODWE_OBSERVATIONS.json").read_text())
        for item in evidence["observations"]:
            if item["response"]:
                with self.subTest(request=item["request"]):
                    self.assertEqual(capture.classify(bytes.fromhex(item["response"])), item["response_decoded"])

    def test_distinguishes_shared_magic(self):
        self.assertEqual(capture.classify(bytes.fromhex("aa550db0019a0400000000025b"))["protocol"], "aa55")
        decoded = capture.classify(bytes.fromhex("aa55f703020001b191"))
        self.assertEqual((decoded["protocol"], decoded["payload"]), ("goodwe-modbus-rtu", "0001"))
        self.assertFalse(capture.classify(bytes.fromhex("aa55f703020001b190"))["valid"])

    def test_module_frames_are_not_modbus_unit_90(self):
        for wire in ("5a5a01020000f4d0", "5a5a01030000a510", "5a5a010e000034d3"):
            decoded = capture.classify(bytes.fromhex(wire))
            self.assertEqual(decoded["protocol"], "goodwe-5a5a")
            self.assertTrue(decoded["valid"])
        self.assertFalse(capture.classify(bytes.fromhex("5a5a01020000f4d1"))["valid"])
        for family in (1, 2, 3):
            body = b"ZZ" + bytes((family, 1, 0, 0))
            decoded = capture.classify(body + capture.crc16(body).to_bytes(2, "little"))
            self.assertEqual(decoded["valid"], family in (1, 2))

    def test_discovery(self):
        self.assertEqual(capture.classify(b"WIFIKIT-214028-READ")["kind"], "request")
        response = capture.classify(b"192.0.2.118,020000000008,Solar-WiFi99000008")
        self.assertEqual((response["protocol"], response["address"]), ("discovery", "192.0.2.118"))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.log"
            wire = b"192.0.2.118,020000000008,Solar-WiFi99000008".hex(" ").upper()
            path.write_text("<14>1 2026-10-27T16:20:00Z openwatt-pi aa55-server solargo - - tx 192.0.2.134:12345 " + wire)
            event = capture.inventory(path)["events"][0]
            self.assertEqual(event["name"], "solargo")
            self.assertEqual(event["advertised_name"], "Solar-WiFi99000008")

    def test_concatenated_records_and_filter(self):
        prefix = "<14>1 2026-10-27T16:20:00Z openwatt-pi aa55-server solargo - - "
        record = prefix + "rx 192.0.2.134:12345 F7 03 75 06 00 01 6A 91"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.log"
            path.write_text(record + prefix + "unhandled request" + record)
            report = capture.inventory(path, "192.0.2.134")
            self.assertEqual(report["event_count"], 2)
            self.assertEqual(len(report["inventory"]), 1)
            self.assertEqual(report["inventory"][0]["occurrences"], 2)
            self.assertEqual(report["inventory"][0]["register"], 0x7506)
            self.assertEqual(capture.inventory(path, "192.0.2.8")["event_count"], 0)


if __name__ == "__main__":
    unittest.main()
