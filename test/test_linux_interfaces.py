"""Linux driver integration tests. Run as root inside an isolated network namespace.

unshare -nm --propagation private sh -c 'mount -t sysfs sysfs /sys && python3 test/test_linux_interfaces.py'
"""
import argparse
from pathlib import Path
import socket
import shutil
import struct
import subprocess
import tempfile
import threading
import time

from test_harness import OpenWattProcess


def ip(*args):
    subprocess.run(["ip", *args], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default="bin/x86_64_linux_debug/openwatt")
    args = parser.parse_args()
    binary = Path(args.binary).resolve()
    assert set(p.name for p in Path("/sys/class/net").iterdir()) == {"lo"}, "Run in a fresh network namespace"
    subprocess.run(["sysctl", "-qw", "net.ipv6.conf.default.disable_ipv6=1"], check=True)
    ip("link", "set", "lo", "up")
    ip("link", "add", "ow503can0", "type", "vcan")
    ip("link", "add", "ow503can1", "type", "vcan")
    ip("link", "add", "ow503eth", "type", "veth", "peer", "name", "ow503peer")
    ip("link", "set", "ow503eth", "up")
    ip("link", "set", "ow503peer", "up")

    with tempfile.TemporaryDirectory(prefix="ow503-") as temporary:
        directory = Path(temporary)
        (directory / "conf").mkdir()
        (directory / "conf/startup.conf").write_text(
            "/stream/console/add name=test-stdio input=stdin output=stdout\n"
            "/console/session/add name=test-session stream=test-stdio profile=dumb\n"
        )
        process = OpenWattProcess(str(binary), startup_delay=0.1)
        process.project_root = directory
        reader = None
        try:
            assert process.start(), process.get_crash_info()
            reader = threading.Thread(target=lambda: process.stderr_lines.extend(process.process.stderr.readlines()))
            reader.start()
            time.sleep(1)
            console = process.get_console()

            def command(text, delay=0.2):
                response = console.send_command(text, read_delay=delay)
                assert process.is_running(), process.get_crash_info()
                if "/get " in text or text.endswith("/print") or text.endswith("/export"):
                    assert response.strip(), f"No console response to {text}"
                assert "Invalid value" not in response and "Unknown command" not in response, response
                print(text, response.strip(), sep="\n", flush=True)
                return response

            def get(path, name, prop):
                response = command(f"{path}/get {name} {prop}")
                return response.strip()

            can_path = "/interface/can"
            ether_path = "/interface/ethernet"
            adapters = {get(can_path, name, "adapter"): name for name in ("can1", "can2")}
            left, right = adapters["ow503can0"], adapters["ow503can1"]
            assert get(can_path, left, "running") == "true"
            assert get(can_path, right, "running") == "true"
            assert get(can_path, left, "baud-rate") == "0"
            assert "ow503can0" in command("/port/print")
            assert "can1" not in command(f"{ether_path}/print")
            command(f"{ether_path}/add name=wire adapter=ow503eth")
            assert get(ether_path, "wire", "running") == "true"
            saved = command("/system/config/export")
            assert "/interface/can/add" not in saved
            assert "/interface/ethernet/add name=wire" in saved
            print("PASS discovery, classification, ownership and persistence", flush=True)

            command(f"{can_path}/add name=duplicate adapter=ow503can0")
            assert get(can_path, "duplicate", "running") == "false"
            assert get(can_path, left, "running") == "true"
            command(f"{can_path}/remove duplicate")
            command(f"{can_path}/add name=wrong adapter=ow503eth baud-rate=250000")
            assert get(can_path, "wrong", "running") == "false"
            assert "UP" in subprocess.check_output(["ip", "link", "show", "ow503eth"], text=True)
            command(f"{can_path}/remove wrong")
            print("PASS duplicate ownership and non-CAN adapter rejection", flush=True)

            ports = "/interface/bridge/port"
            bridges = "/interface/bridge"
            command(f"{ports}/add name=waiting bridge=absent interface={left}")
            assert get(can_path, left, "running") == "false"
            command(f"{bridges}/add name=absent disabled=true")
            assert get(can_path, left, "running") == "false"
            command(f"{bridges}/set absent disabled=false")
            assert get(can_path, left, "running") == "true"
            command(f"{bridges}/set absent disabled=true")
            assert get(can_path, left, "running") == "false"
            command(f"{bridges}/set absent disabled=false")
            assert get(can_path, left, "running") == "true"
            command(f"{can_path}/set {left} disabled=true")
            assert get(bridges, "absent", "running") == "true"
            command(f"{can_path}/set {left} disabled=false")
            command(f"{bridges}/remove absent")
            assert get(can_path, left, "running") == "false"
            command(f"{bridges}/add name=absent")
            assert get(can_path, left, "running") == "true"
            command(f"{ports}/set waiting pvid=42 ingress-filtering=false untagged-egress=false")
            assert get(ports, "waiting", "pvid") == "42"
            saved = command("/system/config/export")
            assert "/interface/bridge/port/add name=waiting" not in saved
            error = console.send_command(f"{ports}/add name=duplicate-port bridge=absent interface={left}")
            assert "already has a bridge port" in error
            error = console.send_command(f"{ports}/add name=cycle bridge=absent interface=absent")
            assert "cycle" in error
            command(f"{bridges}/add name=other disabled=true")
            command(f"{ports}/set waiting bridge=other")
            assert get(can_path, left, "running") == "false"
            assert get(bridges, "absent", "running") == "true"
            command(f"{bridges}/set other disabled=false")
            assert get(can_path, left, "running") == "true"
            command(f"{ports}/remove waiting")
            command(f"{bridges}/remove absent")
            command(f"{bridges}/remove other")
            assert get(can_path, left, "running") == "true"
            print("PASS membership persistence, dependency direction, reassignment and validation", flush=True)

            command("/interface/bridge/add name=canbridge")
            command(f"/interface/bridge/port/add name=can-left bridge=canbridge interface={left}")
            command(f"/interface/bridge/port/add name=can-right bridge=canbridge interface={right}")
            with socket.socket(socket.AF_CAN, socket.SOCK_RAW, socket.CAN_RAW) as tx, socket.socket(socket.AF_CAN, socket.SOCK_RAW, socket.CAN_RAW) as rx:
                tx.bind(("ow503can0",))
                rx.bind(("ow503can1",))
                rx.settimeout(2)
                for can_id, length, payload in [(0x123, 3, b"abc"), (0x80012345, 8, b"12345678"), (0x40000321, 4, b"")]:
                    tx.send(struct.pack("=IB3x8s", can_id, length, payload))
                    received_id, received_length, received = struct.unpack("=IB3x8s", rx.recv(16))
                    assert (received_id, received_length) == (can_id, length)
                    if not can_id & 0x40000000:
                        assert received[:length] == payload
                assert int(get(can_path, left, "rx-packets")) == 3
                assert int(get(can_path, right, "tx-packets")) == 3
            command("/interface/bridge/remove canbridge")
            assert get(can_path, left, "running") == "false"
            assert get("/interface/bridge/port", "can-left", "bridge") == "canbridge"
            command("/interface/bridge/port/remove can-left")
            command("/interface/bridge/port/remove can-right")
            print("PASS standard, extended and RTR CAN RX/TX through the bridge", flush=True)

            with socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x88B6)) as peer:
                peer.bind(("ow503peer", 0))
                frame = bytes.fromhex("ffffffffffff02000000050388b6") + b"ow503" * 10
                before = int(get(ether_path, "wire", "rx-packets"))
                for _ in range(8):
                    peer.send(frame)
                assert int(get(ether_path, "wire", "rx-packets")) >= before + 8
            print("PASS reactor-driven Ethernet RX", flush=True)

            ip("link", "add", "ow503eth2", "type", "veth", "peer", "name", "ow503peer2")
            ip("link", "set", "ow503eth2", "up")
            ip("link", "set", "ow503peer2", "up")
            command(f"{ether_path}/add name=wire2 adapter=ow503eth2")
            command("/interface/bridge/add name=ethbridge")
            command("/interface/bridge/port/add name=eth-left bridge=ethbridge interface=wire")
            command("/interface/bridge/port/add name=eth-right bridge=ethbridge interface=wire2")
            assert Path("/sys/class/net/ow503eth/master").exists()
            before = int(get(ether_path, "wire", "rx-packets"))
            with socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x88B6)) as tx, socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x88B6)) as rx:
                tx.bind(("ow503peer", 0))
                rx.bind(("ow503peer2", 0))
                rx.settimeout(2)
                tx.send(frame)
                assert rx.recv(2048) == frame
            assert int(get(ether_path, "wire", "rx-packets")) == before
            command("/interface/bridge/port/remove eth-right")
            assert get("/interface/bridge", "ethbridge", "running") == "true"
            assert get(ether_path, "wire2", "running") == "true"
            assert not Path("/sys/class/net/ow503eth2/master").exists()
            command("/interface/bridge/port/add name=eth-right bridge=ethbridge interface=wire2")
            assert Path("/sys/class/net/ow503eth2/master").exists()
            command("/interface/bridge/remove ethbridge")
            assert not Path("/sys/class/net/ow503eth/master").exists()
            assert get(ether_path, "wire", "running") == "false"
            command("/interface/bridge/port/remove eth-left")
            command("/interface/bridge/port/remove eth-right")
            after = int(get(ether_path, "wire", "rx-packets"))
            assert after == before, "Offloaded traffic was replayed after detaching the bridge"
            with socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x88B6)) as tx:
                tx.bind(("ow503peer", 0))
                for _ in range(8):
                    tx.send(frame)
            assert int(get(ether_path, "wire", "rx-packets")) >= after + 8
            print("PASS kernel bridge offload and return to reactor RX", flush=True)

            ip("link", "del", "ow503eth")
            time.sleep(1.5)
            assert get(ether_path, "wire", "running") == "false"
            ip("link", "add", "ow503eth", "type", "veth", "peer", "name", "ow503peer")
            ip("link", "set", "ow503eth", "up")
            ip("link", "set", "ow503peer", "up")
            time.sleep(2)
            assert get(ether_path, "wire", "running") == "true"
            print("PASS Ethernet disappearance and reconnection", flush=True)

            command("/interface/bridge/add name=reconnect")
            command(f"/interface/bridge/port/add name=reconnect-left bridge=reconnect interface={left}")
            command(f"/interface/bridge/port/add name=reconnect-right bridge=reconnect interface={right}")
            baseline_fds = len(list(Path(f"/proc/{process.process.pid}/fd").iterdir()))
            for _ in range(3):
                ip("link", "del", "ow503can0")
                time.sleep(0.5)
                assert "ow503can0" not in command("/port/print")
                assert left not in command(f"{can_path}/print")
                assert "reconnect-left" not in command("/interface/bridge/port/print")
                assert get("/interface/bridge", "reconnect", "running") == "true"
                ip("link", "add", "ow503can0", "type", "vcan")
                time.sleep(0.5)
                assert get(can_path, left, "adapter") == "ow503can0"
                assert get(can_path, left, "running") == "true"
                assert get("/interface/bridge", "reconnect", "running") == "true"
                assert "reconnect-left" not in command("/interface/bridge/port/print")
                command(f"/interface/bridge/port/add name=reconnect-left bridge=reconnect interface={left}")
            assert len(list(Path(f"/proc/{process.process.pid}/fd").iterdir())) == baseline_fds
            print("PASS CAN unplug/replug and descriptor cleanup", flush=True)
            command("/interface/bridge/remove reconnect")
            command("/interface/bridge/port/remove reconnect-left")
            command("/interface/bridge/port/remove reconnect-right")

            command(f"{can_path}/set {left} disabled=true")
            command(f"{can_path}/add name=manual adapter=ow503can0")
            assert get(can_path, "manual", "running") == "true"
            ip("link", "del", "ow503can0")
            time.sleep(0.5)
            assert get(can_path, "manual", "adapter") == "ow503can0"
            assert get(can_path, "manual", "running") == "false"
            ip("link", "add", "ow503can0", "type", "vcan")
            time.sleep(1.5)
            assert get(can_path, "manual", "running") == "true"
            print("PASS operator-created CAN survives removal and reconnects", flush=True)
            print("ALL LINUX INTERFACE TESTS PASSED", flush=True)
        finally:
            if process.process and process.process.poll() is not None:
                cores = list(directory.glob("core*"))
                if cores and shutil.which("gdb"):
                    subprocess.run(["gdb", "-batch", "-ex", "bt", str(binary), str(cores[0])], check=False)
            if process.process and process.process.poll() is None:
                process.process.terminate()
                process.process.wait(timeout=5)
            if reader:
                reader.join(timeout=5)
            print("\n".join(process.stderr_lines), flush=True)
            if process.process and process.process.stdin:
                try:
                    process.process.stdin.close()
                except OSError:
                    pass
            process.stop()


if __name__ == "__main__":
    main()
