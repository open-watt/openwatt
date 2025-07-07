module devices.goodwe.scanner;

// implement a network scanner for goodwe devices...

/+

GOODWE scanning works like this:

  - broadcast "WIFIKIT-214028-READ" on UDP port 48899
  - devices respond like this:
     "192.168.3.4,289C6E05B350,Solar-WiFi22CW0007"

{
    UDPStream udp = new UDPStream(48899, options: StreamOptions.AllowBroadcast);
    udp.connect();

    udp.write("WIFIKIT-214028-READ");
    ubyte[1024] buffer;
    udp.read(buffer);
    udp.read(buffer);
    udp.read(buffer);
    udp.read(buffer);
    udp.read(buffer);
    udp.read(buffer);
    udp.read(buffer);
}


Maybe we need to probe those devices for appropriate protocol?
   - SBP-G2 seems to allow AA55 protocol on 8899, and also RTU direct to 8899 by UDP

+/
