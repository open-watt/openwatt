module apps.energy.link;

import urt.lifetime;
import urt.meta : AliasSeq;
import urt.string;

import apps.energy.model;
import apps.energy.reference;

import manager;
import manager.base;
import manager.collection;
import manager.component;

nothrow @nogc:


// Installed inline topology: breakers, contactors, meters, grid links, and
// other infrastructure that connects circuits without being protocol-bound.
class EnergyLink : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("kind", kind),
                                 Prop!("parent", parent_circuit),
                                 Prop!("child", child_circuit),
                                 Prop!("circuit", circuit),
                                 Prop!("capacity", capacity),
                                 Prop!("closed", closed),
                                 Prop!("meter-phase", meter_phase),
                                 Prop!("meter-sign", meter_sign),
                                 Prop!("meter", meter));
nothrow @nogc:

    enum type_name = "link";
    enum path = "/apps/energy/link";
    enum collection_id = CollectionType.link;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!EnergyLink, id, flags);
        _closed = true;
    }

    const(char)[] kind() const pure
    {
        if (_kind.length != 0)
            return _kind[];
        if (_capacity != 0)
            return "breaker";
        if (_meter_path.length != 0)
            return "meter";
        return null;
    }
    void kind(const(char)[] value)
    {
        if (_kind[] == value)
            return;
        _kind = value.makeString(g_app.allocator);
        restart();
    }

    const(char)[] parent_circuit() const pure { return _parent_circuit[]; }
    void parent_circuit(const(char)[] value)
    {
        if (_parent_circuit[] == value)
            return;
        _parent_circuit = value.makeString(g_app.allocator);
        restart();
    }

    const(char)[] child_circuit() const pure { return _child_circuit[]; }
    void child_circuit(const(char)[] value)
    {
        if (_child_circuit[] == value)
            return;
        _child_circuit = value.makeString(g_app.allocator);
        restart();
    }

    const(char)[] circuit() const pure { return _circuit[]; }
    void circuit(const(char)[] value)
    {
        if (_circuit[] == value)
            return;
        _circuit = value.makeString(g_app.allocator);
        restart();
    }

    uint capacity() const pure { return _capacity; }
    void capacity(uint value)
    {
        if (_capacity == value)
            return;
        _capacity = value;
        restart();
    }

    bool closed() const pure { return _closed; }
    void closed(bool value)
    {
        if (_closed == value)
            return;
        _closed = value;
        restart();
    }

    ubyte meter_phase() const pure { return _meter_phase; }
    void meter_phase(ubyte value)
    {
        if (_meter_phase == value)
            return;
        _meter_phase = value;
        restart();
    }

    MeterSign meter_sign() const pure { return _meter_sign; }
    void meter_sign(MeterSign value)
    {
        if (_meter_sign == value)
            return;
        _meter_sign = value;
        restart();
    }

    const(char)[] meter() const pure { return _meter_path[]; }
    const(char)[] meter(const(char)[] value)
    {
        if (value.length == 0)
        {
            _meter_path = String();
            _meter = null;
            restart();
            return null;
        }
        _meter_path = value.makeString(g_app.allocator);
        _meter = resolve_component_path(value);
        restart();
        return null;
    }

    Component meter_ref()
    {
        if (_meter is null && _meter_path.length != 0)
            _meter = resolve_component_path(_meter_path[]);
        return _meter;
    }

protected:
    override bool validate() const
    {
        return _child_circuit.length == 0 ? _circuit.length != 0 || _parent_circuit.length != 0
                                          : _parent_circuit.length != 0;
    }

    override CompletionStatus startup()
    {
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        return CompletionStatus.complete;
    }

    override void update() {}

private:
    String _kind;
    String _parent_circuit;
    String _child_circuit;
    String _circuit;
    uint _capacity;
    bool _closed;
    ubyte _meter_phase;
    MeterSign _meter_sign;
    String _meter_path;
    Component _meter;
}
