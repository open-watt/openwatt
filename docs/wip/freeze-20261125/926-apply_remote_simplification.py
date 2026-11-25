from pathlib import Path
p=Path('D:/tmp/ow-926-dead-source-20261125/src/manager/sync/peer.d')
s=p.read_text()
for a,b in [('=> uses_rdp ? _remote : InetAddress();','=> _remote;'),('_udp.frame_room(_remote)','_udp.frame_room(_udp.remote)'),('_udp.tx_ready(_remote)','_udp.tx_ready(_udp.remote)'),('_udp.wait_tx(_remote, _tx_waiter)','_udp.wait_tx(_udp.remote, _tx_waiter)'),('_udp.egress_iface(_remote)','_udp.egress_iface(_udp.remote)'),('stale.egress_iface(orphan._remote)','stale.egress_iface(stale.remote)'),('        _remote = link;\n',''),('    InetAddress             _remote;','    version (HasRDP)\n        InetAddress         _remote;')]:
 assert s.count(a)==1,(a,s.count(a));s=s.replace(a,b)
p.write_text(s)
