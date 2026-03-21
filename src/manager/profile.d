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
import urt.string;
import urt.string.format;

import manager.component;

import protocol.http.message : HTTPMethod;
import manager.config;
import manager.device;
import manager.element;
import manager.sampler;

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

enum ElementType : ubyte
{
    modbus,
    can,
    zigbee,
    http,
    aa55,
    mqtt
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

    ElementType type() const
        => cast(ElementType)(_element_index >> 13);

    size_t element() const
        => _element_index & 0x1FFF;

    const(char)[] get_description(ref const(Profile) profile) const
        => _description.cache_string(profile.desc_strings);

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
    ValueDesc value_desc = ValueDesc(modbus_data_type!"u16");
}

struct ElementDesc_CAN
{
    uint message_id;
    ubyte offset;
    ValueDesc value_desc;
}

struct ElementDesc_Zigbee
{
    ushort cluster_id;
    ushort attribute_id;
    ushort manufacturer_code;
    ValueDesc value_desc;
}

struct RequestDesc
{
pure nothrow @nogc:

    enum FormatType : ubyte
    {
        none,       // no body formatting (static URL or URL placeholders)
        json,       // JSON body template with {key}/{value} expand-and-merge
        form,       // key=val&key=val body template with {key}/{value}
    }

    enum ParseMode : ubyte
    {
        json,       // walk JSON response by element paths (default)
        regex,      // element identifier is a regex capture pattern
        none,       // don't parse response
    }

    const(char)[] get_name(ref const(Profile) profile) const
        => _name.cache_string(profile.http_strings);

    const(char)[] get_path(ref const(Profile) profile) const
        => _path.cache_string(profile.http_strings);

    const(char)[] get_body_template(ref const(Profile) profile) const
        => _body_template.cache_string(profile.http_strings);

    const(char)[] get_parse_template(ref const(Profile) profile) const
        => _parse_template.cache_string(profile.http_strings);

    const(char)[] get_root_path(ref const(Profile) profile) const
        => _root_path.cache_string(profile.http_strings);

    const(char)[] get_success_expr(ref const(Profile) profile) const
        => _success_expr.cache_string(profile.http_strings);

    FormatType format_type;
    HTTPMethod method;
    ParseMode parse_mode;

private:
    ushort _name;
    ushort _path;
    ushort _body_template;
    ushort _parse_template;
    ushort _root_path;
    ushort _success_expr;
}

struct ElementDesc_HTTP
{
pure nothrow @nogc:
    const(char)[] get_identifier(ref const(Profile) profile) const
        => _identifier.cache_string(profile.http_strings);

    const(char)[] get_write_key(ref const(Profile) profile) const
        => _write_key.cache_string(profile.http_strings);

    const(char)[] get_response_path(ref const(Profile) profile) const
        => _response_path.cache_string(profile.http_strings);

    ushort request_index;        // index into request_descs[]
    ushort write_request_index;  // index for write, ushort.max if read-only
    bool identifier_quoted;      // true = literal string key, false = walk path
    TextValueDesc value_desc;

private:
    ushort _identifier;    // "evse.temp" or quoted literal
    ushort _write_key;     // override key for write, 0 if same as identifier
    ushort _response_path; // override parse path, 0 if same as identifier
}

struct ElementDesc_AA55
{
    ubyte function_code;
    ubyte offset;
    ValueDesc value_desc;
}

struct ElementDesc_MQTT
{
    ushort read_topic;
    ushort write_topic;
    TextValueDesc value_desc;

pure nothrow @nogc:
    const(char)[] get_read_topic(ref const(Profile) profile) const
        => read_topic.cache_string(profile.mqtt_strings);

    const(char)[] get_write_topic(ref const(Profile) profile) const
        => write_topic.cache_string(profile.mqtt_strings);
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
        if(mqtt_strings)
            defaultAllocator().freeArray(mqtt_strings);
        if(mb_elements)
            defaultAllocator().freeArray(mb_elements);
        if(can_elements)
            defaultAllocator().freeArray(can_elements);
        if(zb_elements)
            defaultAllocator().freeArray(zb_elements);
        if(http_elements)
            defaultAllocator().freeArray(http_elements);
        if(request_descs)
            defaultAllocator().freeArray(request_descs);
        if(http_strings)
            defaultAllocator().freeArray(http_strings);
        if(param_strings)
            defaultAllocator().freeArray(param_strings);
        if(aa55_elements)
            defaultAllocator().freeArray(aa55_elements);
        if(mqtt_elements)
            defaultAllocator().freeArray(mqtt_elements);
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

    ref const(ElementDesc_Modbus) get_mb(size_t i) const pure
        => mb_elements[i];

    ref const(ElementDesc_CAN) get_can(size_t i) const pure
        => can_elements[i];

    ref const(ElementDesc_Zigbee) get_zb(size_t i) const pure
        => zb_elements[i];

    ref const(ElementDesc_HTTP) get_http(size_t i) const pure
        => http_elements[i];

    ref const(RequestDesc) get_request(size_t i) const pure
        => request_descs[i];

    ref const(ElementDesc_AA55) get_aa55(size_t i) const pure
        => aa55_elements[i];

    ref const(ElementDesc_MQTT) get_mqtt(size_t i) const pure
        => mqtt_elements[i];

    auto get_parameters() const pure
        => StringRange(param_strings, indirections[_params .. _params + _param_count]);

    auto get_mqtt_subs() const pure
        => StringRange(mqtt_strings, indirections[_mqtt_subs .. _mqtt_subs + _mqtt_sub_count]);

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

    DeviceTemplate[] device_templates;
    ComponentTemplate[] component_templates;
    ElementTemplate[] element_templates;
    ElementDesc[] elements;
    Lookup[] lookup_table;
    ElementDesc_Modbus[] mb_elements;
    ElementDesc_CAN[] can_elements;
    ElementDesc_Zigbee[] zb_elements;
    ElementDesc_HTTP[] http_elements;
    RequestDesc[] request_descs;
    ElementDesc_AA55[] aa55_elements;
    ElementDesc_MQTT[] mqtt_elements;
    ushort[] indirections;
    char[] id_strings;
    char[] name_strings;
    char[] lookup_strings;
    char[] expression_strings;
    char[] desc_strings;
    char[] param_strings;
    char[] http_strings;
    char[] mqtt_strings;
    ushort _params, _param_count;
    ushort _mqtt_subs, _mqtt_sub_count;

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
    size_t expression_string_len = 0;
    size_t desc_string_len = 0;
    size_t mqtt_string_len = 0;
    size_t http_string_len = 0;
    size_t param_string_len = 0;
    size_t request_count = 0;
    size_t num_device_templates = 0;
    size_t num_component_templates = 0;
    size_t num_element_templates = 0;
    size_t num_indirections = 0;
    size_t mb_count = 0;
    size_t can_count = 0;
    size_t zb_count = 0;
    size_t http_count = 0;
    size_t aa55_count = 0;
    size_t mqtt_count = 0;

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

        case "parameters":
        case "mqtt-variables":
        case "mqtt-subscribe":
            const(char)[] tail = root_item.value;
            bool is_params = root_item.name[] == "parameters" || root_item.name[] == "mqtt-variables";
            while (!tail.empty)
            {
                const(char)[] value = tail.split!','.unQuote;
                if (value.empty)
                    continue;

                if (is_params)
                    param_string_len += cache_len(value.length);
                else
                    mqtt_string_len += cache_len(value.length);
                ++num_indirections;
            }
            break;

        case "requests":
            requests: foreach (ref req_item; root_item.sub_items)
            {
                if (req_item.name != "request")
                {
                    writeWarning("Expected 'request:' in requests block, got: ", req_item.name);
                    continue;
                }
                const(char)[] tail = req_item.value;
                const(char)[] req_name = tail.split!','.unQuote;

                auto p_method = enum_from_key!HTTPMethod(tail.split!','.unQuote);
                if (p_method == null)
                {
                    writeWarning("Unknown HTTP method in request '", req_name, "'");
                    continue;
                }

                const(char)[] path = tail.split!','.unQuote;
                size_t sub_string_len = 0;

                foreach (ref sub; req_item.sub_items)
                {
                    switch (sub.name)
                    {
                        case "success":
                            sub_string_len += cache_len(sub.value.length);
                            break;
                        case "root":
                            sub_string_len += cache_len(sub.value.unQuote.length);
                            break;
                        case "parse":
                            sub_string_len += cache_len(sub.value.unQuote.length);
                            break;
                        case "format":
                            const(char)[] fmt_tail = sub.value;
                            const(char)[] fmt_type = fmt_tail.split!','.unQuote;
                            if (fmt_type == "json" || fmt_type == "form")
                                sub_string_len += cache_len(fmt_tail.unQuote.length);
                            else
                            {
                                writeWarning("Unknown format type '", fmt_type, "' in request '", req_name, "'");
                                continue requests;
                            }
                            break;
                        default:
                            writeWarning("Unknown sub-item '", sub.name, "' in request '", req_name, "'");
                            continue requests;
                    }
                }

                ++request_count;
                http_string_len += cache_len(req_name.length) + cache_len(path.length) + sub_string_len;
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

                switch (reg_item.name)
                {
                    case "mb", "reg": ++mb_count; break;
                    case "can": ++can_count; break;
                    case "zb": ++zb_count; break;
                    case "http":
                        ++http_count;
                        {
                            const(char)[] htail = reg_item.value;
                            htail = htail.split_element_and_desc();
                            const(char)[] req_name = htail.split!','.unQuote;
                            const(char)[] identifier = htail.split!','.unQuote;
                            http_string_len += cache_len(identifier.length);

                            foreach (ref sub; reg_item.sub_items)
                            {
                                if (sub.name == "write")
                                {
                                    const(char)[] wt = sub.value;
                                    const(char)[] w_req = wt.split!','.unQuote;
                                    const(char)[] w_key = wt.split!','.unQuote;
                                    http_string_len += cache_len(w_key.length);
                                }
                                else if (sub.name == "response")
                                    http_string_len += cache_len(sub.value.unQuote.length);
                            }
                        }
                        break;
                    case "aa55": ++aa55_count; break;
                    case "mqtt":
                        ++mqtt_count;
                        tail = reg_item.value;
                        const(char)[] topic = tail.split!','.unQuote;
                        mqtt_string_len += cache_len(topic.length);

                        foreach (ref reg_conf; reg_item.sub_items)
                        {
                            if (reg_conf.name != "write")
                                continue;
                            tail = reg_conf.value;
                            const(char)[] write_topic = tail.split!','.unQuote;
                            mqtt_string_len += cache_len(write_topic.length);
                            break;
                        }
                        break;
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
                    ElementTemplate.Type ty = ElementTemplate.Type.expression;
                    switch (cItem.name)
                    {
                        case "id":
                            id_string_length += cache_len(cItem.value.unQuote.length);
                            break;

                        case "template":
                            // add template string to string cache...
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
    profile.mqtt_strings = allocator.allocArray!char(2 + mqtt_string_len);
    profile.http_strings = allocator.allocArray!char(2 + http_string_len);
    profile.param_strings = allocator.allocArray!char(2 + param_string_len);

    profile.mb_elements = allocator.allocArray!ElementDesc_Modbus(mb_count);
    profile.can_elements = allocator.allocArray!ElementDesc_CAN(can_count);
    profile.zb_elements = allocator.allocArray!ElementDesc_Zigbee(zb_count);
    profile.http_elements = allocator.allocArray!ElementDesc_HTTP(http_count);
    profile.request_descs = allocator.allocArray!RequestDesc(request_count);
    profile.aa55_elements = allocator.allocArray!ElementDesc_AA55(aa55_count);
    profile.mqtt_elements = allocator.allocArray!ElementDesc_MQTT(mqtt_count);

    StringCacheBuilder id_cache, name_cache, lookup_cache, expr_cache, desc_cache, mqtt_string_cache, http_string_cache, param_string_cache;
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
    if (profile.mqtt_strings)
        mqtt_string_cache = StringCacheBuilder(profile.mqtt_strings);
    if (profile.http_strings)
        http_string_cache = StringCacheBuilder(profile.http_strings);
    if (profile.param_strings)
        param_string_cache = StringCacheBuilder(profile.param_strings);

    num_device_templates = 0;
    num_component_templates = 0;
    num_element_templates = 0;
    num_indirections = 0;
    item_count = 0;
    mb_count = 0;
    can_count = 0;
    zb_count = 0;
    http_count = 0;
    request_count = 0;
    aa55_count = 0;
    mqtt_count = 0;

    // parse the elements
    foreach (ref root_item; conf.sub_items) switch (root_item.name)
    {
        case "parameters":
        case "mqtt-variables":
        case "mqtt-subscribe":
            bool is_params = root_item.name == "parameters" || root_item.name == "mqtt-variables";
            if (is_params ? profile._param_count : profile._mqtt_sub_count > 0)
            {
                writeWarning("Duplicate ", root_item.name, " definition");
                break;
            }

            if (is_params)
                profile._params = cast(ushort)num_indirections;
            else
                profile._mqtt_subs = cast(ushort)num_indirections;

            const(char)[] tail = root_item.value;
            while (!tail.empty)
            {
                const(char)[] value = tail.split!','.unQuote;
                if (value.empty)
                    continue;

                if (is_params)
                    profile.indirections[num_indirections++] = param_string_cache.add_string(value);
                else
                    profile.indirections[num_indirections++] = mqtt_string_cache.add_string(value);

                if (is_params)
                    ++profile._param_count;
                else
                    ++profile._mqtt_sub_count;
            }
            break;

        case "requests":
            requests2: foreach (ref req_item; root_item.sub_items)
            {
                if (req_item.name != "request")
                    continue;

                const(char)[] tail = req_item.value;
                const(char)[] req_name = tail.split!','.unQuote;

                auto p_method = enum_from_key!HTTPMethod(tail.split!','.unQuote);
                if (p_method == null)
                    continue;

                const(char)[] path = tail.split!','.unQuote;

                const(char)[] success_expr, root_path, parse_template, body_template;
                RequestDesc.FormatType format_type;
                RequestDesc.ParseMode parse_mode;

                foreach (ref sub; req_item.sub_items)
                {
                    switch (sub.name)
                    {
                        case "success":
                            success_expr = sub.value;
                            break;
                        case "root":
                            root_path = sub.value.unQuote;
                            break;
                        case "parse":
                        {
                            const(char)[] parse_val = sub.value.unQuote;
                            if (parse_val == "regex")
                                parse_mode = RequestDesc.ParseMode.regex;
                            else if (parse_val == "none")
                                parse_mode = RequestDesc.ParseMode.none;
                            else
                            {
                                // "json" or "json, {key}.subpath"
                                const(char)[] parse_tail = sub.value;
                                const(char)[] first = parse_tail.split!','.unQuote;
                                if (first == "json" && !parse_tail.empty)
                                    parse_template = parse_tail.unQuote;
                                else if (first != "json")
                                    parse_template = sub.value.unQuote;
                            }
                            break;
                        }
                        case "format":
                            const(char)[] fmt_tail = sub.value;
                            const(char)[] fmt_type = fmt_tail.split!','.unQuote;
                            if (fmt_type == "json")
                            {
                                format_type = RequestDesc.FormatType.json;
                                body_template = fmt_tail.unQuote;
                            }
                            else if (fmt_type == "form")
                            {
                                format_type = RequestDesc.FormatType.form;
                                body_template = fmt_tail.unQuote;
                            }
                            else
                                continue requests2;
                            break;
                        default:
                            continue requests2;
                    }
                }

                ref RequestDesc req = profile.request_descs[request_count++];
                req.method = *p_method;
                req._name = http_string_cache.add_string(req_name);
                req._path = http_string_cache.add_string(path);
                req.format_type = format_type;
                req.parse_mode = parse_mode;
                req._success_expr = http_string_cache.add_string(success_expr);
                req._root_path = http_string_cache.add_string(root_path);
                req._parse_template = http_string_cache.add_string(parse_template);
                req._body_template = http_string_cache.add_string(body_template);
            }
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
                        e.access = type.parse_access();

                        parse_value_desc(mb.value_desc, ty, units);
                        break;

                    case "can":
                        const(char)[] tail = reg_item.value;
                        tail = tail.split_element_and_desc();

                        const(char)[] msg_id = tail.split!',';
                        const(char)[] offset = tail.split!',';
                        const(char)[] type = tail.split!','.unQuote;
                        const(char)[] units = tail.split!','.unQuote;

                        e._element_index = cast(ushort)((ElementType.can << 13) | can_count);
                        ref ElementDesc_CAN can = profile.can_elements[can_count++];

                        size_t taken;
                        ulong ti = msg_id.parse_uint_with_base(&taken);
                        if (taken != msg_id.length || ti > 0x1FFFFFFF) // 29 bits for CAN2.0B
                        {
                            writeWarning("Invalid CAN message id: ", msg_id);
                            break;
                        }
                        can.message_id = cast(uint)ti;
                        ti = offset.parse_uint_with_base(&taken);
                        if (taken != offset.length || ti >= 64)
                        {
                            writeWarning("Invalid CAN message offset: ", offset);
                            break;
                        }
                        can.offset = cast(ubyte)ti;

                        parse_value_desc(can.value_desc, type.parse_data_type(), units);
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

                        DataType ty = type.split!('/', false).parse_data_type(zb.cluster_id == 0xEF00 ? DataType.big_endian : DataType.little_endian);
                        e.access = type.parse_access();

                        parse_value_desc(zb.value_desc, ty, units);

                        if (zb.cluster_id == 0xEF00)
                        {
                            // confirm that the tuya data types are valid
                            ushort len = zb.value_desc.data_length;
                            if (zb.value_desc.is_bitfield)
                            {
                                if (!(len == 1 || len == 2 || len == 4))
                                    writeWarning("Tuya bitmap datapoint '", id, "' must be 1, 2, 4 bytes");
                            }
                            else if (zb.value_desc.is_enum)
                            {
                                if (len != 1)
                                    writeWarning("Tuya enum datapoint '", id, "' must be 1 byte");
                            }
                            else if (zb.value_desc.is_bool)
                            {
                                if (len != 1)
                                    writeWarning("Tuya bool datapoint '", id, "' must be 1 byte");
                            }
                            else if (zb.value_desc.is_numeric)
                            {
                                if (len != 4)
                                    writeWarning("Tuya value datapoint '", id, "' must be 4 bytes");
                            }
                        }
                        break;

                    case "http":
                        e._element_index = cast(ushort)((ElementType.http << 13) | http_count);
                        ref ElementDesc_HTTP http = profile.http_elements[http_count++];

                        const(char)[] htail = reg_item.value;
                        htail = htail.split_element_and_desc();

                        const(char)[] req_name = htail.split!','.unQuote;
                        const(char)[] raw_identifier = htail.split!',';
                        http.identifier_quoted = raw_identifier.length >= 2 && raw_identifier[0] == '"' && raw_identifier[$-1] == '"';
                        const(char)[] identifier = raw_identifier.unQuote;
                        const(char)[] type = htail.split!','.unQuote;
                        const(char)[] units = htail.split!','.unQuote;

                        http._identifier = http_string_cache.add_string(identifier);

                        http.write_request_index = ushort.max;
                        http.request_index = find_request_index(*profile, req_name);
                        if (http.request_index == ushort.max && !req_name.empty)
                            writeWarning("Unknown request '", req_name, "' for http element: ", id);

                        TextType ty = type.parse_text_type();
                        if (ty == TextType.enum_ || ty == TextType.bf)
                        {
                            const(VoidEnumInfo)* ei = profile.find_enum_template(units);
                            if (ei)
                                http.value_desc = TextValueDesc(ty, ei);
                            else
                                writeWarning("Unknown enum/bitfield type: ", units);
                            units = htail.split!','.unQuote;
                        }
                        else
                        {
                            http.value_desc = TextValueDesc(ty);
                            if (!http.value_desc.parse_units(units))
                                writeWarning("Invalid units '", units, "' for http element: ", id);
                        }

                        foreach (ref sub; reg_item.sub_items)
                        {
                            if (sub.name == "write")
                            {
                                const(char)[] wt = sub.value;
                                const(char)[] w_req = wt.split!','.unQuote;
                                const(char)[] w_key = wt.split!','.unQuote;

                                http.write_request_index = find_request_index(*profile, w_req);
                                if (http.write_request_index == ushort.max)
                                    writeWarning("Unknown write request '", w_req, "' for http element: ", id);

                                if (!w_key.empty)
                                    http._write_key = http_string_cache.add_string(w_key);

                            }
                            else if (sub.name == "response")
                                http._response_path = http_string_cache.add_string(sub.value.unQuote);
                        }

                        bool has_read = http.request_index != ushort.max;
                        bool has_write = http.write_request_index != ushort.max;
                        if (has_read && has_write)
                            e.access = Access.read_write;
                        else if (has_write)
                            e.access = Access.write;
                        else
                            e.access = Access.read;
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
                            writeWarning("Invalid AA55 function code: ", fn);
                            break;
                        }
                        aa55.function_code = cast(ubyte)ti;
                        ti = offset.parse_uint_with_base(&taken);
                        if (taken != offset.length || ti > ubyte.max)
                        {
                            writeWarning("Invalid AA55 value offset: ", offset);
                            break;
                        }
                        aa55.offset = cast(ubyte)ti;

                        parse_value_desc(aa55.value_desc, type.parse_data_type(), units);
                        break;

                    case "mqtt":
                        const(char)[] tail = reg_item.value;
                        tail = tail.split_element_and_desc();

                        const(char)[] topic = tail.split!','.unQuote;
                        const(char)[] type = tail.split!','.unQuote;
                        const(char)[] units = tail.split!','.unQuote;

                        e._element_index = cast(ushort)((ElementType.mqtt << 13) | mqtt_count);
                        ref ElementDesc_MQTT mqtt = profile.mqtt_elements[mqtt_count++];

                        mqtt.read_topic = mqtt_string_cache.add_string(topic);

                        TextType ty = type.split!('/', false).parse_text_type();
                        mqtt.value_desc = TextValueDesc(ty);
                        if (!mqtt.value_desc.parse_units(units))
                            writeWarning("Invalid units '", units, "' for MQTT element: ", id);

                        foreach (ref reg_conf; reg_item.sub_items)
                        {
                            if (reg_conf.name != "write")
                                continue;
                            tail = reg_conf.value;
                            const(char)[] write_topic = tail.split!','.unQuote;
                            mqtt.write_topic = mqtt_string_cache.add_string(write_topic);
                            break;
                        }

                        if (!type.empty)
                            e.access = type.parse_access();
                        else if (mqtt.write_topic)
                        {
                            if (mqtt.read_topic)
                                e.access = Access.read_write;
                            else
                                e.access = Access.write;
                        }
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

ushort find_request_index(ref const Profile profile, const(char)[] name) pure nothrow @nogc
{
    if (name.empty)
        return ushort.max;
    foreach (i, ref req; profile.request_descs)
    {
        if (req.get_name(profile) == name)
            return cast(ushort)i;
    }
    return ushort.max;
}

size_t cache_len(size_t str_len) pure nothrow @nogc
    => str_len ? 2 + str_len + (str_len & 1) : 0;

inout(char)[] cache_string(ushort offset, inout(char)[] cache) pure nothrow @nogc
    => offset ? as_dstring(cache.ptr + offset) : null;

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

Access parse_access(ref const(char)[] access)
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
    make_element_template!("import_reactive", "kvarh", "Total Import Reactive Energy", "Accumulated imported reactive energy", Frequency.medium),
    make_element_template!("import_reactive1", "kvarh", "Total Import Reactive Energy 1", "Phase A imported reactive energy", Frequency.medium),
    make_element_template!("import_reactive2", "kvarh", "Total Import Reactive Energy 2", "Phase B imported reactive energy", Frequency.medium),
    make_element_template!("import_reactive3", "kvarh", "Total Import Reactive Energy 3", "Phase C imported reactive energy", Frequency.medium),
    make_element_template!("export_reactive", "kvarh", "Total Export Reactive Energy", "Accumulated exported reactive energy", Frequency.medium),
    make_element_template!("export_reactive1", "kvarh", "Total Export Reactive Energy 1", "Phase A exported reactive energy", Frequency.medium),
    make_element_template!("export_reactive2", "kvarh", "Total Export Reactive Energy 2", "Phase B exported reactive energy", Frequency.medium),
    make_element_template!("export_reactive3", "kvarh", "Total Export Reactive Energy 3", "Phase C exported reactive energy", Frequency.medium),
    make_element_template!("net_reactive", "kvarh", "Total (Net) Reactive Energy", "Net accumulated reactive energy", Frequency.medium),
    make_element_template!("net_reactive1", "kvarh", "Total (Net) Reactive Energy 1", "Phase A net accumulated reactive energy", Frequency.medium),
    make_element_template!("net_reactive2", "kvarh", "Total (Net) Reactive Energy 2", "Phase B net accumulated reactive energy", Frequency.medium),
    make_element_template!("net_reactive3", "kvarh", "Total (Net) Reactive Energy 3", "Phase C net accumulated reactive energy", Frequency.medium),
    make_element_template!("absolute_reactive", "kvarh", "Gross (Absolute) Reactive Energy", "Absolute accumulated reactive energy", Frequency.medium),
    make_element_template!("absolute_reactive1", "kvarh", "Gross (Absolute) Reactive Energy 1", "Phase A absolute accumulated reactive energy", Frequency.medium),
    make_element_template!("absolute_reactive2", "kvarh", "Gross (Absolute) Reactive Energy 2", "Phase B absolute accumulated reactive energy", Frequency.medium),
    make_element_template!("absolute_reactive3", "kvarh", "Gross (Absolute) Reactive Energy 3", "Phase C absolute accumulated reactive energy", Frequency.medium),
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
//    make_element_template!("state", "???", "Inverter State", "Current inverter operating state", Frequency.high), // TODO: standardise these enums
//    make_element_template!("mode", "???", "Inverter Mode", "Current inverter operating mode", Frequency.high),
    make_element_template!("temp", "°C", "Temperature", "Inverter temperature", Frequency.low),
    make_element_template!("rated_power", "W", "Rated Power", "Inverter rated output power", Frequency.constant),
    make_element_template!("efficiency", "%", "Efficiency", "Current conversion efficiency", Frequency.high),
    make_element_template!("bus_voltage", "V", "DC Bus Voltage", null, Frequency.realtime),
];

__gshared immutable KnownElementTemplate[] g_EVSE_elements = [
//    make_element_template!("state", "J1772PilotState", "EVSE State", "Current J1772 pilot state", Frequency.high), // TODO: ...
//    make_element_template!("error", "Bitfield", "Error Flags", "EVSE error flags", Frequency.high),
    make_element_template!("connected", "Boolean", "Vehicle Connected", null, Frequency.medium),
    make_element_template!("session_energy", "Wh", "Session Energy", "Energy delivered in current charging session", Frequency.low),
    make_element_template!("lifetime_energy", "Wh", "Lifetime Energy", "Total energy delivered by the EVSE", Frequency.low),
];

__gshared immutable KnownElementTemplate[] g_Vehicle_elements = [
    make_element_template!("vin", null, "Vehicle Identification Number", null, Frequency.constant),
    make_element_template!("soc", "%", "State of Charge", null, Frequency.medium),
    make_element_template!("range", "km", "Remaining Range", null, Frequency.medium),
    make_element_template!("battery_capacity", "kWh", "Battery Capacity", null, Frequency.constant),
];

__gshared immutable KnownElementTemplate[] g_ChargeControl_elements = [
    make_element_template!("max_current", "A", "Max Charging Current", "Maximum charging current/limit", Frequency.constant),
    make_element_template!("min_current", "A", "Min Charging Current", "Minimum charging current", Frequency.constant),
    make_element_template!("target_current", "A", "Target Charging Current", "Target/commanded charging current", Frequency.realtime),
    make_element_template!("actual_current", "A", "Actual Charging Current", "Actual charging current", Frequency.realtime), // TODO: should this be represented by a meter instead?
    make_element_template!("max_power", "W", "Max Charging Power", "Maximum charging power", Frequency.constant),
    make_element_template!("target_power", "W", "Target Charging Power", "Target/commanded charging power", Frequency.realtime),
    make_element_template!("actual_power", "W", "Actual Charging Power", "Actual charging power", Frequency.realtime), // TODO: should this be represented by a meter instead?
];

__gshared immutable KnownElementTemplate[] g_Switch_elements = [
    make_element_template!("switch", "Boolean", "Switch State", null, Frequency.realtime),
//    make_element_template!("mode", "SwitchMode", "Switch Mode", "Current switch mode", Frequency.high), // TODO: ...
    make_element_template!("timer", "s", "Timer", "Timer value", Frequency.high),
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
