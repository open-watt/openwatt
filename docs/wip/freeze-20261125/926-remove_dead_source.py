from pathlib import Path
p=Path('D:/tmp/ow-926-dead-source-20261125/src/driver/bl808/xram.d')
s=p.read_text()
a='''    // A payload of up to max_length bytes to build in XRAM and send with tx_commit; null when the link has no
    // room, and tx_ready invites again once it does.
    final void[] tx_reserve(size_t max_length)
        => link_up ? xram_reserve(_channel, max_length) : null;

'''
b='''    final void tx_abandon()
    {
        xram_abandon(_channel);
    }

'''
assert s.count(a)==1 and s.count(b)==1
s=s.replace(a,'').replace(b,'')
p.write_text(s)
p=Path('D:/tmp/ow-926-dead-source-20261125/src/router/iface/endpoint.d')
s=p.read_text()
a='        if (!ep._link.open(ep, local, remote))';b='        if (!ep._link.open(local, remote))'
assert s.count(a)==1;s=s.replace(a,b)
a='        bool open(UDPEndpoint* owner, const(InetAddress)* local_address, const(InetAddress)* remote_address)'
b='        bool open(const(InetAddress)* local_address, const(InetAddress)* remote_address)'
assert s.count(a)==1;s=s.replace(a,b)
p.write_text(s)
