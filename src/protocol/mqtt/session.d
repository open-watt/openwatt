module protocol.mqtt.session;

import urt.array;
import urt.lifetime;
import urt.mem.allocator;
import urt.string;
import urt.time;

import protocol.mqtt.codec : ProtocolLevel;

nothrow @nogc:


// session_expiry_interval (MQTT v5): 0 = end at disconnect, 0xFFFFFFFF = never, else seconds-from-detach.
// v3.1.1: clean_session=1 maps to 0, clean_session=0 to never.
enum uint expiry_never = 0xFFFFFFFF;

struct SessionSubscription
{
    String filter;
    uint subscription_id;        // 0 = unset
    ubyte qos;
    bool no_local;
    bool retain_as_published;
    ubyte retain_handling;
}

enum OutboundState : ubyte
{
    awaiting_puback,             // QoS 1
    awaiting_pubrec,             // QoS 2
    awaiting_pubcomp,            // QoS 2, after PUBREL
}

struct OutboundMessage
{
    @disable this(this);

    ushort packet_id;
    OutboundState state;
    ubyte qos;
    bool retain;
    bool dup;                    // becomes true on resend after reconnect
    String topic;
    Array!ubyte payload;
    Array!ubyte properties;
}

// Inbound QoS 2 held between PUBREC and PUBREL; QoS 1 dispatches inline.
struct InboundMessage
{
    @disable this(this);

    ushort packet_id;
    ubyte flags;                 // raw fixed-header low nibble of the original PUBLISH
    String topic;
    Array!ubyte payload;
    Array!ubyte properties;
}

struct Will
{
    @disable this(this);

    bool present;
    bool sent;                   // becomes true after the broker publishes it
    ubyte qos;
    bool retain;
    uint delay_interval;         // v5; seconds before publish on abnormal disconnect
    String topic;
    Array!ubyte payload;
    Array!ubyte properties;
}

struct Session
{
nothrow @nogc:
    @disable this(this);

    this(String client_id, ProtocolLevel level)
    {
        this.client_id = client_id.move;
        this.protocol_level = level;
        this.next_packet_id = 1;
    }

    String client_id;
    ProtocolLevel protocol_level;

    uint expiry_interval = 0;
    MonoTime disconnect_time;     // valid only when connection is null

    // Opaque to keep session.d independent of connection.d; broker casts at the boundary.
    void* connection;

    Array!SessionSubscription subscriptions;
    Will will;
    Array!OutboundMessage pending_outbound;
    Array!InboundMessage pending_inbound;

    void attach(void* new_connection)
    {
        connection = new_connection;
    }

    void detach(MonoTime now)
    {
        connection = null;
        disconnect_time = now;
    }

    bool expired(MonoTime now) const
    {
        if (connection !is null)
            return false;
        if (expiry_interval == expiry_never)
            return false;
        if (expiry_interval == 0)
            return true;
        return now - disconnect_time >= expiry_interval.seconds;
    }

    // Allocates forward from next_packet_id, skipping any id still in pending_outbound. Packet ID 0 is reserved by the spec.
    ushort alloc_packet_id()
    {
        ushort start = next_packet_id;
        for (;;)
        {
            ushort candidate = next_packet_id;
            next_packet_id = (next_packet_id == 0xFFFF) ? cast(ushort)1 : cast(ushort)(next_packet_id + 1);

            bool taken = false;
            foreach (ref m; pending_outbound)
            {
                if (m.packet_id == candidate)
                {
                    taken = true;
                    break;
                }
            }
            if (!taken)
                return candidate;

            if (next_packet_id == start)
                return 0;       // 64k ids exhausted -- impossible under any sane workload
        }
    }

    // Returns true for a new entry, false for an upsert of an existing filter.
    bool record_subscription(String filter, ubyte qos, bool no_local, bool retain_as_published, ubyte retain_handling, uint subscription_id)
    {
        foreach (ref s; subscriptions)
        {
            if (s.filter[] == filter[])
            {
                s.qos = qos;
                s.no_local = no_local;
                s.retain_as_published = retain_as_published;
                s.retain_handling = retain_handling;
                s.subscription_id = subscription_id;
                return false;
            }
        }
        SessionSubscription* s = &subscriptions.pushBack();
        s.filter = filter.move;
        s.qos = qos;
        s.no_local = no_local;
        s.retain_as_published = retain_as_published;
        s.retain_handling = retain_handling;
        s.subscription_id = subscription_id;
        return true;
    }

    bool drop_subscription(const(char)[] filter)
    {
        for (size_t i = 0; i < subscriptions.length; ++i)
        {
            if (subscriptions[i].filter[] == filter)
            {
                subscriptions.remove(i);
                return true;
            }
        }
        return false;
    }

    OutboundMessage* find_outbound(ushort packet_id)
    {
        foreach (ref m; pending_outbound)
            if (m.packet_id == packet_id)
                return &m;
        return null;
    }

    bool remove_outbound(ushort packet_id)
    {
        for (size_t i = 0; i < pending_outbound.length; ++i)
        {
            if (pending_outbound[i].packet_id == packet_id)
            {
                pending_outbound.remove(i);
                return true;
            }
        }
        return false;
    }

    InboundMessage* find_inbound(ushort packet_id)
    {
        foreach (ref m; pending_inbound)
            if (m.packet_id == packet_id)
                return &m;
        return null;
    }

    bool remove_inbound(ushort packet_id)
    {
        for (size_t i = 0; i < pending_inbound.length; ++i)
        {
            if (pending_inbound[i].packet_id == packet_id)
            {
                pending_inbound.remove(i);
                return true;
            }
        }
        return false;
    }

    void reset()
    {
        subscriptions.clear();
        pending_outbound.clear();
        pending_inbound.clear();
        will = Will.init;
        expiry_interval = 0;
        next_packet_id = 1;
    }


private:
    ushort next_packet_id = 1;
}

unittest
{
    {
        // construction and basic identity
        Session s = Session(StringLit!"client-1", ProtocolLevel._5);
        assert(s.client_id[] == "client-1");
        assert(s.protocol_level == ProtocolLevel._5);
        assert(s.connection is null);
        assert(s.subscriptions.length == 0);
        assert(s.pending_outbound.length == 0);
        assert(s.pending_inbound.length == 0);
        assert(!s.will.present);
    }

    {
        // attach / detach / expiry
        Session s = Session(StringLit!"c", ProtocolLevel._5);

        int dummy_conn;
        s.attach(&dummy_conn);
        assert(s.connection is &dummy_conn);
        assert(!s.expired(getTime()));   // attached never expires

        MonoTime t = getTime();
        s.detach(t);
        assert(s.connection is null);

        s.expiry_interval = 0;
        assert(s.expired(t));

        s.expiry_interval = expiry_never;
        assert(!s.expired(t + 3_600_000.seconds));

        s.expiry_interval = 60;
        assert(!s.expired(t + 30.seconds));
        assert( s.expired(t + 60.seconds));
        assert( s.expired(t + 120.seconds));
    }

    {
        // packet-id allocator: monotonic, skips collisions, wraps past 65535
        Session s = Session(StringLit!"c", ProtocolLevel._5);

        ushort a = s.alloc_packet_id();
        ushort b = s.alloc_packet_id();
        ushort c = s.alloc_packet_id();
        assert(a == 1);
        assert(b == 2);
        assert(c == 3);

        OutboundMessage* m = &s.pending_outbound.pushBack();
        m.packet_id = 4;
        m.state = OutboundState.awaiting_puback;
        m.qos = 1;
        ushort d = s.alloc_packet_id();
        assert(d == 5);
    }

    {
        // record_subscription upserts by filter
        Session s = Session(StringLit!"c", ProtocolLevel._5);

        assert( s.record_subscription(StringLit!"a/b", 0, false, false, 0, 0));
        assert(!s.record_subscription(StringLit!"a/b", 2, true,  true,  1, 5));
        assert(s.subscriptions.length == 1);
        assert(s.subscriptions[0].qos == 2);
        assert(s.subscriptions[0].no_local);
        assert(s.subscriptions[0].retain_as_published);
        assert(s.subscriptions[0].retain_handling == 1);
        assert(s.subscriptions[0].subscription_id == 5);

        assert( s.record_subscription(StringLit!"c/+", 1, false, false, 0, 0));
        assert(s.subscriptions.length == 2);

        assert( s.drop_subscription("a/b"));
        assert(!s.drop_subscription("a/b"));
        assert(s.subscriptions.length == 1);
        assert(s.subscriptions[0].filter[] == "c/+");
    }

    {
        // pending outbound find/remove
        Session s = Session(StringLit!"c", ProtocolLevel._5);

        OutboundMessage* a = &s.pending_outbound.pushBack();
        a.packet_id = 10;
        a.state = OutboundState.awaiting_puback;
        a.qos = 1;

        OutboundMessage* b = &s.pending_outbound.pushBack();
        b.packet_id = 11;
        b.state = OutboundState.awaiting_pubrec;
        b.qos = 2;

        assert(s.find_outbound(10) !is null);
        assert(s.find_outbound(11) !is null);
        assert(s.find_outbound(99) is null);

        assert( s.remove_outbound(10));
        assert(!s.remove_outbound(10));
        assert(s.pending_outbound.length == 1);
        assert(s.pending_outbound[0].packet_id == 11);
    }

    {
        // pending inbound find/remove
        Session s = Session(StringLit!"c", ProtocolLevel._5);

        InboundMessage* a = &s.pending_inbound.pushBack();
        a.packet_id = 7;
        a.flags = 0x04;   // qos 2

        assert(s.find_inbound(7) !is null);
        assert(s.find_inbound(8) is null);
        assert( s.remove_inbound(7));
        assert(!s.remove_inbound(7));
        assert(s.pending_inbound.length == 0);
    }

    {
        // reset wipes per-connection state but retains identity
        Session s = Session(StringLit!"c", ProtocolLevel._5);
        s.expiry_interval = 60;
        s.will.present = true;
        s.record_subscription(StringLit!"a/b", 0, false, false, 0, 0);
        OutboundMessage* m = &s.pending_outbound.pushBack();
        m.packet_id = 1;
        InboundMessage* im = &s.pending_inbound.pushBack();
        im.packet_id = 2;

        s.reset();

        assert(s.client_id[] == "c");
        assert(s.protocol_level == ProtocolLevel._5);
        assert(s.expiry_interval == 0);
        assert(!s.will.present);
        assert(s.subscriptions.length == 0);
        assert(s.pending_outbound.length == 0);
        assert(s.pending_inbound.length == 0);
    }
}
