#!/usr/bin/env python3
"""Capture isolated ES configuration reads and optional unchanged scalar writes.

The reassertion list excludes grid protection, network credentials and actions.
It proves ACK/readback for the current value, not every possible value or restart
persistence. Normal client sampling is restored in finally.
"""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import socket
import sys
import time
from types import SimpleNamespace

from test_harness import OpenWattConsole
from test_goodwe_server import frame

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from goodwe_capture import crc16


def run(args):
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("a", encoding="utf-8", buffering=1) as log:
        def record(event, **values):
            row = dict(time=datetime.now(timezone.utc).isoformat(), event=event, **values)
            log.write(json.dumps(row) + "\n")
            print(json.dumps(row), flush=True)

        with socket.create_connection((args.pi, 23), timeout=8) as conn:
            conn.settimeout(None)
            reader = conn.makefile("r", encoding="utf-8", errors="replace")
            writer = conn.makefile("w", encoding="utf-8")
            console = OpenWattConsole(SimpleNamespace(stdin=writer, stdout=reader))

            def command(text):
                reply = console.send_command(text, read_delay=0.15, timeout=2)
                if any(error in reply for error in ("Unknown command", "Missing argument", "send failed", "must be running")):
                    raise RuntimeError(reply)
                return reply

            def exchange(packet, kind, address, count):
                sent = command(f"/protocol/goodwe/client/send client={args.client} data=" + ",".join(map(str, packet)))
                if "draining" in sent:
                    raise RuntimeError(sent)
                deadline = time.monotonic() + 2
                response = b""
                while time.monotonic() < deadline:
                    reply = command(f"/protocol/goodwe/client/received client={args.client}")
                    match = re.search(r"^data=([0-9A-F ]+)", reply, re.M)
                    if match:
                        response = bytes.fromhex(match[1])
                        break
                    time.sleep(0.1)
                payload = None
                if kind == "modbus":
                    rtu = response[2:] if response[:3] == b"\xaa\x55\xf7" else response
                    if (len(rtu) == count * 2 + 5 and rtu[:3] == bytes((247, 3, count * 2))
                            and crc16(rtu[:-2]) == int.from_bytes(rtu[-2:], "little")):
                        payload = rtu[3:-2]
                elif (len(response) >= 9 and response[:2] == b"\xaa\x55"
                      and len(response) == response[6] + 9
                      and sum(response[:-2]) == int.from_bytes(response[-2:], "big")
                      and response[4] == packet[4] and response[5] == packet[5] | 128):
                    payload = response[7:-2]
                    if kind == "aa55-read" and len(payload) != count * 2:
                        payload = None
                record("exchange", kind=kind, address=address, count=count,
                       request=packet.hex(), response=response.hex(), valid=payload is not None,
                       words=[int.from_bytes(payload[i:i+2], "big") for i in range(0, len(payload), 2)]
                       if payload is not None and kind != "aa55-write" else None)
                return payload

            manual = command(f"/protocol/goodwe/client/get {args.client} manual")
            if "false" not in [line.strip() for line in manual.splitlines()]:
                raise RuntimeError("Client already in manual mode; refusing to interrupt")
            command(f"/protocol/goodwe/client/set {args.client} manual=true")
            try:
                time.sleep(1.8)
                for address, count in ((45400, 17), (45417, 16), (45433, 66), (45443, 67),
                                       (45526, 13), (45510, 1), (45512, 1), (45728, 1),
                                       (0x0556, 19), (0xB9B9, 2), (0xB1AC, 1), (0x7506, 1), (0xB7BC, 1)):
                    body = bytes((247, 3)) + address.to_bytes(2, "big") + count.to_bytes(2, "big")
                    exchange(body + crc16(body).to_bytes(2, "little"), "modbus", address, count)
                if args.reassert:
                    for address in (0x0556, 0x0558, 0x0559, 0x0560, 0x05A1):
                        read = frame(1, 0x1a, address.to_bytes(2, "big") + b"\x01", 0xb0, 0x7f)
                        current = exchange(read, "aa55-read", address, 1)
                        if current is None:
                            continue
                        value = int.from_bytes(current, "big")
                        if value > (100 if address in (0x0560, 0x05A1) else 1):
                            record("reassert_skipped", address=address, reason="unexpected current value")
                            continue
                        write = frame(2, 0x39, address.to_bytes(2, "big") + b"\x01" + current, 0xb0, 0x7f)
                        ack = exchange(write, "aa55-write", address, 1)
                        after = exchange(read, "aa55-read", address, 1)
                        record("unchanged_write", address=address, value=value,
                               acknowledged=ack == b"\x06", verified=ack == b"\x06" and after == current)
                        if after is not None and after != current:
                            raise RuntimeError("Unexpected change after unchanged-value write")
            finally:
                try:
                    command(f"/protocol/goodwe/client/set {args.client} manual=false")
                    record("sampling_restored")
                finally:
                    conn.shutdown(socket.SHUT_RDWR)
                    console.reader_thread.join(timeout=2)
                    reader.close()
                    writer.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", required=True)
    parser.add_argument("--pi", required=True)
    parser.add_argument("--client", default="cabin_solar")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--reassert", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_-]+", args.client):
        parser.error("Invalid client name")
    run(args)
