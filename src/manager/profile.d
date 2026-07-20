module manager.profile;

import urt.algorithm : binary_search, qsort;
import urt.array;
import urt.conv;
import urt.hash;
import urt.log;
import urt.map;
import urt.mem;
import urt.mem.string;
import urt.meta.enuminfo;
import urt.si.unit : ScaledUnit;
import urt.string;
import urt.string.format;

import manager.component;

import manager.sample.codec : Encoding;
import manager.config;
import manager.device;
import manager.element;
import manager.sample : find_enum_info, mint_desc, register_enum_info, SampleDesc;
import manager.series : DataFormat, ValueType;
import manager.sample.spec : compile_spec, LayoutContext;

version = IncludeDescription;

nothrow @nogc:


alias ModelMask = ushort;

enum Access : ubyte
{
    none = 0,
    read = 1,
    write = 2,
    read_write = 3
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

enum SumType : ubyte
{
    sum,                // strict sum
    right,              // Riemann sum - right (when samples are already averages for the period)
    trapezoid,          // Riemann sum - trapezoid (for instantaneous samples)
    positive_trapezoid, // Riemann sum - trapezoid excluding negative signal
    negative_trapezoid, // Riemann sum - trapezoid excluding positive signal
}

SamplingMode freq_to_element_mode(Frequency frequency)
{
    final switch (frequency)
    {
        case Frequency.realtime:
        case Frequency.high:
        case Frequency.medium:
        case Frequency.low:
            return SamplingMode.poll;
        case Frequency.constant:
            return SamplingMode.constant;
        case Frequency.on_demand:
            return SamplingMode.on_demand;
        case Frequency.report:
            return SamplingMode.report;
        case Frequency.configuration:
            return SamplingMode.config;
    }
}

struct ElementDesc
{
pure nothrow @nogc:
    CacheString display_units;
    Access access = Access.read;
    Frequency update_frequency = Frequency.medium;

    uint kind() const
        => _kind;

    size_t element() const
        => _index;

    const(char)[] get_description(ref const(Profile) profile) const
        => _description.cache_string(profile.desc_strings);

private:
    ubyte _kind;
    ushort _index;
    ushort _description;
}

struct ProfileCosts
{
    size_t string_bytes;

    void add_string(const(char)[] value) pure nothrow @nogc
    {
        if (value.length)
            string_bytes += 2 + value.length + (value.length & 1);
    }
}

struct ProfileBuilder
{
nothrow @nogc:

    Profile* profile;
    const(char)[] element_id;

    bool compile_value(const(char)[] type, const(char)[] following, ref const LayoutContext ctx,
                       out ushort desc_index, out ubyte span)
    {
        const(char)[] units = following;
        const(char)[] value_type = type.split!('/', false);
        Access access = type.parse_access();
        // The following column is access in normalized profiles; other values are the
        // legacy units/enum column until the profile sweep is complete.
        if (units == "R" || units == "W" || units == "RW")
        {
            access = units.parse_access();
            units = null;
        }
        if (_element)
            _element.access = access;
        type = value_type;

        const(VoidEnumInfo)* resolve(const(char)[] name)
            => profile.find_enum_template(name);

        bool has_ref = false;
        foreach (c; type)
            has_ref |= c == ':';

        ScaledUnit unit;
        float pre_scale = 1;
        const(VoidEnumInfo)* ei = null;
        SampleDesc desc;
        if (units.length && !has_ref)
        {
            // legacy two-column spellings: enum names and dt formats ride the units column
            if (type.startsWith("enum") || type.startsWith("bf"))
            {
                ei = profile.find_enum_template(units);
                if (!ei)
                    writeWarning("Unknown enum type: ", units);
                units = null;
            }
            else if (type.startsWith("dt"))
            {
                char[64] spelled = void;
                size_t len = type.length + 1 + units.length;
                if (len <= spelled.length)
                {
                    spelled[0 .. type.length] = type[];
                    spelled[type.length] = ':';
                    spelled[type.length + 1 .. len] = units[];
                    if (compile_spec(spelled[0 .. len], ctx, unit, 1, null, &resolve, desc))
                    {
                        desc_index = mint_desc(desc);
                        span = desc.enc.wire_bytes;
                        return true;
                    }
                }
                writeWarning("Invalid date_time format: ", units);
                return false;
            }
        }
        if (units.length)
        {
            ptrdiff_t taken = unit.parseUnit(units, pre_scale);
            if (taken != units.length)
                writeWarning("Invalid units '", units, "' for element: ", element_id);
        }
        if (!compile_spec(type, ctx, unit, pre_scale, ei, &resolve, desc))
        {
            writeWarning("Invalid data type '", type, "' for element: ", element_id);
            return false;
        }
        desc_index = mint_desc(desc);
        span = wire_span(desc, type);
        return true;
    }

    const(VoidEnumInfo)* find_enum(const(char)[] name)
        => profile.find_enum_template(name);

    ushort intern(const(char)[] s)
        => _strings ? _strings.add_string(s) : 0;

    void access(Access value)
    {
        if (_element)
            _element.access = value;
    }

private:
    StringCacheBuilder* _strings;
    ElementDesc* _element;
}

interface ProfileSections
{
nothrow @nogc:
    uint element_size(uint kind);
    void count_element(uint kind, ref const ConfItem item, ref ProfileCosts costs);
    // slot is element_size bytes; the handler emplaces its own struct's init before filling
    bool parse_element(uint kind, ref const ConfItem item, void[] slot, ref ProfileBuilder b);
}

interface ProfileRootSections
{
nothrow @nogc:
    uint root_size(uint kind, ref const ConfItem item);
    void count_root(uint kind, ref const ConfItem item, ref ProfileCosts costs);
    // slot is root_size bytes and belongs to this parsed Profile
    bool parse_root(uint kind, ref const ConfItem item, void[] slot, ref ProfileBuilder b);
}

enum uint first_section_kind = 16;

uint register_profile_section(const(char)[] name, ProfileSections handler)
{
    debug foreach (ref s; g_profile_sections)
        assert(s.name != name, "profile section already registered");
    uint kind = cast(uint)(first_section_kind + g_profile_sections.length);
    assert(kind <= ubyte.max, "too many profile sections");
    g_profile_sections ~= ProfileSectionReg(name, handler, kind);
    return kind;
}

enum uint first_root_section_kind = 1;

uint register_profile_root_section(const(char)[] name, ProfileRootSections handler)
{
    debug foreach (ref s; g_profile_root_sections)
        assert(s.name != name, "profile root section already registered");
    uint kind = cast(uint)(first_root_section_kind + g_profile_root_sections.length);
    g_profile_root_sections ~= ProfileRootSectionReg(name, handler, kind);
    return kind;
}

struct ElementTemplate
{
pure nothrow @nogc:
    enum Type : ubyte
    {
        expression,
        map,
        sum,
        alias_
    }

    Type type;
    ubyte index;

    Access access = Access.read;
    Frequency update_frequency = Frequency.medium;

    CacheString display_units;

    const(char)[] get_id(ref const(Profile) profile) const
        => _id.cache_string(profile.id_strings);

    const(char)[] get_name(ref const(Profile) profile) const
        => profile.name_strings ? _name.cache_string(profile.name_strings) : null;

    const(char)[] get_desc(ref const(Profile) profile) const
        => profile.desc_strings ? _description.cache_string(profile.desc_strings) : null;

    const(char)[] get_expression(ref const(Profile) profile) const
    {
        assert(type == Type.expression, "ElementTemplate is not of type `expression`");
        return _value.cache_string(profile.expression_strings);
    }

    const(char*) get_source(ref const(Profile) profile) const
    {
        assert(type == Type.sum || type == Type.alias_, "ElementTemplate is not of type `sum` or `alias`");
        return profile.id_strings.ptr + _value;
    }

    ref inout(ElementDesc) get_element_desc(ref inout(Profile) profile) inout
    {
        assert(type == Type.map, "ElementTemplate is not of type `map`");
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
        => _id.cache_string(profile.id_strings);

    const(char)[] get_template() const
        => _template[];

    bool is_hidden() const
        => _hidden;

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
    bool _hidden;
}

struct DeviceTemplate
{
pure nothrow @nogc:
    size_t num_models() const
        => _models.length;

    const(char)[] get_model(size_t i, ref const(Profile) profile) const
        => _models[i].cache_string(profile.id_strings);

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
        if (expression_strings)
            defaultAllocator().freeArray(expression_strings);
        if(param_strings)
            defaultAllocator().freeArray(param_strings);
        foreach (ref b; section_blocks)
            if (b.data)
                defaultAllocator().free(b.data);
        if(section_blocks)
            defaultAllocator().freeArray(section_blocks);
        foreach (ref b; root_blocks)
            if (b.data)
                defaultAllocator().free(b.data);
        if(root_blocks)
            defaultAllocator().freeArray(root_blocks);
        if(section_strings)
            defaultAllocator().freeArray(section_strings);
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
        if (const(VoidEnumInfo)** enum_info = name in enum_templates)
            return *enum_info;
        return find_enum_info(name);
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
                const(char)[] eid = lookup_table[i].id.cache_string(lookup_strings);
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

    ref const(T) get_section(T)(uint kind, size_t i) const pure
    {
        foreach (ref b; section_blocks)
        {
            if (b.kind == kind)
            {
                assert(T.sizeof <= b.esize && i < b.count);
                return *cast(const(T)*)(b.data.ptr + i*b.esize);
            }
        }
        assert(false, "no such profile section");
    }

    const(void)[] get_root_section(uint kind) const pure
    {
        foreach (ref b; root_blocks)
            if (b.kind == kind)
                return b.data;
        return null;
    }

    const(char)[] get_section_string(ushort offset) const pure
        => offset.cache_string(section_strings);

    auto get_parameters() const pure
        => StringRange(param_strings, indirections[_params .. _params + _param_count]);

    void drop_lookup_strings()
    {
        if (!lookup_strings)
            return;

        foreach (ref l; lookup_table)
        {
            auto id = l.id.cache_string(lookup_strings);
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

    struct StringRange
    {
        const(char)[] str_cache;
        const(ushort)[] list;

    pure nothrow @nogc:
        bool empty() const
            => list.length == 0;
        size_t length() const
            => list.length;
        const(char)[] front() const
            => list[0].cache_string(str_cache);
        void popFront()
        {
            list = list[1 .. $];
        }
    }

    String name;

    struct SectionBlock
    {
        uint kind;
        ushort esize;
        ushort count;
        void[] data;
    }

    struct RootBlock
    {
        uint kind;
        void[] data;
    }

    DeviceTemplate[] device_templates;
    ComponentTemplate[] component_templates;
    ElementTemplate[] element_templates;
    ElementDesc[] elements;
    Lookup[] lookup_table;
    SectionBlock[] section_blocks;
    RootBlock[] root_blocks;
    ushort[] indirections;
    char[] id_strings;
    char[] name_strings;
    char[] lookup_strings;
    char[] expression_strings;
    char[] desc_strings;
    char[] param_strings;
    char[] section_strings;
    ushort _params, _param_count;

    Map!(String, const(VoidEnumInfo)*) enum_templates;
}

unittest
{
    import urt.si.unit : ScaledUnit;
    import manager.sample.codec : clear_encoding_registry, find_encoding, register_builtin_encodings;
    import manager.sample.spec : stream_le_context;

    assert(!find_encoding("yymmddhhmmss"));
    register_builtin_encodings();
    scope(exit) clear_encoding_registry();

    // wire spans for byte-stream maps (CAN): derived per family from the compiled desc
    {
        import manager.series : ValueType;
        SampleDesc d;
        assert(compile_spec("u16", stream_le_context, ScaledUnit(), 1, null, null, d));
        assert(wire_span(d, "u16") == 2);
        assert(compile_spec("str8", stream_le_context, ScaledUnit(), 1, null, null, d));
        assert(d.fmt.type == ValueType.char_ && wire_span(d, "str8") == 8);
        assert(compile_spec("u8[8]", stream_le_context, ScaledUnit(), 1, null, null, d));
        assert(wire_span(d, "u8[8]") == 8);
        assert(compile_spec("dt48:yymmddhhmmss", stream_le_context, ScaledUnit(), 1, null, null, d));
        assert(wire_span(d, "dt48:yymmddhhmmss") == 6);
    }

    // registered-section parse: handler fills its slots through ProfileBuilder; legacy
    // two-column spellings, one-token `u16:0.1V`, and enum templates all resolve
    {
        const(char)[] joined = "3, u16:0.1V\tdesc: singleTokenVolts";
        assert(joined.split_element_and_desc() == "3, u16:0.1V");
        assert(joined == "desc: singleTokenVolts");

        static struct TDesc
        {
            ubyte addr;
            ubyte length;
            ushort desc = 0xFFFF;
        }
        static class TestSections : ProfileSections
        {
        nothrow @nogc:
            uint element_size(uint)
                => cast(uint)TDesc.sizeof;
            void count_element(uint, ref const ConfItem, ref ProfileCosts) {}
            bool parse_element(uint kind, ref const ConfItem item, void[] slot, ref ProfileBuilder b)
            {
                TDesc* d = cast(TDesc*)slot.ptr;
                *d = TDesc.init;
                const(char)[] tail = item.value;
                const(char)[] addr = tail.split!',';
                const(char)[] type = tail.split!','.unQuote;
                const(char)[] units = tail.split!','.unQuote;
                size_t taken;
                d.addr = cast(ubyte)addr.parse_uint_with_base(&taken);
                return b.compile_value(type, units, stream_le_context, d.desc, d.length);
            }
        }
        static struct TRoot
        {
            ushort first;
            ushort second;
        }
        static class TestRoots : ProfileRootSections
        {
        nothrow @nogc:
            uint root_size(uint, ref const ConfItem)
                => cast(uint)TRoot.sizeof;
            void count_root(uint, ref const ConfItem item, ref ProfileCosts costs)
            {
                const(char)[] tail = item.value;
                costs.add_string(tail.split!','.unQuote);
                costs.add_string(tail.split!','.unQuote);
            }
            bool parse_root(uint, ref const ConfItem item, void[] slot, ref ProfileBuilder b)
            {
                TRoot* root = cast(TRoot*)slot.ptr;
                const(char)[] tail = item.value;
                root.first = b.intern(tail.split!','.unQuote);
                root.second = b.intern(tail.split!','.unQuote);
                return true;
            }
        }
        uint tsec = register_profile_section("tsec", defaultAllocator().allocT!TestSections());
        uint troot = register_profile_root_section("troot", defaultAllocator().allocT!TestRoots());

        static immutable string conf_text =
            "enum: Mode\n" ~
            "\toff: 0\n" ~
            "\teco: 1\n" ~
            "\n" ~
            "troot: alpha, beta\n" ~
            "\n" ~
            "registers:\n" ~
            "\ttsec: 1, u16, 0.1V\tdesc: chargeVoltage\n" ~
            "\ttsec: 2, enum8, Mode\tdesc: mode\n" ~
            "\ttsec: 3, u16:0.1V\tdesc: singleTokenVolts\n" ~
            "\ttsec: 4, str8, W\tdesc: name\n" ~
            "\ttsec: 5, str8/W\tdesc: legacyName\n";
        Profile* prof = parse_profile(conf_text, "tprof");
        assert(prof !is null);

        import manager.sample : desc_by_index;

        // The normalized descriptor carries the scaling and native format directly.
        ref const TDesc cv = prof.get_section!TDesc(tsec, 0);
        assert(cv.desc != 0xFFFF && cv.length == 2 && cv.addr == 1);
        SampleDesc cvd = desc_by_index(cv.desc);
        assert(cvd.fmt.type == ValueType.f64);
        assert(cvd.pre_scale == 0.1);

        // profile enums register qualified and resolve locally by bare name
        ref const TDesc md = prof.get_section!TDesc(tsec, 1);
        assert(md.desc != 0xFFFF && md.length == 1);
        assert(desc_by_index(md.desc).fmt.enum_info is prof.find_enum_template("Mode"));
        assert(find_enum_info("tprof.Mode") is prof.find_enum_template("Mode"));

        // the one-token spelling mints the same desc as the two-column form
        ref const TDesc st = prof.get_section!TDesc(tsec, 2);
        assert(st.desc == cv.desc);

        ref const TDesc nm = prof.get_section!TDesc(tsec, 3);
        assert(desc_by_index(nm.desc).fmt.type == ValueType.char_ && nm.length == 8);
        assert(prof.elements[3].access == Access.write);
        assert(prof.get_section!TDesc(tsec, 4).desc == nm.desc);
        assert(prof.elements[4].access == Access.write);

        assert(prof.elements.length == 5);
        assert(prof.elements[0].kind == tsec && prof.elements[1].element == 1);

        const(void)[] root_data = prof.get_root_section(troot);
        assert(root_data.length == TRoot.sizeof);
        ref const TRoot root = *cast(const(TRoot)*)root_data.ptr;
        assert(prof.get_section_string(root.first) == "alpha");
        assert(prof.get_section_string(root.second) == "beta");
    }
}

Profile* load_profile(const(char)[] filename, NoGCAllocator allocator = defaultAllocator())
{
    import urt.file;

    void[] file = load_file(filename, allocator);
    scope (exit) { allocator.free(file); }
    if (!file)
        return null;

    const(char)[] name = filename;
    foreach_reverse (i, c; name)
    {
        if (c == '/' || c == '\\')
        {
            name = name[i+1 .. $];
            break;
        }
    }
    foreach_reverse (i, c; name)
    {
        if (c == '.')
        {
            name = name[0 .. i];
            break;
        }
    }
    return parse_profile(cast(const char[])file, name, allocator);
}

Profile* parse_profile(const(char)[] conf, const(char)[] profile_name = null, NoGCAllocator allocator = defaultAllocator())
{
    ConfItem root = parse_config(conf);
    return parse_profile(root, profile_name, allocator);
}

Profile* parse_profile(ConfItem conf, const(char)[] profile_name = null, NoGCAllocator allocator = defaultAllocator())
{
    Profile* profile = allocator.allocT!Profile();

    // first we need to count up all the memory...
    size_t item_count = 0;
    size_t id_string_length = 0;
    size_t name_string_length = 0;
    size_t lookup_string_len = 0;
    size_t expression_string_len = 0;
    size_t desc_string_len = 0;
    size_t param_string_len = 0;
    size_t num_device_templates = 0;
    size_t num_component_templates = 0;
    size_t num_element_templates = 0;
    size_t num_indirections = 0;

    ProfileCosts section_costs;
    Array!ushort section_counts;
    section_counts.resize(g_profile_sections.length);
    Array!uint root_sizes;
    root_sizes.resize(g_profile_root_sections.length);

    // we need to count the items and buffer lengths
    foreach (ref root_item; conf.sub_items) switch (root_item.name)
    {
        case "enum":
        case "bitfield":
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
            VoidEnumInfo* enum_info = parse_enum(root_item, root_item.name == "bitfield");
            if (!enum_info)
            {
                writeWarning("Failed to parse enum: ", enum_name);
                break;
            }

            char[128] qualified = void;
            size_t qlen = profile_name.length + 1 + enum_name.length;
            assert(qlen <= qualified.length, "qualified enum name too long");
            qualified[0 .. profile_name.length] = profile_name[];
            qualified[profile_name.length] = '.';
            qualified[profile_name.length + 1 .. qlen] = enum_name[];
            const(VoidEnumInfo)* canonical = register_enum_info(qualified[0 .. qlen], enum_info);
            profile.enum_templates.insert(enum_name.makeString(allocator), canonical);
            break;

        case "parameters":
            const(char)[] tail = root_item.value;
            while (!tail.empty)
            {
                const(char)[] value = tail.split!','.unQuote;
                if (value.empty)
                    continue;

                param_string_len += cache_len(value.length);
                ++num_indirections;
            }
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
                        continue;

                    tail = reg_conf.value;
                    const(char)[] id = tail.split!','.unQuote;
                    const(char)[] display_units = tail.split!','.unQuote;
                    const(char)[] freq = tail.split!','.unQuote;
                    const(char)[] desc = tail.split!','.unQuote;
                    if (!tail.empty)
                        writeWarning("Unexpected data in element desc: ", tail);

                    lookup_string_len += cache_len(id.length);
                    desc_string_len += cache_len(desc.length);
                }

                if (ProfileSectionReg* s = find_profile_section(reg_item.name))
                {
                    ++section_counts[s.kind - first_section_kind];
                    s.handler.count_element(s.kind, reg_item, section_costs);
                }
                else
                    writeWarning("Unknown element type: ", reg_item.name);
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
                    ElementTemplate.Type ty = ElementTemplate.Type.expression;
                    switch (cItem.name)
                    {
                        case "id":
                            id_string_length += cache_len(cItem.value.unQuote.length);
                            break;

                        case "template":
                            // add template string to string cache...
                            break;

                        case "hidden":
                            break;

                        case "element-alias":
                            ty = ElementTemplate.Type.alias_;
                            goto case "element";
                        case "element-sum":
                            ty = ElementTemplate.Type.sum;
                            goto case "element";
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

                            if (ty == ElementTemplate.Type.expression)
                                expression_string_len += cache_len(tail.length);
                            else if (ty == ElementTemplate.Type.alias_)
                            {
                                const(char)[] target = tail.split!','.unQuote;
                                if (target.length < 2 || target[0] != '@')
                                {
                                    writeWarning("Invalid element-alias target: ", target);
                                    continue;
                                }
                                id_string_length += cache_len(target.length);
                            }
                            else if (ty == ElementTemplate.Type.sum)
                            {
                                const(char)[] alg = tail.split!',';
                                const(char)[] src = tail.split!',';
                                if (!enum_from_key!SumType(alg))
                                {
                                    writeWarning("Invalid element-sum algorithm: ", alg);
                                    continue;
                                }
                                if (src.length < 2 || src[0] != '@')
                                {
                                    writeWarning("Invalid element-sum source: ", src);
                                    continue;
                                }
                                id_string_length += cache_len(src.length);
                            }

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
                                if (!tail.empty)
                                    writeWarning("Unexpected data in element desc: ", tail);

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
            if (ProfileRootSectionReg* s = find_profile_root_section(root_item.name))
            {
                size_t i = s.kind - first_root_section_kind;
                if (root_sizes[i])
                    writeWarning("Duplicate ", root_item.name, " definition");
                else
                {
                    uint bytes = s.handler.root_size(s.kind, root_item);
                    assert(bytes > 0, "profile root sections must allocate storage");
                    root_sizes[][i] = bytes;
                    s.handler.count_root(s.kind, root_item, section_costs);
                }
            }
            else
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
    profile.id_strings = allocator.allocArray!char(2 + id_string_length);
    profile.name_strings = allocator.allocArray!char(2 + name_string_length);
    profile.lookup_strings = allocator.allocArray!char(2 + lookup_string_len);
    profile.expression_strings = allocator.allocArray!char(2 + expression_string_len);
    profile.desc_strings = allocator.allocArray!char(2 + desc_string_len);
    profile.param_strings = allocator.allocArray!char(2 + param_string_len);

    size_t active_sections = 0;
    foreach (n; section_counts)
        if (n)
            ++active_sections;
    profile.section_blocks = allocator.allocArray!(Profile.SectionBlock)(active_sections);
    profile.section_strings = allocator.allocArray!char(2 + section_costs.string_bytes);
    {
        size_t sb = 0;
        foreach (ref s; g_profile_sections)
        {
            ushort n = section_counts[s.kind - first_section_kind];
            if (!n)
                continue;
            uint esz = s.handler.element_size(s.kind);
            profile.section_blocks[sb++] = Profile.SectionBlock(s.kind, cast(ushort)esz, n, allocator.allocArray!ubyte(n * esz));
        }
    }

    size_t active_roots = 0;
    foreach (n; root_sizes)
        if (n)
            ++active_roots;
    profile.root_blocks = allocator.allocArray!(Profile.RootBlock)(active_roots);
    {
        size_t rb = 0;
        foreach (i, ref s; g_profile_root_sections)
        {
            uint n = root_sizes[i];
            if (n)
                profile.root_blocks[rb++] = Profile.RootBlock(s.kind, allocator.allocArray!ubyte(n));
        }
    }

    StringCacheBuilder id_cache, name_cache, lookup_cache, expr_cache, desc_cache, param_string_cache;
    if (profile.name_strings)
        id_cache = StringCacheBuilder(profile.id_strings);
    if (profile.name_strings)
        name_cache = StringCacheBuilder(profile.name_strings);
    if (profile.lookup_strings)
        lookup_cache = StringCacheBuilder(profile.lookup_strings);
    if (profile.expression_strings)
        expr_cache = StringCacheBuilder(profile.expression_strings);
    if (profile.desc_strings)
        desc_cache = StringCacheBuilder(profile.desc_strings);
    if (profile.param_strings)
        param_string_cache = StringCacheBuilder(profile.param_strings);

    StringCacheBuilder section_string_cache;
    if (profile.section_strings)
        section_string_cache = StringCacheBuilder(profile.section_strings);

    ProfileBuilder builder;
    builder.profile = profile;
    builder._strings = profile.section_strings ? &section_string_cache : null;

    num_device_templates = 0;
    num_component_templates = 0;
    num_element_templates = 0;
    num_indirections = 0;
    item_count = 0;
    section_counts[][] = 0;
    Array!bool root_parsed;
    root_parsed.resize(g_profile_root_sections.length);

    foreach (ref root_item; conf.sub_items)
    {
        if (root_item.name != "parameters")
            continue;
        if (profile._param_count > 0)
        {
            writeWarning("Duplicate parameters definition");
            continue;
        }
        profile._params = cast(ushort)num_indirections;
        const(char)[] tail = root_item.value;
        while (!tail.empty)
        {
            const(char)[] value = tail.split!','.unQuote;
            if (value.empty)
                continue;
            profile.indirections[num_indirections++] = param_string_cache.add_string(value);
            ++profile._param_count;
        }
    }

    foreach (ref root_item; conf.sub_items)
    {
        ProfileRootSectionReg* s = find_profile_root_section(root_item.name);
        if (!s)
            continue;
        size_t i = s.kind - first_root_section_kind;
        if (root_parsed[][i])
            continue;
        root_parsed[][i] = true;
        ref Profile.RootBlock blk = root_block(profile, s.kind);
        s.handler.parse_root(s.kind, root_item, blk.data, builder);
    }

    // parse the elements
    foreach (ref root_item; conf.sub_items) switch (root_item.name)
    {
        case "parameters":
            break;

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

                if (ProfileSectionReg* s = find_profile_section(reg_item.name))
                {
                    ref Profile.SectionBlock blk = section_block(profile, s.kind);
                    ushort idx = section_counts[s.kind - first_section_kind]++;
                    e._kind = cast(ubyte)s.kind;
                    e._index = idx;
                    builder.element_id = id;
                    builder._element = &e;
                    s.handler.parse_element(s.kind, reg_item, blk.data[idx*blk.esize .. (idx+1)*blk.esize], builder);
                }
                else
                    writeWarning("Unknown element type: ", reg_item.name);
            }
            break;

        case "device-template":
            ref DeviceTemplate device = profile.device_templates[num_device_templates++];

            void allocate_component(ref ConfItem conf)
            {
                ref ComponentTemplate component = profile.component_templates[num_component_templates++];

                foreach (ref cItem; conf.sub_items) switch (cItem.name)
                {
                    case "element-alias":
                    case "element-sum":
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
            break;
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

                    case "hidden":
                        component._hidden = cItem.value.unQuote != "false";
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
                    ElementTemplate.Type ty = ElementTemplate.Type.expression;
                    switch (cItem.name)
                    {
                        case "element-alias":
                            ty = ElementTemplate.Type.alias_;
                            goto case "element";
                        case "element-sum":
                            ty = ElementTemplate.Type.sum;
                            goto case "element";
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

                            if (ty == ElementTemplate.Type.expression)
                            {
                                // element value is the expression
                                e._value = expr_cache.add_string(tail);
                            }
                            else if (ty == ElementTemplate.Type.alias_)
                            {
                                const(char)[] target = tail.split!','.unQuote;
                                if (target.length < 2 || target[0] != '@')
                                {
                                    writeWarning("Invalid element-alias target: ", target);
                                    continue;
                                }
                                e._value = id_cache.add_string(target[1 .. $]);
                            }
                            else if (ty == ElementTemplate.Type.sum)
                            {
                                const(char)[] alg = tail.split!',';
                                const(char)[] src = tail.split!',';

                                const(SumType)* sum_type = enum_from_key!SumType(alg);
                                if (!sum_type || src.length < 2 || src[0] != '@')
                                    continue; // error alrady reported in prior pass
                                src = src[1 .. $];

                                // index is the algorithm, _value is the data source
                                e.index = *sum_type;
                                e._value = id_cache.add_string(src);
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

                            // TODO: should we be able to specify this at the element template level?
                            //       ElementDesc will always override it since there's no 'unknown' state...
                            e.access = elem_desc ? elem_desc.access : Access.read;

                            // TODO: default should be on-demand, but this is more useful while debugging.
                            e.update_frequency = Frequency.medium;
                            if (!freq.empty)
                            {
                                if (freq.ieq("realtime")) e.update_frequency = Frequency.realtime;
                                else if (freq.ieq("high")) e.update_frequency = Frequency.high;
                                else if (freq.ieq("medium")) e.update_frequency = Frequency.medium;
                                else if (freq.ieq("low")) e.update_frequency = Frequency.low;
                                else if (freq.ieq("const")) e.update_frequency = Frequency.constant;
                                else if (freq.ieq("ondemand")) e.update_frequency = Frequency.on_demand;
                                else if (freq.ieq("on_demand")) e.update_frequency = Frequency.on_demand;
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

VoidEnumInfo* parse_enum(ConfItem conf, bool is_bitfield = false)
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
                is_bitfield = true;     // shift syntax declares flag members
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
    VoidEnumInfo* info;
    if (min >= byte.min && max <= byte.max)
    {
        auto b_values = cast(byte[])talloc(1 * count);
        foreach (i, v; t_vals)
            b_values[i] = cast(byte)v;
        info = make_enum_info(enum_name, keys[], b_values[]);
    }
    else if (min >= short.min && max <= short.max)
    {
        auto s_values = cast(short[])talloc(2 * count);
        foreach (i, v; t_vals)
            s_values[i] = cast(short)v;
        info = make_enum_info(enum_name, keys[], s_values[]);
    }
    else if (min >= int.min && max <= int.max)
    {
        auto i_values = cast(int[])talloc(4 * count);
        foreach (i, v; t_vals)
            i_values[i] = cast(int)v;
        info = make_enum_info(enum_name, keys[], i_values[]);
    }
    else
        info = make_enum_info(enum_name, keys[], t_vals[]);
    info.bitfield = is_bitfield;
    return info;
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

// substitute {parameter} placeholders in a string.
MutableString!0 substitute_parameters(const(char)[] pattern, scope const(char)[] delegate(size_t offset, const(char)[] param) nothrow @nogc get_sub, ref bool unclosed_token)
{
    auto r = MutableString!0(Reserve, pattern.length);
    size_t i;
    outer: while (i < pattern.length)
    {
        if (pattern[i] != '{')
        {
            r ~= pattern[i++];
            continue;
        }

        size_t tok_end = pattern[i .. $].findFirst('}');
        if (tok_end == pattern.length - i)
        {
            unclosed_token = true;
            return MutableString!0(); // unclosed token
        }

        const(char)[] sub = get_sub(r.length, pattern[i + 1 .. i + tok_end]);
        r ~= sub;
        i = i + tok_end + 1;
    }
    return r;
}


private:

struct ProfileSectionReg
{
    const(char)[] name;
    ProfileSections handler;
    uint kind;
}

struct ProfileRootSectionReg
{
    const(char)[] name;
    ProfileRootSections handler;
    uint kind;
}

__gshared Array!ProfileSectionReg g_profile_sections;
__gshared Array!ProfileRootSectionReg g_profile_root_sections;

ProfileSectionReg* find_profile_section(const(char)[] name)
{
    foreach (ref s; g_profile_sections)
    {
        if (s.name == name)
            return &s;
    }
    return null;
}

ProfileRootSectionReg* find_profile_root_section(const(char)[] name)
{
    foreach (ref s; g_profile_root_sections)
    {
        if (s.name == name)
            return &s;
    }
    return null;
}

ref Profile.SectionBlock section_block(Profile* p, uint kind)
{
    foreach (ref b; p.section_blocks)
    {
        if (b.kind == kind)
            return b;
    }
    assert(false, "no such profile section");
}

ref Profile.RootBlock root_block(Profile* p, uint kind)
{
    foreach (ref b; p.root_blocks)
    {
        if (b.kind == kind)
            return b;
    }
    assert(false, "no such profile root section");
}

// the wire byte span a compiled desc reads; strN's numeral is the field's char count
ubyte wire_span(ref const SampleDesc desc, const(char)[] spec)
{
    if (const(Encoding)* enc = desc.enc)
        return enc.wire_bytes;
    const(DataFormat)* fmt = desc.fmt;
    if (fmt.type == ValueType.char_)
    {
        uint n = 0;
        size_t i = 3;   // char_ only compiles from the str family
        while (i < spec.length && spec[i] >= '0' && spec[i] <= '9')
            n = n*10 + (spec[i++] - '0');
        return cast(ubyte)n;
    }
    uint count = fmt.count ? fmt.count : 1;
    return cast(ubyte)(desc.layout.container_bytes * count);
}

size_t cache_len(size_t str_len) pure
    => str_len ? 2 + str_len + (str_len & 1) : 0;

inout(char)[] cache_string(ushort offset, inout(char)[] cache) pure
    => offset ? as_dstring(cache.ptr + offset) : null;

int lookup_cmp(ref const Profile.Lookup a, ref const Profile.Lookup b) pure
    => a.hash - b.hash;

const(char)[] split_element_and_desc(ref const(char)[] line) pure
{
    import urt.util : swap;

    size_t desc = line.length;
    for (size_t i = 0; i + 5 <= line.length; ++i)
    {
        if ((i == 0 || is_whitespace(line[i - 1])) && line[i .. i + 5] == "desc:")
        {
            desc = i;
            break;
        }
    }
    if (desc == line.length)
        return line.swap(null);

    const(char)[] element = line[0 .. desc].trimBack;
    line = line[desc .. $];
    return element;
}

Access parse_access(ref const(char)[] access) pure
{
    if (access.length > 0)
    {
        if (access[0] == 'R')
        {
            if (access.length > 1 && access[1] == 'W')
                return Access.read_write;
        }
        else if (access[0] == 'W')
            return Access.write;
    }
    return Access.read;
}

template make_element_template(string id, string units, string name, string desc, Frequency update_frequency)
{
    enum string text = id ~ units ~ name ~ desc;
    enum make_element_template = KnownElementTemplate(text.ptr, ushort(id.length), ushort(name.length), ushort(desc.length), ubyte(units.length), update_frequency);
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
    "EnergyMeter": g_EnergyMeter_elements,
    "Battery": g_Battery_elements,
    "BatteryConfig": g_BatteryConfig_elements,
    "Solar": g_Solar_elements,
    "SolarConfig": g_SolarConfig_elements,
    "Inverter": g_Inverter_elements,
    "InverterConfig": g_InverterConfig_elements,
    "EVSE": g_EVSE_elements,
    "Port": g_Port_elements,
    "Vehicle": g_Vehicle_elements,
    "WaterHeater": g_WaterHeater_elements,
    "PowerControl": g_PowerControl_elements,
    "Switch": g_Switch_elements,
    "ContactSensor": g_ContactSensor_elements,
    "ModbusConfig": g_ModbusConfig_elements,
    "EthernetConfig": g_EthernetConfig_elements,
    "WifiConfig": g_WifiConfig_elements,
    "CellularConfig": g_CellularConfig_elements,
    "ZigbeeConfig": g_ZigbeeConfig_elements,
];

__gshared immutable KnownElementTemplate[] g_DeviceInfo_elements = [
    make_element_template!("type", null, "Device Type", "Device category", Frequency.constant),
    make_element_template!("name", null, "Device Name", "Device display name", Frequency.constant),
    make_element_template!("manufacturer_name", null, "Manufacturer", "Manufacturer display name", Frequency.constant),
    make_element_template!("manufacturer_id", null, "Manufacturer ID", "Manufacturer identifier code", Frequency.constant),
    make_element_template!("brand_name", null, "Brand", "Brand display name", Frequency.constant),
    make_element_template!("brand_id", null, "Brand ID", "Brand idenitifier code", Frequency.constant),
    make_element_template!("model_name", null, "Model", "Model display name", Frequency.constant),
    make_element_template!("model_id", null, "Model ID", "Model identifier code", Frequency.constant),
    make_element_template!("serial_number", null, "Serial Number", null, Frequency.constant),
    make_element_template!("firmware_version", null, "Firmware Version", null, Frequency.constant),
    make_element_template!("hardware_version", null, "Hardware Version", null, Frequency.constant),
    make_element_template!("software_version", null, "Software Version", null, Frequency.constant),
    make_element_template!("app_ver", null, "Application Version", "Zigbee application version", Frequency.constant),
    make_element_template!("zcl_ver", null, "ZCL Version", "Zigbee ZCL version", Frequency.constant),
];

__gshared immutable KnownElementTemplate[] g_DeviceStatus_elements = [
    make_element_template!("time", "systime", "Current Time", null, Frequency.high),
    make_element_template!("up_time", "s", "Uptime", null, Frequency.high),
    make_element_template!("running_time", "s", "Running Time", "Total Running Time", Frequency.high),
    make_element_template!("running_time_with_load", "s", "Running Time With Load", "Running time under load", Frequency.high),
];

__gshared immutable KnownElementTemplate[] g_Network_elements = [
    make_element_template!("mode", null, "Network Mode", "Active network mode/type", Frequency.high),
];

__gshared immutable KnownElementTemplate[] g_Modbus_elements = [
    make_element_template!("status", null, "Connection Status", null, Frequency.high),
    make_element_template!("variant", null, "Protocol Variant", "rtu, tcp, or ascii", Frequency.constant),
    make_element_template!("address", null, "Device Address", "Modbus slave/unit address", Frequency.constant),
];

__gshared immutable KnownElementTemplate[] g_Ethernet_elements = [
    make_element_template!("status", null, "Connection Status", null, Frequency.high),
    make_element_template!("link_speed", "Mbps", "Link Speed", null, Frequency.high),
    make_element_template!("mac_address", null, "MAC Address", null, Frequency.low),
    make_element_template!("ip_address", null, "IP Address", null, Frequency.medium),
    make_element_template!("gateway", null, "Default Gateway", null, Frequency.medium),
];

__gshared immutable KnownElementTemplate[] g_Wifi_elements = [
    make_element_template!("status", null, "Connection Status", null, Frequency.high),
    make_element_template!("ssid", null, "SSID", "Connected network SSID", Frequency.high),
    make_element_template!("rssi", "dBm", "Signal Strength", null, Frequency.high),
    make_element_template!("bssid", null, "BSSID", "Connected AP MAC address", Frequency.high),
    make_element_template!("channel", null, "Channel", "Wi-Fi channel", Frequency.high),
];

__gshared immutable KnownElementTemplate[] g_Cellular_elements = [
    make_element_template!("status", null, "Connection Status", null, Frequency.high),
    make_element_template!("signal_strength", "dBm", "Signal Strength", null, Frequency.realtime),
    make_element_template!("operator", null, "Network Operator", null, Frequency.low),
    make_element_template!("imei", null, "Device IMEI", null, Frequency.low),
    make_element_template!("iccid", null, "SIM ICCID", "ID of GPRS/4G module", Frequency.low),
    make_element_template!("ip_address", null, "IP Address", null, Frequency.medium),
];

__gshared immutable KnownElementTemplate[] g_Zigbee_elements = [
    make_element_template!("status", null, "Connection Status", null, Frequency.high),
    make_element_template!("rssi", "dBm", "Received Signal Power", null, Frequency.realtime),
    make_element_template!("lqi", null, "Link Quality Index", null, Frequency.realtime),
    make_element_template!("eui", null, "EUI64", "MAC address", Frequency.low),
    make_element_template!("address", null, "Network Address", null, Frequency.medium),
];

__gshared immutable KnownElementTemplate[] g_EnergyMeter_elements = [
    make_element_template!("type", "CircuitType", "Meter Type", "Circuit type of energy meter", Frequency.constant),
    make_element_template!("voltage", "V", "Voltage", "Line voltage", Frequency.realtime),
    make_element_template!("voltage1", "V", "Voltage 1", "Phase A Voltage", Frequency.realtime),
    make_element_template!("voltage2", "V", "Voltage 2", "Phase B Voltage", Frequency.realtime),
    make_element_template!("voltage3", "V", "Voltage 3", "Phase C Voltage", Frequency.realtime),
    make_element_template!("ipv", "V", "Inter-Phase Voltage", "Line-to-line voltage average", Frequency.realtime),
    make_element_template!("ipv1", "V", "Inter-Phase Voltage 1", "Line-to-line voltage AB", Frequency.realtime),
    make_element_template!("ipv2", "V", "Inter-Phase Voltage 2", "Line-to-line voltage BC", Frequency.realtime),
    make_element_template!("ipv3", "V", "Inter-Phase Voltage 3", "Line-to-line voltage CA", Frequency.realtime),
    make_element_template!("current", "A", "Current", "Line current", Frequency.realtime),
    make_element_template!("current1", "A", "Current 1", "Phase A Current", Frequency.realtime),
    make_element_template!("current2", "A", "Current 2", "Phase B Current", Frequency.realtime),
    make_element_template!("current3", "A", "Current 3", "Phase C Current", Frequency.realtime),
    make_element_template!("power", "W", "Active Power", null, Frequency.realtime),
    make_element_template!("power1", "W", "Active Power 1", "Phase A Active Power", Frequency.realtime),
    make_element_template!("power2", "W", "Active Power 2", "Phase B Active Power", Frequency.realtime),
    make_element_template!("power3", "W", "Active Power 3", "Phase C Active Power", Frequency.realtime),
    make_element_template!("apparent", "VA", "Apparent Power", null, Frequency.realtime),
    make_element_template!("apparent1", "VA", "Apparent Power 1", "Phase A Apparent Power", Frequency.realtime),
    make_element_template!("apparent2", "VA", "Apparent Power 2", "Phase B Apparent Power", Frequency.realtime),
    make_element_template!("apparent3", "VA", "Apparent Power 3", "Phase C Apparent Power", Frequency.realtime),
    make_element_template!("reactive", "var", "Reactive Power", null, Frequency.realtime),
    make_element_template!("reactive1", "var", "Reactive Power 1", "Phase A Reactive Power", Frequency.realtime),
    make_element_template!("reactive2", "var", "Reactive Power 2", "Phase B Reactive Power", Frequency.realtime),
    make_element_template!("reactive3", "var", "Reactive Power 3", "Phase C Reactive Power", Frequency.realtime),
    make_element_template!("pf", "1", "Power Factor", null, Frequency.realtime),
    make_element_template!("pf1", "1", "Power Factor 1", "Phase A Power Factor", Frequency.realtime),
    make_element_template!("pf2", "1", "Power Factor 2", "Phase B Power Factor", Frequency.realtime),
    make_element_template!("pf3", "1", "Power Factor 3", "Phase C Power Factor", Frequency.realtime),
    make_element_template!("frequency", "Hz", "Frequency", "Line frequency", Frequency.realtime),
    make_element_template!("phase", "deg", "Phase Angle", null, Frequency.realtime),
//    make_element_template!("nature", "LoadNature", "Load Nature", "Load nature", Frequency.constant), // TODO: maybe move the LoadNature enum into core and make it 1st class?

    // cumulative energy
    make_element_template!("type", "CircuitType", "Meter Type", "Circuit type of energy meter", Frequency.constant),
    make_element_template!("import", "kWh", "Total Import Energy", "Accumulated imported active energy", Frequency.medium),
    make_element_template!("import1", "kWh", "Total Import Energy 1", "Phase A imported active energy", Frequency.medium),
    make_element_template!("import2", "kWh", "Total Import Energy 2", "Phase B imported active energy", Frequency.medium),
    make_element_template!("import3", "kWh", "Total Import Energy 3", "Phase C imported active energy", Frequency.medium),
    make_element_template!("export", "kWh", "Total Export Energy", "Accumulated exported active energy", Frequency.medium),
    make_element_template!("export1", "kWh", "Total Export Energy 1", "Phase A exported active energy", Frequency.medium),
    make_element_template!("export2", "kWh", "Total Export Energy 2", "Phase B exported active energy", Frequency.medium),
    make_element_template!("export3", "kWh", "Total Export Energy 3", "Phase C exported active energy", Frequency.medium),
    make_element_template!("net", "kWh", "Total (Net) Active Energy", "Net accumulated active energy", Frequency.medium),
    make_element_template!("net1", "kWh", "Total (Net) Active Energy 1", "Phase A net accumulated active energy", Frequency.medium),
    make_element_template!("net2", "kWh", "Total (Net) Active Energy 2", "Phase B net accumulated active energy", Frequency.medium),
    make_element_template!("net3", "kWh", "Total (Net) Active Energy 3", "Phase C net accumulated active energy", Frequency.medium),
    make_element_template!("absolute", "kWh", "Gross (Absolute) Active Energy", "Absolute accumulated active energy", Frequency.medium),
    make_element_template!("absolute1", "kWh", "Gross (Absolute) Active Energy 1", "Phase A absolute accumulated active energy", Frequency.medium),
    make_element_template!("absolute2", "kWh", "Gross (Absolute) Active Energy 2", "Phase B absolute accumulated active energy", Frequency.medium),
    make_element_template!("absolute3", "kWh", "Gross (Absolute) Active Energy 3", "Phase C absolute accumulated active energy", Frequency.medium),
    make_element_template!("q1", "kvarh", "Reactive Energy Q1", "Quadrant 1 reactive energy (active import, inductive)", Frequency.medium),
    make_element_template!("q2", "kvarh", "Reactive Energy Q2", "Quadrant 2 reactive energy (active export, inductive)", Frequency.medium),
    make_element_template!("q3", "kvarh", "Reactive Energy Q3", "Quadrant 3 reactive energy (active export, capacitive)", Frequency.medium),
    make_element_template!("q4", "kvarh", "Reactive Energy Q4", "Quadrant 4 reactive energy (active import, capacitive)", Frequency.medium),
    make_element_template!("inductive", "kvarh", "Inductive Reactive Energy", "Total inductive reactive energy (= q1 + q2)", Frequency.medium),
    make_element_template!("inductive1", "kvarh", "Inductive Reactive Energy 1", "Phase A inductive reactive energy", Frequency.medium),
    make_element_template!("inductive2", "kvarh", "Inductive Reactive Energy 2", "Phase B inductive reactive energy", Frequency.medium),
    make_element_template!("inductive3", "kvarh", "Inductive Reactive Energy 3", "Phase C inductive reactive energy", Frequency.medium),
    make_element_template!("capacitive", "kvarh", "Capacitive Reactive Energy", "Total capacitive reactive energy (= q3 + q4)", Frequency.medium),
    make_element_template!("capacitive1", "kvarh", "Capacitive Reactive Energy 1", "Phase A capacitive reactive energy", Frequency.medium),
    make_element_template!("capacitive2", "kvarh", "Capacitive Reactive Energy 2", "Phase B capacitive reactive energy", Frequency.medium),
    make_element_template!("capacitive3", "kvarh", "Capacitive Reactive Energy 3", "Phase C capacitive reactive energy", Frequency.medium),
    make_element_template!("net_reactive", "kvarh", "Total (Net) Reactive Energy", "Net accumulated reactive energy", Frequency.medium),
    make_element_template!("net_reactive1", "kvarh", "Total (Net) Reactive Energy 1", "Phase A net accumulated reactive energy", Frequency.medium),
    make_element_template!("net_reactive2", "kvarh", "Total (Net) Reactive Energy 2", "Phase B net accumulated reactive energy", Frequency.medium),
    make_element_template!("net_reactive3", "kvarh", "Total (Net) Reactive Energy 3", "Phase C net accumulated reactive energy", Frequency.medium),
    make_element_template!("absolute_reactive", "kvarh", "Gross (Absolute) Reactive Energy", "Absolute accumulated reactive energy", Frequency.medium),
    make_element_template!("absolute_reactive1", "kvarh", "Gross (Absolute) Reactive Energy 1", "Phase A absolute accumulated reactive energy", Frequency.medium),
    make_element_template!("absolute_reactive2", "kvarh", "Gross (Absolute) Reactive Energy 2", "Phase B absolute accumulated reactive energy", Frequency.medium),
    make_element_template!("absolute_reactive3", "kvarh", "Gross (Absolute) Reactive Energy 3", "Phase C absolute accumulated reactive energy", Frequency.medium),
    // reactive energy split by ACTIVE power direction (orthogonal to inductive/capacitive Q-sign split)
    make_element_template!("reactive_import", "kvarh", "Reactive Energy (Active Import)", "Reactive energy accumulated while active power was imported (= q1 + q4)", Frequency.medium),
    make_element_template!("reactive_import1", "kvarh", "Reactive Energy (Active Import) 1", "Phase A reactive energy accumulated while active was imported", Frequency.medium),
    make_element_template!("reactive_import2", "kvarh", "Reactive Energy (Active Import) 2", "Phase B reactive energy accumulated while active was imported", Frequency.medium),
    make_element_template!("reactive_import3", "kvarh", "Reactive Energy (Active Import) 3", "Phase C reactive energy accumulated while active was imported", Frequency.medium),
    make_element_template!("reactive_export", "kvarh", "Reactive Energy (Active Export)", "Reactive energy accumulated while active power was exported (= q2 + q3)", Frequency.medium),
    make_element_template!("reactive_export1", "kvarh", "Reactive Energy (Active Export) 1", "Phase A reactive energy accumulated while active was exported", Frequency.medium),
    make_element_template!("reactive_export2", "kvarh", "Reactive Energy (Active Export) 2", "Phase B reactive energy accumulated while active was exported", Frequency.medium),
    make_element_template!("reactive_export3", "kvarh", "Reactive Energy (Active Export) 3", "Phase C reactive energy accumulated while active was exported", Frequency.medium),

    // apparent energy split by active flow direction at sample time
    make_element_template!("apparent_import", "kVAh", "Apparent Import Energy", "Apparent energy accumulated while active power flowing in", Frequency.medium),
    make_element_template!("apparent_import1", "kVAh", "Apparent Import Energy 1", "Phase A apparent import energy", Frequency.medium),
    make_element_template!("apparent_import2", "kVAh", "Apparent Import Energy 2", "Phase B apparent import energy", Frequency.medium),
    make_element_template!("apparent_import3", "kVAh", "Apparent Import Energy 3", "Phase C apparent import energy", Frequency.medium),
    make_element_template!("apparent_export", "kVAh", "Apparent Export Energy", "Apparent energy accumulated while active power flowing out", Frequency.medium),
    make_element_template!("apparent_export1", "kVAh", "Apparent Export Energy 1", "Phase A apparent export energy", Frequency.medium),
    make_element_template!("apparent_export2", "kVAh", "Apparent Export Energy 2", "Phase B apparent export energy", Frequency.medium),
    make_element_template!("apparent_export3", "kVAh", "Apparent Export Energy 3", "Phase C apparent export energy", Frequency.medium),

    make_element_template!("total_apparent", "kVAh", "Total Apparent Energy", "Accumulated apparent energy", Frequency.medium),
    make_element_template!("total_apparent1", "kVAh", "Total Apparent Energy 1", "Phase A accumulated apparent energy", Frequency.medium),
    make_element_template!("total_apparent2", "kVAh", "Total Apparent Energy 2", "Phase B accumulated apparent energy", Frequency.medium),
    make_element_template!("total_apparent3", "kVAh", "Total Apparent Energy 3", "Phase C accumulated apparent energy", Frequency.medium),

    // demand
    make_element_template!("demand", "W", "Active Demand", "Active power demand", Frequency.medium),
    make_element_template!("demand1", "W", "Active Demand 1", "Phase A active power demand", Frequency.medium),
    make_element_template!("demand2", "W", "Active Demand 2", "Phase B active power demand", Frequency.medium),
    make_element_template!("demand3", "W", "Active Demand 3", "Phase C active power demand", Frequency.medium),
    make_element_template!("reactive_demand", "var", "Reactive Demand", "Reactive power demand", Frequency.medium),
    make_element_template!("reactive_demand1", "var", "Reactive Demand 1", "Phase A reactive power demand", Frequency.medium),
    make_element_template!("reactive_demand2", "var", "Reactive Demand 2", "Phase B reactive power demand", Frequency.medium),
    make_element_template!("reactive_demand3", "var", "Reactive Demand 3", "Phase C reactive power demand", Frequency.medium),
    make_element_template!("apparent_demand", "VA", "Apparent Demand", "Apparent power demand", Frequency.medium),
    make_element_template!("current_demand", "A", "Current Demand", "Line current demand", Frequency.medium),
    make_element_template!("import_demand", "W", "Import Demand", "Import active power demand", Frequency.medium),
    make_element_template!("export_demand", "W", "Export Demand", "Export active power demand", Frequency.medium),
    make_element_template!("max_demand", "W", "Maximum Demand", "Maximum active power demand", Frequency.medium),
    make_element_template!("max_reactive_demand", "var", "Maximum Reactive Demand", "Maximum reactive power demand", Frequency.medium),
    make_element_template!("max_apparent_demand", "VA", "Maximum Apparent Demand", "Maximum apparent power demand", Frequency.medium),
    make_element_template!("max_current_demand", "A", "Maximum Current Demand", "Maximum line current demand", Frequency.medium),
    make_element_template!("max_import_demand", "W", "Maximum Import Demand", "Maximum import active power demand", Frequency.medium),
    make_element_template!("max_export_demand", "W", "Maximum Export Demand", "Maximum export active power demand", Frequency.medium),
    make_element_template!("min_demand", "W", "Minimum Demand", "Minimum active power demand", Frequency.medium),
];

__gshared immutable KnownElementTemplate[] g_Battery_elements = [
    make_element_template!("soc", "%", "State of Charge", null, Frequency.high),
    make_element_template!("soh", "%", "State of Health", null, Frequency.low),
//    make_element_template!("mode", "BatteryMode", "Battery Mode", "Current battery operating mode", Frequency.high), // TODO: move enum and hook up
    make_element_template!("temp", "°C", "Temperature", "Average/representative battery temperature", Frequency.low),
    make_element_template!("low_battery", "Boolean", "Low Battery Warning", null, Frequency.medium),
    make_element_template!("remain_capacity", "Ah", "Remaining Capacity", null, Frequency.realtime),
    make_element_template!("full_capacity", "Ah", "Full Capacity", null, Frequency.low),
    make_element_template!("cycle_count", "Count", "Charge Cycles", "Number of charge cycles completed", Frequency.low),
    make_element_template!("max_charge_current", "A", "Max Charge Current", "Maximum realtime charge current", Frequency.realtime),
    make_element_template!("max_discharge_current", "A", "Max Discharge Current", "Maximum realtime discharge current", Frequency.realtime),
    make_element_template!("max_charge_power", "W", "Max Charge Power", "Maximum reltime charge power", Frequency.realtime),
    make_element_template!("max_discharge_power", "W", "Max Discharge Power", "Maximum realtime discharge power", Frequency.realtime),
    // cell voltages/temps
    make_element_template!("mosfet_temp", "°C", "MOSFET Temperature", null, Frequency.low),
    make_element_template!("env_temp", "°C", "Environment Temperature", null, Frequency.low),
    // energy-management setpoints (optional; writable; tracked by the energy app)
    make_element_template!("target_state", "%", "Target SOC", "SOC target the BMS/inverter should aim for; the energy app may shift this throughout the day", Frequency.high),
    make_element_template!("min_state", "%", "Min SOC", "SOC floor below which the BMS must not discharge regardless of load demand", Frequency.high),
//    make_element_template!("warning_flag", "Bitfield", "Warning Flags", "Battery warning flags", Frequency.high),
//    make_element_template!("protection_flag", "Bitfield", "Protection Flags", "Battery protection flags", Frequency.high),
//    make_element_template!("status_fault_flag", "Bitfield", "Status/Fault Flags", "Battery status/fault flags", Frequency.high),
//    make_element_template!("balance_status", "Bitfield", "Cell Balance Status", "Battery cell balance status", Frequency.high),
];

__gshared immutable KnownElementTemplate[] g_BatteryConfig_elements = [
    make_element_template!("topology", null, "Battery Topology", "Battery arrangement description", Frequency.constant),
    make_element_template!("pack_count", null, "Pack Count", "Number of battery packs/modules", Frequency.constant),
    make_element_template!("packs_series", null, "Packs in Series", "Number of battery packs in series", Frequency.constant),
    make_element_template!("packs_parallel", null, "Packs in Parallel", "Number of battery packs in parallel", Frequency.constant),
    make_element_template!("cell_count", null, "Cell Count", "Total number of cells in the pack", Frequency.constant),
    make_element_template!("cells_series", null, "Cells in Series", "Number of cells in series in the pack", Frequency.constant),
    make_element_template!("cells_parallel", null, "Cells in Parallel", "Number of cells in parallel in the pack", Frequency.constant),
    make_element_template!("cell_chemistry", null, "Cell Chemistry", "Battery cell chemistry type", Frequency.constant),
    make_element_template!("voltage_min", "V", "Minimum Voltage", "Minimum allowable pack voltage", Frequency.constant),
    make_element_template!("voltage_max", "V", "Maximum Voltage", "Maximum allowable pack voltage", Frequency.constant),
    make_element_template!("cell_voltage_min", "V", "Minimum Cell Voltage", "Minimum allowable cell voltage", Frequency.constant),
    make_element_template!("cell_voltage_max", "V", "Maximum Cell Voltage", "Maximum allowable cell voltage", Frequency.constant),
    make_element_template!("design_capacity", "Ah", "Design Capacity", "Design/nominal battery capacity", Frequency.constant),
    make_element_template!("rated_energy", "Wh", "Rated Energy Capacity", "Rated energy capacity of the battery pack", Frequency.constant),
    make_element_template!("max_charge_current", "A", "Max Charge Current", "Maximum continuous charge current", Frequency.constant),
    make_element_template!("max_discharge_current", "A", "Max Discharge Current", "Maximum continuous discharge current", Frequency.constant),
    make_element_template!("peak_charge_current", "A", "Peak Charge Current", "Peak charge current (short duration)", Frequency.constant),
    make_element_template!("peak_discharge_current", "A", "Peak Discharge Current", "Peak discharge current (short duration)", Frequency.constant),
    make_element_template!("max_charge_power", "W", "Max Charge Power", null, Frequency.constant),
    make_element_template!("max_discharge_power", "W", "Max Discharge Power", null, Frequency.constant),
    make_element_template!("temp_min_charge", "°C", "Min Charging Temperature", "Minimum allowable charging temperature", Frequency.constant),
    make_element_template!("temp_max_charge", "°C", "Max Charging Temperature", "Maximum allowable charging temperature", Frequency.constant),
    make_element_template!("temp_min_discharge", "°C", "Min Discharging Temperature", "Minimum allowable discharging temperature", Frequency.constant),
    make_element_template!("temp_max_discharge", "°C", "Max Discharging Temperature", "Maximum allowable discharging temperature", Frequency.constant),
];

__gshared immutable KnownElementTemplate[] g_Solar_elements = [
//    make_element_template!("state", "PVState", "PV State", "Current solar PV state", Frequency.high), // TODO: move enum and hook up
//    make_element_template!("mode", "PVModes", "Operating Mode", "Current solar PV operating mode", Frequency.high), // TODO: move enum and hook up
    make_element_template!("temp", "°C", "Temperature", "Panel/module temperature", Frequency.low),
    make_element_template!("efficiency", "%", "Efficiency", "MPPT/conversion efficiency", Frequency.medium),
];

__gshared immutable KnownElementTemplate[] g_SolarConfig_elements = [
    make_element_template!("panel_count", null, "Panel Count", "Total number of panels in the array", Frequency.constant),
    make_element_template!("string_count", null, "String Count", "Number of strings in the array", Frequency.constant),
    make_element_template!("topology", null, "Array Topology", "Array arrangement description", Frequency.constant),
    make_element_template!("rated_power", "W", "Rated Power", "Panel rated power (Wp)", Frequency.constant),
    make_element_template!("voltage_mpp", "V", "Voltage at MPP", "Voltage at maximum power point", Frequency.constant),
    make_element_template!("current_mpp", "A", "Current at MPP", "Current at maximum power point", Frequency.constant),
    make_element_template!("voltage_oc", "V", "Open Circuit Voltage", null, Frequency.constant),
    make_element_template!("current_sc", "A", "Short Circuit Current", null, Frequency.constant),
    make_element_template!("temp_coeff_power", "%/°C", "Temperature Coefficient of Power", null, Frequency.constant),
    make_element_template!("temp_coeff_voltage", "V/°C", "Temperature Coefficient of Voltage", null, Frequency.constant),
];

__gshared immutable KnownElementTemplate[] g_Inverter_elements = [
    make_element_template!("state", null, "Inverter State", "Operating state", Frequency.high),
    make_element_template!("events", null, "Event Flags", "Active fault/event flags (bitfield)", Frequency.high),
//    make_element_template!("mode", "???", "Inverter Mode", "Current inverter operating mode", Frequency.high),
    make_element_template!("temp", "°C", "Temperature", "Inverter temperature (representative)", Frequency.low),
    make_element_template!("heatsink_temp", "°C", "Heatsink Temperature", "Heatsink temperature (closest to die)", Frequency.low),
    make_element_template!("cabinet_temp", "°C", "Cabinet Temperature", "Cabinet/ambient temperature inside the enclosure", Frequency.low),
    make_element_template!("transformer_temp", "°C", "Transformer Temperature", "Transformer temperature (transformer-based inverters)", Frequency.low),
    make_element_template!("rated_power", "W", "Rated Power", "Inverter rated output power", Frequency.constant),
    make_element_template!("efficiency", "%", "Efficiency", "Current conversion efficiency", Frequency.high),
    make_element_template!("bus_voltage", "V", "DC Bus Voltage", null, Frequency.realtime),
];

__gshared immutable KnownElementTemplate[] g_InverterConfig_elements = [
    make_element_template!("rated_power", "W", "Rated Power", "Rated active power output", Frequency.constant),
    make_element_template!("rated_apparent", "VA", "Rated Apparent Power", "Rated apparent power output", Frequency.constant),
    make_element_template!("rated_current", "A", "Rated Current", "Rated AC current", Frequency.constant),
    make_element_template!("rated_reactive_inject", "var", "Rated Reactive Injection", "Maximum reactive output when injecting (over-excited / leading)", Frequency.constant),
    make_element_template!("rated_reactive_absorb", "var", "Rated Reactive Absorption", "Maximum reactive output when absorbing (under-excited / lagging)", Frequency.constant),
    make_element_template!("pf_over_excited", "1", "Min PF Over-Excited", "Minimum power factor when over-excited (leading)", Frequency.constant),
    make_element_template!("pf_under_excited", "1", "Min PF Under-Excited", "Minimum power factor when under-excited (lagging)", Frequency.constant),
    make_element_template!("voltage_nominal", "V", "Nominal Voltage", "Nominal AC line voltage", Frequency.constant),
    make_element_template!("voltage_min", "V", "Minimum Voltage", "Minimum operational AC line voltage", Frequency.constant),
    make_element_template!("voltage_max", "V", "Maximum Voltage", "Maximum operational AC line voltage", Frequency.constant),
    make_element_template!("intentional_islanding", null, "Intentional Islanding Modes", "Bitfield of supported intentional islanding categories", Frequency.constant),
];

__gshared immutable KnownElementTemplate[] g_EVSE_elements = [
//    make_element_template!("state", "J1772PilotState", "EVSE State", "Current J1772 pilot state", Frequency.high), // TODO: ...
//    make_element_template!("error", "Bitfield", "Error Flags", "EVSE error flags", Frequency.high),
    make_element_template!("connected", "Boolean", "Vehicle Connected", null, Frequency.medium),
    make_element_template!("session_energy", "Wh", "Session Energy", "Energy delivered in current charging session", Frequency.low),
    make_element_template!("lifetime_energy", "Wh", "Lifetime Energy", "Total energy delivered by the EVSE", Frequency.low),
];

__gshared immutable KnownElementTemplate[] g_Port_elements = [
    make_element_template!("role", null, "Port Role", "Stable electrical terminal role", Frequency.constant),
    make_element_template!("flow", null, "Flow Domain", "consume | supply | bidirectional", Frequency.constant),
    make_element_template!("circuit", null, "Circuit", "Connected circuit name", Frequency.high),
    make_element_template!("capacity", "A", "Capacity", "Port current limit", Frequency.constant),
    make_element_template!("closed", "Boolean", "Closed", "Electrical continuity state", Frequency.high),
    make_element_template!("phase", null, "Meter Phase", "Per-phase meter slot", Frequency.constant),
    make_element_template!("meter_sign", null, "Meter Sign", "normal | inverted", Frequency.constant),
];

__gshared immutable KnownElementTemplate[] g_Vehicle_elements = [
    make_element_template!("vin", null, "Vehicle Identification Number", null, Frequency.constant),
    make_element_template!("soc", "%", "State of Charge", null, Frequency.medium),
    make_element_template!("range", "km", "Remaining Range", null, Frequency.medium),
    make_element_template!("battery_capacity", "kWh", "Battery Capacity", null, Frequency.constant),
];

__gshared immutable KnownElementTemplate[] g_PowerControl_elements = [
    make_element_template!("kind", null, "Control Kind", "autonomous | discrete | continuous | staged", Frequency.constant),
    make_element_template!("direction", null, "Direction", "consume | produce | bidirectional", Frequency.constant),
    make_element_template!("unit", null, "Setpoint Unit", "A | W | percent | nameplate_fraction", Frequency.constant),
    make_element_template!("min", null, "Minimum Setpoint", "Minimum non-zero setpoint in `unit`", Frequency.constant),
    make_element_template!("max", null, "Maximum Setpoint", "Maximum setpoint in `unit`", Frequency.constant),
    make_element_template!("step", null, "Setpoint Step", "Resolution of setpoint changes in `unit`", Frequency.constant),
    make_element_template!("setpoint", null, "Setpoint", "The actuator value; type depends on kind/unit", Frequency.realtime),
    make_element_template!("can_disable", "Boolean", "Can Disable", "False for devices that cannot be cleanly turned off", Frequency.constant),
    make_element_template!("min_on_time", "s", "Min On Time", "Minimum duration the device must remain on after being turned on", Frequency.constant),
    make_element_template!("min_off_time", "s", "Min Off Time", "Minimum duration the device must remain off after being turned off", Frequency.constant),
    make_element_template!("min_dwell", "s", "Min Dwell", "Minimum time between setpoint changes", Frequency.constant),
    make_element_template!("max_cycles_per_hour", "Count", "Max Cycles per Hour", "Cap on on-off transitions per hour", Frequency.constant),
    make_element_template!("ramp_rate", null, "Ramp Rate", "Maximum rate of setpoint change in `unit`/s", Frequency.constant),
    make_element_template!("command_latency", "s", "Command Latency", "Typical command-to-effect lag (informational)", Frequency.constant),
    make_element_template!("autonomous_mode", null, "Autonomous Mode", "track_meter | schedule | weather | unknown (when kind=autonomous)", Frequency.constant),
];

__gshared immutable KnownElementTemplate[] g_WaterHeater_elements = [
    make_element_template!("temperature", "°C", "Temperature", "Current water temperature", Frequency.high),
    make_element_template!("target_temperature", "°C", "Target Temperature", "Normal heating setpoint", Frequency.high),
    make_element_template!("min_temperature", "°C", "Min Temperature", "Comfort floor for hot water availability", Frequency.constant),
    make_element_template!("super_temperature", "°C", "Super Temperature", "Opportunistic ceiling for super-heating when surplus energy is available", Frequency.constant),
    make_element_template!("state", null, "Heater State", "Heating/idle/error", Frequency.high),
    make_element_template!("mode", null, "Operating Mode", "Normal/vacation/boost/etc", Frequency.constant),
    make_element_template!("volume", "L", "Tank Volume", "Tank capacity (informational)", Frequency.constant),
];

__gshared immutable KnownElementTemplate[] g_Switch_elements = [
    make_element_template!("switch", "Boolean", "Switch State", null, Frequency.realtime),
//    make_element_template!("mode", "SwitchMode", "Switch Mode", "Current switch mode", Frequency.high), // TODO: ...
    make_element_template!("timer", "s", "Timer", "Timer value", Frequency.high),
    make_element_template!("direction", null, "Direction", "consume | produce | bidirectional", Frequency.constant),
    make_element_template!("nameplate_power", "W", "Nameplate Power", "Known nominal load when on", Frequency.constant),
    make_element_template!("min_on_time", "s", "Min On Time", "Minimum duration the switch must remain on after being turned on", Frequency.constant),
    make_element_template!("min_off_time", "s", "Min Off Time", "Minimum duration the switch must remain off after being turned off", Frequency.constant),
    make_element_template!("min_dwell", "s", "Min Dwell", "Minimum time between transitions", Frequency.constant),
    make_element_template!("max_cycles_per_hour", "Count", "Max Cycles per Hour", "Cap on on-off cycles per hour (relay-protection)", Frequency.constant),
    make_element_template!("command_latency", "s", "Command Latency", "Typical command-to-effect lag (informational)", Frequency.constant),
    make_element_template!("can_disable", "Boolean", "Can Disable", "False for switches that accept commands but cannot be cleanly turned off", Frequency.constant),
];

__gshared immutable KnownElementTemplate[] g_ContactSensor_elements = [
    make_element_template!("open", "Boolean", "Open State", "Open/closed state of the sensor", Frequency.realtime),
    make_element_template!("alarm", "Boolean", "Alarm Status", "Alarm status of the sensor", Frequency.realtime),
    make_element_template!("tamper", "Boolean", "Tamper Detection", "Tamper detection status", Frequency.high),
];

__gshared immutable KnownElementTemplate[] g_ModbusConfig_elements = [
    make_element_template!("address", null, "Modbus Address", "Modbus slave address (1-247)", Frequency.configuration),
    make_element_template!("baud_rate", null, "Baud Rate", "Serial baud rate", Frequency.configuration),
    make_element_template!("parity", null, "Parity", "Serial parity setting", Frequency.configuration),
    make_element_template!("stop_bits", null, "Stop Bits", "Number of stop bits", Frequency.configuration),
];

__gshared immutable KnownElementTemplate[] g_EthernetConfig_elements = [
    make_element_template!("dhcp_enabled", "Boolean", "DHCP Enabled", "DHCP enable/disable", Frequency.configuration),
    make_element_template!("ip_address", null, "IP Address", "Static IPv4 address", Frequency.configuration),
    make_element_template!("gateway", null, "Default Gateway", "Default gateway", Frequency.configuration),
    make_element_template!("dns_primary", null, "Primary DNS Server", "Primary DNS server address", Frequency.configuration),
    make_element_template!("dns_secondary", null, "Secondary DNS Server", "Secondary DNS server address", Frequency.configuration),
    make_element_template!("hostname", null, "Hostname", "Device hostname", Frequency.configuration),
];

__gshared immutable KnownElementTemplate[] g_WifiConfig_elements = [
    make_element_template!("ssid", null, "SSID", "Target network SSID", Frequency.configuration),
    make_element_template!("password", null, "Password", "Wi-Fi password/key", Frequency.configuration),
    make_element_template!("security", null, "Security Mode", "Wi-Fi security mode", Frequency.configuration),
    make_element_template!("dhcp_enabled", "Boolean", "DHCP Enabled", "DHCP enable/disable", Frequency.configuration),
    make_element_template!("ip_address", null, "IP Address", "Static IPv4 address", Frequency.configuration),
    make_element_template!("gateway", null, "Default Gateway", "Default gateway", Frequency.configuration),
];

__gshared immutable KnownElementTemplate[] g_CellularConfig_elements = [
    make_element_template!("apn", null, "APN", "Access point name", Frequency.configuration),
    make_element_template!("username", null, "Username", "APN username", Frequency.configuration),
    make_element_template!("password", null, "Password", "APN password", Frequency.configuration),
    make_element_template!("pin", null, "SIM PIN", "SIM PIN code", Frequency.configuration),
];

__gshared immutable KnownElementTemplate[] g_ZigbeeConfig_elements = [
];
