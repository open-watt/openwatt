module protocol.ble.client;

import urt.endian;
import urt.lifetime;
import urt.log;
import urt.string;

import manager;
import manager.base;
import manager.collection;

import router.iface;
import router.iface.mac;
import router.iface.packet;

import protocol.ble.iface;

nothrow @nogc:


class BLEClient : BaseObject
{
    __gshared Property[2] Properties = [ Property.create!("interface", iface)(),
                                         Property.create!("peer", peer)() ];
nothrow @nogc:

    enum type_name = "ble-client";
    enum collection_id = CollectionType.ble_client;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!BLEClient, id, flags);
    }

    // Properties

    inout(BaseInterface) iface() inout pure
        => _iface;
    void iface(BaseInterface value)
    {
        if (_iface is value)
            return;
        if (_subscribed)
        {
            _iface.unsubscribe(&incoming_packet);
            _iface.unsubscribe(&iface_state_change);
            _subscribed = false;
        }
        _iface = value;
        restart();
    }

    MACAddress peer() const pure
        => _peer;
    void peer(MACAddress value)
    {
        if (_peer == value)
            return;
        _peer = value;
        restart();
    }

    // API

    void read_characteristic(ushort handle)
    {
        if (!_connected || !_iface)
            return;

        import urt.endian;
        ubyte[2] payload = handle.nativeToLittleEndian;

        Packet p;
        ref att = p.init!BLEATTFrame(payload[]);
        att.src = local_mac;
        att.dst = _peer;
        att.opcode = ATTOpcode.read_req;
        _iface.forward(p);
    }

protected:

    override bool validate() const
        => _iface !is null && cast(bool)_peer;

    override CompletionStatus startup()
    {
        if (!_iface || !_iface.running)
            return CompletionStatus.continue_;

        if (!_subscribed)
        {
            PacketFilter filter;
            filter.type = PacketType.unknown; // accept all BLE packet types
            _iface.subscribe(&incoming_packet, filter);
            _iface.subscribe(&iface_state_change);
            _subscribed = true;
        }
        if (_connect_handle >= 0)
            return CompletionStatus.continue_;
        if (_connected)
            return CompletionStatus.complete;

        // send connect_ind to the interface
        Packet p;
        ref ll = p.init!BLELLFrame(null);
        ll.src = local_mac;
        ll.dst = _peer;
        ll.pdu_type = BLELLType.connect_ind;

        _connect_handle = _iface.forward(p, &on_connect_complete);

        if (_connect_handle < 0)
        {
            log.error("failed to submit connect request");
            return CompletionStatus.error;
        }

        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        if (_connect_handle >= 0)
        {
            _iface.abort(_connect_handle);
            _connect_handle = -1;
        }

        if (_connected)
        {
            // send disconnect to the interface
            Packet p;
            ref ll = p.init!BLELLFrame(null);
            ll.src = local_mac;
            ll.dst = _peer;
            ll.pdu_type = BLELLType.disconnect_ind;
            _iface.forward(p);
            _connected = false;
        }

        if (_subscribed)
        {
            _iface.unsubscribe(&incoming_packet);
            _iface.unsubscribe(&iface_state_change);
            _subscribed = false;
        }

        return CompletionStatus.complete;
    }

    override void update()
    {
    }

private:
    ObjectRef!BaseInterface _iface;
    MACAddress _peer;
    MACAddress _local_mac;
    int _connect_handle = -1;
    bool _subscribed;
    bool _connected;

    MACAddress local_mac()
    {
        if (!_local_mac)
        {
            import urt.crc;
            uint crc = name[].calculate_crc!(Algorithm.crc32_iso_hdlc);
            _local_mac = MACAddress(0x02, 0x13, 0x37, crc & 0xFF, (crc >> 8) & 0xFF, (crc >> 16) & 0xFF);
        }
        return _local_mac;
    }

    void on_connect_complete(int handle, MessageState state)
    {
        if (state < MessageState.complete)
            return;

        _connect_handle = -1;

        if (state == MessageState.complete)
        {
            _connected = true;
            log.info("connected to ", _peer);
        }
        else
        {
            log.error("connection to ", _peer, " failed");
            restart();
        }
    }

    void incoming_packet(ref const Packet p, BaseInterface i, PacketDirection dir, void* user_data)
    {
        if (p.type == PacketType.ble_ll)
        {
            ref ll = p.hdr!BLELLFrame;
            if (ll.dst != local_mac)
                return;

            if (ll.pdu_type == BLELLType.disconnect_ind)
            {
                _connected = false;
                log.info("disconnected from ", _peer);
                restart();
            }
            else if (ll.pdu_type == BLELLType.data_start || ll.pdu_type == BLELLType.data_continue)
                assert(false, "TODO: LL data PDU defragmentation not implemented in BLEClient");
        }
        else if (p.type == PacketType.ble_att)
        {
            ref att = p.hdr!BLEATTFrame;
            if (att.dst != local_mac)
                return;

            const(ubyte)[] payload = cast(const(ubyte)[])p.data;

            switch (att.opcode)
            {
                case ATTOpcode.read_rsp:
                    log.info("read_rsp: [ ", cast(void[])payload, " ]");
                    break;

                case ATTOpcode.notification:
                    if (payload.length >= 2)
                        log.infof("notification handle={0,04x}: [{1}]",
                            payload.ptr[0..2].littleEndianToNative!ushort,
                            cast(void[])(payload.length > 2 ? payload[2 .. $] : null));
                    break;

                case ATTOpcode.write_rsp:
                    log.info("write_rsp");
                    break;

                default:
                    break;
            }
        }
    }


    void iface_state_change(BaseObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }
}
