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
import urt.string;
import urt.variant;

import manager.base;
import manager.collection : CID;
import manager.expression : NamedArgument;
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

// Set at SyncModule.init() once singleton encoders exist.
__gshared SyncEncoder[SyncEncoderKind.max + 1] g_encoders;

pragma(inline, true)
SyncEncoder encoder_for(SyncEncoderKind kind) nothrow @nogc
    => g_encoders[kind];


// Reset frames carry no value - the contract is that the receiver knows the
// init value from the type's properties. This assert proves the contract holds
// at the moment we omit the value: the local prop value at emit time must
// equal what init_val() reports. Divergence here would silently desync mirrors.
debug void assert_reset_matches_init(BaseObject obj, ref const Property p) nothrow @nogc
{
    if (!p.get || !p.init_val)
        return;
    Variant cur = p.get(obj);
    Variant iv = p.init_val();
    assert(cur == iv,
        "encode_reset: prop value diverges from init_val - receiver assumes init");
}


abstract class SyncEncoder
{
nothrow @nogc:

    alias log = Log!"sync.encoder";

    // Registry (identity)

    abstract void encode_add_name(SyncPeer peer, CID cid, const(char)[] name);
    abstract void encode_rekey(SyncPeer peer, CID old_cid, CID new_cid);

    // Mirror protocol - object lifecycle

    // Encoder walks obj.properties() and reads each via p.get(obj) while
    // encoding. No pre-extracted prop list is passed in.
    abstract void encode_bind(SyncPeer peer, BaseObject obj, uint seq);
    abstract void encode_unbind(SyncPeer peer, CID target, uint seq);

    // Request the peer create an authoritative object of this type. `props`
    // carries the full initial state - name is one of the properties -
    // because object construction is atomic with validation; if any setter
    // fails the object is torn down. Creating then separately setting would
    // expose the object in a transiently-invalid state.
    abstract void encode_create(SyncPeer peer, const(char)[] type,
                                NamedArgument[] props, uint seq);
    abstract void encode_destroy(SyncPeer peer, CID target, uint seq);

    // Mirror protocol - state + property

    abstract void encode_state(SyncPeer peer, CID target, StateSignal sig);

    // Single-property update. For the fast path (dirty flush batched per object)
    // the encoder composes its own frame shape inside tick_dirty; these are the
    // per-event shape used for correlated echoes and request responses.
    abstract void encode_set(SyncPeer peer, BaseObject obj,
                             size_t prop_index, uint seq);

    // Forwarding variant - used when we're a mid-hub relaying a set to the
    // authoritative peer. We don't apply locally (authority might reject), so
    // the value has to travel as an explicit Variant rather than being read
    // from a local obj.
    abstract void encode_set(SyncPeer peer, CID target, const(char)[] prop_name,
                             ref const Variant value, uint seq);

    abstract void encode_reset(SyncPeer peer, CID target,
                               const(char)[] prop_name, uint seq);

    // Commands + errors + enum schema

    abstract void encode_cmd(SyncPeer peer, uint seq, const(char)[] text);
    abstract void encode_result(SyncPeer peer, uint seq,
                                ref const Variant value, const(char)[] out_text);
    abstract void encode_error(SyncPeer peer, uint seq, const(char)[] text);

    abstract void encode_sub(SyncPeer peer, const(char)[] pattern);
    abstract void encode_unsub(SyncPeer peer, const(char)[] pattern);

    abstract void encode_enum_req(SyncPeer peer, const(char)[] type_name, uint seq);
    abstract void encode_enum(SyncPeer peer, const(char)[] type_name,
                              ref const Variant members, uint seq);

    // Inbound entry point
    //
    // One frame at a time. Reads the kind tag, decodes the frame, and calls
    // the matching inbound_* in manager.sync - which operates on SyncModule
    // state. For bind/create frames, the encoder's decode loop emits a bind
    // (or create) call followed by zero or more set calls, one per prop.
    //
    // No intermediate SyncMessage / SyncEvent struct. No PropReader.

    abstract void decode_and_dispatch(SyncPeer peer, const(ubyte)[] frame);

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
