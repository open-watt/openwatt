from pathlib import Path
p=Path('D:/tmp/ow-926-dead-source-20261125/src/manager/sync/peer.d');s=p.read_text()
a='    assert(peer.open_link());\n\n    // a destroyed transport'
assert s.count(a)==1;s=s.replace(a,'    assert(peer.open_link());\n    static if (has_rdp)\n        assert(peer.remote == InetAddress(), "link addressing does not replace remote configuration");\n\n    // a destroyed transport')
a='        far.bind_rdp_session(wire.b, wire.addr_a);\n'
assert s.count(a)==1;s=s.replace(a,a+'        assert(near.remote == wire.addr_b && far.remote == wire.addr_a);\n')
p.write_text(s)
