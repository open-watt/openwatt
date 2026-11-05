#!/usr/bin/env python3
"""Exercise AA55 discovery, shared Devices, dispatch and control selection.

--skip-lease-tests omits the two 30-second expiry waits during focused iteration.
The default run includes them. --runtime-log preserves the runtime's stderr.
"""

import argparse
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

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from goodwe_capture import crc16


BINARY = None
CHECK_LEASE = True
RUNTIME_LOG = None


def frame(control, fn, payload=b"", source=0xC0, destination=0x7F):
    data = bytes((0xAA, 0x55, source, destination, control, fn, len(payload))) + payload
    return data + sum(data).to_bytes(2, "big")


class GoodWeServerTest(unittest.TestCase):
    def test_shared_device(self):
        if BINARY is None:
            self.skipTest("run test_goodwe_server.py with --binary")
        with tempfile.TemporaryDirectory(prefix="openwatt-aa55-") as directory:
            root = Path(directory)
            (root / "conf/profiles").mkdir(parents=True)
            shutil.copyfile(Path(__file__).parent / "profiles/aa55_server_test.conf",
                            root / "conf/profiles/aa55_server_test.conf")
            shutil.copyfile(Path(__file__).parent / "profiles/aa55_dispatch_test.conf",
                            root / "conf/profiles/aa55_dispatch_test.conf")
            shutil.copyfile(Path(__file__).resolve().parents[1] / "conf/profiles/goodwe_profiles/gwxx48es.conf",
                            root / "conf/profiles/gwxx48es.conf")
            listener = socket.socket()
            self.addCleanup(listener.close)
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            listener.settimeout(5)
            (root / "conf/startup.conf").write_text(
                f"/stream/tcp-client/add name=test remote=127.0.0.1:{listener.getsockname()[1]}\n"
                "/console/session/add name=test stream=test profile=dumb\n", encoding="utf-8")
            shutil.copyfile(Path(__file__).resolve().parents[1] / "conf/profiles/modbus_profiles/goodwe_ems.conf",
                            root / "conf/profiles/goodwe_ems.conf")
            reservations = [socket.socket(socket.AF_INET, socket.SOCK_DGRAM) for _ in range(6)]
            for reservation in reservations:
                reservation.bind(("127.0.0.1", 0))
            port, discovery_port, proxy_port, profile_port, mirror_port, dispatch_state_port = [s.getsockname()[1] for s in reservations]
            for reservation in reservations:
                reservation.close()
            with (root / "conf/startup.conf").open("a", encoding="utf-8") as startup:
                for name, bind_port in (("profile", profile_port), ("mirror", mirror_port)):
                    startup.write(f"/protocol/goodwe/server/add name={name} device=profile profile=gwxx48es model=gw5048es "
                                  f"bind-address=127.0.0.1 port={bind_port} discovery-port=0 trace=false\n")

            runtime = OpenWattProcess(binary_path=BINARY, startup_delay=0.5)
            runtime.project_root = root
            runtime.crash_file = root / "crash.txt"
            runtime.output_file = root / "output.txt"
            runtime.log_file = root / "log.txt"
            self.assertTrue(runtime.start())
            stderr_lines = []
            def drain_stderr():
                stderr_lines.extend(iter(runtime.process.stderr.readline, ''))
            stderr_reader = threading.Thread(target=drain_stderr, daemon=True)
            stderr_reader.start()
            transcript = []
            writer = None
            try:
                control, _ = listener.accept()
                self.addCleanup(control.close)
                reader = control.makefile("r", encoding="utf-8", errors="replace")
                writer = control.makefile("w", encoding="utf-8")
                self.addCleanup(reader.close)
                self.addCleanup(writer.close)
                console = OpenWattConsole(SimpleNamespace(stdin=writer, stdout=reader))
                runtime.console = console

                def command(text):
                    result = console.send_command(text, read_delay=0.2, timeout=2)
                    transcript.append(text + "\n" + result)
                    self.assertNotIn("Element not found", result, result)
                    self.assertNotIn("Unknown", result, result)
                    self.assertNotIn("Missing argument", result, result)
                    self.assertNotIn("Invalid value for property", result, result)
                    return result

                command(f"/protocol/goodwe/server/add name=source device=source profile=aa55_server_test "
                        f"bind-address=127.0.0.1 port={port} discovery-port={discovery_port} trace=false")
                battery_tree = command("/device/print filter=profile.battery.meter.*")
                self.assertEqual(battery_tree.count("power"), 1, battery_tree)
                command("/element/set element=profile.config.advanced.battery_function.off_grid_min_soc value=20%")
                command("/protocol/modbus/node/add name=native-profile")
                command("/binding/modbus/add name=native-profile node=native-profile device=house-profile profile=goodwe_ems model=GW6000ES20")
                self.assertIn("mode", command("/device/print filter=house-profile.config.basic.working_mode.*"))
                self.assertIn("manufacturer_ems_code_raw", command("/device/print filter=house-profile.config.advanced.ems.*"))
                self.assertIn("over_voltage_level_1_phase", command("/device/print filter=house-profile.config.advanced.safety.protection.*"))
                refused = command("/element/set element=house-profile.config.advanced.safety.protection.over_voltage_level_1_phase value=301V")
                self.assertIn("above maximum", refused)
                command("/binding/modbus/set native-profile disabled=true")
                values = {"info.firmware": '"2323G"', "info.model_id": '"GW5048D-ES"',
                          "info.serial_number": '"00000ESU00000001"', "info.nominal": '"3600"',
                          "info.software": '"TEST-0001"', "grid.voltage": "230.5V", "grid.power": "0W"}
                values.update({"registers.holding": "3333", "registers.input": "4444"})
                for path, value in values.items():
                    command(f"/element/set element=source.{path} value={value}")

                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                    client.settimeout(2)

                    def query(data, target=port):
                        client.sendto(data, ("127.0.0.1", target))
                        response, sender = client.recvfrom(65535)
                        self.assertEqual(sender, ("127.0.0.1", target))
                        self.assertEqual(response[:2], b"\xaa\x55")
                        self.assertEqual(len(response), response[6] + 9)
                        self.assertEqual(sum(response[:-2]), int.from_bytes(response[-2:], "big"))
                        return response

                    reserve = query(frame(1, 0x1a, b"\x05\xa1\x01"), profile_port)
                    self.assertEqual(reserve[7:-2], b"\x00\x14")

                    for function, expected in ((3, 3333), (4, 4444)):
                        request = bytes((247, function, 0, 10, 0, 1))
                        client.sendto(request + crc16(request).to_bytes(2, "little"), ("127.0.0.1", port))
                        reply, _ = client.recvfrom(1024)
                        self.assertEqual(crc16(reply[2:]), 0)
                        self.assertEqual(reply[:5], bytes((170, 85, 247, function, 2)))
                        self.assertEqual(int.from_bytes(reply[5:7], "big"), expected)

                    client.sendto(b"WIFIKIT-214028-READ", ("127.0.0.1", discovery_port))
                    discovery, sender = client.recvfrom(1024)
                    self.assertEqual(sender[1], discovery_port)
                    self.assertEqual(discovery, b"127.0.0.1,020000000001,Solar-WiFiOpenWatt")
                    module_read = bytes.fromhex("5a5a01030000a510")
                    client.settimeout(0.2)
                    client.sendto(module_read, ("127.0.0.1", port))
                    with self.assertRaises(socket.timeout):
                        client.recvfrom(1024)
                    command('/protocol/goodwe/server/set source module-network-config="DHCP,192.0.2.5,255.255.255.0,192.0.2.1,192.0.2.1"')
                    client.sendto(module_read, ("127.0.0.1", port))
                    module_reply, _ = client.recvfrom(1024)
                    # Synthetic network metadata with a valid module CRC.
                    self.assertEqual(module_reply, bytes.fromhex(
                        "5a5a01830030444843502c3139322e302e322e352c3235352e3235352e3235352e302c"
                        "3139322e302e322e312c3139322e302e322e312ac3"))
                    for data in (module_read[:-1], module_read + b"\x00",
                                 module_read[:-1] + b"\x00", bytes.fromhex("5a5a01020000f4d0"),
                                 module_reply):
                        client.sendto(data, ("127.0.0.1", port))
                        with self.assertRaises(socket.timeout):
                            client.recvfrom(1024)
                    invalid = command('/protocol/goodwe/server/set source module-network-config="DHCP,192.0.2.5,255.255.255.0,192.0.2.1,192.0.2.1,extra"')
                    self.assertIn("unexpected data", invalid)
                    client.sendto(module_read, ("127.0.0.1", port))
                    self.assertEqual(client.recvfrom(1024)[0], module_reply)
                    command('/protocol/goodwe/server/set source module-network-config=""')
                    client.sendto(module_read, ("127.0.0.1", port))
                    with self.assertRaises(socket.timeout):
                        client.recvfrom(1024)
                    module_values = {"firmware": "V1.1.3.14", "network.mode": "DHCP", "network.address": "192.0.2.5",
                                     "network.netmask": "255.255.255.0", "network.gateway": "192.0.2.1", "network.dns": "192.0.2.1"}
                    for path, value in module_values.items():
                        command(f'/element/set element=source.communication_module.{path} value="{value}"')
                    for fn, expected in ((1, b"V1.1.3.14"), (3, b"DHCP,192.0.2.5,255.255.255.0,192.0.2.1,192.0.2.1")):
                        request = b"ZZ" + bytes((1, fn, 0, 0))
                        client.sendto(request + crc16(request).to_bytes(2, "little"), ("127.0.0.1", port))
                        reply, _ = client.recvfrom(1024)
                        self.assertEqual(crc16(reply), 0)
                        self.assertEqual(reply[6:-2], expected)
                    for name, value in (("server1", '"1"'), ("server2", '"connected"'),
                                        ("channel", "1"), ("sent", "300"), ("received", "400")):
                        command(f'/element/set element=source.communication_module.{name} value={value}')
                    for fn, selector, expected in ((4, 1, b"\x01"), (4, 2, b"connected"),
                                                   (5, 1, bytes.fromhex("01012c0190"))):
                        request = b"ZZ" + bytes((1, fn, 0, 1, selector))
                        client.sendto(request + crc16(request).to_bytes(2, "little"), ("127.0.0.1", port))
                        reply, _ = client.recvfrom(1024)
                        self.assertEqual(crc16(reply), 0)
                        self.assertEqual(reply[6:-2], expected)
                    client.settimeout(2)
                    identity = query(bytes.fromhex("aa55c07f0102000241"))
                    self.assertEqual(identity[7:12], b"2323G")
                    self.assertEqual(identity[38:54], b"00000ESU00000001")
                    self.assertEqual(query(frame(1, 6))[41:43], bytes.fromhex("0901"))

                    client.settimeout(0.2)
                    for data in (frame(2, 0x39, b"\x01\x02"), frame(1, 2)[:-1], frame(1, 2) + b"\x00"):
                        client.sendto(data, ("127.0.0.1", port))
                        with self.assertRaises(socket.timeout):
                            client.recvfrom(1024)
                    client.settimeout(2)
                    command("/protocol/goodwe/server/reply name=source control=2 fn=57 data=1")
                    self.assertEqual(query(frame(2, 0x39, b"\x01\x02"))[4:8], b"\x02\xb9\x01\x01")
                    command("/protocol/goodwe/server/clear-replies name=source")

                    command(f"/protocol/goodwe/client/add name=client remote=127.0.0.1:{port}")
                    self.assertEqual(query(frame(1, 2))[2], 0x7F,
                                     "Client startup must not allocate an inverter address")
                    command("/binding/goodwe/add name=reader client=client device=proxy profile=aa55_server_test")
                    command(f"/protocol/goodwe/server/add name=proxy device=proxy profile=aa55_server_test "
                            f"bind-address=127.0.0.1 port={proxy_port} discovery-port=0 trace=false")
                    time.sleep(1)
                    self.assertEqual(query(frame(1, 2), proxy_port)[38:54], b"00000ESU00000001")
                    self.assertEqual(query(frame(1, 6), proxy_port)[41:43], bytes.fromhex("0901"))
                    command("/element/set element=source.grid.voltage value=241.2V")
                    time.sleep(1)
                    self.assertEqual(query(frame(1, 6), proxy_port)[41:43], bytes.fromhex("096c"))

                    # Direct reads must also accept replies from an address previously
                    # assigned by another client, without registering or reallocating it.
                    for fn in (2, 6):
                        response = bytearray(query(frame(1, fn)))
                        response[2] = 0x0D
                        if fn == 2:
                            response[-2:-2] = bytes(13)
                            response[6] += 13
                        else:
                            response[41:43] = bytes.fromhex("097a")
                        response[-2:] = sum(response[:-2]).to_bytes(2, "big")
                        command('/protocol/goodwe/server/raw-reply server=source request='
                                + ','.join(map(str, frame(1, fn))) + ' response='
                                + ','.join(map(str, response)))
                    command("/protocol/goodwe/client/set client disabled=true")
                    command("/protocol/goodwe/client/set client disabled=false")
                    time.sleep(1)
                    self.assertEqual(query(frame(1, 6), proxy_port)[41:43], bytes.fromhex("097a"))
                    command("/protocol/goodwe/server/clear-replies name=source")
                    time.sleep(1)

                    command("/protocol/goodwe/server/set proxy serial-number=00000ESU99000008")
                    self.assertEqual(query(frame(1, 2), proxy_port)[38:54], b"00000ESU99000008")
                    self.assertEqual(query(frame(1, 2))[38:54], b"00000ESU00000001")

                    command("/protocol/goodwe/server/set proxy disabled=true")
                    client.settimeout(0.2)
                    client.sendto(frame(1, 6), ("127.0.0.1", proxy_port))
                    with self.assertRaises((socket.timeout, ConnectionResetError)):
                        client.recvfrom(1024)
                    command("/protocol/goodwe/server/set proxy disabled=false")
                    client.settimeout(2)
                    self.assertEqual(query(frame(1, 6), proxy_port)[41:43], bytes.fromhex("096c"))

                    # Raw experiments share the real client's socket but suspend its sampler.
                    import re
                    raw_request = bytes.fromhex("f703078000019000")
                    raw_reply = bytes.fromhex("f70302002aa18f")
                    byte_list = lambda data: ",".join(str(b) for b in data)
                    command(f"/protocol/goodwe/server/raw-reply server=source request={byte_list(raw_request)} response={byte_list(raw_reply)}")
                    command("/protocol/goodwe/client/set client manual=true")
                    time.sleep(1.6)
                    client.sendto(raw_request, ("127.0.0.1", proxy_port))
                    self.assertEqual(client.recvfrom(1024)[0], bytes.fromhex("aa55f7830220c3"))
                    requests = command("/protocol/goodwe/server/requests server=proxy")
                    capture_id = re.findall(r"id=(\d+)", requests)[-1]
                    command(f"/protocol/goodwe/server/relay server=proxy id={capture_id} client=client")
                    received = command("/protocol/goodwe/client/received client=client")
                    self.assertIn("F7 03 02 00 2A A1 8F", received)
                    command(f"/protocol/goodwe/server/respond server=proxy id={capture_id} data={byte_list(raw_reply)}")
                    self.assertEqual(client.recvfrom(1024)[0], raw_reply)
                    command("/protocol/goodwe/client/request client=client wire=modbus fn=3 address=0x0780 count=1")
                    self.assertIn("F7 03 02 00 2A A1 8F", command("/protocol/goodwe/client/received client=client"))
                    command("/protocol/goodwe/client/request client=client wire=module fn=1")
                    self.assertIn("5A 5A 01 81", command("/protocol/goodwe/client/received client=client"))
                    command("/protocol/goodwe/client/request client=client control=1 fn=2")
                    self.assertIn("AA 55", command("/protocol/goodwe/client/received client=client"))
                    command(f"/protocol/goodwe/server/raw-reply server=proxy request={byte_list(raw_request)} response={byte_list(raw_reply)}")
                    client.sendto(raw_request, ("127.0.0.1", proxy_port))
                    self.assertEqual(client.recvfrom(1024)[0], raw_reply)
                    command("/protocol/goodwe/server/clear-replies name=proxy")
                    marker_request = frame(1, 0x1A, b"\x05\x9c\x02")
                    client.sendto(marker_request, ("127.0.0.1", proxy_port))
                    capture_id = re.findall(r"id=(\d+)", command("/protocol/goodwe/server/requests server=proxy"))[-1]
                    command(f"/protocol/goodwe/server/answer server=proxy id={capture_id} data=0,42 repeat=true")
                    self.assertEqual(query(marker_request, proxy_port)[7:-2], b"\x00\x2a")
                    client.settimeout(0.2)
                    client.sendto(frame(1, 0x1A, b"\x05\x9d\x02"), ("127.0.0.1", proxy_port))
                    with self.assertRaises(socket.timeout):
                        client.recvfrom(1024)
                    client.settimeout(2)
                    command(f"/protocol/goodwe/server/answer server=proxy id={capture_id} data=0,43")
                    reply = client.recvfrom(1024)[0]
                    self.assertEqual(reply[7:-2], b"\x00\x2b")
                    self.assertEqual(sum(reply[:-2]), int.from_bytes(reply[-2:], "big"))
                    command("/protocol/goodwe/client/set client manual=false")
                    command("/element/set element=source.grid.voltage value=238V")
                    time.sleep(1)
                    self.assertEqual(query(frame(1, 6), proxy_port)[41:43], bytes.fromhex("094c"))
                    self.assertTrue(runtime.is_running())
                    # Exercise dispatch against a wire-level inverter, including readback
                    # and the automatic-mode restoration when the binding is disabled.
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as inverter:
                        inverter.bind(("127.0.0.1", 0))
                        inverter.settimeout(0.2)
                        writes = []
                        fallback = [10]
                        stopped = threading.Event()
                        def crc_frame(data):
                            crc = 0xffff
                            for byte in data:
                                crc ^= byte
                                for _ in range(8):
                                    crc = (crc >> 1) ^ (0xa001 if crc & 1 else 0)
                            return data + crc.to_bytes(2, "little")
                        def serve():
                            words = {47513: bytes.fromhex("00ff0000")}
                            while not stopped.is_set():
                                try:
                                    packet, peer = inverter.recvfrom(1024)
                                except socket.timeout:
                                    continue
                                if packet[:2] == b"\xaa\x55":
                                    reply = frame(1, 0x82, bytes(64), 0x7f, 0xc0)
                                elif packet[1] == 16:
                                    address = int.from_bytes(packet[2:4], "big")
                                    words[address] = packet[7:11]
                                    writes.append(tuple(int.from_bytes(words[address][i:i+2], "big") for i in (0, 2)))
                                    reply = b"\xaa\x55" + crc_frame(packet[:6])
                                elif packet[1] == 6:
                                    fallback[0] = int.from_bytes(packet[4:6], "big")
                                    reply = crc_frame(packet[:6])
                                elif int.from_bytes(packet[2:4], "big") == 47505:
                                    reply = crc_frame(b"\xf7\x03\x02" + fallback[0].to_bytes(2, "big"))
                                else:
                                    address = int.from_bytes(packet[2:4], "big")
                                    reply = b"\xaa\x55" + crc_frame(b"\xf7\x03\x04" + words.get(address, bytes(4)))
                                inverter.sendto(reply, peer)
                        worker = threading.Thread(target=serve, daemon=True)
                        worker.start()
                        try:
                            command(f"/protocol/goodwe/server/add name=dispatch-state device=dispatch profile=aa55_dispatch_test bind-address=127.0.0.1 port={dispatch_state_port} discovery-port=0 trace=false")
                            command(f"/protocol/goodwe/client/add name=dispatch remote=127.0.0.1:{inverter.getsockname()[1]}")
                            command("/binding/goodwe-control/add name=dispatch device=dispatch client=dispatch register=47511 scheme=battery_power")
                            time.sleep(2.2)
                            self.assertEqual(fallback[0], 10)
                            self.assertIn("disable binding", command("/binding/goodwe-control/set dispatch register=42000"))
                            self.assertIn("incompatible", command("/element/set element=dispatch.inverter.control.kind value=discrete"))
                            command("/element/set element=dispatch.inverter.control.enable value=false")
                            time.sleep(2.2)
                            self.assertEqual(writes[-1], (255, 0))
                            command("/element/set element=dispatch.inverter.control.enable value=true")
                            time.sleep(2.2)
                            self.assertEqual(writes[-1], (1, 0))
                            autonomous_writes = len(writes)
                            time.sleep(2.2)
                            self.assertEqual(len(writes), autonomous_writes, "Autonomous mode must not keep issuing EMS writes")
                            if CHECK_LEASE:
                                command("/element/set element=dispatch.inverter.control.kind value=continuous")
                                command("/element/set element=dispatch.inverter.control.setpoint value=123W")
                                time.sleep(3.2)
                                self.assertEqual(fallback[0], 10)
                                self.assertIn((11, 123), writes)
                                for counter in (1, 2, 3):
                                    time.sleep(12)
                                    command(f"/element/set element=dispatch.inverter.control.watchdog.feed value={counter}")
                                self.assertIn("continuous", command("/device/print filter=dispatch.inverter.control.kind"))
                                self.assertEqual(writes[-1], (11, 123))
                                time.sleep(31.5)
                                self.assertEqual(writes[-1], (1, 0))
                                self.assertEqual(fallback[0], 10)
                                self.assertIn("autonomous", command("/device/print filter=dispatch.inverter.control.kind"))
                                command("/element/set element=dispatch.inverter.control.kind value=continuous")
                                command("/element/set element=dispatch.inverter.control.setpoint value=0W")
                                time.sleep(31.5)
                                self.assertEqual(writes[-1], (1, 0))
                                self.assertIn("automatic", command("/device/print filter=dispatch.inverter.control.result"))
                            command("/element/set element=dispatch.inverter.control.kind value=continuous")
                            command("/element/set element=dispatch.inverter.control.setpoint value=-137W")
                            time.sleep(3.2)
                            self.assertEqual(writes[-1], (8, 0))  # No fresh SOC authorises discharge.
                            command("/element/set element=dispatch.inverter.control.setpoint value=1001W")
                            time.sleep(1.2)
                            self.assertEqual(writes[-1], (8, 0))
                            command("/element/set element=dispatch.inverter.control.kind value=autonomous")
                            time.sleep(1.2)
                            command("/apps/energy/start")
                            command("/apps/energy/link/add name=main parent=grid child=house meter=source.grid capacity=63A")
                            command("/apps/energy/appliance/add name=dispatch device=dispatch grid=house state=profile.battery.store")
                            command("/element/set element=profile.battery.store.soc value=50%")
                            command("/element/set element=source.grid.power value=1000W")
                            command('/apps/energy/policy/add name=surplus target=dispatch tier=opportunistic goal="soc(100)"')
                            time.sleep(2.2)
                            self.assertEqual(writes[-1], (1, 0))
                            command("/element/set element=source.grid.power value=-250W")
                            command("/element/set element=dispatch.battery.meter.voltage value=52V")
                            command("/element/set element=dispatch.inverter.mode value=off_grid")
                            time.sleep(2.2)
                            self.assertEqual(writes[-1], (1, 0))
                            self.assertIn("false", command("/device/print filter=dispatch.inverter.control.available"))
                            command("/element/set element=dispatch.inverter.mode value=on_grid")
                            command("/element/set element=dispatch.battery.meter.voltage value=52V")
                            time.sleep(4.2)
                            self.assertEqual(writes[-1], (11, 250), command("/apps/energy/why") + command("/apps/energy/topology"))
                            command("/element/set element=source.grid.power value=1000W")
                            time.sleep(2.2)
                            self.assertEqual(writes[-1], (1, 0))
                            command("/apps/energy/policy/set surplus disabled=true")
                            # Two policies on one physical appliance select distinct controls.
                            command("/binding/goodwe-control/add name=storage device=dispatch client=dispatch register=47513 scheme=battery_power component=battery.control charge-limit=222")
                            time.sleep(2.2)
                            self.assertIn("false", command("/device/print filter=dispatch.battery.control.enable"))
                            command("/element/set element=dispatch.battery.control.enable value=true")
                            command("/element/set element=dispatch.inverter.control.max value=111W")
                            command("/apps/energy/controls")
                            command("/device/print filter=dispatch.inverter.control.*")
                            command("/device/print filter=dispatch.battery.control.*")
                            command("/element/set element=dispatch.inverter.mode value=on_grid")
                            command("/element/set element=dispatch.battery.meter.voltage value=52V")
                            command('/apps/energy/policy/add name=primary target=dispatch control=inverter.control tier=essential goal="(false)"')
                            command('/apps/energy/policy/add name=storage target=dispatch control=battery.control tier=essential goal="(false)"')
                            command("/element/set element=dispatch.battery.meter.voltage value=52V")
                            time.sleep(2.2)
                            primary = command("/device/print filter=dispatch.inverter.control.setpoint")
                            storage = command("/device/print filter=dispatch.battery.control.setpoint")
                            diagnostic = command("/apps/energy/why") + command("/device/print filter=dispatch.inverter.control.*") + command("/device/print filter=dispatch.battery.control.*")
                            self.assertAlmostEqual(float(re.search(r"setpoint\s+([\d.eE+-]+)W", primary)[1]), 111, delta=0.001, msg=diagnostic)
                            self.assertAlmostEqual(float(re.search(r"setpoint\s+([\d.eE+-]+)W", storage)[1]), 222, delta=0.001)
                            self.assertIn((11, 111), writes)
                            self.assertIn((11, 222), writes)
                            decisions = command("/apps/energy/why")
                            self.assertRegex(decisions, r"prim[^\n]*\b111\b")
                            self.assertRegex(decisions, r"stor[^\n]*\b222\b")
                            command("/apps/energy/policy/set storage control=missing.control")
                            command("/element/set element=dispatch.battery.meter.voltage value=52V")
                            time.sleep(2.2)
                            self.assertIn("autonomous", command("/device/print filter=dispatch.battery.control.kind"))
                            self.assertIn("continuous", command("/device/print filter=dispatch.inverter.control.kind"))
                            command("/apps/energy/policy/set primary disabled=true")
                            command("/apps/energy/policy/set storage disabled=true")
                            command("/binding/goodwe-control/set storage disabled=true")
                            command("/binding/goodwe-control/set dispatch disabled=true")
                            time.sleep(1)
                            self.assertEqual(writes[-1], (1, 0))
                            self.assertEqual(fallback[0], 10)
                        finally:
                            stopped.set()
                            worker.join(1)
            except Exception:
                print("\n".join(transcript))
                print(''.join(stderr_lines))
                raise
            finally:
                if runtime.console:
                    runtime.console.close()
                    runtime.console = None
                if writer:
                    writer.close()
                process = runtime.process
                if runtime.process and runtime.process.poll() is None:
                    runtime.process.terminate()
                    runtime.process.wait(timeout=5)
                stderr_reader.join(timeout=2)
                if RUNTIME_LOG:
                    Path(RUNTIME_LOG).write_text("".join(stderr_lines), encoding="utf-8")
                runtime.stop()
                if process:
                    for pipe in (process.stdin, process.stdout, process.stderr):
                        pipe.close()


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--skip-lease-tests", action="store_true")
    parser.add_argument("--runtime-log")
    args = parser.parse_args()
    RUNTIME_LOG = args.runtime_log
    CHECK_LEASE = not args.skip_lease_tests
    BINARY = str(Path(args.binary).resolve())
    unittest.main(argv=[__file__])
