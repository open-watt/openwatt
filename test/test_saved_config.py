import argparse
from pathlib import Path
import tempfile
import threading
import time
import zlib

from test_harness import OpenWattProcess


def quoted(value):
    return '"' + ''.join('\\' + c if c in '\\"$' else c for c in value) + '"'


def revision(data):
    return data + f'\n# crc32={zlib.crc32(data):08X}\n'.encode()


def boot(binary, directory, expect_running=True):
    process = OpenWattProcess(str(binary), startup_delay=0.05)
    process.project_root = directory
    reader = None
    try:
        started = process.start()
        if started:
            reader = threading.Thread(target=lambda: process.stderr_lines.extend(process.process.stderr.readlines()))
            reader.start()
            time.sleep(1.5)
        running = started and process.is_running()
        assert running == expect_running, (directory, process.get_crash_info())
    finally:
        if process.process:
            process.process.terminate()
            process.process.wait(timeout=5)
        if reader:
            reader.join(timeout=5)
        if process.process and process.process.stdin:
            try:
                process.process.stdin.close()
            except OSError:
                pass
        process.stop()
    return '\n'.join(process.stderr_lines)


def completed(directory, basename='config.conf'):
    return sorted((p for p in (directory / 'conf').glob(basename + '.*') if p.suffix[1:].isdigit()), key=lambda p: int(p.suffix[1:]))


def observed(directory):
    return completed(directory, 'observed.conf')[-1].read_text()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', default='bin/x86_64_windows_debug/openwatt.exe')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    binary = (root / args.binary).resolve()
    (root / '.tmp').mkdir(exist_ok=True)
    workspace = Path(tempfile.mkdtemp(prefix='saved-config-', dir=root / '.tmp'))

    def fixture(name, script):
        directory = workspace / name
        (directory / 'conf').mkdir(parents=True)
        (directory / 'conf/startup.conf').write_text(script, encoding='utf-8')
        (directory / 'conf/user.conf').write_text('/system/config/save file=conf/observed.conf\n', encoding='utf-8')
        return directory

    values = ['', 'source', '00123', 'true', 'null', '@missing', '$name', 'a,b', 'a b', '"', '\\', '\\a\\b', 'a"b"c', 'line\nnext', '\\$name"']
    directory = fixture('strings', ''.join(f'/stream/memory/add name=item{i} comment={quoted(value)}\n' for i, value in enumerate(values)) + '/system/config/save\n')
    boot(binary, directory)
    before = observed(directory)
    boot(binary, directory)
    after = observed(directory)
    for i, value in enumerate(values):
        line = f'/stream/memory/set item{i} comment={quoted(value)}' if value else f'/stream/memory/add name=item{i} disabled=true'
        assert line in before and line in after, (value, before, after)
    print('PASS: string literals survive save and reboot', flush=True)

    directory = fixture('ordering', '\n'.join([
        '/stream/memory/add name=left disabled=true',
        '/stream/memory/add name=right disabled=true',
        '/stream/memory/add name=live comment=enabled',
        '/stream/tcp-client/add name=uplink remote=127.0.0.1:9 disabled=true',
        '/stream/duplex/add name=pair tx=left rx=right disabled=true',
        '/stream/bridge/add name=aggregate streams=pair,uplink disabled=true',
        '/certificate/add name=cert cert-type=self_signed disabled=true',
        '/stream/tls/add name=secure stream=aggregate certificate=cert disabled=true',
        '/stream/tls/add name=outer stream=secure certificate=cert disabled=true',
        '/interface/can/add name=canbus stream=uplink protocol=ebyte disabled=true',
        '/protocol/http/server/add name=front disabled=true',
        '/certificate/add name=acme cert-type=acme http-server=front domain=example.com disabled=true',
        '/protocol/http/server/set front certificates=acme',
        '/sync/ws-server/add name=sync http-server=front disabled=true',
        '/protocol/websocket/server/add name=ws http-server=front disabled=true',
        '/interface/websocket/add name=outbound stream=outer disabled=true',
        '/apps/api/add name=api http-server=front disabled=true',
        '/apps/ota/add name=ota http-server=front disabled=true',
        '/protocol/http/fileserver/add name=files http-server=front disabled=true',
        '/interface/modbus/add name=bus stream=aggregate disabled=true',
        '/protocol/modbus/node/add name=node interface=bus address=1 disabled=true',
        '/log/sink/add name=custom stream=left disabled=true',
        '/system/config/save',
        '',
    ]))
    for _ in range(2):
        logs = boot(binary, directory)
        exported = observed(directory)
        for name in ['left', 'right', 'live', 'uplink', 'pair', 'aggregate', 'cert', 'secure', 'outer', 'canbus', 'front', 'acme', 'sync', 'ws', 'outbound', 'api', 'ota', 'files', 'bus', 'node', 'custom']:
            assert exported.count(f' name={name} ') == 1, (name, exported, logs)
        create, configure, enable = exported.split('# Configure\n')[0], exported.split('# Configure\n')[1].split('# Enable\n')[0], exported.split('# Enable\n')[1]
        assert '/set ' not in create and '/add ' not in configure + enable
        assert 'disabled=' not in configure
        assert '/stream/memory/set live disabled=false\n' in enable
        assert '/stream/memory/set left disabled=false' not in enable
        for prop in ['stream="aggregate"', 'stream="secure"', 'stream="uplink"', 'http-server="front"', 'certificates="acme"', 'stream="outer"']:
            assert prop in configure, (prop, configure)
        assert 'Item does not exist:' not in logs and "Set '" not in logs, logs
    print('PASS: phased restore handles cycles, same-type references, CAN, TLS bridges, web services and enabled state', flush=True)

    directory = fixture('bridge-membership', '\n'.join([
        '/interface/bridge/add name=master',
        '/interface/bridge/add name=member',
        '/interface/bridge/port/add name=port bridge=master interface=member pvid=42',
        '/interface/bridge/port/add name=missing bridge=absent-master interface=absent-member',
        '/system/config/save',
        '',
    ]))
    for _ in range(2):
        logs = boot(binary, directory)
        exported = observed(directory)
        assert '/interface/bridge/port/add name=port' in exported
        assert '/interface/bridge/port/set port bridge="master" interface="member" pvid=42' in exported
        assert 'bridge="absent-master" interface="absent-member"' in exported
        assert 'Invalid value' not in logs and 'Item does not exist:' not in logs, logs
    print('PASS: bridge memberships and unresolved endpoint names survive save and reboot', flush=True)

    directory = fixture('boot-created', '/stream/memory/set system comment=saved\n/system/config/save\n')
    (directory / 'conf/system.conf').write_text('/stream/memory/add name=system comment=boot\n', encoding='utf-8')
    for _ in range(2):
        boot(binary, directory)
        assert '/stream/memory/set system comment="saved"' in observed(directory)
    print('PASS: explicit properties apply to existing boot-created objects', flush=True)

    script = '/stream/memory/add name=sample\n'
    for i in range(1, 7):
        script += f'/stream/memory/set sample comment=revision{i}\n/system/config/save\n'
    directory = fixture('revisions', script)
    boot(binary, directory)
    assert [p.name for p in completed(directory)] == [f'config.conf.{i}' for i in range(2, 7)]
    previous = (directory / 'conf/config.conf.6').read_bytes()
    assert previous.endswith(f'\n# crc32={zlib.crc32(previous[:-18]):08X}\n'.encode())
    (directory / 'conf/config.conf.7.tmp').write_bytes(b'partial')
    boot(binary, directory)
    assert 'comment="revision6"' in observed(directory)
    assert (directory / 'conf/config.conf.6').read_bytes() == previous
    print('PASS: retain five revisions; ignore interrupted candidate', flush=True)

    (directory / 'conf/config.conf.8').write_bytes(b'partial')
    logs = boot(binary, directory)
    assert (directory / 'conf/config.conf.8.bad').exists()
    assert 'comment="revision6"' in observed(directory)
    assert 'trying an older revision' in logs
    (directory / 'conf/config.conf.9').write_bytes(revision(b')'))
    boot(binary, directory)
    assert (directory / 'conf/config.conf.9.bad').exists()
    assert 'comment="revision6"' in observed(directory)
    print('PASS: corrupt and unparseable revisions roll back', flush=True)

    (directory / 'conf/config.conf.10.tmp').mkdir()
    (directory / 'conf/user.conf').write_text('/system/config/save\n', encoding='utf-8')
    logs = boot(binary, directory)
    assert 'failed to save configuration' in logs
    assert (directory / 'conf/config.conf.6').read_bytes() == previous
    assert len(completed(directory)) == 5
    print('PASS: failed candidate write preserves completed revisions', flush=True)

    directory = fixture('exhausted', '/stream/memory/add name=factory\n/system/config/save\n')
    (directory / 'conf/config.conf.1').write_bytes(b'broken')
    logs = boot(binary, directory, expect_running=False)
    assert not completed(directory)
    assert 'refusing to replace deployment configuration with defaults' in logs
    print('PASS: exhausted revisions do not execute factory/startup defaults', flush=True)

    directory = fixture('legacy', '/stream/memory/add name=factory\n')
    (directory / 'conf/config.conf').write_text('/stream/memory/add name=legacy\n/system/config/save\n', encoding='utf-8')
    boot(binary, directory)
    assert 'name=legacy' in observed(directory) and 'name=factory' not in observed(directory)
    assert (directory / 'conf/config.conf.1').exists()
    print('PASS: legacy saved configuration migrates to revisions', flush=True)

    directory = fixture('secrets', '/secret/add name=example algorithm=sha256 password=first services=admin\n/system/config/save\n')
    boot(binary, directory)
    assert completed(directory, 'secret.store')
    first = (directory / 'conf/config.conf.1').read_bytes()
    next_secret_revision = int(completed(directory, 'secret.store')[-1].suffix[1:]) + 1
    (directory / f'conf/secret.store.{next_secret_revision}.tmp').mkdir()
    (directory / 'conf/user.conf').write_text('/secret/set example password=second\n/system/config/save\n', encoding='utf-8')
    logs = boot(binary, directory)
    assert 'secret store could not be saved' in logs
    assert len(completed(directory)) == 1
    assert (directory / 'conf/config.conf.1').read_bytes() == first
    print('PASS: secret-store write failure blocks config publication', flush=True)
    print(f'Artifacts: {workspace}', flush=True)


if __name__ == '__main__':
    main()
