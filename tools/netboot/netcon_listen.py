# Prints the MT7621 netconsole: UDP broadcasts to port 6666.
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', 6666))
print(time.strftime('%H:%M:%S'), 'listening', flush=True)
while True:
    d, a = s.recvfrom(4096)
    print(time.strftime('%H:%M:%S'), a[0], d.decode('latin-1').rstrip('\r\n'), flush=True)
