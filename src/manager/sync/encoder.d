module manager.sync.encoder;

// SyncEncoder - abstract interface for per-encoding serialization.
//
// Two concrete implementations planned:
//   - JsonEncoder   (text frames, operator/browser-facing, self-describing)
//   - BinaryEncoder (packed binary, BL808 D0/M0 shmem ring, throughput-critical)
//
// Encoders are singletons at module scope - no collection, no lifecycle, no
// configurable state. A SyncPeer references one via a `SyncEncoderKind` enum
// property; `encoder_for(kind)` resolves to the singleton instance.
//
// Outbound: router calls encode_* for events; tick_dirty runs per-peer per-tick
// for the property fast path.
// Inbound: peer hands received bytes to decode_and_dispatch, which reads the
// kind tag, decodes fields, and calls the matching inbound_* free function in
// manager.sync (the SyncModule namespace).

import urt.log;
import urt.meta.enuminfo : VoidEnumInfo;
import urt.string;
import urt.variant;

import manager.base;
import manager.collection : CID;
import manager.element : Element;
import manager.expression : NamedArgument;
import manager.record : Sample;
import manager.series : DataFormat, RecordBlock, ValueType;
import manager.sync.peer;


nothrow @nogc:


// Selector used on SyncPeer properties + CLI. Resolves to the singleton
// SyncEncoder via `encoder_for(kind)`. Kept as a plain enum so CLI args
// parse as strings (`encoder=json`) and property state stays compact.
enum SyncEncoderKind : ubyte
{
    json,
    binary,
}

enum uint model_protocol_version = 1;
enum uint max_frame_size = 65_536;

// Set at SyncModule.init() once singleton encoders exist.
__gshared SyncEncoder[SyncEncoderKind.max + 1] g_encoders;

pragma(inline, true)
SyncEncoder encoder_for(SyncEncoderKind kind) nothrow @nogc
    => g_encoders[kind];


// Decoded `type` form-1 payload: strings straight off the wire, resolved to a
// local DataFormat by the module (enum names resolve against pushed dictionaries).
struct WireFormat
{
    const(char)[] type;
    const(char)[] series;
    const(char)[] unit;
    const(char)[] enum_name;
    Variant min;
    Variant max;
    Variant step;
    uint rate;
    ubyte count = 1;
}

const(char)[] value_type_name(ValueType t) pure
{
    final switch (t) with (ValueType)
    {
        case bool_: return "bool";
        case u8:    return "u8";
        case s8:    return "s8";
        case u16:   return "u16";
        case s16:   return "s16";
        case u32:   return "u32";
        case s32:   return "s32";
        case u64:   return "u64";
        case s64:   return "s64";
        case f32:   return "f32";
        case f64:   return "f64";
        case char_: return "char";
        case user:  return "user";
    }
}

bool value_type_from_name(const(char)[] s, out ValueType t)
{
    static foreach (m; __traits(allMembers, ValueType))
    {
        if (s[] == value_type_name(__traits(getMember, ValueType, m))[])
        {
            t = __traits(getMember, ValueType, m);
            return true;
        }
    }
    return false;
}

bool wire_serialisable(ref const DataFormat f) pure
    => f.clock is null && (f.type != ValueType.user || f.user_type.variant !is null);

// Reset frames carry no value - the contract is that the receiver knows the
// init value from the type's properties. This assert proves the contract holds
// at the moment we omit the value: the local prop value at emit time must
// equal what init_val() reports. Divergence here would silently desync mirrors.
debug void assert_reset_matches_init(BaseObject obj, ref const Property p) nothrow @nogc
{
    if (!p.get || !p.init_val)
        return;
    Variant cur = p.get(obj, p);
    Variant iv = p.init_val();
    assert(cur == iv, "encode_reset: prop value diverges from init_val - receiver assumes init");
}


abstract class SyncEncoder
{
nothrow @nogc:

    alias log = Log!"sync.encoder";

    // Registry (identity)
    //
    // Introduces an object to the peer: binds our session handle to its (name, type)
    // and announces all three. Local ids never travel - every other verb cites the
    // object by the session handle this established. Handle values stay small and
    // dense, so the binary encoder can varint them.

    abstract void encode_add_name(SyncPeer peer, BaseObject obj);

    // Mirror protocol - object lifecycle

    // Encoder walks obj.properties() and reads each via p.get while
    // encoding. No pre-extracted prop list is passed in.
    abstract void encode_bind(SyncPeer peer, BaseObject obj, uint seq);
    abstract void encode_unbind(SyncPeer peer, CID target, uint seq);

    // Request the peer create an authoritative object of this type. `props`
    // carries the full initial state - name is one of the properties -
    // because object construction is atomic with validation; if any setter
    // fails the object is torn down. Creating then separately setting would
    // expose the object in a transiently-invalid state.
    abstract void encode_create(SyncPeer peer, const(char)[] type, NamedArgument[] props, uint seq);
    abstract void encode_destroy(SyncPeer peer, CID target, uint seq);

    // Mirror protocol - state + property

    abstract void encode_state(SyncPeer peer, CID target, StateSignal sig);

    // Single-property update. For the fast path (dirty flush batched per object)
    // the encoder composes its own frame shape inside tick_dirty; these are the
    // per-event shape used for correlated echoes and request responses.
    abstract void encode_set(SyncPeer peer, BaseObject obj, size_t prop_index, uint seq);

    // Forwarding variant - used when we're a mid-hub relaying a set to the
    // authoritative peer. We don't apply locally (authority might reject), so
    // the value has to travel as an explicit Variant rather than being read
    // from a local obj.
    abstract void encode_set(SyncPeer peer, CID target, const(char)[] prop_name, ref const Variant value, uint seq);

    abstract void encode_reset(SyncPeer peer, CID target, const(char)[] prop_name, uint seq);

    // Commands + errors + enum schema

    abstract void encode_cmd(SyncPeer peer, uint seq, const(char)[] text);
    abstract void encode_result(SyncPeer peer, uint seq, ref const Variant value, const(char)[] out_text);
    abstract void encode_error(SyncPeer peer, uint seq, const(char)[] text);

    // Completion request for a partial command line; answered synchronously with
    // the candidate tokens plus the line extended by their common prefix.
    abstract void encode_suggest(SyncPeer peer, uint seq, const(char)[] text);
    abstract void encode_suggestions(SyncPeer peer, uint seq, const(String)[] suggestions, const(char)[] completed);

    abstract void encode_sub(SyncPeer peer, const(char)[] pattern);
    abstract void encode_unsub(SyncPeer peer, const(char)[] pattern);

    abstract void encode_enum_req(SyncPeer peer, const(char)[] type_name, uint seq);
    abstract void encode_enum(SyncPeer peer, const(char)[] type_name, ref const Variant members, uint seq);

    // Element history recall (record streams). Times are unix milliseconds
    // on the wire; samples are (time, value) pairs.

    abstract void encode_history_req(SyncPeer peer, const(char)[] path, ulong from_ms, ulong to_ms, uint max_points, uint seq);
    abstract void encode_history(SyncPeer peer, uint seq, const(char)[] path, const(Sample)[] samples);

    abstract void encode_log_sub(SyncPeer peer, Severity max_severity, bool off, const(char)[] tag);
    abstract bool encode_log(SyncPeer peer, const(char)[] line);

    // Time sync (clock discipline over the channel)
    //
    // Pull: a remote sends time_req to its authority and stashes its own send
    // time keyed by seq; the authority answers time_resp with its receive and
    // transmit wall times (unix ns) plus its current timebase version. Push:
    // when the authority's clock steps it sends time_push carrying the new
    // version and the signed delta - latency-independent, so no round trip.

    abstract void encode_time_req(SyncPeer peer, uint seq);
    abstract void encode_time_resp(SyncPeer peer, uint seq, ulong recv_ns, ulong xmit_ns, uint ver);
    abstract void encode_time_push(SyncPeer peer, uint ver, long delta_ns);

    // Model plane (data-model space): hello negotiation, push-only schema
    // interning, node introduction and value feed. Handle resolution and
    // interning decisions stay on the peer; encoders only serialize.

    abstract void encode_hello(SyncPeer peer);

    abstract void encode_model_sub(SyncPeer peer, uint seq, const(char[])[] patterns, bool once);

    // form 1: intern a format under a session ft id
    abstract void encode_type_format(SyncPeer peer, uint ft, ref const DataFormat fmt);
    // form 2: a named type's dictionary, pushed before the first format that cites it
    abstract void encode_type_enum(SyncPeer peer, const(char)[] name, const(VoidEnumInfo)* info);

    // e is null for container nodes (class "device"); ft cites a session format id
    abstract void encode_add(SyncPeer peer, SyncHandle h, const(char)[] path, const(char)[] node_class, uint ft, Element* e);

    abstract void encode_val(SyncPeer peer, SyncHandle h, Element* e);
    abstract void encode_val_block(SyncPeer peer, SyncHandle h, ref const RecordBlock blk);

    abstract void encode_res(SyncPeer peer, uint seq);
    abstract void encode_res(SyncPeer peer, uint seq, ref const Variant value);
    abstract void encode_err(SyncPeer peer, uint seq, const(char)[] code, const(char)[] text);

    // Inbound entry point
    //
    // One frame at a time. Reads the kind tag, decodes the frame, and calls
    // the matching inbound_* in manager.sync - which operates on SyncModule
    // state. For bind/create frames, the encoder's decode loop emits a bind
    // (or create) call followed by zero or more set calls, one per prop.
    //
    // No intermediate SyncMessage / SyncEvent struct. No PropReader.
    //
    // Returns false only when the frame cites state that hasn't arrived yet
    // (a val racing its add); an armed sublayer withholds the ack so the
    // sender's catch-up resupplies it. Malformed frames return true: they
    // will never become applicable.

    abstract bool decode_and_dispatch(SyncPeer peer, const(ubyte)[] frame);

    // Per-peer per-tick property flush
    //
    // Walks peer._bound; for each object with props_dirty != 0, emits one or
    // more frames carrying the dirty property values. Frame shape is fully the
    // encoder's choice - per-property for JSON readability, packed per-object
    // for binary efficiency.
    //
    // Clears the dirty bits on emit.

    abstract void tick_dirty(SyncPeer peer);
}
