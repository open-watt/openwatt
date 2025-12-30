module manager.profile;

import urt.algorithm : binary_search, qsort;
import urt.array;
import urt.conv;
import urt.hash;
import urt.log;
import urt.map;
import urt.mem;
import urt.mem.string;
import urt.meta;
import urt.string;
import urt.string.format;

import manager.component;
import manager.config;
import manager.device;
import manager.sampler;

version = IncludeDescription;

nothrow @nogc:


enum Access : ubyte
{
    read,
    write,
    read_write
}

enum Frequency : ubyte
{
    realtime = 0,
    high,   // ie, seconds
    medium, // ie, 10s seconds
    low,    // ie, minutes
    constant,
    on_demand,
    report,
    configuration
}

enum ElementType : ubyte
{
    modbus,
    zigbee,
    http,
    aa55
}

struct ElementDesc
{
pure nothrow @nogc:
    CacheString display_units;
    Frequency update_frequency = Frequency.medium;

    ElementType type() const
        => cast(ElementType)(_element_index >> 13);

    size_t element() const
        => _element_index & 0x1FFF;

    const(char)[] get_description(ref const(Profile) profile) const
        => profile.desc_strings ? as_dstring(profile.desc_strings.ptr + _description) : null;

private:
    ushort _element_index; // bits 0-12: index, bits 13-15: type
    ushort _description;
}

struct ElementDesc_Modbus
{
    import protocol.modbus.message : RegisterType;
    import protocol.modbus.sampler : modbus_data_type;

    ushort reg;
    RegisterType reg_type = RegisterType.HoldingRegister;
    Access access = Access.read;
    ValueDesc value_desc = ValueDesc(modbus_data_type!"u16");
}

struct ElementDesc_Zigbee
{
    ushort cluster_id;
    ushort attribute_id;
    ushort manufacturer_code;
    Access access = Access.read;
    ValueDesc value_desc;
}

struct ElementDesc_HTTP
{
}

struct ElementDesc_AA55
{
    ubyte function_code;
    ubyte offset;
    ValueDesc value_desc;
}

struct ElementTemplate
{
pure nothrow @nogc:
    enum Type : ubyte
    {
        constant,
        map
    }

    Type type;
    ubyte index;

    const(char)[] get_id(ref const(Profile) profile) const
        => as_dstring(profile.id_strings.ptr + _id);

    const(char)[] get_constant_value(ref const(Profile) profile) const
    {
        assert(type == Type.constant, "ElementTemplate is not of type Constant");
        return as_dstring(profile.id_strings.ptr + _value);
    }

    ref inout(ElementDesc) get_element_desc(ref inout(Profile) profile) inout
    {
        assert(type == Type.map, "ElementTemplate is not of type Map");
        return profile.elements[_value];
    }

private:
    ushort _id;
    ushort _value;
}

struct ComponentTemplate
{
pure nothrow @nogc:
    const(char)[] get_id(ref const(Profile) profile) const
        => as_dstring(profile.id_strings.ptr + _id);

    const(char)[] get_template() const
        => _template[];

    ref inout(ComponentTemplate) get_component(size_t i, ref inout(Profile) profile) inout
        => profile.get_component(this, i);

    ref inout(ElementTemplate) get_element(size_t i, ref inout(Profile) profile) inout
        => profile.get_element(this, i);

    auto components(ref Profile profile)
    {
        struct Range
        {
            ComponentTemplate* component;
            Profile* profile;
            ushort index, count;
            ref inout(ComponentTemplate) front() inout pure nothrow @nogc => profile.get_component(*component, index);
            void popFront() pure nothrow @nogc { ++index; }
            bool empty() const pure nothrow @nogc => index >= count;
        }
        return Range(&this, &profile, 0, _num_components);
    }

    auto elements(ref Profile profile)
    {
        struct Range
        {
            ComponentTemplate* component;
            Profile* profile;
            ushort index, count;
            ref inout(ElementTemplate) front() inout pure nothrow @nogc => profile.get_element(*component, index);
            void popFront() pure nothrow @nogc { ++index; }
            bool empty() const pure nothrow @nogc => index >= count;
        }
        return Range(&this, &profile, 0, _num_elements);
    }

private:
    ushort _id;
    CacheString _template;
    ushort _elements;
    ushort _components;
    ushort _num_elements;
    ushort _num_components;
}

struct DeviceTemplate
{
pure nothrow @nogc:
    const(char)[] get_model(size_t i, ref const(Profile) profile) const
        => as_dstring(profile.id_strings.ptr + _models[i]);

    ref inout(ComponentTemplate) get_component(size_t i, ref inout(Profile) profile) inout
        => profile.get_component(this, i);

    auto components(ref Profile profile)
    {
        struct Range
        {
            DeviceTemplate* device;
            Profile* profile;
            ushort index, count;
            ref inout(ComponentTemplate) front() inout pure nothrow @nogc => profile.get_component(*device, index);
            void popFront() pure nothrow @nogc { ++index; }
            bool empty() const pure nothrow @nogc => index >= count;
        }
        return Range(&this, &profile, 0, _num_components);
    }

private:
    Array!ushort _models;
    ushort _components;
    ushort _num_components;
}

struct Profile
{
nothrow @nogc:

    this(this) @disable;
    this(ref Profile rh) @disable;
    this(Profile rh) @disable;

    ~this()
    {
        if (device_templates)
            defaultAllocator().freeArray(device_templates);
        if (component_templates)
            defaultAllocator().freeArray(component_templates);
        if (element_templates)
            defaultAllocator().freeArray(element_templates);
        if (elements)
            defaultAllocator().freeArray(elements);
        if (lookup_table)
            defaultAllocator().freeArray(lookup_table);
        if (indirections)
            defaultAllocator().freeArray(indirections);
        if (id_strings)
            defaultAllocator().freeArray(id_strings);
        if (lookup_strings)
            defaultAllocator().freeArray(lookup_strings);
        if (desc_strings)
           defaultAllocator().freeArray(desc_strings);
        if(mb_elements)
            defaultAllocator().freeArray(mb_elements);
        if(zb_elements)
            defaultAllocator().freeArray(zb_elements);
        if(http_elements)
            defaultAllocator().freeArray(http_elements);
        if(aa55_elements)
            defaultAllocator().freeArray(aa55_elements);
    }

    inout(DeviceTemplate)* get_model_template(const(char)[] model) inout pure
    {
        foreach (ref dt; device_templates)
        {
            // TODO: DEPRECATED: REMOVE THIS LOGIC!
            if (!model && dt._models.length == 0)
                return &dt;

            foreach (i; 0 .. dt._models.length)
            {
                if (dt.get_model(i, this).icmp(model) == 0)
                    return &dt;
            }
        }
        return null;
    }

    ref inout(ComponentTemplate) get_component(ref const(DeviceTemplate) device, size_t index) inout pure
    {
        assert(index < device._num_components, "Component index out of range");
        return component_templates[indirections[device._components + index]];
    }

    ref inout(ComponentTemplate) get_component(ref const(ComponentTemplate) component, size_t index) inout pure
    {
        assert(index < component._num_components, "Component index out of range");
        return component_templates[indirections[component._components + index]];
    }

    ref inout(ElementTemplate) get_element(ref const(ComponentTemplate) component, size_t index) inout pure
    {
        assert(index < component._num_elements, "Component index out of range");
        return element_templates[indirections[component._elements + index]];
    }

    ptrdiff_t find_element(const(char)[] id) const pure
    {
        uint hash = fnv1a(cast(ubyte[])id);
        ushort low_hash = cast(ushort)(hash & 0xFFFF);

        size_t i = binary_search!((ref a, b) => a.hash - b)(lookup_table[], low_hash);
        if (i == lookup_table.length)
            return -1;
        // seek to first in sequence
        while (i > 0 && lookup_table[i - 1].hash == low_hash)
            --i;

        // find item among hash collisions...
        if (lookup_strings)
        {
            while (true)
            {
                const(char)[] eid = as_dstring(lookup_strings.ptr + lookup_table[i].id);
                if (eid[] == id[])
                    return lookup_table[i].index;
                if (++i < lookup_table.length || lookup_table[i].hash != low_hash)
                    return -1;
            }
        }
        else
        {
            while (true)
            {
                if (lookup_table[i].id == hash >> 16)
                    return lookup_table[i].index;
                if (++i < lookup_table.length || lookup_table[i].hash != low_hash)
                    return -1;
            }
        }
        return -1;
    }

    ref const(ElementDesc_Modbus) get_mb(size_t i) const pure
        => mb_elements[i];

    ref const(ElementDesc_Zigbee) get_zb(size_t i) const pure
        => zb_elements[i];

    ref const(ElementDesc_AA55) get_aa55(size_t i) const pure
        => aa55_elements[i];

    void drop_lookup_strings()
    {
        if (!lookup_strings)
            return;

        foreach (ref l; lookup_table)
        {
            auto id = as_dstring(lookup_strings.ptr + l.id);
            uint hash = fnv1a(cast(ubyte[])id);
            l.id = hash >> 16;
        }

        defaultAllocator().freeArray(lookup_strings);
        lookup_strings = null;
    }

    void drop_description_strings()
    {
        defaultAllocator().freeArray(desc_strings);
        desc_strings = null;
    }

private:
    struct Lookup
    {
        ushort hash;
        ushort id;
        ushort index;
    }

    String name;

    DeviceTemplate[] device_templates;
    ComponentTemplate[] component_templates;
    ElementTemplate[] element_templates;
    ElementDesc[] elements;
    Lookup[] lookup_table;
    ElementDesc_Modbus[] mb_elements;
    ElementDesc_Zigbee[] zb_elements;
    ElementDesc_HTTP[] http_elements;
    ElementDesc_AA55[] aa55_elements;
    ushort[] indirections;
    char[] id_strings;
    char[] lookup_strings;
    char[] desc_strings;

    Map!(String, const(VoidEnumInfo)*) enum_templates;
}

Profile* load_profile(const(char)[] filename, NoGCAllocator allocator = defaultAllocator())
{
    import urt.file;

    void[] file = load_file(filename, allocator);
    scope (exit) { allocator.free(file); }
    if (!file)
        return null;
    return parse_profile(cast(const char[])file, allocator);
}

Profile* parse_profile(const(char)[] conf, NoGCAllocator allocator = defaultAllocator())
{
    ConfItem root = parseConfig(conf);
    return parse_profile(root);
}

Profile* parse_profile(ConfItem conf, NoGCAllocator allocator = defaultAllocator())
{
    Profile* profile = allocator.allocT!Profile();

    // first we need to count up all the memory...
    size_t item_count = 0;
    size_t id_string_length = 0;
    size_t lookup_string_len = 0;
    size_t desc_string_len = 0;
    size_t num_device_templates = 0;
    size_t num_component_templates = 0;
    size_t num_element_templates = 0;
    size_t num_indirections = 0;
    size_t mb_count = 0;
    size_t zb_count = 0;
    size_t http_count = 0;
    size_t aa55_count = 0;

    // we need to count the items and buffer lengths
    foreach (ref root_item; conf.subItems) switch (root_item.name)
    {
        case "enum":
            const(char)[] enum_name = root_item.value.unQuote;
            if (enum_name.empty)
            {
                writeWarning("Enum definition missing name; use \"enum: name\"");
                break;
            }
            if (enum_name[] in profile.enum_templates)
            {
                writeWarning("Duplicate enum definition: ", enum_name);
                break;
            }
            const(VoidEnumInfo)* enum_info = parse_enum(root_item);
            if (!enum_info)
            {
                writeWarning("Failed to parse enum: ", enum_name);
                break;
            }

            profile.enum_templates.insert(enum_name.makeString(allocator), enum_info);
            break;

        case "elements", "registers":
            item_count += root_item.subItems.length;

            foreach (ref reg_item; root_item.subItems)
            {
                // HACK: this is bad!
                const(char)[] extra = reg_item.value;
                const(char)[] tail = extra.split_element_and_desc();
                if (!extra.empty)
                {
                    const(char)[] name = extra.split!':';
                    reg_item.subItems.pushFront(ConfItem(name, extra));
                }

                foreach (ref reg_conf; reg_item.subItems) switch (reg_conf.name)
                {
                    case "desc":
                        tail = reg_conf.value;
                        const(char)[] id = tail.split!','.unQuote;
                        const(char)[] displayUnits = tail.split!','.unQuote;
                        const(char)[] freq = tail.split!','.unQuote;
                        const(char)[] desc = tail.split!','.unQuote;
                        // TODO: if !tail.empty, warn about unexpected data...

                        lookup_string_len += cache_len(id.length);
                        desc_string_len += cache_len(desc.length);
                        break;

                    case "valueid", "valuedesc":
                        // TODO: CREATE ENUM FROM DEPRECATED ENUM DESCRIPTION...
                        break;

                    // handled in second pass...
//                    case "others":
//                        continue;

                    default:
                        writeWarning("Invalid token: ", reg_conf.name);
                }

                switch (reg_item.name)
                {
                    case "mb", "reg": ++mb_count; break;
                    case "zb": ++zb_count; break;
                    case "http": ++http_count; break;
                    case "aa55": ++aa55_count; break;
                    default:
                        writeWarning("Unknown element type: ", reg_item.name);
                        break;
                }
            }
            break;

        case "device-template":
            ++num_device_templates;

            void count_component_strings(ref ConfItem conf)
            {
                ++num_component_templates;
                ++num_indirections;

                foreach (ref cItem; conf.subItems)
                {
                    ElementTemplate.Type ty = ElementTemplate.Type.constant;
                    switch (cItem.name)
                    {
                        case "id":
                            id_string_length += cache_len(cItem.value.unQuote.length);
                            break;

                        case "template":
                            // add template string to string cache...
                            break;

                        case "element-map":
                            ty = ElementTemplate.Type.map;
                            goto case;
                        case "element":
                            ++num_element_templates;
                            ++num_indirections;

                            const(char)[] tail = cItem.value;
                            id_string_length += cache_len(tail.split!','.unQuote.length);

                            if (ty == ElementTemplate.Type.constant)
                                id_string_length += cache_len(tail.split!','.length);
                            break;

                        case "component":
                            count_component_strings(cItem);
                            break;

                        default:
                            writeWarning("Invalid token: ", cItem.name);
                            break;
                    }
                }
            }

            foreach (ref item; root_item.subItems) switch (item.name)
            {
                case "model":
                    id_string_length += cache_len(item.value.unQuote.length);
                    break;

                case "component":
                    count_component_strings(item);
                    break;

                default:
                    writeWarning("Invalid token: ", item.name);
                    break;
            }
            break;

        default:
            writeWarning("Invalid token: ", root_item.name);
    }

    assert(item_count < ushort.max, "Too many register entries!");
    assert(num_indirections < ushort.max, "Too many indirections!");

    // allocate the buffers
    // TODO: aggregate the allocations into one big buffer?
    profile.device_templates = allocator.allocArray!DeviceTemplate(num_device_templates);
    profile.component_templates = allocator.allocArray!ComponentTemplate(num_component_templates);
    profile.element_templates = allocator.allocArray!ElementTemplate(num_element_templates);
    profile.elements = allocator.allocArray!ElementDesc(item_count);
    profile.lookup_table = allocator.allocArray!(Profile.Lookup)(item_count);
    profile.indirections = allocator.allocArray!ushort(num_indirections);
    profile.id_strings = allocator.allocArray!char(id_string_length);
    profile.lookup_strings = allocator.allocArray!char(lookup_string_len);
    profile.desc_strings = allocator.allocArray!char(desc_string_len);

    if(mb_count)
        profile.mb_elements = allocator.allocArray!ElementDesc_Modbus(mb_count);
    if(zb_count)
        profile.zb_elements = allocator.allocArray!ElementDesc_Zigbee(zb_count);
    if(http_count)
        profile.http_elements = allocator.allocArray!ElementDesc_HTTP(http_count);
    if(aa55_count)
        profile.aa55_elements = allocator.allocArray!ElementDesc_AA55(aa55_count);

    auto id_cache = StringCacheBuilder(profile.id_strings);
    auto lookup_cache = StringCacheBuilder(profile.lookup_strings);
    auto desc_cache = StringCacheBuilder(profile.desc_strings);

    num_device_templates = 0;
    num_component_templates = 0;
    num_element_templates = 0;
    num_indirections = 0;
    item_count = 0;
    mb_count = 0;
    zb_count = 0;
    http_count = 0;
    aa55_count = 0;

    // parse the elements
    foreach (ref root_item; conf.subItems) switch (root_item.name)
    {
        case "elements", "registers":
            foreach (i, ref reg_item; root_item.subItems)
            {
                ref ElementDesc e = profile.elements[item_count];
                ref Profile.Lookup l = profile.lookup_table[item_count++];
                l.index = cast(ushort)i;

                const(char)[] id, displayUnits, freq;

                foreach (ref reg_conf; reg_item.subItems) switch (reg_conf.name)
                {
                    case "desc":
                        const(char)[] tail = reg_conf.value;
                        id = tail.split!','.unQuote;
                        displayUnits = tail.split!','.unQuote;
                        freq = tail.split!','.unQuote;
                        const(char)[] desc = tail.split!','.unQuote;

                        l.id = lookup_cache.add_string(id);
                        l.hash = fnv1a(cast(ubyte[])id) & 0xFFFF;

                        e._description = desc_cache.add_string(desc);
                        break;

                    default:
                        continue;
                }

                Frequency frequency = Frequency.medium;
                if (!freq.empty)
                {
                    if (freq.ieq("realtime")) frequency = Frequency.realtime;
                    else if (freq.ieq("high")) frequency = Frequency.high;
                    else if (freq.ieq("medium")) frequency = Frequency.medium;
                    else if (freq.ieq("low")) frequency = Frequency.low;
                    else if (freq.ieq("const")) frequency = Frequency.constant;
                    else if (freq.ieq("ondemand")) frequency = Frequency.on_demand;
                    else if (freq.ieq("report")) frequency = Frequency.report;
                    else if (freq.ieq("config")) frequency = Frequency.configuration;
                    else writeWarning("Invalid frequency value: ", freq);
                }
                e.update_frequency = frequency;
                e.display_units = addString(displayUnits);

                void parse_value_desc(ref ValueDesc desc, DataType type, const(char)[] units)
                {
                    if ((type & DataType.enumeration) && units)
                    {
                        const(VoidEnumInfo)** enum_info = units in profile.enum_templates;
                        if (enum_info)
                            desc = ValueDesc(type, *enum_info);
                        else
                        {
                            writeWarning("Unknown enum type: ", units);
                            desc = ValueDesc(type);
                        }
                    }
                    else if (type.data_kind == DataKind.date_time)
                    {
                        switch (units)
                        {
                            case "yymmddhhmmss":
                                desc = ValueDesc(type, DateFormat.yymmddhhmmss);
                                break;
                            default:
                                writeWarning("Invalid date_time format: ", units);
                                break;
                        }
                    }
                    else
                    {
                        desc = ValueDesc(type);
                        if (!desc.parse_units(units))
                            writeWarning("Invalid units '", units, "' for element: ", id);
                    }
                }

                // the actual element data...
                switch (reg_item.name)
                {
                    case "mb", "reg":
                        const(char)[] tail = reg_item.value;
                        tail = tail.split_element_and_desc();

                        const(char)[] register = tail.split!',';
                        const(char)[] type = tail.split!','.unQuote;
                        const(char)[] units = tail.split!','.unQuote;

                        e._element_index = cast(ushort)((ElementType.modbus << 13) | mb_count);
                        ref ElementDesc_Modbus mb = profile.mb_elements[mb_count++];

                        // TODO: MOVE THIS CODE!
                        import protocol.modbus.message : RegisterType;
                        import protocol.modbus.sampler : parse_modbus_data_type;

                        size_t taken;
                        ulong reg = register.parse_uint_with_base(&taken);
                        if (taken != register.length || reg > 105535)
                        {
                            writeWarning("Invalid Modbus register: ", register);
                            break;
                        }
                        if (reg < 10000)
                        {
                            mb.reg_type = RegisterType.Coil;
                            mb.reg = cast(ushort)reg;
                        }
                        else if (reg < 20000)
                        {
                            mb.reg_type = RegisterType.DiscreteInput;
                            mb.reg = cast(ushort)(reg - 10000);
                        }
                        else if (reg < 30000)
                            break;
                        else if (reg < 40000)
                        {
                            mb.reg_type = RegisterType.InputRegister;
                            mb.reg = cast(ushort)(reg - 30000);
                        }
                        else
                        {
                            mb.reg_type = RegisterType.HoldingRegister;
                            mb.reg = cast(ushort)(reg - 40000);
                        }

                        DataType ty = type.split!('/', false).parse_modbus_data_type();
                        if (type.length > 0)
                        {
                            if (type[0] == 'R')
                            {
                                if (type.length > 1 && type[1] == 'W')
                                    mb.access = Access.read_write;
                                else
                                    mb.access = Access.read;
                            }
                            else if (type[0] == 'W')
                                mb.access = Access.write;
                        }
                        parse_value_desc(mb.value_desc, ty, units);
                        break;

                    case "zb":
                        const(char)[] tail = reg_item.value;
                        tail = tail.split_element_and_desc();

                        const(char)[] cluster = tail.split!',';
                        const(char)[] mfg = tail.split!',';
                        const(char)[] attrib = mfg.split!'(';
                        const(char)[] type = tail.split!','.unQuote;
                        const(char)[] units = tail.split!','.unQuote;

                        e._element_index = cast(ushort)((ElementType.zigbee << 13) | zb_count);
                        ref ElementDesc_Zigbee zb = profile.zb_elements[zb_count++];

                        size_t taken;
                        ulong t = cluster.parse_uint_with_base(&taken);
                        if (taken != cluster.length || t > 0xFFFF)
                        {
                            writeWarning("Invalid Zigbee cluster ID: ", cluster);
                            break;
                        }
                        zb.cluster_id = cast(ushort)t;

                        t = attrib.parse_uint_with_base(&taken);
                        if (taken != attrib.length || t > 0xFFFF)
                        {
                            writeWarning("Invalid Zigbee attribute ID: ", attrib);
                            break;
                        }
                        zb.attribute_id = cast(ushort)t;

                        if (mfg.length > 0)
                        {
                            if (mfg[$-1] != ')')
                            {
                                writeWarning("Invalid Zigbee manufacturer code: ", mfg);
                                break;
                            }
                            mfg = mfg[0.. $-1].trimBack;

                            t = mfg.parse_uint_with_base(&taken);
                            if (taken != mfg.length || t > 0xFFFF)
                            {
                                writeWarning("Invalid Zigbee manufacturer code: ", mfg);
                                break;
                            }
                            zb.manufacturer_code = cast(ushort)t;
                        }
                        else
                            zb.manufacturer_code = 0;

                        DataType ty = type.split!('/', false).parse_data_type();
                        if (type.length > 0)
                        {
                            if (type[0] == 'R')
                            {
                                if (type.length > 1 && type[1] == 'W')
                                    zb.access = Access.read_write;
                                else
                                    zb.access = Access.read;
                            }
                            else if (type[0] == 'W')
                                zb.access = Access.write;
                        }
                        parse_value_desc(zb.value_desc, ty, units);
                        break;

                    case "http":
                        e._element_index = cast(ushort)((ElementType.http << 13) | http_count);
                        ref ElementDesc_HTTP http = profile.http_elements[http_count++];
                        break;

                    case "aa55":
                        import protocol.goodwe.aa55;

                        const(char)[] tail = reg_item.value;
                        tail = tail.split_element_and_desc();

                        const(char)[] fn = tail.split!',';
                        const(char)[] offset = tail.split!',';
                        const(char)[] type = tail.split!','.unQuote;
                        const(char)[] units = tail.split!','.unQuote;

                        e._element_index = cast(ushort)((ElementType.aa55 << 13) | aa55_count);
                        ref ElementDesc_AA55 aa55 = profile.aa55_elements[aa55_count++];

                        size_t taken;
                        ulong ti = fn.parse_uint_with_base(&taken);
                        if (taken != fn.length || ti > ubyte.max)
                        {
                            writeWarning("Invalid AA55 control code: ", fn);
                            break;
                        }
                        aa55.function_code = cast(ubyte)ti;
                        ti = offset.parse_uint_with_base(&taken);
                        if (taken != offset.length || ti > ubyte.max)
                        {
                            writeWarning("Invalid AA55 function code: ", offset);
                            break;
                        }
                        aa55.offset = cast(ubyte)ti;

                        parse_value_desc(aa55.value_desc, type.parse_data_type(), units);
                        break;

                    default:
                        writeWarning("Unknown element type: ", reg_item.name);
                        break;
                }
            }
            break;

        case "device-template":
            ref DeviceTemplate device = profile.device_templates[num_device_templates++];

            void allocate_component(ref ConfItem conf)
            {
                ref ComponentTemplate component = profile.component_templates[num_component_templates++];

                foreach (ref cItem; conf.subItems) switch (cItem.name)
                {
                    case "element-map":
                    case "element":
                        ++component._num_elements;
                        break;

                    case "component":
                        ++component._num_components;
                        allocate_component(cItem);
                        break;

                    default:
                        break;
                }
            }

            foreach (ref item; root_item.subItems) switch (item.name)
            {
                case "component":
                    ++device._num_components;
                    allocate_component(item);
                    break;

                default:
                    break;
            }
            break;

        default:
            continue;
    }

    // sort the lookup table so the lookup function works...
    qsort!lookup_cmp(profile.lookup_table);

    // TODO: scan for duplicate registers
    //...

    num_device_templates = 0;
    num_component_templates = 0;

    // now finally parse the templates
    foreach (ref root_item; conf.subItems) switch (root_item.name)
    {
        case "device-template":
            ref DeviceTemplate device = profile.device_templates[num_device_templates++];
            device._components = cast(ushort)num_indirections;
            num_indirections += device._num_components;
            size_t component_count = 0;

            void parse_component(ref ComponentTemplate component, ref ConfItem conf)
            {
                component._components = component._num_components ? cast(ushort)num_indirections : 0;
                num_indirections += component._num_components;
                component._elements = component._num_elements ? cast(ushort)num_indirections : 0;
                num_indirections += component._num_elements;
                size_t component_count = 0;
                size_t element_count = 0;

                foreach (ref cItem; conf.subItems) switch (cItem.name)
                {
                    case "id":
                        component._id = id_cache.add_string(cItem.value.unQuote);
                        break;

                    case "template":
                        component._template = addString(cItem.value.unQuote);
                        break;

                    case "component":
                        profile.indirections[component._components + component_count] = cast(ushort)num_component_templates++;
                        parse_component(profile.component_templates[profile.indirections[component._components + component_count++]], cItem);
                        break;

                    default:
                        break;
                }

                foreach (ref cItem; conf.subItems)
                {
                    ElementTemplate.Type ty = ElementTemplate.Type.constant;
                    switch (cItem.name)
                    {
                        case "element-map":
                            ty = ElementTemplate.Type.map;
                            goto case;
                        case "element":
                            profile.indirections[component._elements + element_count] = cast(ushort)num_element_templates++;
                            ref ElementTemplate e = profile.element_templates[profile.indirections[component._elements + element_count++]];
                            e.type = ty;

                            const(char)[] tail = cItem.value;
                            e._id = id_cache.add_string(tail.split!','.unQuote);

                            if (ty == ElementTemplate.Type.constant)
                            {
                                // store the element value as the source string
                                e._value = id_cache.add_string(tail.split!',');
                            }
                            else
                            {
                                // lookup item now...
                                const(char)[] id = tail.split!','.unQuote;

                                if (id.length < 2 || id[0] != '@')
                                {
                                    writeWarning("Invalid element-map value: ", id);
                                    continue;
                                }
                                id = id[1 .. $];
                                const(char)[] index = id.split!':';
                                if (!id)
                                    id = index;
                                else
                                {
                                    ulong i = index.parse_uint();
                                    if (i > ubyte.max)
                                    {
                                        writeWarning("Invalid element index in element-map: ", index);
                                        continue;
                                    }
                                    e.index = cast(ubyte)i;
                                }

                                ptrdiff_t i = profile.find_element(id);
                                if (i < 0)
                                {
                                    writeWarning("Unknown element in element-map: ", id);
                                    continue;
                                }
                                // add the element index to the template...
                                e._value = cast(ushort)i;
                            }
                            break;

                        default:
                            break;
                    }
                }
            }

            foreach (ref item; root_item.subItems) switch (item.name)
            {
                case "model":
                    device._models ~= id_cache.add_string(item.value.unQuote);
                    break;

                case "component":
                    profile.indirections[device._components + component_count] = cast(ushort)num_component_templates++;
                    parse_component(profile.component_templates[profile.indirections[device._components + component_count++]], item);
                    break;

                default:
                    writeWarning("Invalid token: ", item.name);
                    break;
            }
            break;

        default:
            continue;
    }

    return profile;
}

VoidEnumInfo* parse_enum(ConfItem conf)
{
    const(char)[] enum_name = conf.value.unQuote;
    size_t count = conf.subItems.length;

    auto keys = Array!(const(char)[])(Reserve, count);
    auto t_vals = Array!long(Reserve, count);
    long min, max;
    foreach (i, ref item; conf.subItems)
    {
        keys ~= item.name.unQuote;
        const(char)[] val = item.value.split!',';

        size_t taken;
        ref long v = t_vals.pushBack(val.parse_int_with_base(&taken));
        if (taken > 0 && taken < val.length)
        {
            // TODO: there could be type suffixes?

            // TODO: we could/(should?) unlease the command expression parser on this...

            val = val[taken .. $].trimFront;
            if (val.length > 2 && val[0..2] == "<<")
            {
                val = val[2 .. $].trimFront;
                ulong shift = val.parse_uint_with_base(&taken);
                v <<= shift;
            }
        }
        if (taken != val.length)
        {
            writeWarning("Invalid enum value: ", val);
            v = 0;
        }
        min = v < min ? v : min;
        max = v > max ? v : max;
    }

    import urt.mem.temp;
    if (min >= byte.min && max <= byte.max)
    {
        auto b_values = cast(byte[])talloc(1 * count);
        foreach (i, v; t_vals)
            b_values[i] = cast(byte)v;
        return make_enum_info(enum_name, keys[], b_values[]);
    }
    else if (min >= short.min && max <= short.max)
    {
        auto s_values = cast(short[])talloc(2 * count);
        foreach (i, v; t_vals)
            s_values[i] = cast(short)v;
        return make_enum_info(enum_name, keys[], s_values[]);
    }
    else if (min >= int.min && max <= int.max)
    {
        auto i_values = cast(int[])talloc(4 * count);
        foreach (i, v; t_vals)
            i_values[i] = cast(int)v;
        return make_enum_info(enum_name, keys[], i_values[]);
    }
    return make_enum_info(enum_name, keys[], t_vals[]);
}


private:

size_t cache_len(size_t str_len) pure nothrow @nogc
    => 2 + str_len + (str_len & 1);

int lookup_cmp(ref const Profile.Lookup a, ref const Profile.Lookup b) pure nothrow @nogc
    => a.hash - b.hash;

const(char)[] split_element_and_desc(ref const(char)[] line)
{
    size_t colon = line.findFirst(':');
    if (colon == line.length)
        return line;
    // seek back to beginning of token before the colon...
    while (colon > 0 && is_whitespace(line[colon - 1]))
        --colon;
    while (colon > 0 && !is_whitespace(line[colon - 1]))
        --colon;
    const(char)[] element = line[0 .. colon].trimBack;
    line = line[colon .. $];
    return element;
}
