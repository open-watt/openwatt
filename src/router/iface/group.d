module router.iface.group;

import urt.mem.allocator : defaultAllocator;
import urt.string;

import manager;
import manager.base;
import manager.collection;

import router.iface;


nothrow @nogc:


class InterfaceGroup : BaseObject
{
    alias Properties = AliasSeq!(Prop!("interface", iface),
                                 Prop!("group", group));
nothrow @nogc:

    enum type_name = "interface-group";
    enum path = "/interface/group";
    enum collection_id = CollectionType.interface_group;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!InterfaceGroup, id, flags);
    }

    // Properties
    inout(BaseInterface) iface() inout pure
        => _iface;
    const(char)[] iface(BaseInterface value)
    {
        if (!value)
            return "interface cannot be null";
        if (_iface is value)
            return null;
        _iface = value;
        mark_set!(typeof(this), "interface")();
        return null;
    }

    const(char)[] group() const pure
        => _group[];
    void group(const(char)[] value)
    {
        _group = value.makeString(defaultAllocator);
        mark_set!(typeof(this), "group")();
    }

protected:
    mixin RekeyHandler;

    override bool validate() const pure nothrow @nogc
        => _iface !is null && !_group.empty;

private:
    ObjectRef!BaseInterface _iface;
    String _group;
}
