"""Turn concatenated OpenWatt syslog captures into a JSON wire inventory.

Usage: python tools/goodwe_capture.py capture.log --peer 192.0.2.134
The input is never changed. All packets are preserved; classification does not
establish the meaning of a request or that a response belongs to it.
"""

import argparse
import collections
import json
import ipaddress
import re
import time
from pathlib import Path


def crc16(data):
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def classify(data):
    if data == b"WIFIKIT-214028-READ":
        return {"protocol": "discovery", "kind": "request"}
    discovery = re.fullmatch(rb"([0-9.]+),([0-9A-Fa-f]{12}),([ -~]{1,128})", data)
    if discovery:
        try:
            address = str(ipaddress.IPv4Address(discovery[1].decode()))
        except ipaddress.AddressValueError:
            pass
        else:
            return {"protocol": "discovery", "kind": "response", "address": address,
                    "module_id": discovery[2].decode(), "advertised_name": discovery[3].decode()}
    if data[:2] == b"\x5a\x5a":
        result = {"protocol": "goodwe-5a5a", "valid": False,
                  "body": data[2:-2].hex() if len(data) >= 4 else ""}
        if len(data) >= 8:
            length = int.from_bytes(data[4:6], "big")
            result.update(version=data[2], function=data[3], declared_length=length,
                          crc_valid=crc16(data[:-2]) == int.from_bytes(data[-2:], "little"),
                          length_valid=len(data) == length + 8,
                          recognized_version=data[2] in (1, 2),
                          payload=data[6:-2].hex(), kind="response" if data[3] & 128 else "request")
            result["valid"] = result["crc_valid"] and result["length_valid"] and result["recognized_version"]
        return result
    if data[:2] == b"\xaa\x55":
        valid = len(data) >= 9 and len(data) == data[6] + 9
        valid = valid and sum(data[:-2]) & 0xFFFF == int.from_bytes(data[-2:], "big")
        result = {"protocol": "aa55", "valid": valid}
        if valid:
            result.update(source=data[2], destination=data[3], control=data[4],
                          function=data[5], payload=data[7:-2].hex(),
                          kind="response" if data[5] & 0x80 else "request")
            return result
        # GoodWe also prefixes Modbus replies with AA55; their CRC covers the
        # RTU body only, and they do not have the AA55 vendor-frame layout.
        body = data[2:]
        if len(body) >= 5 and crc16(body[:-2]) == int.from_bytes(body[-2:], "little"):
            result = {"protocol": "goodwe-modbus-rtu", "valid": True,
                      "kind": "response", "unit": body[0], "function": body[1]}
            if body[1] & 0x80:
                result["exception"] = body[2]
                result["valid"] = len(body) == 5
            elif body[1] in (1, 2, 3, 4):
                result["byte_count"] = body[2]
                result["payload"] = body[3:-2].hex()
                result["valid"] = len(body) == body[2] + 5
            elif body[1] in (6, 16):
                result["valid"] = len(body) == 8
                if result["valid"]:
                    result.update(register=int.from_bytes(body[2:4], "big"))
                    result["value" if body[1] == 6 else "count"] = int.from_bytes(body[4:6], "big")
            return result
        return {"protocol": "aa55", "valid": False}
    if len(data) >= 4 and crc16(data[:-2]) == int.from_bytes(data[-2:], "little"):
        result = {"protocol": "modbus-rtu", "valid": True, "unit": data[0], "function": data[1]}
        if len(data) == 8 and data[1] in (1, 2, 3, 4):
            result.update(kind="read-request", register=int.from_bytes(data[2:4], "big"),
                          count=int.from_bytes(data[4:6], "big"))
        elif data[1] == 6:
            result["valid"] = len(data) == 8
            if result["valid"]:
                result.update(kind="write-single-request", register=int.from_bytes(data[2:4], "big"),
                              value=int.from_bytes(data[4:6], "big"))
        elif data[1] == 16:
            result["valid"] = len(data) >= 9
            if result["valid"]:
                count = int.from_bytes(data[4:6], "big")
                result.update(kind="write-multiple-request", register=int.from_bytes(data[2:4], "big"),
                              count=count, byte_count=data[6], payload=data[7:-2].hex())
                result["valid"] = count > 0 and data[6] == count * 2 and len(data) == data[6] + 9
        return result
    return {"protocol": "unclassified"}


def inventory(path, peer=None):
    groups = {}
    events = []
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    for record in re.split(r"(?=<\d+>1 )", text):
        match = re.search(r"^<\d+>1 (\S+) \S+ (aa55(?:-server)?) (\S+) - - "
                          r"(discovery rx|experiment tx|rx|tx) (\S+) ((?:[0-9A-F]{2}(?: |$))*)$", record)
        if not match or (peer and not match[5].startswith(peer + ":")):
            continue
        timestamp, tag, name, direction, endpoint, wire = match.groups()
        data = bytes.fromhex(wire)
        event = dict(timestamp=timestamp, tag=tag, name=name, direction=direction,
                     peer=endpoint, hex=data.hex(), **classify(data))
        events.append(event)
        key = (tag, name, direction, data.hex())
        if key not in groups:
            groups[key] = dict(event, occurrences=0, first_seen=timestamp)
        groups[key]["occurrences"] += 1
        groups[key]["last_seen"] = timestamp
    return {"input": str(path), "peer_filter": peer, "event_count": len(events),
            "protocol_counts": dict(collections.Counter(e["protocol"] for e in events)),
            "inventory": list(groups.values()), "events": events}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture")
    parser.add_argument("--peer")
    parser.add_argument("--output")
    parser.add_argument("--watch", type=float, help="Refresh the output file when capture changes; interval in seconds")
    args = parser.parse_args()
    if args.watch is not None and (not args.output or args.watch <= 0):
        parser.error("--watch requires --output and a positive interval")
    previous = None
    while True:
        stat = Path(args.capture).stat()
        current = (stat.st_mtime_ns, stat.st_size)
        if current != previous:
            output = json.dumps(inventory(args.capture, args.peer), indent=2) + "\n"
            if args.output:
                target = Path(args.output)
                temporary = target.with_suffix(target.suffix + ".tmp")
                temporary.write_text(output, encoding="utf-8")
                temporary.replace(target)
            else:
                print(output, end="")
            previous = current
        if args.watch is None:
            break
        time.sleep(args.watch)
