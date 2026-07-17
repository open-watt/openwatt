module manager.id;

// ===========================================================================================
// ID STRATEGY (settled 2026-07-15) - migration pending, see TODO.md "ID strategy migration"
// ===========================================================================================
//
// Identity is the NAME. Ids are permanent, monotonic, process-local handles: never derived by
// hashing a name, never persisted, never sent on the wire. The hash-based scheme below
// (fnv1a ids + rehash chains + rekey repair) is to be deleted and replaced with:
//
// Ids are TWO-LEVEL: EID = (container id, element index). The container level is ONE id space
// with per-type tables (the CID type bits): collection objects and Devices are both registered
// types in it, but only collection types carry BaseObject machinery - a Device is NOT a
// BaseObject (no state machine; passive container materialized by bindings) and the ad-hoc
// g_app.devices Map dissolves into the device type's table. The data plane shards per
// container. Element index 0 may denote the container itself, unifying object refs and element
// refs into one type. Packed 64-bit in RAM (acceptable: ids never persist and never wire).
//
//   container level: collection tables map name -> CID -> object; a rename touches ONE name
//                    entry - children resolve by composition, so device rename is O(1) and
//                    full element paths are never stored or interned
//   element level:   each container owns a dense element-index table, one tagged word per index
//                      bound   -> Element*   the index is bound to a live element
//                      dormant -> null       parked, waiting for a claimant
//                      forward -> index      permanent alias of another index (write-once)
//                    relative paths resolve through the component tree
//   hard-wired indices: property projections COMPUTE their EID as (obj CID, Prop! index) - a
//                    compile-time literal index, no lookup, no cache; profile elements take
//                    their template index, deterministic per profile version
//
// Lifecycle:
//   - first mention of a name (a forward reference) parks a fresh id on the name
//   - creation at a name claims the parked id as the object's primary
//   - rename moves the OBJECT between name entries; ids do not move, so every held ref follows
//     the object for free; the old name becomes an empty tombstone
//   - rename onto a name holding parked id J: the claimant keeps its primary I and writes
//     J = forward(I); both the followers and the waiters now reach the object
//   - death parks the primary on the object's final name; refs deref to null
//   - the next object created at that name claims the parked id and every ref resurrects
//   - the machine instantiates at BOTH levels: container ids park on collection names, element
//     indices park within their container's table; a forward reference under an absent container
//     reserves the container id plus a stub element table, and each level claims independently
//
// Invariants:
//   - every name resolves to at most one live object; every object has exactly one live name
//     and one primary id
//   - a forward slot is write-once: a forwarded id can never re-bind or park, so forwarding is
//     permanent, transitive, immutable
//   - no operation ever rewrites an id held in a ref. deref follows forward chains (they can
//     grow through park-then-claim-by-rename cycles) and holders self-heal by writing the
//     terminal id back through their own field - lossless at any time, from any thread
//   - ids are not reclaimed in v1; a forward costs one immortal word
//
// Costs: deref is an array index plus forward hops until healed; rename, death, claim and
// forward are each O(1) single-word writes. No broadcasts, no lists, no allocation, and no
// collision concept (string hashing is internal to the name map).
//
// Reclamation (designed-for extension; unbounded DISTINCT NAMES are the exhaustion vector -
// renames alone mint nothing, and empty tombstones are deleted eagerly): id slots carry a
// count of durable holders (RAII wrapper for struct fields; hoisted locals are uncounted
// borrows, safe because release defers to the frame boundary). Release at zero holders; zero
// makes freelist reuse ABA-safe with no generation tags. Self-healing drains forwards to zero
// through ordinary use, so rename-merge forwards self-collect. Name entries and their strings
// (refcounted String, not the append-only intern table) release when no object, no parked id,
// no holders. Nothing observable changes, so v1 ships without it; add when churn metrics
// (id high-watermark in sysinfo) justify.
//
// CID is not merely unified with EID - it IS the EID's container level (type bits kept, slot
// as a dense per-type index). The wire shares none of this: peers exchange names once per
// session and bind session-local varint handles (introducer allocates, parity bit for
// direction, never reused); config and containers persist names only.
//
// Migration (execution order settled 2026-07-17; container level lands BEFORE element level:
// EIDs embed the CID, so durable element refs are worthless until CIDs stop rekeying):
//   0. ids off the wire: sync exchanges names once per session and binds varint session
//      handles (introducer allocates, parity bit per direction, never reused). Sync today
//      ships raw CIDs and leans on cross-peer hash agreement, so this lands FIRST - it turns
//      the id cutover from a protocol+internals event into a pure internal refactor
//   1. the park/claim/forward machine as a standalone unit-tested component. Per-type id
//      tables are DENSE ARRAYS indexed by slot - one tagged word each (bound/dormant/forward),
//      allocator is next_slot++, no binary search, no collision concept; name -> id (where
//      parking lives) is a separate string map touched only on lookup/create/rename/death.
//      insert() is the claim state machine (absent -> reserve/new, parked/tombstone -> claim,
//      live -> duplicate error)
//   2. container cutover: CollectionTable becomes the container level of the scheme (sorted
//      entries, binary search and rehash chains die); delete rehash(), rekey(), do_rekey(),
//      broadcast_rekey() and rekey_field() - rename-following becomes intrinsic instead of
//      repaired; hash_id survives only inside the name maps' string hashing. Then Devices
//      register as a container type and the ad-hoc g_app.devices Map dissolves
//   3. element level: per-container element-index tables owned by their containers; element
//      destruction parks the primary index instead of nulling in place; full-path interning
//      stays deleted (legacy ElementTable + hash-EIDs already removed from element.d);
//      Cursor trades its Element2* for an EID
//   4. ObjectRef and element refs converge on one EID ref type (element index 0 = the container
//      itself), deref via a shared follow-forwards + self-heal helper
//   5. audit holders: no persisted ids, no wire ids, no blind hashing - every id enters a
//      holder through the table (property projections excepted: (obj CID, Prop! index) is
//      computed, which is safe because both components are table-issued identities)
// ===========================================================================================

import urt.array;
import urt.map;
import urt.mem.allocator : defaultAllocator;
import urt.string.string;

import manager.collection : CID;

nothrow @nogc:


struct ID(uint _type_bits)
{
    alias This = typeof(this);

    uint raw;

    enum This invalid = This(0);

    bool opCast(T : bool)() const pure
        => raw != 0;

    bool opEquals(This rhs) const pure
        => raw == rhs.raw;

    ptrdiff_t opCmp(This rhs) const pure
    {
        static if (ptrdiff_t.sizeof > 4)
            return cast(ptrdiff_t)raw - cast(ptrdiff_t)rhs.raw;
        else
            return (raw > rhs.raw) - (raw < rhs.raw);
    }

    size_t toHash() const pure
        => raw;

    static if (_type_bits > 0)
    {
        enum uint type_bits = _type_bits;
        enum uint id_bits = 32 - _type_bits;
        enum uint id_mask = (1u << id_bits) - 1;

        uint type_index() const pure
            => raw >> id_bits;

        // the two-level EID (strategy above): this container id + an element index
        EID element(ushort index) const pure
            => EID(this, index);

        uint slot() const pure
            => raw & id_mask;
    }
}

// The two-level element id from the strategy above: container CID in the low 32 bits, element
// index above it, top 16 bits spare. Element index 0 denotes the container itself, so object
// refs and element refs converge on one type. The resolution tables land with the migration;
// the handle's shape is settled now. Never persisted, never on the wire.
struct EID
{
nothrow @nogc:

    ulong raw;

    enum EID invalid = EID();

    this(CID container, ushort index = 0) pure
    {
        raw = container.raw | (ulong(index) << 32);
    }

    CID container() const pure
        => CID(cast(uint)raw);

    ushort index() const pure
        => cast(ushort)(raw >> 32);

    bool opCast(T : bool)() const pure
        => raw != 0;

    bool opEquals(EID rhs) const pure
        => raw == rhs.raw;

    size_t toHash() const pure
        => cast(size_t)(raw ^ (raw >> 32));
}

// The park/claim/forward machine (migration step 1). One instantiation per id space: the
// container level is per-type tables over BaseObject; each container's element-index table is
// the same machine over its element type. Slots are dense and immortal (v1: no reclamation),
// one tagged word each:
//     0              dormant - parked on a name, waiting for a claimant
//     T   (bit0 = 0) bound to a live object
//     fwd (bit0 = 1) permanent forward to slot (word >> 1), write-once
// Names are a separate map, touched only on lookup/create/rename/death. A name entry always
// holds a terminal (never forwarded) id: rename-merge rewrites the entry to the claimant's
// primary at the moment it writes the forward.
struct IdMachine(T) if (is(T == class) || is(T == U*, U))
{
nothrow @nogc:

    // park a fresh id on the name (forward reference), or return whatever it already holds
    uint reserve(const(char)[] name)
    {
        if (uint* p = name in _names)
            return *p;
        return mint(name);
    }

    // create at a name: absent mints, parked claims, live is a duplicate (returns 0)
    uint claim(const(char)[] name, T obj)
    {
        debug assert(obj !is null);
        if (uint* p = name in _names)
        {
            uint id = *p;
            size_t w = _slots[][id];
            debug assert(!(w & 1), "name entry holds a forwarded id");
            if (w)
                return 0;
            _slots[][id] = cast(size_t)cast(void*)obj;
            return id;
        }
        uint id = mint(name);
        _slots[][id] = cast(size_t)cast(void*)obj;
        return id;
    }

    // bind an object to a reserved id: the claim's second half when reserve and creation are
    // separate steps (collections allocate the id before the object constructs with it)
    void bind(uint id, T obj)
    {
        debug assert(obj !is null);
        debug assert(id && id < _slots.length && _slots[][id] == 0, "bind to a live or forwarded id");
        _slots[][id] = cast(size_t)cast(void*)obj;
    }

    // move the object between name entries; ids don't move, so every held ref follows for
    // free. renaming onto a parked name forwards the waiter's id to the primary; onto a live
    // name fails. the old entry becomes an empty tombstone, deleted eagerly.
    bool rename(uint id, const(char)[] old_name, const(char)[] new_name)
    {
        if (uint* p = new_name in _names)
        {
            uint j = *p;
            if (j != id)
            {
                size_t w = _slots[][j];
                debug assert(!(w & 1), "name entry holds a forwarded id");
                if (w)
                    return false;
                _slots[][j] = (size_t(id) << 1) | 1;
                *p = id;
            }
            _slot_names[][id] = _slot_names[][j];
        }
        else
        {
            String s = new_name.makeString(defaultAllocator);
            _slot_names[][id] = s;
            _names.insert(s.move, id);
        }
        if (old_name[] != new_name[])
            _names.remove(old_name);
        return true;
    }

    // death parks the primary on the object's final name; refs deref null until the next
    // object created at that name claims it
    void release(uint id)
    {
        debug assert(id && id < _slots.length && !(_slots[][id] & 1), "release of invalid or forwarded id");
        _slots[][id] = 0;
    }

    // follow forwards to the terminal slot, healing the held id in place
    T deref(ref uint id)
    {
        uint i = id;
        if (!i || i >= _slots.length)
            return null;
        size_t w = _slots[][i];
        while (w & 1)
        {
            i = cast(uint)(w >> 1);
            w = _slots[][i];
        }
        if (i != id)
            id = i;
        return cast(T)cast(void*)w;
    }

    // follow forwards without healing (const contexts)
    inout(T) get(uint id) inout pure
    {
        if (!id || id >= _slots.length)
            return null;
        size_t w = _slots[][id];
        while (w & 1)
            w = _slots[][w >> 1];
        return cast(inout(T))cast(void*)w;
    }

    // raw slot accessor for dense iteration: dormant and forwarded slots yield null, so a
    // forwarded object is visited only at its terminal slot
    inout(T) at(uint id) inout pure
    {
        if (!id || id >= _slots.length)
            return null;
        size_t w = _slots[][id];
        return (w & 1) ? null : cast(inout(T))cast(void*)w;
    }

    uint find(const(char)[] name) const pure
    {
        const(uint)* p = name in _names;
        return p ? *p : 0;
    }

    // `in`-operator style: transient pointer to the bound ref, or null; invalidated by the
    // next mint (the slot array may move)
    T* lookup(const(char)[] name)
    {
        uint t = terminal(find(name));
        if (!t)
            return null;
        size_t* w = &_slots[][t];
        return (*w && !(*w & 1)) ? cast(T*)w : null;
    }

    // iterate bound objects in slot order
    auto values()
    {
        struct Range
        {
        nothrow @nogc:
            IdMachine* m;
            uint slot;
            bool empty() const pure => slot > m.slot_count;
            T front() pure => m.at(slot);
            void popFront() { ++slot; advance(); }
            private void advance() { while (slot <= m.slot_count && m.at(slot) is null) ++slot; }
        }
        auto r = Range(&this, 1);
        r.advance();
        return r;
    }

    // iterate the names of bound objects in slot order
    auto names()
    {
        struct Range
        {
        nothrow @nogc:
            IdMachine* m;
            uint slot;
            bool empty() const pure => slot > m.slot_count;
            String front() pure => m.name_string(slot);
            void popFront() { ++slot; advance(); }
            private void advance() { while (slot <= m.slot_count && m.at(slot) is null) ++slot; }
        }
        auto r = Range(&this, 1);
        r.advance();
        return r;
    }

    // the slot's name (terminal name for forwarded slots). the slice borrows the name entry's
    // storage: stable until that slot renames
    const(char)[] name_of(uint id) const pure
    {
        uint t = terminal(id);
        return t ? _slot_names[t][] : null;
    }

    String name_string(uint id) const pure
    {
        uint t = terminal(id);
        return t ? _slot_names[t] : String();
    }

    uint slot_count() const pure
    {
        uint n = cast(uint)_slots.length;
        return n ? n - 1 : 0;
    }

private:
    Array!size_t _slots;        // slot 0 reserved as the invalid id
    Array!String _slot_names;   // parallel: the slot's name entry (shared refcount with _names)
    Map!(String, uint) _names;

    uint mint(const(char)[] name)
    {
        if (_slots.empty)
        {
            _slots ~= 0;
            _slot_names ~= String();
        }
        uint id = cast(uint)_slots.length;
        _slots ~= 0;
        String s = name.makeString(defaultAllocator);
        _slot_names ~= s;
        _names.insert(s.move, id);
        return id;
    }

    uint terminal(uint id) const pure
    {
        if (!id || id >= _slots.length)
            return 0;
        size_t w = _slots[][id];
        while (w & 1)
        {
            id = cast(uint)(w >> 1);
            w = _slots[][id];
        }
        return id;
    }
}

// the element level of the id scheme: IdMachine's nameless twin - the component tree is
// the name map, so indices park positionally and rebind at the same mount. Index 0 denotes
// the container itself; slots start at 1.
struct IndexTable(T) if (is(T == class) || is(T == U*, U))
{
nothrow @nogc:

    ushort mint(T obj)
    {
        debug assert(obj !is null);
        if (_slots.empty)
            _slots ~= 0;
        debug assert(_slots.length <= ushort.max, "index space exhausted");
        ushort index = cast(ushort)_slots.length;
        _slots ~= cast(size_t)cast(void*)obj;
        return index;
    }

    void bind(ushort index, T obj)
    {
        debug assert(obj !is null);
        debug assert(index && index < _slots.length && _slots[][index] == 0, "bind to a live or forwarded index");
        _slots[][index] = cast(size_t)cast(void*)obj;
    }

    void release(ushort index)
    {
        debug assert(index && index < _slots.length && !(_slots[][index] & 1), "release of invalid or forwarded index");
        _slots[][index] = 0;
    }

    void forward(ushort from, ushort to)
    {
        debug assert(from && from < _slots.length && _slots[][from] == 0, "forward of a live or forwarded index");
        debug assert(to && to < _slots.length);
        _slots[][from] = (size_t(to) << 1) | 1;
    }

    T deref(ref ushort index)
    {
        ushort i = index;
        if (!i || i >= _slots.length)
            return null;
        size_t w = _slots[][i];
        while (w & 1)
        {
            i = cast(ushort)(w >> 1);
            w = _slots[][i];
        }
        if (i != index)
            index = i;
        return cast(T)cast(void*)w;
    }

    inout(T) get(ushort index) inout pure
    {
        if (!index || index >= _slots.length)
            return null;
        size_t w = _slots[][index];
        while (w & 1)
            w = _slots[][w >> 1];
        return cast(inout(T))cast(void*)w;
    }

    ushort index_count() const pure
    {
        uint n = cast(uint)_slots.length;
        return cast(ushort)(n ? n - 1 : 0);
    }

private:
    Array!size_t _slots;    // slot 0 reserved: index 0 denotes the container itself
}

unittest
{
    static struct Thing { int x; }
    Thing a, b, c;

    IdMachine!(Thing*) m;

    // forward reference parks; creation claims; the parked id resurrects
    uint held = m.reserve("motor");
    assert(held && m.deref(held) is null);
    assert(m.claim("motor", &a) == held);
    assert(m.deref(held) is &a);

    // creating at a live name is a duplicate error
    assert(m.claim("motor", &b) == 0);

    // rename: held ids follow the object with no repair; the old name dies
    assert(m.rename(held, "motor", "pump"));
    assert(m.deref(held) is &a);
    assert(m.find("motor") == 0 && m.find("pump") == held);

    // death parks on the final name; recreation rebinds every old ref
    m.release(held);
    assert(m.deref(held) is null);
    assert(m.claim("pump", &b) == held);
    assert(m.deref(held) is &b);

    // rename onto a parked name: the waiter's id forwards to the primary and self-heals
    uint waiter = m.reserve("valve");
    assert(waiter != held);
    assert(m.rename(held, "pump", "valve"));
    assert(m.deref(waiter) is &b);
    assert(waiter == held);
    assert(m.find("valve") == held);

    // rename onto a live name fails
    uint other = m.claim("fan", &c);
    assert(other != 0);
    assert(!m.rename(held, "valve", "fan"));

    // a forwarded slot never rebinds: creating at the merged name claims the primary
    m.release(held);
    assert(m.claim("valve", &a) == held);

    // forward chains survive park-then-claim-by-rename cycles and heal to the terminal
    uint chain = m.reserve("gate");
    assert(m.rename(held, "valve", "gate"));
    uint stale = waiter & ~0u;   // a copy that still holds the pre-merge id value
    assert(m.deref(stale) is &a && stale == held);
    assert(m.deref(chain) is &a && chain == held);

    // split reserve/bind (collections allocate the id before the object constructs)
    uint pre = m.reserve("relay");
    assert(m.deref(pre) is null);
    m.bind(pre, &c);
    assert(m.get(pre) is &c && m.at(pre) is &c);

    // name recovery: bound, parked, and forwarded slots all resolve; forwarded slots are
    // skipped by the raw iteration accessor
    assert(m.name_of(pre) == "relay");
    assert(m.name_string(held)[] == "gate");
    uint parked = m.reserve("spare");
    assert(m.name_of(parked) == "spare");
    assert(m.slot_count >= 6);

    // index table: the nameless element level; index 0 is the container itself
    IndexTable!(Thing*) it;
    ushort i1 = it.mint(&a);
    ushort i2 = it.mint(&b);
    assert(i1 == 1 && i2 == 2);
    assert(it.get(i1) is &a && it.get(i2) is &b);

    // release parks positionally; bind rebinds the same index
    it.release(i1);
    assert(it.get(i1) is null);
    it.bind(i1, &c);
    assert(it.get(i1) is &c);

    // forwards chase to the terminal and heal the held index
    it.release(i2);
    it.forward(i2, i1);
    ushort held_index = i2;
    assert(it.deref(held_index) is &c && held_index == i1);
    assert(it.get(i2) is &c);
    assert(it.index_count == 2);
}
