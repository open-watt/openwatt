"""Inventory command factory cases in a locally decompiled SolarGo APK.

This extracts factual command identifiers and literal byte prefixes, not a
validated device protocol. It never executes Java or sends network requests.
Dynamic builders and unresolved byte expressions remain explicitly unresolved.
"""

import argparse
import hashlib
import json
import re
from pathlib import Path


ASCII = dict(zip("NUL SOH STX ETX EOT ENQ ACK BEL BS HT LF VT FF CR SO SI DLE DC1 DC2 DC3 DC4 NAK SYN ETB CAN EM SUB ESC FS GS RS US".split(), range(32)))
ASCII.update(SP=32, DEL=127)
FACTORIES = {
    "com/goodwe/hybrid/common/DataCollectUtil.java": (
        "buildPackage", "build105SettingPackage", "build105ReadingPackage",
        "buildETSettingPackage", "buildETPackage", "buildWifiPackage",
        "buildSolarGoSettingPackage", "buildUpgradePackage"),
    "com/goodwe/udp/HybridUdpPackageUtils.java": ("buildReadPackage", "buildSettingPackage"),
    "com/goodwe/udp/UdpPackageUtils.java": (
        "buildPackage", "buildWifiPackage", "buildSettingPackage",
        "buildWifiSettingPackage", "buildHTSetPackageEx", "buildUpgradePackage"),
    "com/goodwe/udp/HjUdpPkgUtils.java": ("buildPackage", "buildSettingPackage"),
    "com/goodwe/udp/UdpPkgUtils.java": ("buildPackage",),
}


def literal_bytes(expression):
    result = []
    for token in expression.split(","):
        token = token.strip()
        if token.startswith("Ascii.") and token[6:] in ASCII:
            value = ASCII[token[6:]]
        elif re.fullmatch(r"-?(?:0[xX][0-9a-fA-F]+|\d+)", token):
            value = int(token, 16 if "x" in token.lower() else 10)
        else:
            return None
        if not -128 <= value <= 255:
            return None
        result.append(value & 255)
    return bytes(result).hex()


def factory_span(source, method):
    # Factory declarations/cases have their own lines in jadx output. Limit to
    # the next method declaration, so cases cannot bleed into another factory.
    declaration = re.search(r"^    (?:public|private) static byte\[\] " + re.escape(method) + r"\([^\n)]*\bint \w+[^\n]*", source, re.M)
    if not declaration:
        return None
    start = declaration.end()
    end = re.search(r"^    (?:public|private|protected) .*\(", source[start:], re.M)
    stop = start + end.start() if end else len(source)
    return start, stop


def factory_cases(source, method):
    span = factory_span(source, method)
    if span is None:
        return []
    start, stop = span
    cases = list(re.finditer(r"^\s*case (\w+)(?: /\* (\d+) \*/)?\s*:", source[start:stop], re.M))
    rows = []
    for index, match in enumerate(cases):
        offset = start + match.start()
        body = source[start + match.end():start + cases[index + 1].start() if index + 1 < len(cases) else stop]
        # A nested switch's default is not part of its preceding case.
        body = re.split(r"^\s*default\s*:", body, maxsplit=1, flags=re.M)[0]
        arrays = re.findall(r"(?:new byte\[\]\s*|byte\[\]\s+\w+\s*=\s*)\{([^{}]*)\}", body)
        prefixes = [literal_bytes(value) for value in arrays]
        prefixes += [value.lower() for value in re.findall(r'getByteArrayByString\("([0-9a-fA-F]+)"\)', body)]
        name = match[1]
        rows.append(dict(factory=method, case=name, case_id=int(match[2] or name) if (match[2] or name).isdigit() else None,
                         source_line=source.count("\n", 0, offset) + 1,
                         literal_byte_arrays=[value for value in prefixes if value is not None],
                         unresolved_byte_arrays=sum(value is None for value in prefixes),
                         constant_references=sorted(set(re.findall(r"Constant\.(\w+)", body))),
                         status="static candidate; model applicability, request assembly, response and side effects require verification"))
    return rows


def inventory(root):
    files = []
    commands = []
    definitions = []
    for relative, methods in FACTORIES.items():
        path = Path(root) / relative
        data = path.read_bytes()
        source = data.decode("utf-8")
        files.append(dict(path=relative, sha256=hashlib.sha256(data).hexdigest()))
        for method in methods:
            span = factory_span(source, method)
            if span is not None:
                start, stop = span
                body = source[start:stop]
                literals = [literal_bytes(value) for value in re.findall(r"(?:new byte\[\]\s*|byte\[\]\s+\w+\s*=\s*)\{([^{}]*)\}", body)]
                definitions.append(dict(source=relative, factory=method,
                                        source_line=source.count("\n", 0, start) + 1,
                                        literal_byte_arrays=sorted(set(value for value in literals if value is not None)),
                                        unresolved_byte_arrays=sum(value is None for value in literals),
                                        conditional_ids=sorted(set(int(value) for value in re.findall(r"\b(?:pkgType|packageType)\s*(?:==|!=)\s*(\d+)", body))),
                                        status="whole-factory literal/condition index, including non-switch branches; no automatic operation association"))
            for row in factory_cases(source, method):
                commands.append(dict(source=relative, **row))
    direct_calls = []
    constant_path = Path(root) / "com/goodwe/hybrid/common/Constant.java"
    constant_data = constant_path.read_bytes()
    files.append(dict(path=constant_path.relative_to(root).as_posix(), sha256=hashlib.sha256(constant_data).hexdigest()))
    constant_source = constant_data.decode("utf-8")
    constant_arrays = []
    for match in re.finditer(r"public static (?:final )?byte\[\]\s+(\w+)\s*=\s*\{([^{}]+)\}", constant_source):
        expression = re.sub(r'Integer\.valueOf\("([0-9A-Fa-f]+)", 16\)\.byteValue\(\)', lambda value: str(int(value[1], 16)), match[2])
        value = literal_bytes(expression)
        constant_arrays.append(dict(name=match[1], bytes=value,
                                    source_line=constant_source.count("\n", 0, match.start()) + 1,
                                    status="literal only" if value is not None else "unresolved"))
    call_pattern = re.compile(r"GoodUtil\.(?:INSTANCE\.)?(readMoreByte|readByte|writeSingle|writeMultiple)(\$default)?\(\s*(?:GoodUtil\.INSTANCE,\s*)?([^,\n]+)")
    for path in sorted((Path(root) / "com/goodwe").rglob("*.java")):
        data = path.read_bytes()
        source = data.decode("utf-8")
        matches = list(call_pattern.finditer(source))
        if not matches:
            continue
        relative = path.relative_to(root).as_posix()
        if not any(row["path"] == relative for row in files):
            files.append(dict(path=relative, sha256=hashlib.sha256(data).hexdigest()))
        for match in matches:
            address = match[3].strip()
            direct_calls.append(dict(source=relative, source_line=source.count("\n", 0, match.start()) + 1,
                                     operation=match[1], address=int(address) if address.isdecimal() else None,
                                     address_resolution="literal" if address.isdecimal() else "dynamic/unresolved",
                                     status="static call site; count, values, carrier and device applicability require tracing"))
    return dict(schema_version=1, scope="SolarGo factory switch cases and GoodUtil register call sites; other builders are not indexed; includes multiple inverter families",
                warning="This is an index for discovery, not a sendable command registry. A method named Reading can contain a restart command. Never classify safety from the name.",
                sources=files, command_case_count=len(commands), commands=commands, factories=definitions,
                constant_arrays=constant_arrays,
                direct_register_call_count=len(direct_calls), direct_register_calls=direct_calls)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sources", help="jadx sources directory")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    result = inventory(args.sources)
    Path(args.output).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"Indexed {result['command_case_count']} factory cases and {result['direct_register_call_count']} register call sites; static candidates only")
