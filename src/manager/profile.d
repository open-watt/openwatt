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


alias ModelMask = ushort;

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
    RegisterType reg_type = RegisterType.holding_register;
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

    // 1-byte padding here...
    Frequency update_frequency = Frequency.medium;

    CacheString display_units;

    const(char)[] get_id(ref const(Profile) profile) const
        => as_dstring(profile.id_strings.ptr + _id);

    const(char)[] get_name(ref const(Profile) profile) const
        => profile.name_strings ? as_dstring(profile.name_strings.ptr + _name) : null;

    const(char)[] get_desc(ref const(Profile) profile) const
        => profile.desc_strings ? as_dstring(profile.desc_strings.ptr + _description) : null;

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
    ushort _name;
    ushort _description;
    package ModelMask _model_mask;
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
    package ModelMask _model_mask;
}

struct DeviceTemplate
{
pure nothrow @nogc:
    size_t num_models() const
        => _models.length;

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
        if (name_strings)
            defaultAllocator().freeArray(name_strings);
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
                if (wildcard_match_i(dt.get_model(i, this), model))
                    return &dt;
            }
        }
        return null;
    }

    const(VoidEnumInfo)* find_enum_template(const(char)[] name)
    {
        import manager;

        const(VoidEnumInfo)** enum_info = name in enum_templates;
        if (!enum_info)
            enum_info = name in g_app.enum_templates;
        if (!enum_info)
            return null;
        return *enum_info;
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
                if (++i == lookup_table.length || lookup_table[i].hash != low_hash)
                    return -1;
            }
        }
        else
        {
            while (true)
            {
                if (lookup_table[i].id == hash >> 16)
                    return lookup_table[i].index;
                if (++i == lookup_table.length || lookup_table[i].hash != low_hash)
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
    char[] name_strings;
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
    ConfItem root = parse_config(conf);
    return parse_profile(root);
}

Profile* parse_profile(ConfItem conf, NoGCAllocator allocator = defaultAllocator())
{
    Profile* profile = allocator.allocT!Profile();

    // first we need to count up all the memory...
    size_t item_count = 0;
    size_t id_string_length = 0;
    size_t name_string_length = 0;
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
    foreach (ref root_item; conf.sub_items) switch (root_item.name)
    {
        case "enum":
            const(char)[] enum_name = root_item.value.unQuote;
            if (enum_name.empty)
            {
                writeWarning("Enum definition missing name; use \"enum: name\"");
                break;
            }
            if (profile.find_enum_template(enum_name))
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
            item_count += root_item.sub_items.length;

            foreach (ref reg_item; root_item.sub_items)
            {
                // HACK: this is bad!
                const(char)[] extra = reg_item.value;
                const(char)[] tail = extra.split_element_and_desc();
                if (!extra.empty)
                {
                    const(char)[] name = extra.split!':';
                    reg_item.sub_items.pushFront(ConfItem(name, extra));
                    reg_item.value = tail;
                }

                foreach (ref reg_conf; reg_item.sub_items)
                {
                    if (reg_conf.name != "desc")
                    {
                        writeWarning("Invalid token: ", reg_conf.name);
                        continue;
                    }

                    tail = reg_conf.value;
                    const(char)[] id = tail.split!','.unQuote;
                    const(char)[] display_units = tail.split!','.unQuote;
                    const(char)[] freq = tail.split!','.unQuote;
                    const(char)[] desc = tail.split!','.unQuote;
                    // TODO: if !tail.empty, warn about unexpected data...

                    lookup_string_len += cache_len(id.length);
                    desc_string_len += cache_len(desc.length);
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

                foreach (ref cItem; conf.sub_items)
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

                            const(char)[] extra = cItem.value;
                            const(char)[] tail = extra.split_element_and_desc();
                            if (!extra.empty)
                            {
                                const(char)[] name = extra.split!':';
                                cItem.sub_items.pushFront(ConfItem(name, extra));
                                cItem.value = tail;
                            }

                            id_string_length += cache_len(tail.split!','.unQuote.length);

                            if (ty == ElementTemplate.Type.constant)
                                id_string_length += cache_len(tail.split!','.length);

                            foreach (ref el_item; cItem.sub_items)
                            {
                                if (el_item.name[] != "desc")
                                {
                                    writeWarning("Invalid token: ", el_item.name);
                                    continue;
                                }

                                tail = el_item.value;
                                const(char)[] display_units = tail.split!','.unQuote;
                                const(char)[] freq = tail.split!','.unQuote;
                                const(char)[] name = tail.split!','.unQuote;
                                const(char)[] desc = tail.split!','.unQuote;
                                // TODO: if !tail.empty, warn about unexpected data...

                                name_string_length += cache_len(name.length);
                                desc_string_len += cache_len(desc.length);
                            }
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

            foreach (ref item; root_item.sub_items) switch (item.name)
            {
                case "model":
                    const(char)[] models = item.value;
                    while (const(char)[] model = models.split!',')
                        id_string_length += cache_len(model.unQuote.length);
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
    profile.name_strings = allocator.allocArray!char(name_string_length);
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
    auto name_cache = StringCacheBuilder(profile.name_strings);
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
    foreach (ref root_item; conf.sub_items) switch (root_item.name)
    {
        case "elements", "registers":
            foreach (i, ref reg_item; root_item.sub_items)
            {
                ref ElementDesc e = profile.elements[item_count];
                ref Profile.Lookup l = profile.lookup_table[item_count++];
                l.index = cast(ushort)i;

                const(char)[] id, display_units, freq;

                foreach (ref reg_conf; reg_item.sub_items)
                {
                    if (reg_conf.name[] != "desc")
                        continue;

                    const(char)[] tail = reg_conf.value;
                    id = tail.split!','.unQuote;
                    display_units = tail.split!','.unQuote;
                    freq = tail.split!','.unQuote;
                    const(char)[] desc = tail.split!','.unQuote;

                    uint hash = fnv1a(cast(ubyte[])id);
                    l.hash = hash & 0xFFFF;
                    if (profile.lookup_strings)
                        l.id = lookup_cache.add_string(id);
                    else
                        l.id = hash >> 16;

                    e._description = desc_cache.add_string(desc);
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
                e.display_units = addString(display_units);

                void parse_value_desc(ref ValueDesc desc, DataType type, const(char)[] units)
                {
                    if ((type & DataType.enumeration) && units)
                    {
                        const(VoidEnumInfo)* enum_info = profile.find_enum_template(units);
                        if (enum_info)
                            desc = ValueDesc(type, enum_info);
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
                            mb.reg_type = RegisterType.coil;
                            mb.reg = cast(ushort)reg;
                        }
                        else if (reg < 20000)
                        {
                            mb.reg_type = RegisterType.discrete_input;
                            mb.reg = cast(ushort)(reg - 10000);
                        }
                        else if (reg < 30000)
                            break;
                        else if (reg < 40000)
                        {
                            mb.reg_type = RegisterType.input_register;
                            mb.reg = cast(ushort)(reg - 30000);
                        }
                        else
                        {
                            mb.reg_type = RegisterType.holding_register;
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

                foreach (ref cItem; conf.sub_items) switch (cItem.name)
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

            foreach (ref item; root_item.sub_items)
            {
                if (item.name[] != "component")
                    continue;

                ++device._num_components;
                allocate_component(item);
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
    foreach (ref root_item; conf.sub_items) switch (root_item.name)
    {
        case "device-template":
            ref DeviceTemplate device = profile.device_templates[num_device_templates++];
            device._components = cast(ushort)num_indirections;
            num_indirections += device._num_components;
            size_t component_count = 0;

            ushort parse_model_filter(const(char)[] models)
            {
                models = models.trim();
                ushort mask;
                while (const(char)[] model = models.split!','.unQuote)
                {
                    foreach (i; 0 .. device.num_models)
                    {
                        if (wildcard_match_i(model, device.get_model(i, *profile), true))
                            mask |= 1 << i;
                    }
                }
                return mask;
            }

            void parse_component(ref ComponentTemplate component, ref ConfItem conf)
            {
                component._components = component._num_components ? cast(ushort)num_indirections : 0;
                num_indirections += component._num_components;
                component._elements = component._num_elements ? cast(ushort)num_indirections : 0;
                num_indirections += component._num_elements;
                size_t component_count = 0;
                size_t element_count = 0;

                // get model filter
                const(char)[] model_filter = conf.value;
                const(char)[] tail = model_filter.split!'[';
                if (!model_filter.empty && model_filter[$-1] == ']')
                    component._model_mask = parse_model_filter(model_filter[0 .. $-1]);
                else
                    component._model_mask = ModelMask.max;

                // first pass - metadata and children
                foreach (ref cItem; conf.sub_items) switch (cItem.name)
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

                // second pass - the elements
                foreach (ref cItem; conf.sub_items)
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

                            model_filter = cItem.value;
                            tail = model_filter.split!'[';

                            // get model filter
                            if (!model_filter.empty && model_filter[$-1] == ']')
                                e._model_mask = parse_model_filter(model_filter[0 .. $-1]);
                            else
                                e._model_mask = ModelMask.max;

                            const(ElementDesc)* elem_desc;

                            const(char)[] elem_id = tail.split!','.unQuote;
                            e._id = id_cache.add_string(elem_id);

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
                                const(char)[] index = id.split!'$';
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

                                elem_desc = &e.get_element_desc(*profile);
                            }

                            const(char)[] display_units, freq, description;

                            foreach (ref el_item; cItem.sub_items)
                            {
                                if (el_item.name[] != "desc")
                                    continue;

                                tail = el_item.value;
                                display_units = tail.split!','.unQuote;
                                freq = tail.split!','.unQuote;
                                const(char)[] name = tail.split!','.unQuote;
                                description = tail.split!','.unQuote;

                                e._name = name_cache.add_string(name);
                            }

                            e.display_units = display_units ? addString(display_units) : elem_desc ? elem_desc.display_units : CacheString();
                            e._description = description ? desc_cache.add_string(description) : elem_desc ? elem_desc._description : 0;

                            // TODO: default should be on-demand, but this is more useful while debugging...
                            e.update_frequency = Frequency.medium;
                            if (!freq.empty)
                            {
                                if (freq.ieq("realtime")) e.update_frequency = Frequency.realtime;
                                else if (freq.ieq("high")) e.update_frequency = Frequency.high;
                                else if (freq.ieq("medium")) e.update_frequency = Frequency.medium;
                                else if (freq.ieq("low")) e.update_frequency = Frequency.low;
                                else if (freq.ieq("const")) e.update_frequency = Frequency.constant;
                                else if (freq.ieq("ondemand")) e.update_frequency = Frequency.on_demand;
                                else if (freq.ieq("report")) e.update_frequency = Frequency.report;
                                else if (freq.ieq("config")) e.update_frequency = Frequency.configuration;
                                else writeWarning("Invalid frequency value: ", freq);
                            }
                            else if (elem_desc)
                                e.update_frequency = elem_desc.update_frequency;
                            break;

                        default:
                            break;
                    }
                }
            }

            // gather the models first; we'll need them in the components...
            models: foreach (ref item; root_item.sub_items)
            {
                if (item.name[] != "model")
                    continue;

                const(char)[] models = item.value;
                while (const(char)[] model = models.split!',')
                {
                    if (device._models.length >= 16)
                    {
                        writeWarning("Device template can (currently) have a maximum of 16 models!");
                        break models;
                    }

                    device._models ~= id_cache.add_string(model.unQuote);
                }
            }

            foreach (ref item; root_item.sub_items)
            {
                if (item.name[] != "component")
                    continue;

                profile.indirections[device._components + component_count] = cast(ushort)num_component_templates++;
                parse_component(profile.component_templates[profile.indirections[device._components + component_count++]], item);
            }
            break;

        default:
            continue;
    }

    // TODO: we seem to have over-estimated the cache lengths... investigate!
//    debug assert (id_cache.full, "Miscalculated ID string cache size!");
    debug assert (lookup_cache.full, "Miscalculated lookup string cache size!");
    debug assert (name_cache.full, "Miscalculated name string cache size!");
//    debug assert (desc_cache.full, "Miscalculated description string cache size!");

    return profile;
}

VoidEnumInfo* parse_enum(ConfItem conf)
{
    const(char)[] enum_name = conf.value.unQuote;
    size_t count = conf.sub_items.length;

    auto keys = Array!(const(char)[])(Reserve, count);
    auto t_vals = Array!long(Reserve, count);
    long min, max;
    foreach (i, ref item; conf.sub_items)
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


struct KnownElementTemplate
{
    immutable(char)* text;
    ushort id_len, name_len, desc_len;
    ubyte units_len;
    Frequency update_frequency;

pure nothrow @nogc:
    string id() const
        => text[0 .. id_len];
    string units() const
        => text[id_len .. id_len + units_len];
    string name() const
        => text[id_len + units_len .. id_len + units_len + name_len];
    string desc() const
        => text[id_len + units_len + name_len .. id_len + units_len + name_len + desc_len];
}

const(KnownElementTemplate)* find_known_element(const(char)[] template_, const(char)[] id)
{
    if (const(KnownElementTemplate[])* elements = template_[] in g_well_known_elements)
    {
        foreach (ref e; *elements)
        {
            if (id == e.id())
                return &e;
        }
    }
    return null;
}


private:

size_t cache_len(size_t str_len) pure nothrow @nogc
    => 2 + str_len + (str_len & 1);

int lookup_cmp(ref const Profile.Lookup a, ref const Profile.Lookup b) pure nothrow @nogc
    => a.hash - b.hash;

const(char)[] split_element_and_desc(ref const(char)[] line)
{
    import urt.util : swap;

    size_t colon = line.findFirst(':');
    if (colon == line.length)
        return line.swap(null);

    // seek back to beginning of token before the colon...
    while (colon > 0 && is_whitespace(line[colon - 1]))
        --colon;
    while (colon > 0 && !is_whitespace(line[colon - 1]))
        --colon;
    const(char)[] element = line[0 .. colon].trimBack;
    line = line[colon .. $];
    return element;
}

template MakeElementTemplate(string id, string units, string name, string desc, Frequency update_frequency)
{
    enum string text = id ~ units ~ name ~ desc;
    enum MakeElementTemplate = KnownElementTemplate(text.ptr, ushort(id.length), ushort(name.length), ushort(desc.length), ubyte(units.length), update_frequency);
}

// well-known element details for common Component types
__gshared immutable KnownElementTemplate[][string] g_well_known_elements = [
    "DeviceInfo": g_DeviceInfo_elements,
    "DeviceStatus": g_DeviceStatus_elements,
    "Network": g_Network_elements,
    "Modbus": g_Modbus_elements,
    "Ethernet": g_Ethernet_elements,
    "Wifi": g_Wifi_elements,
    "Cellular": g_Cellular_elements,
    "Zigbee": g_Zigbee_elements,
    "RealtimeEnergyMeter": g_RealtimeEnergyMeter_elements,
    "CumulativeEnergyMeter": g_CumulativeEnergyMeter_elements,
    "DemandEnergyMeter": g_DemandEnergyMeter_elements,
    "Battery": g_Battery_elements,
    "BatteryConfig": g_BatteryConfig_elements,
    "Solar": g_Solar_elements,
    "SolarConfig": g_SolarConfig_elements,
    "Inverter": g_Inverter_elements,
    "EVSE": g_EVSE_elements,
    "Vehicle": g_Vehicle_elements,
    "ChargeControl": g_ChargeControl_elements,
    "Switch": g_Switch_elements,
    "ContactSensor": g_ContactSensor_elements,
    "ModbusConfig": g_ModbusConfig_elements,
    "EthernetConfig": g_EthernetConfig_elements,
    "WifiConfig": g_WifiConfig_elements,
    "CellularConfig": g_CellularConfig_elements,
    "ZigbeeConfig": g_ZigbeeConfig_elements,
];

__gshared immutable KnownElementTemplate[] g_DeviceInfo_elements = [
    MakeElementTemplate!("type", null, "Device Type", "Device category", Frequency.constant),
    MakeElementTemplate!("name", null, "Device Name", "Device display name", Frequency.constant),
    MakeElementTemplate!("manufacturer_name", null, "Manufacturer", "Manufacturer display name", Frequency.constant),
    MakeElementTemplate!("manufacturer_id", null, "Manufacturer ID", "Manufacturer identifier code", Frequency.constant),
    MakeElementTemplate!("brand_name", null, "Brand", "Brand display name", Frequency.constant),
    MakeElementTemplate!("brand_id", null, "Brand ID", "Brand idenitifier code", Frequency.constant),
    MakeElementTemplate!("model_name", null, "Model", "Model display name", Frequency.constant),
    MakeElementTemplate!("model_id", null, "Model ID", "Model identifier code", Frequency.constant),
    MakeElementTemplate!("serial_number", null, "Serial Number", null, Frequency.constant),
    MakeElementTemplate!("firmware_version", null, "Firmware Version", null, Frequency.constant),
    MakeElementTemplate!("hardware_version", null, "Hardware Version", null, Frequency.constant),
    MakeElementTemplate!("software_version", null, "Software Version", null, Frequency.constant),
    MakeElementTemplate!("app_ver", null, "Application Version", "Zigbee application version", Frequency.constant),
    MakeElementTemplate!("zcl_ver", null, "ZCL Version", "Zigbee ZCL version", Frequency.constant),
];

__gshared immutable KnownElementTemplate[] g_DeviceStatus_elements = [
    MakeElementTemplate!("time", "systime", "Current Time", null, Frequency.high),
    MakeElementTemplate!("up_time", "s", "Uptime", null, Frequency.high),
    MakeElementTemplate!("running_time", "s", "Running Time", "Total Running Time", Frequency.high),
    MakeElementTemplate!("running_time_with_load", "s", "Running Time With Load", "Running time under load", Frequency.high),
];

__gshared immutable KnownElementTemplate[] g_Network_elements = [
    MakeElementTemplate!("mode", null, "Network Mode", "Active network mode/type", Frequency.high),
];

__gshared immutable KnownElementTemplate[] g_Modbus_elements = [
    MakeElementTemplate!("status", null, "Connection Status", null, Frequency.high),
];

__gshared immutable KnownElementTemplate[] g_Ethernet_elements = [
    MakeElementTemplate!("status", null, "Connection Status", null, Frequency.high),
    MakeElementTemplate!("link_speed", "Mbps", "Link Speed", null, Frequency.high),
    MakeElementTemplate!("mac_address", null, "MAC Address", null, Frequency.low),
    MakeElementTemplate!("ip_address", null, "IP Address", null, Frequency.medium),
    MakeElementTemplate!("gateway", null, "Default Gateway", null, Frequency.medium),
];

__gshared immutable KnownElementTemplate[] g_Wifi_elements = [
    MakeElementTemplate!("status", null, "Connection Status", null, Frequency.high),
    MakeElementTemplate!("ssid", null, "SSID", "Connected network SSID", Frequency.high),
    MakeElementTemplate!("rssi", "dBm", "Signal Strength", null, Frequency.high),
    MakeElementTemplate!("bssid", null, "BSSID", "Connected AP MAC address", Frequency.high),
    MakeElementTemplate!("channel", null, "Channel", "Wi-Fi channel", Frequency.high),
];

__gshared immutable KnownElementTemplate[] g_Cellular_elements = [
    MakeElementTemplate!("status", null, "Connection Status", null, Frequency.high),
    MakeElementTemplate!("signal_strength", "dBm", "Signal Strength", null, Frequency.realtime),
    MakeElementTemplate!("operator", null, "Network Operator", null, Frequency.low),
    MakeElementTemplate!("imei", null, "Device IMEI", null, Frequency.low),
    MakeElementTemplate!("iccid", null, "SIM ICCID", "ID of GPRS/4G module", Frequency.low),
    MakeElementTemplate!("ip_address", null, "IP Address", null, Frequency.medium),
];

__gshared immutable KnownElementTemplate[] g_Zigbee_elements = [
    MakeElementTemplate!("status", null, "Connection Status", null, Frequency.high),
    MakeElementTemplate!("rssi", "dBm", "Received Signal Power", null, Frequency.realtime),
    MakeElementTemplate!("lqi", null, "Link Quality Index", null, Frequency.realtime),
    MakeElementTemplate!("eui", null, "EUI64", "MAC address", Frequency.low),
    MakeElementTemplate!("address", null, "Network Address", null, Frequency.medium),
];

__gshared immutable KnownElementTemplate[] g_RealtimeEnergyMeter_elements = [
    MakeElementTemplate!("type", "CircuitType", "Meter Type", "Circuit type of energy meter", Frequency.constant),
    MakeElementTemplate!("voltage", "V", "Voltage", "Line voltage", Frequency.realtime),
    MakeElementTemplate!("voltage1", "V", "Voltage 1", "Phase A Voltage", Frequency.realtime),
    MakeElementTemplate!("voltage2", "V", "Voltage 2", "Phase B Voltage", Frequency.realtime),
    MakeElementTemplate!("voltage3", "V", "Voltage 3", "Phase C Voltage", Frequency.realtime),
    MakeElementTemplate!("ipv", "V", "Inter-Phase Voltage", "Line-to-line voltage average", Frequency.realtime),
    MakeElementTemplate!("ipv1", "V", "Inter-Phase Voltage 1", "Line-to-line voltage AB", Frequency.realtime),
    MakeElementTemplate!("ipv2", "V", "Inter-Phase Voltage 2", "Line-to-line voltage BC", Frequency.realtime),
    MakeElementTemplate!("ipv3", "V", "Inter-Phase Voltage 3", "Line-to-line voltage CA", Frequency.realtime),
    MakeElementTemplate!("current", "A", "Current", "Line current", Frequency.realtime),
    MakeElementTemplate!("current1", "A", "Current 1", "Phase A Current", Frequency.realtime),
    MakeElementTemplate!("current2", "A", "Current 2", "Phase B Current", Frequency.realtime),
    MakeElementTemplate!("current3", "A", "Current 3", "Phase C Current", Frequency.realtime),
    MakeElementTemplate!("power", "W", "Active Power", null, Frequency.realtime),
    MakeElementTemplate!("power1", "W", "Active Power 1", "Phase A Active Power", Frequency.realtime),
    MakeElementTemplate!("power2", "W", "Active Power 2", "Phase B Active Power", Frequency.realtime),
    MakeElementTemplate!("power3", "W", "Active Power 3", "Phase C Active Power", Frequency.realtime),
    MakeElementTemplate!("apparent", "VA", "Apparent Power", null, Frequency.realtime),
    MakeElementTemplate!("apparent1", "VA", "Apparent Power 1", "Phase A Apparent Power", Frequency.realtime),
    MakeElementTemplate!("apparent2", "VA", "Apparent Power 2", "Phase B Apparent Power", Frequency.realtime),
    MakeElementTemplate!("apparent3", "VA", "Apparent Power 3", "Phase C Apparent Power", Frequency.realtime),
    MakeElementTemplate!("reactive", "var", "Reactive Power", null, Frequency.realtime),
    MakeElementTemplate!("reactive1", "var", "Reactive Power 1", "Phase A Reactive Power", Frequency.realtime),
    MakeElementTemplate!("reactive2", "var", "Reactive Power 2", "Phase B Reactive Power", Frequency.realtime),
    MakeElementTemplate!("reactive3", "var", "Reactive Power 3", "Phase C Reactive Power", Frequency.realtime),
    MakeElementTemplate!("pf", "1", "Power Factor", null, Frequency.realtime),
    MakeElementTemplate!("pf1", "1", "Power Factor 1", "Phase A Power Factor", Frequency.realtime),
    MakeElementTemplate!("pf2", "1", "Power Factor 2", "Phase B Power Factor", Frequency.realtime),
    MakeElementTemplate!("pf3", "1", "Power Factor 3", "Phase C Power Factor", Frequency.realtime),
    MakeElementTemplate!("frequency", "Hz", "Frequency", "Line frequency", Frequency.realtime),
    MakeElementTemplate!("phase", "deg", "Phase Angle", null, Frequency.realtime),
//    MakeElementTemplate!("nature", "LoadNature", "Load Nature", "Load nature", Frequency.constant), // TODO: maybe move the LoadNature enum into core and make it 1st class?
];

__gshared immutable KnownElementTemplate[] g_CumulativeEnergyMeter_elements = [
    MakeElementTemplate!("type", "CircuitType", "Meter Type", "Circuit type of energy meter", Frequency.constant),
    MakeElementTemplate!("import", "kWh", "Total Import Energy", "Accumulated imported active energy", Frequency.medium),
    MakeElementTemplate!("import1", "kWh", "Total Import Energy 1", "Phase A imported active energy", Frequency.medium),
    MakeElementTemplate!("import2", "kWh", "Total Import Energy 2", "Phase B imported active energy", Frequency.medium),
    MakeElementTemplate!("import3", "kWh", "Total Import Energy 3", "Phase C imported active energy", Frequency.medium),
    MakeElementTemplate!("export", "kWh", "Total Export Energy", "Accumulated exported active energy", Frequency.medium),
    MakeElementTemplate!("export1", "kWh", "Total Export Energy 1", "Phase A exported active energy", Frequency.medium),
    MakeElementTemplate!("export2", "kWh", "Total Export Energy 2", "Phase B exported active energy", Frequency.medium),
    MakeElementTemplate!("export3", "kWh", "Total Export Energy 3", "Phase C exported active energy", Frequency.medium),
    MakeElementTemplate!("net", "kWh", "Total (Net) Active Energy", "Net accumulated active energy", Frequency.medium),
    MakeElementTemplate!("net1", "kWh", "Total (Net) Active Energy 1", "Phase A net accumulated active energy", Frequency.medium),
    MakeElementTemplate!("net2", "kWh", "Total (Net) Active Energy 2", "Phase B net accumulated active energy", Frequency.medium),
    MakeElementTemplate!("net3", "kWh", "Total (Net) Active Energy 3", "Phase C net accumulated active energy", Frequency.medium),
    MakeElementTemplate!("absolute", "kWh", "Gross (Absolute) Active Energy", "Absolute accumulated active energy", Frequency.medium),
    MakeElementTemplate!("absolute1", "kWh", "Gross (Absolute) Active Energy 1", "Phase A absolute accumulated active energy", Frequency.medium),
    MakeElementTemplate!("absolute2", "kWh", "Gross (Absolute) Active Energy 2", "Phase B absolute accumulated active energy", Frequency.medium),
    MakeElementTemplate!("absolute3", "kWh", "Gross (Absolute) Active Energy 3", "Phase C absolute accumulated active energy", Frequency.medium),
    MakeElementTemplate!("import_reactive", "kvarh", "Total Import Reactive Energy", "Accumulated imported reactive energy", Frequency.medium),
    MakeElementTemplate!("import_reactive1", "kvarh", "Total Import Reactive Energy 1", "Phase A imported reactive energy", Frequency.medium),
    MakeElementTemplate!("import_reactive2", "kvarh", "Total Import Reactive Energy 2", "Phase B imported reactive energy", Frequency.medium),
    MakeElementTemplate!("import_reactive3", "kvarh", "Total Import Reactive Energy 3", "Phase C imported reactive energy", Frequency.medium),
    MakeElementTemplate!("export_reactive", "kvarh", "Total Export Reactive Energy", "Accumulated exported reactive energy", Frequency.medium),
    MakeElementTemplate!("export_reactive1", "kvarh", "Total Export Reactive Energy 1", "Phase A exported reactive energy", Frequency.medium),
    MakeElementTemplate!("export_reactive2", "kvarh", "Total Export Reactive Energy 2", "Phase B exported reactive energy", Frequency.medium),
    MakeElementTemplate!("export_reactive3", "kvarh", "Total Export Reactive Energy 3", "Phase C exported reactive energy", Frequency.medium),
    MakeElementTemplate!("net_reactive", "kvarh", "Total (Net) Reactive Energy", "Net accumulated reactive energy", Frequency.medium),
    MakeElementTemplate!("net_reactive1", "kvarh", "Total (Net) Reactive Energy 1", "Phase A net accumulated reactive energy", Frequency.medium),
    MakeElementTemplate!("net_reactive2", "kvarh", "Total (Net) Reactive Energy 2", "Phase B net accumulated reactive energy", Frequency.medium),
    MakeElementTemplate!("net_reactive3", "kvarh", "Total (Net) Reactive Energy 3", "Phase C net accumulated reactive energy", Frequency.medium),
    MakeElementTemplate!("absolute_reactive", "kvarh", "Gross (Absolute) Reactive Energy", "Absolute accumulated reactive energy", Frequency.medium),
    MakeElementTemplate!("absolute_reactive1", "kvarh", "Gross (Absolute) Reactive Energy 1", "Phase A absolute accumulated reactive energy", Frequency.medium),
    MakeElementTemplate!("absolute_reactive2", "kvarh", "Gross (Absolute) Reactive Energy 2", "Phase B absolute accumulated reactive energy", Frequency.medium),
    MakeElementTemplate!("absolute_reactive3", "kvarh", "Gross (Absolute) Reactive Energy 3", "Phase C absolute accumulated reactive energy", Frequency.medium),
    MakeElementTemplate!("total_apparent", "kVAh", "Total Apparent Energy", "Accumulated apparent energy", Frequency.medium),
    MakeElementTemplate!("total_apparent1", "kVAh", "Total Apparent Energy 1", "Phase A accumulated apparent energy", Frequency.medium),
    MakeElementTemplate!("total_apparent2", "kVAh", "Total Apparent Energy 2", "Phase B accumulated apparent energy", Frequency.medium),
    MakeElementTemplate!("total_apparent3", "kVAh", "Total Apparent Energy 3", "Phase C accumulated apparent energy", Frequency.medium),
];

__gshared immutable KnownElementTemplate[] g_DemandEnergyMeter_elements = [
    MakeElementTemplate!("demand", "W", "Active Demand", "Active power demand", Frequency.medium),
    MakeElementTemplate!("demand1", "W", "Active Demand 1", "Phase A active power demand", Frequency.medium),
    MakeElementTemplate!("demand2", "W", "Active Demand 2", "Phase B active power demand", Frequency.medium),
    MakeElementTemplate!("demand3", "W", "Active Demand 3", "Phase C active power demand", Frequency.medium),
    MakeElementTemplate!("reactive_demand", "var", "Reactive Demand", "Reactive power demand", Frequency.medium),
    MakeElementTemplate!("reactive_demand1", "var", "Reactive Demand 1", "Phase A reactive power demand", Frequency.medium),
    MakeElementTemplate!("reactive_demand2", "var", "Reactive Demand 2", "Phase B reactive power demand", Frequency.medium),
    MakeElementTemplate!("reactive_demand3", "var", "Reactive Demand 3", "Phase C reactive power demand", Frequency.medium),
    MakeElementTemplate!("apparent_demand", "VA", "Apparent Demand", "Apparent power demand", Frequency.medium),
    MakeElementTemplate!("current_demand", "A", "Current Demand", "Line current demand", Frequency.medium),
    MakeElementTemplate!("import_demand", "W", "Import Demand", "Import active power demand", Frequency.medium),
    MakeElementTemplate!("export_demand", "W", "Export Demand", "Export active power demand", Frequency.medium),
    MakeElementTemplate!("max_demand", "W", "Maximum Demand", "Maximum active power demand", Frequency.medium),
    MakeElementTemplate!("max_reactive_demand", "var", "Maximum Reactive Demand", "Maximum reactive power demand", Frequency.medium),
    MakeElementTemplate!("max_apparent_demand", "VA", "Maximum Apparent Demand", "Maximum apparent power demand", Frequency.medium),
    MakeElementTemplate!("max_current_demand", "A", "Maximum Current Demand", "Maximum line current demand", Frequency.medium),
    MakeElementTemplate!("max_import_demand", "W", "Maximum Import Demand", "Maximum import active power demand", Frequency.medium),
    MakeElementTemplate!("max_export_demand", "W", "Maximum Export Demand", "Maximum export active power demand", Frequency.medium),
    MakeElementTemplate!("min_demand", "W", "Minimum Demand", "Minimum active power demand", Frequency.medium),
];

__gshared immutable KnownElementTemplate[] g_Battery_elements = [
    MakeElementTemplate!("soc", "%", "State of Charge", null, Frequency.high),
    MakeElementTemplate!("soh", "%", "State of Health", null, Frequency.low),
//    MakeElementTemplate!("mode", "BatteryMode", "Battery Mode", "Current battery operating mode", Frequency.high), // TODO: move enum and hook up
    MakeElementTemplate!("temp", "°C", "Temperature", "Average/representative battery temperature", Frequency.low),
    MakeElementTemplate!("low_battery", "Boolean", "Low Battery Warning", null, Frequency.medium),
    MakeElementTemplate!("remain_capacity", "Ah", "Remaining Capacity", null, Frequency.realtime),
    MakeElementTemplate!("full_capacity", "Ah", "Full Capacity", null, Frequency.low),
    MakeElementTemplate!("cycle_count", "Count", "Charge Cycles", "Number of charge cycles completed", Frequency.low),
    MakeElementTemplate!("max_charge_current", "A", "Max Charge Current", "Maximum realtime charge current", Frequency.realtime),
    MakeElementTemplate!("max_discharge_current", "A", "Max Discharge Current", "Maximum realtime discharge current", Frequency.realtime),
    MakeElementTemplate!("max_charge_power", "W", "Max Charge Power", "Maximum reltime charge power", Frequency.realtime),
    MakeElementTemplate!("max_discharge_power", "W", "Max Discharge Power", "Maximum realtime discharge power", Frequency.realtime),
    // cell voltages/temps
    MakeElementTemplate!("mosfet_temp", "°C", "MOSFET Temperature", null, Frequency.low),
    MakeElementTemplate!("env_temp", "°C", "Environment Temperature", null, Frequency.low),
//    MakeElementTemplate!("warning_flag", "Bitfield", "Warning Flags", "Battery warning flags", Frequency.high),
//    MakeElementTemplate!("protection_flag", "Bitfield", "Protection Flags", "Battery protection flags", Frequency.high),
//    MakeElementTemplate!("status_fault_flag", "Bitfield", "Status/Fault Flags", "Battery status/fault flags", Frequency.high),
//    MakeElementTemplate!("balance_status", "Bitfield", "Cell Balance Status", "Battery cell balance status", Frequency.high),
];

__gshared immutable KnownElementTemplate[] g_BatteryConfig_elements = [
    MakeElementTemplate!("topology", null, "Battery Topology", "Battery arrangement description", Frequency.constant),
    MakeElementTemplate!("pack_count", null, "Pack Count", "Number of battery packs/modules", Frequency.constant),
    MakeElementTemplate!("packs_series", null, "Packs in Series", "Number of battery packs in series", Frequency.constant),
    MakeElementTemplate!("packs_parallel", null, "Packs in Parallel", "Number of battery packs in parallel", Frequency.constant),
    MakeElementTemplate!("cell_count", null, "Cell Count", "Total number of cells in the pack", Frequency.constant),
    MakeElementTemplate!("cells_series", null, "Cells in Series", "Number of cells in series in the pack", Frequency.constant),
    MakeElementTemplate!("cells_parallel", null, "Cells in Parallel", "Number of cells in parallel in the pack", Frequency.constant),
    MakeElementTemplate!("cell_chemistry", null, "Cell Chemistry", "Battery cell chemistry type", Frequency.constant),
    MakeElementTemplate!("voltage_min", "V", "Minimum Voltage", "Minimum allowable pack voltage", Frequency.constant),
    MakeElementTemplate!("voltage_max", "V", "Maximum Voltage", "Maximum allowable pack voltage", Frequency.constant),
    MakeElementTemplate!("cell_voltage_min", "V", "Minimum Cell Voltage", "Minimum allowable cell voltage", Frequency.constant),
    MakeElementTemplate!("cell_voltage_max", "V", "Maximum Cell Voltage", "Maximum allowable cell voltage", Frequency.constant),
    MakeElementTemplate!("design_capacity", "Ah", "Design Capacity", "Design/nominal battery capacity", Frequency.constant),
    MakeElementTemplate!("rated_energy", "Wh", "Rated Energy Capacity", "Rated energy capacity of the battery pack", Frequency.constant),
    MakeElementTemplate!("max_charge_current", "A", "Max Charge Current", "Maximum continuous charge current", Frequency.constant),
    MakeElementTemplate!("max_discharge_current", "A", "Max Discharge Current", "Maximum continuous discharge current", Frequency.constant),
    MakeElementTemplate!("peak_charge_current", "A", "Peak Charge Current", "Peak charge current (short duration)", Frequency.constant),
    MakeElementTemplate!("peak_discharge_current", "A", "Peak Discharge Current", "Peak discharge current (short duration)", Frequency.constant),
    MakeElementTemplate!("max_charge_power", "W", "Max Charge Power", null, Frequency.constant),
    MakeElementTemplate!("max_discharge_power", "W", "Max Discharge Power", null, Frequency.constant),
    MakeElementTemplate!("temp_min_charge", "°C", "Min Charging Temperature", "Minimum allowable charging temperature", Frequency.constant),
    MakeElementTemplate!("temp_max_charge", "°C", "Max Charging Temperature", "Maximum allowable charging temperature", Frequency.constant),
    MakeElementTemplate!("temp_min_discharge", "°C", "Min Discharging Temperature", "Minimum allowable discharging temperature", Frequency.constant),
    MakeElementTemplate!("temp_max_discharge", "°C", "Max Discharging Temperature", "Maximum allowable discharging temperature", Frequency.constant),
];

__gshared immutable KnownElementTemplate[] g_Solar_elements = [
//    MakeElementTemplate!("state", "PVState", "PV State", "Current solar PV state", Frequency.high), // TODO: move enum and hook up
//    MakeElementTemplate!("mode", "PVModes", "Operating Mode", "Current solar PV operating mode", Frequency.high), // TODO: move enum and hook up
    MakeElementTemplate!("temp", "°C", "Temperature", "Panel/module temperature", Frequency.low),
    MakeElementTemplate!("efficiency", "%", "Efficiency", "MPPT/conversion efficiency", Frequency.medium),
];

__gshared immutable KnownElementTemplate[] g_SolarConfig_elements = [
    MakeElementTemplate!("panel_count", null, "Panel Count", "Total number of panels in the array", Frequency.constant),
    MakeElementTemplate!("string_count", null, "String Count", "Number of strings in the array", Frequency.constant),
    MakeElementTemplate!("topology", null, "Array Topology", "Array arrangement description", Frequency.constant),
    MakeElementTemplate!("rated_power", "W", "Rated Power", "Panel rated power (Wp)", Frequency.constant),
    MakeElementTemplate!("voltage_mpp", "V", "Voltage at MPP", "Voltage at maximum power point", Frequency.constant),
    MakeElementTemplate!("current_mpp", "A", "Current at MPP", "Current at maximum power point", Frequency.constant),
    MakeElementTemplate!("voltage_oc", "V", "Open Circuit Voltage", null, Frequency.constant),
    MakeElementTemplate!("current_sc", "A", "Short Circuit Current", null, Frequency.constant),
    MakeElementTemplate!("temp_coeff_power", "%/°C", "Temperature Coefficient of Power", null, Frequency.constant),
    MakeElementTemplate!("temp_coeff_voltage", "V/°C", "Temperature Coefficient of Voltage", null, Frequency.constant),
];

__gshared immutable KnownElementTemplate[] g_Inverter_elements = [
//    MakeElementTemplate!("state", "???", "Inverter State", "Current inverter operating state", Frequency.high), // TODO: standardise these enums
//    MakeElementTemplate!("mode", "???", "Inverter Mode", "Current inverter operating mode", Frequency.high),
    MakeElementTemplate!("temp", "°C", "Temperature", "Inverter temperature", Frequency.low),
    MakeElementTemplate!("rated_power", "W", "Rated Power", "Inverter rated output power", Frequency.constant),
    MakeElementTemplate!("efficiency", "%", "Efficiency", "Current conversion efficiency", Frequency.high),
    MakeElementTemplate!("bus_voltage", "V", "DC Bus Voltage", null, Frequency.realtime),
];

__gshared immutable KnownElementTemplate[] g_EVSE_elements = [
//    MakeElementTemplate!("state", "J1772PilotState", "EVSE State", "Current J1772 pilot state", Frequency.high), // TODO: ...
//    MakeElementTemplate!("error", "Bitfield", "Error Flags", "EVSE error flags", Frequency.high),
    MakeElementTemplate!("connected", "Boolean", "Vehicle Connected", null, Frequency.medium),
    MakeElementTemplate!("session_energy", "Wh", "Session Energy", "Energy delivered in current charging session", Frequency.low),
    MakeElementTemplate!("lifetime_energy", "Wh", "Lifetime Energy", "Total energy delivered by the EVSE", Frequency.low),
];

__gshared immutable KnownElementTemplate[] g_Vehicle_elements = [
    MakeElementTemplate!("vin", null, "Vehicle Identification Number", null, Frequency.constant),
    MakeElementTemplate!("soc", "%", "State of Charge", null, Frequency.medium),
    MakeElementTemplate!("range", "km", "Remaining Range", null, Frequency.medium),
    MakeElementTemplate!("battery_capacity", "kWh", "Battery Capacity", null, Frequency.constant),
];

__gshared immutable KnownElementTemplate[] g_ChargeControl_elements = [
    MakeElementTemplate!("max_current", "A", "Max Charging Current", "Maximum charging current/limit", Frequency.constant),
    MakeElementTemplate!("min_current", "A", "Min Charging Current", "Minimum charging current", Frequency.constant),
    MakeElementTemplate!("target_current", "A", "Target Charging Current", "Target/commanded charging current", Frequency.realtime),
    MakeElementTemplate!("actual_current", "A", "Actual Charging Current", "Actual charging current", Frequency.realtime), // TODO: should this be represented by a meter instead?
    MakeElementTemplate!("max_power", "W", "Max Charging Power", "Maximum charging power", Frequency.constant),
    MakeElementTemplate!("target_power", "W", "Target Charging Power", "Target/commanded charging power", Frequency.realtime),
    MakeElementTemplate!("actual_power", "W", "Actual Charging Power", "Actual charging power", Frequency.realtime), // TODO: should this be represented by a meter instead?
];

__gshared immutable KnownElementTemplate[] g_Switch_elements = [
    MakeElementTemplate!("switch", "Boolean", "Switch State", null, Frequency.realtime),
//    MakeElementTemplate!("mode", "SwitchMode", "Switch Mode", "Current switch mode", Frequency.high), // TODO: ...
    MakeElementTemplate!("timer", "s", "Timer", "Timer value", Frequency.high),
];

__gshared immutable KnownElementTemplate[] g_ContactSensor_elements = [
    MakeElementTemplate!("open", "Boolean", "Open State", "Open/closed state of the sensor", Frequency.realtime),
    MakeElementTemplate!("alarm", "Boolean", "Alarm Status", "Alarm status of the sensor", Frequency.realtime),
    MakeElementTemplate!("tamper", "Boolean", "Tamper Detection", "Tamper detection status", Frequency.high),
];

__gshared immutable KnownElementTemplate[] g_ModbusConfig_elements = [
    MakeElementTemplate!("address", null, "Modbus Address", "Modbus slave address (1-247)", Frequency.configuration),
    MakeElementTemplate!("baud_rate", null, "Baud Rate", "Serial baud rate", Frequency.configuration),
    MakeElementTemplate!("parity", null, "Parity", "Serial parity setting", Frequency.configuration),
    MakeElementTemplate!("stop_bits", null, "Stop Bits", "Number of stop bits", Frequency.configuration),
];

__gshared immutable KnownElementTemplate[] g_EthernetConfig_elements = [
    MakeElementTemplate!("dhcp_enabled", "Boolean", "DHCP Enabled", "DHCP enable/disable", Frequency.configuration),
    MakeElementTemplate!("ip_address", null, "IP Address", "Static IPv4 address", Frequency.configuration),
    MakeElementTemplate!("gateway", null, "Default Gateway", "Default gateway", Frequency.configuration),
    MakeElementTemplate!("dns_primary", null, "Primary DNS Server", "Primary DNS server address", Frequency.configuration),
    MakeElementTemplate!("dns_secondary", null, "Secondary DNS Server", "Secondary DNS server address", Frequency.configuration),
    MakeElementTemplate!("hostname", null, "Hostname", "Device hostname", Frequency.configuration),
];

__gshared immutable KnownElementTemplate[] g_WifiConfig_elements = [
    MakeElementTemplate!("ssid", null, "SSID", "Target network SSID", Frequency.configuration),
    MakeElementTemplate!("password", null, "Password", "Wi-Fi password/key", Frequency.configuration),
    MakeElementTemplate!("security", null, "Security Mode", "Wi-Fi security mode", Frequency.configuration),
    MakeElementTemplate!("dhcp_enabled", "Boolean", "DHCP Enabled", "DHCP enable/disable", Frequency.configuration),
    MakeElementTemplate!("ip_address", null, "IP Address", "Static IPv4 address", Frequency.configuration),
    MakeElementTemplate!("gateway", null, "Default Gateway", "Default gateway", Frequency.configuration),
];

__gshared immutable KnownElementTemplate[] g_CellularConfig_elements = [
    MakeElementTemplate!("apn", null, "APN", "Access point name", Frequency.configuration),
    MakeElementTemplate!("username", null, "Username", "APN username", Frequency.configuration),
    MakeElementTemplate!("password", null, "Password", "APN password", Frequency.configuration),
    MakeElementTemplate!("pin", null, "SIM PIN", "SIM PIN code", Frequency.configuration),
];

__gshared immutable KnownElementTemplate[] g_ZigbeeConfig_elements = [
];
