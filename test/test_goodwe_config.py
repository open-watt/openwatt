#!/usr/bin/env python3
"""Verify AA55/RTU configuration writes, coupled fields, rejection and readback."""

import argparse
import json
import re
from pathlib import Path
import shutil
import socket
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest

from test_harness import OpenWattConsole, OpenWattProcess
from test_goodwe_server import frame

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from goodwe_capture import crc16
from goodwe_battery_catalogue import selection_fields

BINARY = None


class GoodWeConfigurationTest(unittest.TestCase):
    def test_verified_writes(self):
        if not BINARY:
            self.skipTest("--binary required")
        with tempfile.TemporaryDirectory(prefix="openwatt-goodwe-config-") as directory:
            root = Path(directory)
            (root / "conf/profiles").mkdir(parents=True)
            (root / "conf/profiles/goodwe_invalid_test.conf").write_text(
                "elements:\n"
                "    goodwe-rtu: 47547, 0, u16, RW desc: broken, , ondemand\n"
                "        write: modbus, 47547, 1\n"
                "        commit: schedule\n"
                "device-template:\n"
                "    component:\n"
                "        id: config\n"
                "        element-map: broken, @broken\n", encoding="utf-8")
            shutil.copyfile(Path(__file__).parent / "profiles/goodwe_config_test.conf",
                            root / "conf/profiles/goodwe_config_test.conf")
            shutil.copyfile(Path(__file__).parent / "profiles/goodwe_realtime_load.conf",
                            root / "conf/profiles/goodwe_realtime_load.conf")
            shutil.copyfile(Path(__file__).resolve().parents[1] / "conf/profiles/goodwe_profiles/gwxx48es.conf",
                            root / "conf/profiles/gwxx48es.conf")
            shutil.copyfile(Path(__file__).resolve().parents[1] / "conf/profiles/modbus_profiles/goodwe_ems.conf",
                            root / "conf/profiles/goodwe_ems.conf")
            listener = socket.socket()
            self.addCleanup(listener.close)
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            listener.settimeout(5)
            (root / "conf/startup.conf").write_text(
                f"/stream/tcp-client/add name=test remote=127.0.0.1:{listener.getsockname()[1]}\n"
                "/console/session/add name=test stream=test profile=dumb\n", encoding="utf-8")
            inverter = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.addCleanup(inverter.close)
            inverter.bind(("127.0.0.1", 0))
            inverter.settimeout(0.1)
            registers = {0x056E: bytes.fromhex("00010000"), 0x0560: bytes.fromhex("0014"), 0x05A1: bytes.fromhex("0014"),
                         0x059C: bytes.fromhex("0001a55a"),
                         0x055D: bytes.fromhex("01f4"), 47547: bytes.fromhex("01020304ff55ffdb0050beef")}
            capture = Path(__file__).resolve().parents[1] / "docs/GOODWE_PROFILE_PROBE_20261030.json"
            for event in json.loads(capture.read_text(encoding="utf-8"))["events"]:
                if event.get("kind") == "modbus" and event.get("words") and event["address"] >= 45400:
                    registers[event["address"]] = b"".join(word.to_bytes(2, "big") for word in event["words"])
            registers[45400] = b"\xff\xff" + registers[45400][2:]
            writes = []
            module_writes = []
            drop_module = set()
            write_attempts = []
            reject_native = set()
            reject_vendor = set()
            drop_reads = set()
            errors = []
            reject = threading.Event()
            mismatch = threading.Event()
            pause = threading.Event()
            arrived = threading.Event()
            release = threading.Event()
            stopped = threading.Event()
            slow_reads = threading.Event()
            realtime_times = []
            realtime_counts = {1: 0, 3: 0}
            alarm_pages = {}
            alarm_events = []
            alarm_drift = threading.Event()

            def modbus(data):
                return b"\xaa\x55" + data + crc16(data).to_bytes(2, "little")

            def store(address, data):
                writes.append((address, data))
                previous = registers.get(address, b"")
                if len(previous) > len(data):
                    tail_address = address + len(data) // 2
                    registers[tail_address] = register_data(tail_address, (len(previous) - len(data)) // 2)
                registers.pop(address, None)
                if pause.is_set():
                    pause.clear()
                    arrived.set()
                    release.wait(1)
                if mismatch.is_set():
                    mismatch.clear()
                    registers[address] = (int.from_bytes(data, "big") - 1).to_bytes(len(data), "big")
                else:
                    registers[address] = data

            def register_data(address, count):
                data = bytearray(count * 2)
                for base, block in registers.items():
                    start = max(address * 2, base * 2)
                    end = min((address + count) * 2, base * 2 + len(block))
                    if start < end:
                        data[start-address*2:end-address*2] = block[start-base*2:end-base*2]
                return bytes(data)

            def serve():
                while not stopped.is_set():
                    try:
                        packet, peer = inverter.recvfrom(2048)
                    except socket.timeout:
                        continue
                    try:
                        if packet[:2] == b"ZZ":
                            fn = packet[3]
                            if (packet[2], fn) in drop_module:
                                continue
                            if fn in (10, 11, 12) or (packet[2] == 2 and packet[6:-2]):
                                module_writes.append((packet[2], fn, packet[6:-2]))
                                data = b""
                            elif fn == 2:
                                data = bytes([13]) + b"OpenWatt-Test"
                            elif packet[2] == 2:
                                self.assertEqual(fn, 1)
                                data = b"family-two"
                                wrong = b"ZZ\x01\x81\x00\x05wrong"
                                inverter.sendto(wrong + crc16(wrong).to_bytes(2, "little"), peer)
                            elif fn == 1:
                                data = b"V1.1.3.14"
                            elif fn == 3:
                                data = b"DHCP,192.0.2.5,255.255.255.0,192.0.2.1,192.0.2.1"
                            elif fn == 4:
                                self.assertIn(packet[6], (1, 2))
                                data = b"\x01" if packet[6] == 1 else b"connected"
                            elif fn == 7:
                                data = b"upstream-only"
                            elif fn == 5:
                                self.assertEqual(packet[6], 1)
                                data = bytes.fromhex("01012c0190")
                            else:
                                raise AssertionError(packet.hex())
                            response = b"ZZ" + bytes((packet[2], fn | 128)) + len(data).to_bytes(2, "big") + data
                            reply = response + crc16(response).to_bytes(2, "little")
                        elif packet[:2] == b"\xaa\x55":
                            control, fn = packet[4:6]
                            payload = packet[7:-2]
                            if control == 1 and fn == 2:
                                data = bytes(64)
                            elif control == 1 and fn in (1, 3, 6):
                                if fn in realtime_counts:
                                    realtime_counts[fn] += 1
                                if slow_reads.is_set():
                                    time.sleep(0.2)
                                if fn == 6:
                                    realtime_times.append(time.monotonic())
                                data = bytes(140)
                            elif control == 1 and fn == 9:
                                data = bytearray(86)
                                data[32:34] = registers[0x0560]
                                data[42:44] = b"\x00\x0a"
                                data[66:68] = registers.get(0x0359, bytes(2))
                            elif control == 1 and fn == 0x1A:
                                address = int.from_bytes(payload[:2], "big")
                                data = registers.get(address, bytes(payload[2] * 2))[:payload[2] * 2]
                            elif control == 3 and fn == 0x5e:
                                writes.append((0x035e, bytes(payload)))
                                data = b"\x06"
                            elif control == 3 and fn in (0x26, 0x27, 0x2c, 0x36, 0x59):
                                if fn in reject_vendor:
                                    reject_vendor.remove(fn)
                                    data = b"\x15"
                                else:
                                    writes.append((0x0300 | fn, bytes(payload)))
                                    if fn == 0x59:
                                        registers[0x0359] = b"\x00" + payload
                                    data = b"\x06"
                            elif control == 2 and fn == 0x39:
                                address = int.from_bytes(payload[:2], "big")
                                if reject.is_set():
                                    reject.clear()
                                    data = b"\x15"
                                else:
                                    store(address, payload[3:])
                                    data = b"\x06"
                            else:
                                raise AssertionError(packet.hex())
                            reply = frame(control, fn | 128, bytes(data), 0x7f, packet[2])
                        else:
                            address = int.from_bytes(packet[2:4], "big")
                            if address in (55316, 47016, 55252):
                                alarm_events.append((packet[1], address, int.from_bytes(packet[4:6], "big")))
                            if packet[1] in (3, 4):
                                if address in drop_reads:
                                    continue
                                if slow_reads.is_set() and address >= 45400:
                                    time.sleep(0.4)
                                count = int.from_bytes(packet[4:6], "big")
                                if address == 55252 and count == 65:
                                    selected = int.from_bytes(register_data(47016, 1), "big")
                                    data = alarm_pages.get(selected, bytes(128)) + register_data(55316, 1)
                                    if alarm_drift.is_set():
                                        alarm_drift.clear()
                                        registers[47016] = (selected + 1).to_bytes(2, "big")
                                else:
                                    data = register_data(address, count)
                                reply = modbus(bytes((packet[0], packet[1], len(data))) + data)
                            elif packet[1] == 6:
                                write_attempts.append(address)
                                if address in reject_native:
                                    reject_native.remove(address)
                                    reply = modbus(bytes((packet[0], 0x86, 3)))
                                else:
                                    store(address, packet[4:6])
                                    reply = modbus(packet[:6])
                            elif packet[1] == 16:
                                write_attempts.append(address)
                                if address in reject_native:
                                    reject_native.remove(address)
                                    reply = modbus(bytes((packet[0], 0x90, 3)))
                                else:
                                    store(address, packet[7:-2])
                                    reply = modbus(packet[:6])
                            else:
                                raise AssertionError(packet.hex())
                        inverter.sendto(reply, peer)
                    except Exception as error:
                        errors.append(str(error))

            worker = threading.Thread(target=serve, daemon=True)
            worker.start()
            runtime = OpenWattProcess(binary_path=BINARY, startup_delay=0.5)
            runtime.project_root = root
            runtime.crash_file = root / "crash.txt"
            runtime.output_file = root / "output.txt"
            runtime.log_file = root / "log.txt"
            self.assertTrue(runtime.start())
            stderr = []
            drain = threading.Thread(target=lambda: stderr.extend(iter(runtime.process.stderr.readline, "")), daemon=True)
            drain.start()
            transcript = []
            connection = reader = writer = None
            try:
                connection, _ = listener.accept()
                reader = connection.makefile("r", encoding="utf-8", errors="replace")
                writer = connection.makefile("w", encoding="utf-8")
                runtime.console = OpenWattConsole(SimpleNamespace(stdin=writer, stdout=reader))

                def command(text):
                    output = runtime.console.send_command(text, read_delay=0.15, timeout=2)
                    transcript.append(text + "\n" + output)
                    for bad in ("Element not found", "Unknown command", "Missing argument", "Invalid value for property"):
                        self.assertNotIn(bad, output)
                    return output

                def await_result(expected):
                    for _ in range(8):
                        output = command("/device/print filter=target.status.config_write.result")
                        if expected in output:
                            return
                        time.sleep(0.15)
                    self.fail(output + "\n" + repr(errors))

                for expression, expected in (("1 != 2", "1"), ("1 != 1", "0"), ("1 == 1", "1"), ("1 == 2", "0")):
                    self.assertEqual(command(f":put ({expression})").strip(), expected)

                command(f"/protocol/goodwe/client/add name=wire remote=127.0.0.1:{inverter.getsockname()[1]}")
                command("/binding/goodwe/add name=rejected device=rejected client=wire profile=goodwe_invalid_test")
                time.sleep(0.3)
                missing = runtime.console.send_command("/element/set element=rejected.config.broken value=1", read_delay=0.15, timeout=2)
                self.assertIn("Element not found", missing)
                self.assertIn("Rejected profile field: broken", "".join(stderr))
                self.assertFalse(writes, "Rejected configuration must never materialise a writable device")
                command("/binding/goodwe/remove rejected")
                command("/binding/goodwe/add name=cfg device=target client=wire profile=goodwe_config_test")
                time.sleep(1.2)
                self.assertIn("20%", command("/device/print filter=target.config.on_grid_soc"))
                self.assertNotIn("6553.5", command("/device/print filter=target.config.safety_voltage"))
                registers[45400] = (2650).to_bytes(2, "big") + registers[45400][2:]
                time.sleep(1.2)
                self.assertIn("265", command("/device/print filter=target.config.safety_voltage"))
                registers[45400] = b"\xff\xff" + registers[45400][2:]
                time.sleep(1.2)
                self.assertNotIn("265", command("/device/print filter=target.config.safety_voltage"))
                self.assertIn("above maximum", command("/element/set element=target.config.on_grid_soc value=101%"))
                self.assertEqual(registers[0x0560], b"\x00\x14")
                command("/element/set element=target.config.on_grid_soc value=25%")
                await_result("verified")
                self.assertEqual(registers[0x0560], b"\x00\x19")
                command("/element/set element=target.config.off_grid_soc value=30%")
                await_result("verified")
                self.assertEqual(registers[0x05A1], b"\x00\x1e")
                command("/element/set element=target.config.charge_current value=31.7A")
                await_result("verified")
                self.assertEqual(registers[0x055D], (317).to_bytes(2, "big"))
                original = registers[47547]
                command("/element/set element=target.config.tou.start_hour value=7\n"
                        "/element/set element=target.config.tou.start_minute value=11")
                await_result("verified")
                self.assertEqual(registers[47547], b"\x07\x0b" + original[2:])
                reject.set()
                command("/element/set element=target.config.on_grid_soc value=27%")
                await_result("write rejected")
                self.assertEqual(registers[0x0560], b"\x00\x19")
                self.assertIn("25%", command("/device/print filter=target.config.on_grid_soc"))
                mismatch.set()
                command("/element/set element=target.config.on_grid_soc value=28%")
                await_result("readback mismatch")
                self.assertIn("27%", command("/device/print filter=target.config.on_grid_soc"))
                pause.set()
                command("/element/set element=target.config.on_grid_soc value=29%")
                self.assertTrue(arrived.wait(2))
                command("/element/set element=target.config.on_grid_soc value=30%")
                release.set()
                await_result("verified")
                for _ in range(6):
                    if registers[0x0560] == b"\x00\x1e":
                        break
                    time.sleep(0.3)
                self.assertEqual(registers[0x0560], b"\x00\x1e")
                command("/binding/goodwe/set cfg disabled=true")
                registers[45400] = (2650).to_bytes(2, "big") + registers[45400][2:]
                registers[45417] = registers[45417][:22] + bytes.fromhex("001f002f") + registers[45417][26:]
                registers[45443] = registers[45443][:20] + bytes.fromhex("007b01c80315") + registers[45443][26:]
                slow_reads.set()
                command("/binding/goodwe/add name=load device=load client=wire profile=goodwe_realtime_load model=load")
                command("/binding/goodwe/add name=production device=es client=wire profile=gwxx48es model=GW5048D-ES")
                time.sleep(25)
                self.assertGreaterEqual(len(realtime_times), 10)
                self.assertTrue(all(n >= 5 for n in realtime_counts.values()), realtime_counts)
                self.assertLess(max(b - a for a, b in zip(realtime_times, realtime_times[1:])), 3,
                                "Background configuration reads blocked live telemetry")
                slow_reads.clear()
                command("/binding/goodwe/set load disabled=true")
                self.assertRegex(command("/device/print filter=es.config.meter_ct_detection.status_code"), r"status_code\s+1\b")
                self.assertRegex(command("/device/print filter=es.config.meter_ct_detection.result_code"), r"result_code\s+42330\b")
                self.assertIn("265", command("/device/print filter=es.config.advanced.safety.protection.over_voltage_level_1_phase"))
                self.assertIn("254", command("/device/print filter=es.config.advanced.safety.connection.connect_voltage_upper_limit"))
                self.assertIn("31s", command("/device/print filter=es.config.advanced.safety.connection.grid_connect_power_rate"))
                self.assertIn("47s", command("/device/print filter=es.config.advanced.safety.connection.grid_connect_power_rate_under_fault"))
                for name, expected in (("of_power_slope", 12.3), ("uf_power_slope", 45.6), ("recovery_power_slope", 78.9)):
                    output = command(f"/device/print filter=es.config.advanced.safety.curves.{name}")
                    self.assertAlmostEqual(float(re.search(name + r"\s+([-\d.eE]+)%", output)[1]), expected, places=4)
                self.assertIn("V1.1.3.14", command("/device/print filter=es.status.communication_module.firmware"))
                self.assertIn("192.0.2.5", command("/device/print filter=es.config.communication.wlan_lan.address"))
                self.assertIn("-0.9", command("/device/print filter=es.config.advanced.power_factor"))
                reactive = command("/device/print filter=es.config.advanced.safety.curves.reactive_v4")
                self.assertAlmostEqual(float(re.search(r"reactive_v4\s+([-\d.eE]+)%", reactive)[1]), -60, places=4)
                cosine = command("/device/print filter=es.config.advanced.safety.curves.power_point_c_cos")
                self.assertAlmostEqual(float(re.search(r"power_point_c_cos\s+([-\d.eE]+)%", cosine)[1]) / 100, 0.9, places=4)
                self.assertIn("30%", command("/device/print filter=es.config.advanced.battery_function.off_grid_min_soc"))
                self.assertIn("below minimum", command("/element/set element=es.config.advanced.battery_function.off_grid_min_soc value=5%"))
                command("/element/set element=es.config.advanced.battery_function.off_grid_min_soc value=24%")
                for _ in range(8):
                    if registers[0x05A1] == b"\x00\x18":
                        break
                    time.sleep(0.2)
                self.assertEqual(registers[0x05A1], b"\x00\x18")
                for field, address, value, expected in (
                    ("hardware_power_limit", 0x7506, "1", 1),
                    ("dred", 0xB7BC, "1", 1),
                    ("output_active_power", 0xB1AC, "37.5%", 375),
                    ("battery_function.immediate_charging", 0xB9B9, "1", 1),
                    ("battery_function.charge_cutoff_soc", 0xB9BA, "83%", 83),
                ):
                    command(f"/element/set element=es.config.advanced.{field} value={value}")
                    for _ in range(15):
                        if registers.get(address) == expected.to_bytes(2, "big"):
                            break
                        time.sleep(0.2)
                    self.assertEqual(registers.get(address), expected.to_bytes(2, "big"), field)
                self.assertIn("above maximum", command("/element/set element=es.config.advanced.output_active_power value=101%"))
                for path, expected in (("server1_status", "1"), ("server2_status", "connected"),
                                       ("packets.sent", "300"), ("packets.received", "400")):
                    self.assertIn(expected, command(f"/device/print filter=es.status.communication_module.{path}"))
                for field, address, value, expected in (
                    ("protection.over_voltage_level_1_phase", 45400, "254.3V", 2543),
                    ("protection.over_frequency_level_1", 45409, "52.34Hz", 5234),
                    ("protection.over_voltage_level_1_time_phase_cycles", 45401, "77", 77),
                ):
                    command(f"/element/set element=es.config.advanced.safety.{field} value={value}")
                    for _ in range(15):
                        if registers.get(address) == expected.to_bytes(2, "big"):
                            break
                        time.sleep(0.2)
                    self.assertEqual(registers.get(address), expected.to_bytes(2, "big"), field)
                refused = command("/element/set element=es.config.advanced.safety.protection.over_voltage_level_1_phase value=301V")
                self.assertIn("above maximum", refused)
                # Editing a slot must not send partially updated schedule blocks.
                slot = "es.config.basic.tou.time1"
                registers[47547] = bytes.fromhex("01000200ff7f003200000000")
                before = registers[47547]
                for field, value in (("start_hour", "6"), ("start_minute", "15"),
                                     ("end_hour", "9"), ("end_minute", "45"),
                                     ("enabled_raw", "255"), ("weekdays", "62"),
                                     ("power", "-37%"), ("cutoff_soc", "86%")):
                    command(f"/element/set element={slot}.{field} value={value}")
                time.sleep(0.6)
                self.assertEqual(registers[47547], before)
                command(f"/element/set element={slot}.apply value=1")
                for _ in range(15):
                    if registers[47547] != before:
                        break
                    time.sleep(0.2)
                self.assertEqual(registers[47547], bytes.fromhex("060f092dff3effdb00560000"))
                before = registers[47547]
                command(f"/element/set element={slot}.end_hour value=5")
                command(f"/element/set element={slot}.apply value=2")
                time.sleep(0.8)
                self.assertEqual(registers[47547], before)
                self.assertIn("start must precede end", command("/device/print filter=es.status.config_write.result"))
                command("/binding/goodwe-control/add name=full-profile device=es client=wire register=1390 scheme=legacy")
                time.sleep(2.2)
                self.assertIn("autonomous", command("/device/print filter=es.inverter.control.kind"))
                self.assertEqual(registers[1390], b"\x00\x01\x00\x00")
                self.assertIn("incompatible", command("/element/set element=es.inverter.control.kind value=discrete"))
                command("/binding/goodwe-control/set full-profile disabled=true")
                legacy_mode = "es.config.basic.working_mode.activation"
                clear = (0x0700, b"\x00\x01")
                for index, request, expected in (
                    (1, "general", [clear, (0x0359, b"\x00"), (0x0336, b"\x00")]),
                    (2, "off_grid", [clear, (0x0327, b"\x00\x30"), (0x0326, b"\x04"), (0x0336, b"\x01"), (0x0359, b"\x01")]),
                    (3, "backup", [clear, (0x0336, b"\x00"), (0x032c, bytes.fromhex("0000173b0a")), (0x0359, b"\x02")]),
                    (4, "tou", [(0x0359, b"\x03")])):
                    before = len(writes)
                    command(f"/element/set element={legacy_mode}.requested_mode value={request}")
                    command(f"/element/set element={legacy_mode}.apply value={index}")
                    for _ in range(25):
                        result = command("/device/print filter=es.status.config_write.result")
                        if len(writes) >= before + len(expected) and "verified" in result:
                            break
                        time.sleep(0.2)
                    self.assertIn("verified", result)
                    self.assertEqual(writes[before:], expected)
                before = len(writes)
                reject_vendor.add(0x26)
                command(f"/element/set element={legacy_mode}.requested_mode value=off_grid")
                command(f"/element/set element={legacy_mode}.apply value=5")
                for _ in range(20):
                    result = command("/device/print filter=es.status.config_write.result")
                    if "rejected" in result:
                        break
                    time.sleep(0.2)
                self.assertIn("rejected", result)
                self.assertEqual(writes[before:], [clear, (0x0327, b"\x00\x30")], "Legacy rejection must stop before offgrid/final-mode changes")
                legacy_password = "es.config.communication.wlan_lan.password"
                command(f'/element/set element={legacy_password}.new_password value="FixtureLegacy42"')
                before = len(module_writes)
                command(f"/element/set element={legacy_password}.apply value=1")
                for _ in range(20):
                    result = command("/device/print filter=es.status.config_write.result")
                    if len(module_writes) >= before + 2 and "acknowledged; reconnect" in result:
                        break
                    time.sleep(0.2)
                self.assertEqual(module_writes[before:], [(2, 1, b"AT+WAKEY=WPA2PSK,AES,FixtureLegacy42\r\n"), (1, 12, b"")])
                time.sleep(0.5)
                self.assertFalse(any(a == 0x035e for a, _ in writes))
                command("/element/set element=es.config.advanced.clear_overload value=1")
                for _ in range(15):
                    if (0x035e, b"\x0f") in writes:
                        break
                    time.sleep(0.2)
                self.assertIn((0x035e, b"\x0f"), writes)
                self.assertIn("acknowledged", command("/device/print filter=es.status.config_write.result"))
                self.assertFalse(any(address == 0x059C for address, _ in writes), "CT checks must never start during profile materialisation")
                for field, payload in (("start_request", b"\x00\x01"), ("stop_request", b"\x00\x00")):
                    before = len(writes)
                    command(f"/element/set element=es.config.meter_ct_detection.{field} value=1")
                    for _ in range(15):
                        result = command("/device/print filter=es.status.config_write.result")
                        if len(writes) > before and "acknowledged" in result:
                            break
                        time.sleep(0.2)
                    self.assertEqual(writes[before:], [(0x059C, payload)])
                    self.assertIn("acknowledged", result)
                before = len(writes)
                reject.set()
                command("/element/set element=es.config.meter_ct_detection.start_request value=2")
                for _ in range(15):
                    result = command("/device/print filter=es.status.config_write.result")
                    if "rejected" in result:
                        break
                    time.sleep(0.2)
                self.assertIn("rejected", result)
                self.assertEqual(len(writes), before)
                for field, payload in (("enable_request", b"\x04"), ("disable_request", b"\x01")):
                    before = len(writes)
                    command(f"/element/set element=es.config.advanced.cold_start.{field} value=1")
                    for _ in range(15):
                        result = command("/device/print filter=es.status.config_write.result")
                        if len(writes) > before and "acknowledged" in result:
                            break
                        time.sleep(0.2)
                    self.assertEqual(writes[before:], [(0x0326, payload)])
                    self.assertIn("acknowledged", result)
                command("/protocol/goodwe/client/remove wire")
                time.sleep(0.3)
                self.assertTrue(runtime.is_running())
                command("/binding/goodwe/set production disabled=true")
                native_id = bytearray(66)
                native_id[6:22] = b"00000SPN00000001"
                native_id[22:32] = b"GW6000ES20"
                native_id[42:54] = b"04048-11-S03"
                native_id[54:66] = b"02020-12-S01"
                registers[35000] = bytes(native_id)
                registers[47589] = bytes.fromhex("00000600fa00000000000001")
                registers[45499] = bytes.fromhex("00a2")
                registers[45433] = bytes(2)
                registers[45456] = bytes.fromhex("0001")
                registers[45482] = bytes.fromhex("0064")
                registers[45483] = bytes(2)
                registers[37007] = (67).to_bytes(2, "big")
                registers[37008] = (94).to_bytes(2, "big")
                command(f"/protocol/goodwe/client/add name=native-wire identity=modbus remote=127.0.0.1:{inverter.getsockname()[1]}")
                command("/binding/goodwe/add name=native device=native client=native-wire profile=goodwe_ems model=GW6000ES20")
                for _ in range(20):
                    output = command("/device/print filter=native.info.model_id")
                    if "GW6000ES20" in output:
                        break
                    time.sleep(0.2)
                self.assertIn("GW6000ES20", output)
                history = "native.status.alarms.page"
                window = bytearray(128)
                window[112:128] = ((1_700_000_000).to_bytes(4, "big") + bytes.fromhex("00021234f7010201deadbeef"))
                alarm_pages[1] = bytes(window)
                window[112:116] = (1_800_000_000).to_bytes(4, "big")
                alarm_pages[0] = bytes(window)
                registers[55316] = bytes.fromhex("0003")

                def alarm_page(index, apply, expected):
                    command(f"/element/set element={history}.requested_index value={index}")
                    command(f"/element/set element={history}.apply value={apply}")
                    for _ in range(20):
                        result = command("/device/print filter=native.status.config_write.result")
                        if expected in result:
                            return result
                        time.sleep(0.2)
                    self.fail(result)

                before = len(alarm_events)
                alarm_page(1, 1, "verified")
                events = alarm_events[before:]
                self.assertEqual([e for e in events if e[1] != 55316], [(6, 47016, 1), (3, 55252, 65), (3, 47016, 1)])
                self.assertIn((3, 55316, 1), events[:events.index((6, 47016, 1))])
                self.assertRegex(command(f"/device/print filter={history}.index"), r"index\s+1\b")
                self.assertIn("2023-11-14", command(f"/device/print filter={history}.record1.timestamp"))
                self.assertRegex(command(f"/device/print filter={history}.record1.subcode_mask"), r"subcode_mask\s+2\b")
                self.assertRegex(command(f"/device/print filter={history}.record1.main_code"), r"main_code\s+513\b")
                self.assertIn("true", command(f"/device/print filter={history}.record1.present"))
                self.assertIn("false", command(f"/device/print filter={history}.record8.present"))

                before = len(writes)
                alarm_page(3, 2, "outside current range")
                self.assertEqual(len(writes), before)
                reject_native.add(47016)
                before_events = len(alarm_events)
                alarm_page(0, 3, "failed")
                self.assertFalse(any(e[1] == 55252 for e in alarm_events[before_events:]))
                self.assertEqual(len(writes), before)
                alarm_drift.set()
                alarm_page(0, 4, "cursor changed")
                self.assertRegex(command(f"/device/print filter={history}.index"), r"index\s+1\b")
                self.assertIn("2023-11-14", command(f"/device/print filter={history}.record1.timestamp"))
                before = len(writes)
                registers[55316] = bytes(2)
                alarm_page(0, 5, "no alarm pages")
                self.assertEqual(len(writes), before)
                self.assertNotRegex(command(f"/device/print filter={history}.index"), r"index\s+1\b")
                self.assertNotIn("2023-11-14", command(f"/device/print filter={history}.record1.timestamp"))
                for field, address in (("reactive_qu_seconds", 45468), ("cos_qu_seconds", 45510), ("active_pu_seconds", 45512)):
                    path = f"native.config.advanced.safety.curves.{field}"
                    command(f"/element/set element={path} value=1.8s")
                    for _ in range(15):
                        if registers.get(address) == bytes.fromhex("0400"):
                            break
                        time.sleep(0.2)
                    self.assertEqual(registers.get(address), bytes.fromhex("0400"), field)
                    self.assertIn("above maximum", command(f"/element/set element={path} value=61s"))
                for field, address, value, expected in (("uv1_voltage", 45920, "172.3V", 1723),
                                                        ("uv5_voltage", 45928, "93.7V", 937),
                                                        ("uv1_cycles", 45921, "253", 253)):
                    path = f"native.config.advanced.safety.voltage_ride_through.{field}"
                    command(f"/element/set element={path} value={value}")
                    for _ in range(15):
                        if registers.get(address) == expected.to_bytes(2, "big"):
                            break
                        time.sleep(0.2)
                    self.assertEqual(registers.get(address), expected.to_bytes(2, "big"), field)
                self.assertIn("above maximum", command("/element/set element=native.config.advanced.safety.voltage_ride_through.uv1_voltage value=231V"))
                for _ in range(10):
                    output = command("/device/print filter=native.status.communication_module.firmware")
                    if "V1.1.3.14" in output:
                        break
                    time.sleep(0.2)
                self.assertIn("V1.1.3.14", output)
                for _ in range(15):
                    output = command("/device/print filter=native.battery.store.soc")
                    if "67%" in output:
                        break
                    time.sleep(0.2)
                self.assertIn("67%", output)
                self.assertIn("192.0.2.5", command("/device/print filter=native.config.communication.wlan_lan.address"))
                command("/element/set element=native.config.advanced.safety.protection.over_voltage_level_1_phase value=255.1V")
                for _ in range(15):
                    if registers.get(45400) == (2551).to_bytes(2, "big"):
                        break
                    time.sleep(0.2)
                self.assertEqual(registers.get(45400), (2551).to_bytes(2, "big"))
                for path, address in (("basic.spd", 45293),
                                      ("advanced.backup_npe_relay", 45288),
                                      ("advanced.afci.enabled", 45270),
                                      ("advanced.software_power_limit", 47509)):
                    command(f"/element/set element=native.config.{path} value=1")
                    for _ in range(15):
                        if registers.get(address) == b"\x00\x01":
                            break
                        time.sleep(0.2)
                    self.assertEqual(registers.get(address), b"\x00\x01")
                command("/element/set element=native.config.basic.spd value=2")
                self.assertEqual(registers[45293], b"\x00\x01")
                for field, address, value in (("on_grid_min_soc", 45356, "23%"),
                                              ("off_grid_min_soc", 45358, "27%"),
                                              ("soc_protection_raw", 47500, "1"),
                                              ("backup_soc_holding", 47602, "1")):
                    command(f"/element/set element=native.config.battery_function.limit_protection.{field} value={value}")
                    expected_word = int(value.rstrip("%")).to_bytes(2, "big")
                    for _ in range(15):
                        if registers.get(address) == expected_word:
                            break
                        time.sleep(0.2)
                    self.assertEqual(registers.get(address), expected_word)
                registers[45357] = bytes.fromhex("01cd")
                reserve_pair = "native.config.battery_function.limit_protection.reserve_pair"
                before = len(write_attempts)
                command(f"/element/set element={reserve_pair}.on_grid_min_soc value=20%")
                command(f"/element/set element={reserve_pair}.off_grid_min_soc value=20%")
                time.sleep(0.3)
                self.assertEqual(len(write_attempts), before)
                command(f"/element/set element={reserve_pair}.apply value=1")
                for _ in range(15):
                    if register_data(45356, 3) == bytes.fromhex("001401cd0014"):
                        break
                    time.sleep(0.2)
                self.assertEqual(register_data(45356, 3), bytes.fromhex("001401cd0014"))
                self.assertEqual(write_attempts[before:], [45356], "Both SOC reserves must use one FC16 while preserving voltage")
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
                    probe.bind(("127.0.0.1", 0))
                    proxy_port = probe.getsockname()[1]
                command('/element/set element=native.config.communication.wlan_lan.password.new_password value="FixtureOnly42"')
                command('/element/set element=native.config.basic.working_mode.requested_mode value=peak_shaving')
                command(f"/protocol/goodwe/server/add name=native-proxy device=native profile=goodwe_ems model=GW6000ES20 bind-address=127.0.0.1 port={proxy_port} discovery-port=0 trace=false serial-number=00000SPN99000008")
                time.sleep(0.5)
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
                    probe.settimeout(2)
                    for address, count in ((35000, 33), (35100, 125), (36000, 27), (37000, 22), (45468, 1), (47547, 48), (47000, 1)):
                        request = bytes((247, 3)) + address.to_bytes(2, "big") + count.to_bytes(2, "big")
                        probe.sendto(request + crc16(request).to_bytes(2, "little"), ("127.0.0.1", proxy_port))
                        reply, _ = probe.recvfrom(1024)
                        self.assertEqual(reply[:5], bytes((170, 85, 247, 3, count * 2)))
                        self.assertEqual(crc16(reply[2:]), 0)
                        if address == 35000:
                            self.assertEqual(reply[11:27], b"00000SPN99000008")
                        elif address == 37000:
                            self.assertEqual(reply[19:21], (67).to_bytes(2, "big"))
                        elif address == 45468:
                            self.assertEqual(reply[5:7], bytes.fromhex("0400"))
                        elif address == 47547:
                            self.assertEqual(reply[5:-2], register_data(47547, 48), "Unavailable typed fields must preserve the opaque schedule bytes")
                        elif address == 47000:
                            self.assertEqual(reply[5:7], bytes(2), "Staged mode must not override the actual mode served by the proxy")
                    request = bytes.fromhex("5a5a01000000")
                    request += crc16(request).to_bytes(2, "little")
                    probe.settimeout(0.4)
                    probe.sendto(request, ("127.0.0.1", proxy_port))
                    with self.assertRaises(socket.timeout, msg="Write-only form inputs must never become module read responses"):
                        probe.recvfrom(1024)
                self.assertIn("00000SPN00000001", command("/device/print filter=native.info.serial_number"))
                command("/protocol/goodwe/server/set native-proxy upstream=native-wire")
                time.sleep(0.3)
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
                    probe.settimeout(3)
                    def forwarded(packet):
                        probe.sendto(packet, ("127.0.0.1", proxy_port))
                        return probe.recvfrom(2048)[0]
                    packet = bytes.fromhex("f706ea60beef")
                    packet += crc16(packet).to_bytes(2, "little")
                    self.assertEqual(forwarded(packet), b"\xaa\x55" + packet)
                    self.assertEqual(registers.get(60000), bytes.fromhex("beef"))
                    packet = bytes.fromhex("f710ea6400020401234567")
                    packet += crc16(packet).to_bytes(2, "little")
                    reply = forwarded(packet)
                    self.assertEqual(reply[2:8], bytes.fromhex("f710ea640002"))
                    self.assertEqual(registers.get(60004), bytes.fromhex("01234567"))
                    packet = bytes.fromhex("f704ea600001")
                    packet += crc16(packet).to_bytes(2, "little")
                    reply = forwarded(packet)
                    self.assertEqual(reply[3], 4)
                    self.assertEqual(reply[5:7], bytes.fromhex("beef"))
                    packet = bytes.fromhex("f703ea600001")
                    packet += crc16(packet).to_bytes(2, "little")
                    self.assertEqual(forwarded(packet)[5:7], bytes.fromhex("beef"))
                    packet = bytes.fromhex("f70388b80021")
                    packet += crc16(packet).to_bytes(2, "little")
                    self.assertEqual(forwarded(packet)[11:27], b"00000SPN99000008")
                    reject_native.add(60001)
                    packet = bytes.fromhex("f706ea610001")
                    packet += crc16(packet).to_bytes(2, "little")
                    reply = forwarded(packet)
                    self.assertEqual(reply[:5], bytes.fromhex("aa55f78603"))
                    self.assertEqual(crc16(reply[2:]), 0)
                    packet = bytes.fromhex("5a5a01070000")
                    packet += crc16(packet).to_bytes(2, "little")
                    reply = forwarded(packet)
                    self.assertEqual(reply[6:-2], b"upstream-only")
                    self.assertEqual(reply[3], 0x87)
                    self.assertEqual(crc16(reply), 0)
                    packet = bytes.fromhex("5a5a02010000")
                    packet += crc16(packet).to_bytes(2, "little")
                    reply = forwarded(packet)
                    self.assertEqual(reply[:4], bytes.fromhex("5a5a0281"))
                    self.assertEqual(reply[6:-2], b"family-two", "A family1 reply must not satisfy a family2 request")
                    self.assertEqual(crc16(reply), 0)
                    reply = forwarded(frame(3, 0x5e, b"\x0f", 0x22))
                    self.assertEqual(reply[2:6], bytes.fromhex("7f2203de"))
                    self.assertEqual(reply[7:-2], b"\x06")
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as other:
                        other.settimeout(3)
                        first = bytes.fromhex("f703ea600001")
                        first += crc16(first).to_bytes(2, "little")
                        second = bytes.fromhex("f703ea610001")
                        second += crc16(second).to_bytes(2, "little")
                        probe.sendto(first, ("127.0.0.1", proxy_port))
                        other.sendto(second, ("127.0.0.1", proxy_port))
                        self.assertEqual(probe.recvfrom(2048)[0][5:7], bytes.fromhex("beef"))
                        self.assertEqual(other.recvfrom(2048)[0][5:7], bytes(2))
                    command("/protocol/goodwe/client/remove native-wire")
                    command(f"/protocol/goodwe/client/add name=native-wire identity=modbus remote=127.0.0.1:{inverter.getsockname()[1]}")
                    time.sleep(1)
                    packet = bytes.fromhex("f703ea600001")
                    packet += crc16(packet).to_bytes(2, "little")
                    self.assertEqual(forwarded(packet)[5:7], bytes.fromhex("beef"))
                    command('/protocol/goodwe/server/set native-proxy upstream=""')
                    time.sleep(0.3)
                    reply = forwarded(packet)
                    self.assertEqual(reply[:5], bytes.fromhex("aa55f78302"))
                    command("/protocol/goodwe/server/set native-proxy upstream=native-wire")
                    time.sleep(0.3)
                    for address in range(60010, 60027):
                        drop_reads.add(address)
                        packet = bytes((247, 3)) + address.to_bytes(2, "big") + bytes.fromhex("0001")
                        packet += crc16(packet).to_bytes(2, "little")
                        probe.sendto(packet, ("127.0.0.1", proxy_port))
                    reply = probe.recvfrom(2048)[0]
                    self.assertEqual(reply[:5], bytes.fromhex("aa55f7830a"))
                    self.assertEqual(crc16(reply[2:]), 0)
                command("/protocol/goodwe/server/remove native-proxy")
                slot = "native.config.basic.tou.time1"
                for field, value in (("start_hour", "6"), ("start_minute", "15"),
                                     ("end_hour", "9"), ("end_minute", "45"),
                                     ("enabled_raw", "249"), ("weekdays", "62"),
                                     ("power", "-37.5%"), ("cutoff_soc", "85%"), ("months", "2340")):
                    command(f"/element/set element={slot}.{field} value={value}")
                command(f"/element/set element={slot}.apply value=1")
                expected = bytes.fromhex("060f092df93efe8900550924")
                for _ in range(15):
                    if registers[47547] == expected:
                        break
                    time.sleep(0.2)
                self.assertEqual(registers[47547], expected)
                command(f"/element/set element={slot}.months value=0")
                command(f"/element/set element={slot}.apply value=2")
                time.sleep(0.8)
                self.assertEqual(registers[47547], expected)
                self.assertIn("month and weekday", command("/device/print filter=native.status.config_write.result"))
                for path, address, value, raw in (("port_connection.load.mode", 47595, "soc", 3),
                                                   ("port_connection.load.dry_contact", 47596, "1", 1),
                                                   ("port_connection.load.off_soc", 47597, "32%", 32),
                                                   ("basic.backup.enabled", 45252, "1", 1),
                                                   ("basic.backup.cold_start_holding", 45253, "1", 1),
                                                   ("basic.backup.detection_mode", 45254, "2", 2)):
                    command(f"/element/set element=native.config.{path} value={value}")
                    for _ in range(15):
                        if registers.get(address) == raw.to_bytes(2, "big"):
                            break
                        time.sleep(0.2)
                    self.assertEqual(registers.get(address), raw.to_bytes(2, "big"))
                generator = "native.config.port_connection.generator"
                for field, address, value, raw in (("rated_power", 47759, "5.46kW", 546),
                                                   ("run_time", 47758, "1.7h", 17),
                                                   ("charge_limit", 47747, "23.4%", 234),
                                                   ("load_delay", 45597, "47s", 47),
                                                   ("dry_contact", 47746, "1", 1)):
                    command(f"/element/set element={generator}.{field} value={value}")
                    for _ in range(15):
                        if registers.get(address) == raw.to_bytes(2, "big"):
                            break
                        time.sleep(0.2)
                    self.assertEqual(registers.get(address), raw.to_bytes(2, "big"))
                period = "native.config.port_connection.generator.prohibited_time1"
                for field, value in (("enabled_raw", "255"), ("weekdays", "42"),
                                     ("start_hour", "3"), ("start_minute", "17"),
                                     ("end_hour", "5"), ("end_minute", "29")):
                    command(f"/element/set element={period}.{field} value={value}")
                command(f"/element/set element={period}.apply value=1")
                expected = bytes.fromhex("ff2a0311051d")
                for _ in range(15):
                    if registers.get(47749) == expected:
                        break
                    time.sleep(0.2)
                self.assertEqual(registers.get(47749), expected)
                command(f"/element/set element={period}.end_hour value=1")
                command(f"/element/set element={period}.apply value=2")
                time.sleep(0.8)
                self.assertEqual(registers[47749], expected)
                self.assertIn("start must precede", command("/device/print filter=native.status.config_write.result"))
                for path, address, action in (("advanced.afci.self_test", 45271, 0x05aa),
                                               ("advanced.afci.clear_alarm", 45272, 0x050a),
                                               ("basic.backup.clear_overload", 45260, 1),
                                               ("basic.backup.cold_start", 45248, 4),
                                               ("basic.backup.cancel_cold_start", 45248, 1)):
                    if not path.endswith("cancel_cold_start"):
                        self.assertFalse(any(a == address for a, _ in writes), "Actions must not execute on startup")
                    command(f"/element/set element=native.config.{path} value=1")
                    for _ in range(15):
                        if registers.get(address) == action.to_bytes(2, "big"):
                            break
                        time.sleep(0.2)
                    self.assertEqual(registers.get(address), action.to_bytes(2, "big"))
                    self.assertIn("acknowledged", command("/device/print filter=native.status.config_write.result"))
                    self.assertIn("1", command(f"/device/print filter=native.config.{path}"))
                for path, address in (("basic.tou.time1.delete", 47549),
                                      ("port_connection.generator.prohibited_time1.delete", 47749)):
                    command(f"/element/set element=native.config.{path} value=1")
                    for _ in range(15):
                        if registers.get(address) == bytes.fromhex("5500"):
                            break
                        time.sleep(0.2)
                    self.assertEqual(registers.get(address), bytes.fromhex("5500"))
                    self.assertIn("acknowledged", command("/device/print filter=native.status.config_write.result"))
                registers[47549] = bytes.fromhex("fe3e")
                before = len(writes)
                command("/element/set element=native.config.basic.tou.time1.delete value=2")
                for _ in range(15):
                    result = command("/device/print filter=native.status.config_write.result")
                    if "different type" in result:
                        break
                    time.sleep(0.2)
                self.assertIn("different type", result)
                self.assertEqual(len(writes), before, "Deleting TOU must not remove a load schedule")
                self.assertEqual(register_data(47549, 1), bytes.fromhex("fe3e"))
                for path, address, value, expected in (("self_use.backup_enabled", 47605, "1", 1),
                                                        ("self_use.grid_charge_limit", 47606, "37.2%", 372),
                                                        ("self_use.smart_charge.enabled", 47609, "1", 1),
                                                        ("self_use.smart_charge.months", 47594, "2340", 2340),
                                                        ("self_use.smart_charge.peak_limit", 47592, "42.7%", 427),
                                                        ("self_use.smart_charge.pv_priority", 47613, "1", 1),
                                                        ("tou.enabled", 47612, "1", 1)):
                    command(f"/element/set element=native.config.basic.{path} value={value}")
                    for _ in range(15):
                        if register_data(address, 1) == expected.to_bytes(2, "big"):
                            break
                        time.sleep(0.2)
                    self.assertEqual(register_data(address, 1), expected.to_bytes(2, "big"), path)
                for name, value, expected in (("lvrt_enabled", "true", "00a3"), ("hvrt_enabled", "false", "00a1")):
                    command(f"/element/set element=native.config.advanced.safety.voltage_ride_through.{name} value={value}")
                    for _ in range(15):
                        if registers.get(45499) == bytes.fromhex(expected):
                            break
                        time.sleep(0.2)
                    self.assertEqual(registers.get(45499), bytes.fromhex(expected))
                for name, address in (("of_power_slope", 45453), ("uf_power_slope", 45454), ("recovery_power_slope", 45455)):
                    path = f"native.config.advanced.safety.curves.{name}"
                    command(f"/element/set element={path} value=-37.5%")
                    for _ in range(15):
                        if registers.get(address) == (-375).to_bytes(2, "big", signed=True):
                            break
                        time.sleep(0.2)
                    self.assertEqual(registers.get(address), (-375).to_bytes(2, "big", signed=True))
                    self.assertIn("above maximum", command(f"/element/set element={path} value=201%"))
                smart_time = "native.config.basic.self_use.smart_charge.start_time"
                command(f"/element/set element={smart_time}.hour value=13")
                command(f"/element/set element={smart_time}.minute value=47")
                command(f"/element/set element={smart_time}.apply value=1")
                for _ in range(15):
                    if register_data(47590, 1) == bytes((13, 47)):
                        break
                    time.sleep(0.2)
                self.assertEqual(register_data(47590, 1), bytes((13, 47)))
                self.assertEqual(register_data(47592, 1), (427).to_bytes(2, "big"))
                self.assertEqual(register_data(47594, 1), (2340).to_bytes(2, "big"))
                peak_record = bytearray(register_data(47589, 6))
                peak_record[4] = 252
                registers[47589] = bytes(peak_record)
                before = len(writes)
                command("/element/set element=native.config.basic.self_use.smart_charge.peak_limit value=47.1%")
                for _ in range(15):
                    result = command("/device/print filter=native.status.config_write.result")
                    if "different type" in result:
                        break
                    time.sleep(0.2)
                self.assertIn("different type", result)
                self.assertEqual(len(writes), before, "Smart Charge must not overwrite a peak-shaving record")
                self.assertEqual(register_data(47589, 6), bytes(peak_record))
                self.assertNotIn("2340", command("/device/print filter=native.config.basic.self_use.smart_charge.months"))
                peak = "native.config.basic.peak_shaving"
                before = len(write_attempts)
                for field, value in (("start_hour", "1"), ("start_minute", "23"), ("end_hour", "4"), ("end_minute", "56"),
                                     ("enabled_raw", "252"), ("weekdays", "127"), ("purchase_limit", "4.37kW"), ("reserve_soc", "23%")):
                    command(f"/element/set element={peak}.{field} value={value}")
                self.assertEqual(len(write_attempts), before)
                tail = register_data(47594, 1)
                command(f"/element/set element={peak}.apply value=1")
                for _ in range(15):
                    if register_data(47589, 5) == bytes.fromhex("01170438fc7f01b50017"):
                        break
                    time.sleep(0.2)
                self.assertEqual(register_data(47589, 5), bytes.fromhex("01170438fc7f01b50017"))
                self.assertEqual(register_data(47594, 1), tail, "Peak save must not write the Smart Charge month word")
                self.assertEqual(write_attempts[before:], [47589])
                charge = "native.config.battery_function.immediate_charge"
                before = len(write_attempts)
                for field, value in (("stop_soc", "89%"), ("power", "43%"), ("enabled", "1")):
                    command(f"/element/set element={charge}.{field} value={value}")
                time.sleep(0.5)
                self.assertEqual(len(write_attempts), before, "Staged charge settings must wait for apply")
                command(f"/element/set element={charge}.apply value=1")
                for _ in range(25):
                    if len(write_attempts) >= before + 3:
                        break
                    time.sleep(0.2)
                self.assertEqual(write_attempts[before:], [47546, 47603, 47545])
                for address, value in ((47546, 89), (47603, 43), (47545, 1)):
                    self.assertEqual(registers.get(address), value.to_bytes(2, "big"))
                for _ in range(15):
                    result = command("/device/print filter=native.status.config_write.result")
                    if "verified" in result:
                        break
                    time.sleep(0.2)
                self.assertIn("verified", result)
                before = len(write_attempts)
                reject_native.add(47603)
                command(f"/element/set element={charge}.stop_soc value=87%")
                command(f"/element/set element={charge}.apply value=2")
                for _ in range(25):
                    if 47603 not in reject_native:
                        break
                    time.sleep(0.2)
                time.sleep(0.5)
                self.assertEqual(write_attempts[before:], [47546, 47603], "Failure must stop before enabling charge")
                self.assertIn("failed", command("/device/print filter=native.status.config_write.result"))
                command(f"/element/set element={charge}.stop value=1")
                for _ in range(15):
                    if registers.get(47545) == bytes(2):
                        break
                    time.sleep(0.2)
                self.assertEqual(registers.get(47545), bytes(2))
                selection = "native.config.advanced.safety.reactive_selection"
                before = len(write_attempts)
                for field, value in (("cos_curve", "1"), ("qu_curve", "0"), ("power_factor", "1"), ("reactive_fraction", "0%")):
                    command(f"/element/set element={selection}.{field} value={value}")
                command(f"/element/set element={selection}.apply value=1")
                for _ in range(20):
                    if registers.get(45433) == b"\x00\x01":
                        break
                    time.sleep(0.2)
                self.assertEqual(write_attempts[before:], [45456, 45482, 45483, 45433], "Neutralize the old mode before enabling the new curve")
                before = len(write_attempts)
                command(f"/element/set element={selection}.qu_curve value=1")
                command(f"/element/set element={selection}.apply value=2")
                self.assertIn("mutually exclusive", command("/device/print filter=native.status.config_write.result"))
                self.assertEqual(len(write_attempts), before)
                for field, value in (("cos_curve", "0"), ("qu_curve", "0"), ("power_factor", "-0.93"), ("reactive_fraction", "0%")):
                    command(f"/element/set element={selection}.{field} value={value}")
                command(f"/element/set element={selection}.apply value=3")
                for _ in range(20):
                    if registers.get(45482) == b"\x00\x07":
                        break
                    time.sleep(0.2)
                self.assertEqual(registers.get(45482), b"\x00\x07")
                self.assertEqual(write_attempts[before:], [45433, 45456, 45483, 45482])
                before = len(write_attempts)
                command(f"/element/set element={selection}.power_factor value=0.7")
                command(f"/element/set element={selection}.apply value=4")
                self.assertIn("cannot encode", command("/device/print filter=native.status.config_write.result"))
                self.assertEqual(len(write_attempts), before)
                for field, value in (("cos_curve", "0"), ("qu_curve", "1"), ("power_factor", "1"), ("reactive_fraction", "0%")):
                    command(f"/element/set element={selection}.{field} value={value}")
                reject_native.add(45482)
                command(f"/element/set element={selection}.apply value=5")
                for _ in range(20):
                    result = command("/device/print filter=native.status.config_write.result")
                    if "failed" in result:
                        break
                    time.sleep(0.2)
                self.assertIn("failed", result)
                self.assertEqual(write_attempts[before:], [45433, 45482], "Rejected neutralization must abort before curve activation")
                for field, value in (("cos_curve", "0"), ("qu_curve", "0"), ("power_factor", "1"), ("reactive_fraction", "-37.5%")):
                    command(f"/element/set element={selection}.{field} value={value}")
                arrived.clear()
                release.clear()
                pause.set()
                command(f"/element/set element={selection}.apply value=6")
                self.assertTrue(arrived.wait(2))
                command(f"/element/set element={selection}.reactive_fraction value=-21.7%")
                release.set()
                for _ in range(20):
                    result = command("/device/print filter=native.status.config_write.result")
                    if "verified" in result:
                        break
                    time.sleep(0.2)
                self.assertIn("verified", result)
                self.assertEqual(registers.get(45483), (-375).to_bytes(2, "big", signed=True), "Active apply must retain its snapshot")
                staged = command(f"/device/print filter={selection}.reactive_fraction")
                self.assertAlmostEqual(float(re.search(r"reactive_fraction\s+([-\d.eE]+)%", staged)[1]), -21.7, places=6)
                command(f"/element/set element={selection}.apply value=7")
                for _ in range(20):
                    if registers.get(45483) == (-217).to_bytes(2, "big", signed=True):
                        break
                    time.sleep(0.2)
                self.assertEqual(registers.get(45483), (-217).to_bytes(2, "big", signed=True))
                command(f"/element/set element={selection}.power_factor value=0.87")
                command(f"/element/set element={selection}.reactive_fraction value=0%")
                command(f"/element/set element={selection}.apply value=8")
                for _ in range(20):
                    if registers.get(45482) == (87).to_bytes(2, "big"):
                        break
                    time.sleep(0.2)
                self.assertEqual(registers.get(45482), (87).to_bytes(2, "big"))
                before = len(write_attempts)
                command(f"/element/set element={selection}.power_factor value=-0.925")
                command(f"/element/set element={selection}.apply value=9")
                self.assertIn("cannot encode", command("/device/print filter=native.status.config_write.result"))
                self.assertEqual(len(write_attempts), before, "Power factor requires supported hundredth steps")
                bank = bytearray(register_data(47547, 48))
                for index in range(7):
                    bank[index * 12:index * 12 + 12] = bytes.fromhex("01000200f97f006400000fff") if index < 4 else bytes(12)
                for address in list(registers):
                    if 47547 <= address < 47595:
                        del registers[address]
                registers[47547] = bytes(bank)
                fifth = "native.config.basic.tou.time5"
                fields = (("start_hour", "6"), ("start_minute", "15"), ("end_hour", "9"), ("end_minute", "45"),
                          ("enabled_raw", "249"), ("weekdays", "62"), ("power", "-37.5%"), ("cutoff_soc", "85%"), ("months", "2340"))
                before = len(write_attempts)
                for field, value in fields:
                    command(f"/element/set element={fifth}.{field} value={value}")
                command(f"/element/set element={fifth}.apply value=1")
                for _ in range(15):
                    result = command("/device/print filter=native.status.config_write.result")
                    if "slot limit" in result:
                        break
                    time.sleep(0.2)
                self.assertIn("slot limit", result)
                self.assertEqual(len(write_attempts), before, "A fifth TOU group must not be created")
                self.assertEqual(register_data(47547, 48), bytes(bank))
                bank[4] = 85
                registers[47547] = bytes(bank)
                for field, value in fields:
                    command(f"/element/set element={fifth}.{field} value={value}")
                command(f"/element/set element={fifth}.apply value=2")
                bank[48:60] = bytes.fromhex("060f092df93efe8900550924")
                for _ in range(15):
                    if register_data(47547, 48) == bytes(bank):
                        break
                    time.sleep(0.2)
                self.assertEqual(register_data(47547, 48), bytes(bank))
                self.assertEqual(write_attempts[before:], [47571], "A free fifth physical slot must be usable after a group is deleted")
                for field, value, address, raw in (("address", "17", 45127, bytes.fromhex("0011")),
                                                    ("baud_rate", "57600", 45132, bytes.fromhex("0000e100"))):
                    command(f"/element/set element=native.config.modbus.{field} value={value}")
                    for _ in range(20):
                        result = command("/device/print filter=native.status.config_write.result")
                        if registers.get(address) == raw and "verified" in result:
                            break
                        time.sleep(0.2)
                    self.assertEqual(registers.get(address), raw)
                before = len(writes)
                command("/element/set element=native.config.modbus.baud_rate value=12345")
                time.sleep(0.8)
                self.assertEqual(len(writes), before)
                self.assertIn("cannot encode", command("/device/print filter=native.status.config_write.result"))
                command("/element/set element=native.config.modbus.address value=0")
                time.sleep(0.5)
                self.assertEqual(registers[45127], bytes.fromhex("0011"))

                apn = "native.config.communication.apn"
                for apply, name, expected in ((1, "internet.example", b"\x00\x10internet.example" + bytes(32)),
                                               (2, "", bytes(50))):
                    before = len(writes)
                    self.assertNotIn("Cannot set", command(f'/element/set element={apn}.name value="{name}"'))
                    command(f"/element/set element={apn}.apply value={apply}")
                    for _ in range(20):
                        result = command("/device/print filter=native.status.config_write.result")
                        if len(writes) > before and "verified" in result:
                            break
                        time.sleep(0.2)
                    self.assertIn("verified", result)
                    self.assertEqual(writes[before:], [(47041, expected)])
                before = len(writes)
                command(f'/element/set element={apn}.name value="' + "a" * 49 + '"')
                command(f"/element/set element={apn}.apply value=3")
                time.sleep(0.5)
                self.assertEqual(len(writes), before)
                self.assertIn("forty-eight", command("/device/print filter=native.status.config_write.result"))

                network = "native.config.communication.wlan_lan.configure"
                values = (("mode", "static"), ("address", "192.0.2.10"), ("netmask", "255.255.255.0"),
                          ("gateway", "192.0.2.1"), ("dns", "192.0.2.1"), ("ssid", "OpenWatt-Test"),
                          ("encryption", "WPA2PSK,AES"), ("router_password", "FixtureOnly42"))
                for field, value in values:
                    command(f'/element/set element={network}.{field} value="{value}"')
                before = len(module_writes)
                command(f"/element/set element={network}.apply value=1")
                for _ in range(20):
                    result = command("/device/print filter=native.status.config_write.result")
                    if "acknowledged; reconnect" in result:
                        break
                    time.sleep(0.2)
                self.assertIn("acknowledged; reconnect", result)
                self.assertEqual(module_writes[before:], [
                    (1, 11, b"static,192.0.2.10,255.255.255.0,192.0.2.1,192.0.2.1"),
                    (1, 10, b"\x0dOpenWatt-Test\x0bWPA2PSK,AES\x0dFixtureOnly42"), (1, 12, b"")])
                self.assertNotIn("FixtureOnly42", command(f"/device/print filter={network}.router_password"))
                for field, value in values:
                    command(f'/element/set element={network}.{field} value="{value}"')
                command(f'/element/set element={network}.address value="192.0.2.999"')
                before = len(module_writes)
                command(f"/element/set element={network}.apply value=2")
                time.sleep(0.5)
                self.assertEqual(len(module_writes), before)
                self.assertIn("invalid module IPv4", command("/device/print filter=native.status.config_write.result"))

                password = "native.config.communication.wlan_lan.password"
                command(f'/element/set element={password}.new_password value="FixtureOnly42"')
                before = len(module_writes)
                command(f"/element/set element={password}.apply value=1")
                for _ in range(20):
                    result = command("/device/print filter=native.status.config_write.result")
                    if len(module_writes) >= before + 2 and "acknowledged; reconnect" in result:
                        break
                    time.sleep(0.2)
                self.assertEqual(module_writes[before:], [(2, 1, b"AT+WAKEY=WPA2PSK,AES,FixtureOnly42\r\n"), (1, 12, b"")])
                self.assertNotIn("FixtureOnly42", command(f"/device/print filter={password}.new_password"))
                command(f'/element/set element={password}.new_password value="invalid-password"')
                before = len(module_writes)
                command(f"/element/set element={password}.apply value=2")
                time.sleep(0.5)
                self.assertEqual(len(module_writes), before)
                self.assertIn("permits letters", command("/device/print filter=native.status.config_write.result"))
                command(f'/element/set element={password}.new_password value="FixtureOnly42"')
                drop_module.add((2, 1))
                before = len(module_writes)
                command(f"/element/set element={password}.apply value=3")
                for _ in range(35):
                    result = command("/device/print filter=native.status.config_write.result")
                    if "failed" in result:
                        break
                    time.sleep(0.2)
                self.assertIn("failed", result)
                self.assertEqual(len(module_writes), before, "No reload may follow a failed password command")
                drop_module.clear()

                selection = "native.config.basic.battery_model.selection"
                catalogue_entry = dict(protocolCode=4, capacity="200", chargeVoltage="53.2", chargeCurrent="100",
                                       dischargeVoltage="45", dischargeCurrent="100", dischargeDepthGrid="80",
                                       dischargeDepthOffGrid="80", strongSocStart="14", strongSocEnd="19",
                                       indexCode=116, currentCoefficient="1")

                def stage_battery():
                    for field, value in selection_fields(catalogue_entry):
                        command(f"/element/set element={selection}.{field} value={value}")

                before = len(writes)
                stage_battery()
                self.assertEqual(len(writes), before, "Catalogue fields must remain staged until apply")
                command(f"/element/set element={selection}.apply value=1")
                expected = [(47743, bytes.fromhex("0001")), (47514, bytes.fromhex("0004")),
                            (45350, bytes.fromhex("00c8")),
                            (45352, bytes.fromhex("021403e801c203e8001401c20014")),
                            (47531, bytes.fromhex("008c00be")), (47504, bytes.fromhex("0074")),
                            (47615, bytes.fromhex("0064"))]
                for _ in range(25):
                    result = command("/device/print filter=native.status.config_write.result")
                    if len(writes) >= before + 7 and "verified" in result:
                        break
                    time.sleep(0.2)
                self.assertIn("verified", result)
                self.assertEqual(writes[before:], expected, "Native catalogue transaction must match the captured seven-step sequence")

                for field, value in (("off_grid_discharge_voltage", "44V"), ("forced_charge_end_soc", "5%")):
                    stage_battery()
                    command(f"/element/set element={selection}.{field} value={value}")
                    before = len(write_attempts)
                    command(f"/element/set element={selection}.apply value={before + 10}")
                    time.sleep(0.5)
                    self.assertEqual(len(write_attempts), before, "Invalid coupled catalogue values must fail before any write")
                    self.assertIn("invalid", command("/device/print filter=native.status.config_write.result"))

                stage_battery()
                before = len(writes)
                reject_native.add(47531)
                command(f"/element/set element={selection}.apply value={before + 20}")
                for _ in range(25):
                    result = command("/device/print filter=native.status.config_write.result")
                    if "failed" in result:
                        break
                    time.sleep(0.2)
                self.assertIn("failed", result)
                self.assertEqual(writes[before:], expected[:4], "Catalogue failure must prevent later index/coefficient writes")

                load_root = "native.config.port_connection.load"

                def load_bank(image):
                    for address in list(registers):
                        if 47547 <= address < 47595:
                            del registers[address]
                    registers[47547] = bytes(image)

                def stage_load(slot, flag=254, power="0W", minutes="0min"):
                    for field, value in (("start_hour", "3"), ("start_minute", "17"),
                                         ("end_hour", "5"), ("end_minute", "29"),
                                         ("enabled_raw", str(flag)), ("weekdays", "42"),
                                         ("rated_power", power), ("minimum_run_time", minutes)):
                        command(f"/element/set element={load_root}.time{slot}.{field} value={value}")

                bank = bytearray(96)
                bank[4::12] = bytes([85] * 8)
                load_bank(bank)
                stage_load(1)
                before = len(writes)
                command(f"/element/set element={load_root}.time1.apply value=1")
                bank[:12] = bytes.fromhex("0311051dfe2a000000000000")
                for _ in range(20):
                    if register_data(47547, 48) == bytes(bank):
                        break
                    time.sleep(0.2)
                self.assertEqual(register_data(47547, 48), bytes(bank))
                self.assertEqual([a for a, _ in writes[before:]], [47547], "Standard load must not disable export limiting")

                stage_load(1, 253, "4.37kW", "23min")
                before = len(writes)
                command(f"/element/set element={load_root}.time1.apply value=2")
                bank[:12] = bytes.fromhex("0311051dfd2a01b500170000")
                for _ in range(20):
                    result = command("/device/print filter=native.status.config_write.result")
                    if len(writes) >= before + 2 and "verified" in result:
                        break
                    time.sleep(0.2)
                self.assertIn("verified", result)
                self.assertEqual(register_data(47547, 48), bytes(bank))
                self.assertEqual(writes[before:], [(47509, bytes(2)), (47547, bytes(bank[:12]))])

                before = len(writes)
                reject_native.add(47509)
                stage_load(1, 253, "5.46kW", "31min")
                command(f"/element/set element={load_root}.time1.apply value=3")
                for _ in range(20):
                    result = command("/device/print filter=native.status.config_write.result")
                    if "failed" in result:
                        break
                    time.sleep(0.2)
                self.assertIn("failed", result)
                self.assertEqual(len(writes), before, "Rejected limiter change must prevent the load-record write")
                self.assertEqual(register_data(47547, 48), bytes(bank))
                reject_native.clear()

                bank[16] = 249
                load_bank(bank)
                stage_load(2, 253, "1.23kW", "17min")
                before = len(write_attempts)
                command(f"/element/set element={load_root}.time2.apply value=1")
                for _ in range(20):
                    result = command("/device/print filter=native.status.config_write.result")
                    if "different type" in result:
                        break
                    time.sleep(0.2)
                self.assertIn("different type", result)
                self.assertEqual(len(write_attempts), before, "TOU protection must precede the export-limiter prelude")

                bank[4:48:12] = bytes([1, 253, 254, 2])
                load_bank(bank)
                stage_load(5)
                before = len(write_attempts)
                command(f"/element/set element={load_root}.time5.apply value=1")
                for _ in range(20):
                    result = command("/device/print filter=native.status.config_write.result")
                    if "slot limit" in result:
                        break
                    time.sleep(0.2)
                self.assertIn("slot limit", result)
                self.assertEqual(len(write_attempts), before, "Four-group limit must count both standard and intelligent load types")

                before = len(writes)
                command(f"/element/set element={load_root}.time1.delete value=1")
                for _ in range(20):
                    if register_data(47549, 1) == bytes.fromhex("5500"):
                        break
                    time.sleep(0.2)
                self.assertEqual(writes[before:], [(47549, bytes.fromhex("5500"))])
                stage_load(5)
                command(f"/element/set element={load_root}.time5.apply value=2")
                for _ in range(20):
                    if register_data(47571, 6) == bytes.fromhex("0311051dfe2a000000000000"):
                        break
                    time.sleep(0.2)
                self.assertEqual(register_data(47571, 6), bytes.fromhex("0311051dfe2a000000000000"))

                mode = "native.config.basic.working_mode"
                for request, expected in (
                    ("peak_shaving", [(47612, b"\x00\x00"), (47511, b"\x00\x01\x00\x00"),
                                      (47591, b"\xfc\x7f"), (47000, b"\x00\x04")]),
                    ("self_use", [(47511, b"\x00\x01\x00\x00"), (47591, b"\x03\x7f"),
                                   (47612, b"\x00\x00"), (47000, b"\x00\x05")])):
                    before = len(writes)
                    untouched = register_data(47505, 1)
                    command(f"/element/set element={mode}.requested_mode value={request}")
                    time.sleep(0.2)
                    self.assertEqual(len(writes), before, "Mode selection must remain staged until apply")
                    command(f"/element/set element={mode}.apply value={before + 1}")
                    for _ in range(25):
                        result = command("/device/print filter=native.status.config_write.result")
                        if len(writes) >= before + 4 and "verified" in result:
                            break
                        time.sleep(0.2)
                    self.assertIn("verified", result)
                    self.assertEqual(writes[before:], expected)
                    self.assertEqual(register_data(47505, 1), untouched, "Application mode must not alter manufacturer/watchdog settings")

                before = len(writes)
                reject_native.add(47511)
                command(f"/element/set element={mode}.requested_mode value=peak_shaving")
                command(f"/element/set element={mode}.apply value={before + 1}")
                for _ in range(20):
                    result = command("/device/print filter=native.status.config_write.result")
                    if "failed" in result:
                        break
                    time.sleep(0.2)
                self.assertIn("failed", result)
                self.assertEqual(writes[before:], [(47612, bytes(2))], "Failure must prevent the peak tag and final mode writes")
                reject_native.clear()

                before = len(writes)
                mismatch.set()
                command(f"/element/set element={mode}.requested_mode value=self_use")
                command(f"/element/set element={mode}.apply value={before + 1}")
                for _ in range(20):
                    result = command("/device/print filter=native.status.config_write.result")
                    if "mismatch" in result:
                        break
                    time.sleep(0.2)
                self.assertIn("mismatch", result)
                self.assertEqual([a for a, _ in writes[before:]], [47511], "Readback mismatch must stop the sequence")
                command("/binding/goodwe/set native disabled=true")
                self.assertFalse(errors, errors)
                self.assertNotIn("Invalid Modbus field", "".join(stderr))
                self.assertNotIn("Invalid GoodWe field", "".join(stderr))
                self.assertNotIn("Invalid token", "".join(stderr))
                self.assertTrue(runtime.is_running())
            except Exception:
                print("\n".join(transcript))
                print("".join(stderr))
                raise
            finally:
                stopped.set()
                release.set()
                worker.join(timeout=2)
                if runtime.console:
                    runtime.console.close()
                    runtime.console = None
                if writer:
                    writer.close()
                if runtime.process and runtime.process.poll() is None:
                    runtime.process.terminate()
                    runtime.process.wait(timeout=5)
                if connection:
                    connection.close()
                drain.join(timeout=2)
                process = runtime.process
                runtime.stop()
                if process:
                    for pipe in (process.stdin, process.stdout, process.stderr):
                        pipe.close()
                if reader:
                    reader.close()


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    args = parser.parse_args()
    BINARY = str(Path(args.binary).resolve())
    unittest.main(argv=[__file__])
