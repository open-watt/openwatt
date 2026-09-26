# BOOTP and TFTP server for netbooting a RouterBOOT board, answering only MACs that start with mac-prefix:
#   netboot.py <image> <server-ip> <client-ip> [mac-prefix]
import socket, struct, threading, time, sys, os

IMAGE, HOST, CLIENT_IP = sys.argv[1:4]
BOOTFILE = b'kernel'

def log(*a):
    print(time.strftime('%H:%M:%S'), *a, flush=True)

def bootp():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.bind((HOST, 67))
    log('bootp listening')
    while True:
        data, addr = s.recvfrom(2048)
        if len(data) < 240 or data[0] != 1:
            continue
        xid = data[4:8]
        chaddr = data[28:44]
        mac = ':'.join('%02x' % b for b in chaddr[:6])
        opts = data[240:] if data[236:240] == b'\x63\x82\x53\x63' else b''
        msgtype = None
        i = 0
        while i < len(opts) and opts[i] != 255:
            if opts[i] == 0:
                i += 1; continue
            if opts[i] == 53: msgtype = opts[i + 2]
            i += 2 + opts[i + 1]
        log('bootp request from', mac, 'msgtype', msgtype, 'from', addr)
        if msgtype is not None:
            continue
        if not mac.startswith(TARGET_OUI) and TARGET_OUI:
            log('  ignoring, not the target')
            continue
        reply = bytearray(300)
        reply[0] = 2; reply[1] = 1; reply[2] = 6
        reply[4:8] = xid
        reply[10:12] = data[10:12]
        reply[16:20] = socket.inet_aton(CLIENT_IP)
        reply[20:24] = socket.inet_aton(HOST)
        reply[28:44] = chaddr
        reply[44:44 + len(b'netboot')] = b'netboot'
        reply[108:108 + len(BOOTFILE)] = BOOTFILE
        reply[236:240] = b'\x63\x82\x53\x63'
        o = bytearray()
        if msgtype == 1:
            o += bytes([53, 1, 2])
        elif msgtype == 3:
            o += bytes([53, 1, 5])
        o += bytes([54, 4]) + socket.inet_aton(HOST)
        o += bytes([1, 4]) + socket.inet_aton('255.255.255.0')
        o += bytes([51, 4]) + struct.pack('>I', 3600)
        o += bytes([66, len(HOST)]) + HOST.encode()
        o += bytes([67, len(BOOTFILE)]) + BOOTFILE
        o += bytes([255])
        reply[240:240 + len(o)] = o
        s.sendto(bytes(reply), ('255.255.255.255', 68))
        log('  offered', CLIENT_IP, 'file', BOOTFILE.decode())

def tftp_transfer(peer, blksize):
    img = open(IMAGE, 'rb').read()
    t = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    t.bind((HOST, 0))
    t.settimeout(1.0)
    def send_wait(pkt, want_block):
        for attempt in range(8):
            t.sendto(pkt, peer)
            try:
                while True:
                    d, a = t.recvfrom(1024)
                    if a != peer:
                        continue
                    op = struct.unpack('>H', d[:2])[0]
                    if op == 4 and struct.unpack('>H', d[2:4])[0] == want_block & 0xFFFF:
                        return True
                    if op == 5:
                        log('  tftp error from client', d[4:].rstrip(b'\0'))
                        return False
            except socket.timeout:
                pass
        log('  tftp timeout at block', want_block)
        return False
    if blksize != 512:
        if not send_wait(struct.pack('>H', 6) + b'blksize\0' + str(blksize).encode() + b'\0', 0):
            return
    block = 1
    off = 0
    t0 = time.time()
    while True:
        chunk = img[off:off + blksize]
        if not send_wait(struct.pack('>HH', 3, block & 0xFFFF) + chunk, block):
            return
        off += len(chunk)
        if len(chunk) < blksize:
            break
        block += 1
    log('  tftp sent %d bytes in %.1fs to %s' % (off, time.time() - t0, peer))

def tftp():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((HOST, 69))
    log('tftp listening')
    while True:
        data, addr = s.recvfrom(2048)
        op = struct.unpack('>H', data[:2])[0]
        parts = data[2:].split(b'\0')
        log('tftp op', op, 'from', addr, parts[:-1])
        if op != 1:
            continue
        blksize = 512
        for k, v in zip(parts[2::2], parts[3::2]):
            if k.lower() == b'blksize' and v:
                blksize = min(int(v), 1468)
        threading.Thread(target=tftp_transfer, args=(addr, blksize), daemon=True).start()

TARGET_OUI = sys.argv[4].lower() if len(sys.argv) > 4 else ''
log('serving', IMAGE, os.path.getsize(IMAGE), 'bytes; target', TARGET_OUI or 'any')
threading.Thread(target=bootp, daemon=True).start()
tftp()
