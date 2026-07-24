module protocol.mqtt.ha_discovery;

import urt.array;
import urt.conv : parse_float, parse_uint_with_base;
import urt.format.json;
import urt.hash : fnv1;
import urt.lifetime : move;
import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.mem.temp : tconcat;
import urt.meta.enuminfo : make_enum_info, VoidEnumInfo;
import urt.si.quantity : VarQuantity;
import urt.si.unit : ScaledUnit;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.component;
import manager.device;
import manager.element;
import manager.expression : EvalContext, Expression, free_expression;
import manager.sample : register_constraint, register_enum_info;
import manager.series : format_info, register_format;
import manager.series : Constraint, DataFormat, Scalar, SeriesKind, ValueType;

import protocol.mqtt.ha_jinja : compile_jinja_template;

nothrow @nogc:


alias DiscoveryPublish = void delegate(const(char)[] topic, const(ubyte)[] payload, MonoTime timestamp) nothrow @nogc;

// TODO: Revisit MQTT discovery as a synthesized dynamic profile/binding once MQTT
// element descriptors can carry value and command transforms.

struct HADiscoveryTopic
{
    const(char)[] domain;
    const(char)[] node_id;
    const(char)[] object_id;
    bool bundled;
}

bool parse_ha_discovery_topic(const(char)[] prefix, const(char)[] topic, out HADiscoveryTopic result) pure
{
    result = HADiscoveryTopic.init;
    if (prefix.empty || topic.length <= prefix.length || !topic.startsWith(prefix) || topic[prefix.length] != '/')
        return false;

    const(char)[] tail = topic[prefix.length + 1 .. $];
    const(char)[] first = tail.split!'/';
    const(char)[] second = tail.split!'/';
    const(char)[] third = tail.split!'/';
    if (first.empty || second.empty || third.empty)
        return false;

    if (tail.empty)
    {
        if (third != "config")
            return false;
        result.domain = first;
        result.object_id = second;
        result.bundled = first == "device";
        return true;
    }

    const(char)[] fourth = tail.split!'/';
    if (!tail.empty || fourth != "config" || first == "device")
        return false;
    result.domain = first;
    result.node_id = second;
    result.object_id = third;
    return true;
}

struct HADiscovery
{
nothrow @nogc:

    @disable this(this);

    ~this()
    {
        clear_entities();
    }

    void configure(const(char)[][] prefixes, DiscoveryPublish publisher = null)
    {
        suspend();
        clear_entities();
        _prefixes.clear();
        foreach (prefix; prefixes)
        {
            const(char)[] normalised = normalise_prefix(prefix);
            if (!normalised.empty)
                _prefixes ~= normalised.makeString(defaultAllocator());
        }
        if (publisher)
            resume(publisher);
    }

    void resume(DiscoveryPublish publisher)
    {
        if (_active)
            return;
        _publisher = publisher;
        _active = publisher !is null;
        if (!_active)
            return;
        foreach (ref entity; _entities)
            attach_writer(entity);
    }

    void suspend()
    {
        if (!_active)
            return;
        foreach (ref entity; _entities)
            detach_writer(entity);
        _publisher = null;
        _active = false;
    }

    bool handle_publish(const(char)[] topic, const(ubyte)[] payload, MonoTime timestamp)
    {
        if (_prefixes.empty)
            return false;

        HADiscoveryTopic discovery_topic;
        foreach (ref prefix; _prefixes)
        {
            if (parse_ha_discovery_topic(prefix[], topic, discovery_topic))
            {
                handle_config(discovery_topic, topic, payload);
                return true;
            }
        }

        handle_state_publish(topic, payload, timestamp);
        return false;
    }

    void handle_state_publish(const(char)[] topic, const(ubyte)[] payload, MonoTime timestamp)
    {
        if (_prefixes.empty || payload.empty)
            return;
        foreach (ref entity; _entities)
        {
            if (entity.state_topic[] == topic)
                write_state(entity, payload, cast(SysTime)timestamp);
        }
    }

    size_t entity_count() const pure
        => _entities.length;

private:
    alias log = Log!"mqtt.discovery";

    struct HADevice
    {
        String identity;
        Device device;
        bool announced;
    }

    struct HAEntity
    {
        String config_topic;
        String component_key;
        String domain;
        String object_id;
        String state_topic;
        String command_topic;
        String value_template;
        String command_template;
        String value_expression_source;
        String command_expression_source;
        String payload_on;
        String payload_off;
        String unit;
        String state_class;
        const(VoidEnumInfo)* select_info;
        Element* state;
        Device device;
        Expression* value_expression;
        Expression* command_expression;
        bool value_template_valid;
        bool command_template_valid;
        bool uses_value_json;
        bool writable;
    }

    struct HAEntityId
    {
        String identity;
        String id;
        Device device;
    }

    Array!String _prefixes;
    Array!HADevice _devices;
    Array!HAEntity _entities;
    Array!HAEntityId _entity_ids;
    Map!(String, Variant) _template_locals;
    DiscoveryPublish _publisher;
    bool _active;
    bool _observing;

    static const(char)[] normalise_prefix(const(char)[] prefix) pure
    {
        while (!prefix.empty && prefix[$ - 1] == '/')
            prefix = prefix[0 .. $ - 1];
        while (!prefix.empty && prefix[0] == '/')
            prefix = prefix[1 .. $];
        return prefix;
    }

    void clear_entities()
    {
        foreach (ref entity; _entities)
            release_entity(entity);
        _entities.clear();
    }

    void release_entity(ref HAEntity entity)
    {
        if (_active)
            detach_writer(entity);
        if (entity.value_expression)
            entity.value_expression.free_expression();
        entity.value_expression = null;
        if (entity.command_expression)
            entity.command_expression.free_expression();
        entity.command_expression = null;
    }

    void remove_entities(const(char)[] config_topic)
    {
        for (size_t i = 0; i < _entities.length; )
        {
            if (_entities[i].config_topic[] != config_topic)
            {
                ++i;
                continue;
            }
            release_entity(_entities[i]);
            if (_entities[i].state)
                _entities[i].state.mark_gap();
            _entities.removeSwapLast(i);
        }
    }

    void handle_config(ref const HADiscoveryTopic topic, const(char)[] config_topic, const(ubyte)[] payload)
    {
        remove_entities(config_topic);
        if (payload.empty || !g_app)
            return;

        Variant root = parse_json(cast(const(char)[])payload);
        if (!root.isObject)
        {
            log.warning("invalid Home Assistant discovery payload on ", config_topic);
            return;
        }

        Variant* device_config = json_member(root, "device", "dev");
        if (topic.bundled)
        {
            Variant* components = json_member(root, "components", "cmps");
            if (!components || !components.isObject)
            {
                log.warning("Home Assistant device discovery payload has no components on ", config_topic);
                return;
            }
            foreach (component_key, ref config; *components)
            {
                if (!config.isObject)
                    continue;
                const(char)[] domain = json_string(config, "platform", "p");
                if (domain.empty)
                    continue;
                add_entity(config_topic, component_key, domain, component_key,
                           topic.node_id, root, config, device_config);
            }
            return;
        }

        if (topic.domain == "device_automation" || topic.domain == "tag")
            return;
        add_entity(config_topic, null, topic.domain, topic.object_id,
                   topic.node_id, root, root, device_config);
    }

    void add_entity(const(char)[] config_topic, const(char)[] component_key,
                    const(char)[] domain, const(char)[] topic_object_id,
                    const(char)[] node_id, ref Variant root, ref Variant config,
                    Variant* device_config)
    {
        const(char)[] object_id = json_string(config, "object_id", "obj_id");
        if (object_id.empty)
            object_id = topic_object_id;
        const(char)[] unique_id = json_string(config, "unique_id", "uniq_id");

        const(char)[] identity = device_identity(device_config);
        if (identity.empty)
            identity = unique_id;
        if (identity.empty)
            identity = !node_id.empty ? node_id : object_id;
        if (identity.empty)
            identity = config_topic;

        HADevice* record = find_or_create_device(identity);
        if (!record)
            return;
        apply_device_info(*record, device_config, identity);

        const(char)[] base_topic = json_string(config, "~", null);
        if (base_topic.empty)
            base_topic = json_string(root, "~", null);

        String state_topic = resolve_topic(json_string(config, "state_topic", "stat_t"), base_topic);
        String command_topic = resolve_topic(json_string(config, "command_topic", "cmd_t"), base_topic);
        const(char)[] entity_name = json_string(config, "name", null);
        const(char)[] device_class = json_string(config, "device_class", "dev_cla");
        const(char)[] unit = json_string(config, "unit_of_measurement", "unit_of_meas");
        const(char)[] state_class = json_string(config, "state_class", "stat_cla");

        const(char)[] entity_identity = unique_id.empty
            ? tconcat(domain, ":", object_id)
            : unique_id;
        const(char)[] entity_id = find_or_create_entity_id(record.device, entity_identity,
                                                            object_id, record.identity[]);
        if (entity_id.empty)
            return;

        const(VoidEnumInfo)* select_info;
        if (domain == "select")
        {
            const(char)[] enum_name = tconcat(record.device.id[], ".ha.", entity_id);
            select_info = synth_select_enum(config, enum_name);
            if (!select_info)
            {
                log.warning("invalid Home Assistant select options on ", config_topic);
                return;
            }
        }

        FormatId state_format = select_info
            ? register_format(DataFormat(ValueType.u16, SeriesKind.held, select_info))
            : make_state_format(config, domain, unit, state_class);
        const(char)[] path = tconcat("ha.", entity_id);
        Element* state = record.device.find_or_create_element(path, state_format);
        Component ha_component = record.device.find_component("ha");
        if (ha_component && ha_component.name.empty)
            ha_component.name = "Home Assistant".makeString(defaultAllocator());

        state.name = (entity_name.empty ? object_id : entity_name).makeString(defaultAllocator());
        state.desc = device_class.makeString(defaultAllocator());
        state.display_unit = unit.makeString(defaultAllocator());
        state.sampling_mode = SamplingMode.report;
        if (select_info)
        {
            if (state.value.is_enum)
            {
                const(char)[] prior = select_info.key_for_raw(state.value.asLong);
                state.value(prior.ptr ? select_info.value_for(prior) : Variant());
            }
        }

        HAEntity* entity = &_entities.pushBack();
        entity.config_topic = config_topic.makeString(defaultAllocator());
        entity.component_key = component_key.makeString(defaultAllocator());
        entity.domain = domain.makeString(defaultAllocator());
        entity.object_id = object_id.makeString(defaultAllocator());
        entity.state_topic = state_topic.move;
        entity.command_topic = command_topic.move;
        entity.value_template = json_string(config, "value_template", "val_tpl").makeString(defaultAllocator());
        entity.command_template = json_string(config, "command_template", "cmd_tpl").makeString(defaultAllocator());
        entity.value_template_valid = compile_jinja_template(entity.value_template[],
                                                             entity.value_expression_source,
                                                             entity.value_expression);
        entity.command_template_valid = compile_jinja_template(entity.command_template[],
                                                               entity.command_expression_source,
                                                               entity.command_expression);
        entity.uses_value_json = entity.value_expression_source[].contains("$value_json");
        entity.payload_on = state_payload(config, true).makeString(defaultAllocator());
        entity.payload_off = state_payload(config, false).makeString(defaultAllocator());
        entity.unit = unit.makeString(defaultAllocator());
        entity.state_class = state_class.makeString(defaultAllocator());
        entity.select_info = select_info;
        entity.state = state;
        entity.device = record.device;
        entity.writable = supports_write(domain, entity.command_topic[],
                                         entity.command_template_valid);
        state.access = entity.writable ? Access.read_write : Access.read;
        mount_status_alias(record.device, *state, entity_id);
        if (_active)
            attach_writer(*entity);

        record.device.notify(ComponentEvent.tree_changed);
        if (!record.announced)
        {
            record.announced = true;
            record.device.notify(ComponentEvent.online);
        }
    }

    HADevice* find_or_create_device(const(char)[] identity)
    {
        foreach (ref record; _devices)
            if (record.identity[] == identity)
                return &record;

        String base_id = safe_id(identity);
        String id;
        if (!(base_id[] in g_app.devices))
            id = base_id.move;
        else
        {
            for (size_t suffix = 2; suffix < ushort.max; ++suffix)
            {
                const(char)[] candidate = tconcat(base_id[], suffix);
                if (!(candidate in g_app.devices))
                {
                    id = candidate.makeString(defaultAllocator());
                    break;
                }
            }
        }
        if (id.empty)
            return null;

        Device device = g_app.allocator.allocT!Device(id.move);
        g_app.devices.insert(device.id[], device);

        HADevice* record = &_devices.pushBack();
        record.identity = identity.makeString(defaultAllocator());
        record.device = device;
        return record;
    }

    const(char)[] find_or_create_entity_id(Device device, const(char)[] identity,
                                            const(char)[] object_id,
                                            const(char)[] device_identity)
    {
        foreach (ref entry; _entity_ids)
            if (entry.device is device && entry.identity[] == identity)
                return entry.id[];

        String base_id = safe_id(object_id);
        String device_id = safe_id(device_identity);
        if (base_id.length > device_id.length &&
            base_id[].startsWith(device_id[]) &&
            base_id[device_id.length] == '_')
        {
            String local_id = base_id[device_id.length + 1 .. $].makeString(defaultAllocator());
            base_id = local_id.move;
        }

        String id;
        for (size_t suffix = 1; suffix < ushort.max; ++suffix)
        {
            const(char)[] candidate = suffix == 1 ? base_id[] : tconcat(base_id[], suffix);
            bool occupied = device.find_element(tconcat("ha.", candidate)) !is null;
            if (!occupied)
            {
                foreach (ref entry; _entity_ids)
                {
                    if (entry.device is device && entry.id[] == candidate)
                    {
                        occupied = true;
                        break;
                    }
                }
            }
            if (!occupied)
            {
                id = candidate.makeString(defaultAllocator());
                break;
            }
        }
        if (id.empty)
            return null;

        HAEntityId* entry = &_entity_ids.pushBack();
        entry.identity = identity.makeString(defaultAllocator());
        entry.id = id.move;
        entry.device = device;
        return entry.id[];
    }

    void apply_device_info(ref HADevice record, Variant* config, const(char)[] identity)
    {
        Device device = record.device;
        const(char)[] name = config ? json_string(*config, "name", null) : null;
        if (name.empty)
            name = identity;
        device.name = name.makeString(defaultAllocator());

        set_info(device, "name", name, "Device Name");
        if (config)
        {
            set_info(device, "manufacturer_name", json_string(*config, "manufacturer", "mf"), "Manufacturer");
            set_info(device, "model_name", json_string(*config, "model", "mdl"), "Model");
            set_info(device, "model_id", json_string(*config, "model_id", "mdl_id"), "Model ID");
            set_info(device, "serial_number", json_string(*config, "serial_number", "sn"), "Serial Number");
            set_info(device, "software_version", json_string(*config, "sw_version", "sw"), "Software Version");
            set_info(device, "hardware_version", json_string(*config, "hw_version", "hw"), "Hardware Version");
        }
        Component info = device.find_component("info");
        if (info)
            info.template_ = "DeviceInfo".makeString(defaultAllocator());
    }

    static void set_info(Device device, const(char)[] id, const(char)[] value, const(char)[] name)
    {
        if (value.empty)
            return;
        Element* element = device.set_element(tconcat("info.", id), value);
        element.name = name.makeString(defaultAllocator());
        element.sampling_mode = SamplingMode.constant;
        element.access = Access.read;
    }

    static const(char)[] device_identity(Variant* config)
    {
        if (!config || !config.isObject)
            return null;
        Variant* ids = json_member(*config, "identifiers", "ids");
        if (ids)
        {
            if (ids.isString)
                return ids.asString();
            if (ids.isArray)
                foreach (ref id; ids.asArray()[])
                    if (id.isString && !id.asString().empty)
                        return id.asString();
        }

        Variant* connections = json_member(*config, "connections", "cns");
        if (connections && connections.isArray)
        {
            foreach (ref connection; connections.asArray()[])
            {
                if (connection.isArray && connection.length >= 2 && connection[1].isString)
                    return connection[1].asString();
            }
        }
        return null;
    }

    static String resolve_topic(const(char)[] topic, const(char)[] base)
    {
        if (topic.empty)
            return String();
        if (base.empty || topic.findFirst('~') == topic.length)
            return topic.makeString(defaultAllocator());
        if (topic == "~")
            return base.makeString(defaultAllocator());
        if (topic.startsWith("~/"))
            return tconcat(base, topic[1 .. $]).makeString(defaultAllocator());
        if (topic.length >= 2 && topic[$ - 2 .. $] == "/~")
            return tconcat(topic[0 .. $ - 1], base).makeString(defaultAllocator());
        return topic.makeString(defaultAllocator());
    }

    static const(char)[] state_payload(ref Variant config, bool on)
    {
        const(char)[] value = on
            ? json_string(config, "state_on", "stat_on")
            : json_string(config, "state_off", "stat_off");
        if (value.empty)
            value = on
                ? json_string(config, "payload_on", "pl_on")
                : json_string(config, "payload_off", "pl_off");
        return value.empty ? (on ? "ON" : "OFF") : value;
    }

    static bool supports_write(const(char)[] domain, const(char)[] command_topic,
                               bool command_template_valid) pure
    {
        if (command_topic.empty || !command_template_valid)
            return false;
        return domain == "switch" || domain == "number" || domain == "select" || domain == "text";
    }

    void attach_writer(ref HAEntity entity)
    {
        if (entity.writable && entity.state)
            entity.state.subscribe(&on_element_change);
    }

    void detach_writer(ref HAEntity entity)
    {
        if (entity.writable && entity.state)
            entity.state.unsubscribe(&on_element_change);
    }

    void on_element_change(ref const SampleCommit samples)
    {
        if (_observing || !_publisher)
            return;
        foreach (ref update; samples.updates)
            publish_element(update);
    }

    void publish_element(ref const SampleUpdate update)
    {
        foreach (ref entity; _entities)
        {
            if (entity.state != update.element || !entity.writable)
                continue;

            const(char)[] payload;
            char[128] buffer = void;
            Variant selected;
            Variant transformed;
            const(Variant)* command_value = &update.value;
            if (entity.select_info)
            {
                const(char)[] option;
                if (!select_option(entity.select_info, update.value, option))
                    return;
                selected = Variant(option);
                command_value = &selected;
            }
            if (entity.command_expression)
            {
                Variant no_json;
                transformed = evaluate_template(entity.command_expression, *command_value, no_json);
                if (transformed.isNull)
                    return;
                command_value = &transformed;
            }

            if (!entity.command_expression && entity.domain[] == "switch" && command_value.isBool)
                payload = command_value.asBool ? entity.payload_on[] : entity.payload_off[];
            else if (command_value.isString)
                payload = command_value.asString();
            else
            {
                ptrdiff_t len = write_json(*command_value, buffer[], true);
                if (len <= 0)
                    return;
                payload = buffer[0 .. len];
            }
            _publisher(entity.command_topic[], cast(const(ubyte)[])payload, getTime());
            return;
        }
    }

    void write_state(ref HAEntity entity, const(ubyte)[] payload, SysTime timestamp)
    {
        const(char)[] text = cast(const(char)[])payload;
        Variant json;
        Variant transformed;
        const(Variant)* value;
        if (!entity.value_template.empty)
        {
            if (!entity.value_template_valid || !entity.value_expression)
                return;
            if (entity.uses_value_json)
                json = parse_json(text);
            Variant raw = Variant(text.trim());
            transformed = evaluate_template(entity.value_expression, raw, json);
            if (transformed.isNull)
                return;
            value = &transformed;
        }

        _observing = true;
        scope(exit) _observing = false;

        if (entity.domain[] == "binary_sensor" || entity.domain[] == "switch")
        {
            if (value && value.isBool)
                entity.state.value(value.asBool, timestamp);
            else
            {
                const(char)[] token = value && value.isString ? value.asString() : text.trim();
                if (token == entity.payload_on[])
                    entity.state.value(true, timestamp);
                else if (token == entity.payload_off[])
                    entity.state.value(false, timestamp);
            }
            return;
        }

        if (entity.select_info)
        {
            const(char)[] option;
            if (value)
            {
                if (!value.isString)
                    return;
                option = value.asString();
            }
            else
                option = text.trim();

            if (option == "unknown" || option == "unavailable")
            {
                entity.state.value(Variant(), timestamp);
                return;
            }

            Variant selected = entity.select_info.value_for(option);
            if (!selected.isNull)
                entity.state.value(selected, timestamp);
            return;
        }

        if (value)
        {
            if (value.isNumber)
            {
                write_number(entity, value.asDouble, timestamp);
                return;
            }
            if (value.isBool)
            {
                entity.state.value(value.asBool, timestamp);
                return;
            }
            if (value.isString)
                text = value.asString();
            else
                return;
        }

        text = text.trim();
        if (text == "unknown" || text == "unavailable")
        {
            entity.state.value(Variant(), timestamp);
            return;
        }

        bool numeric = entity.domain[] == "number" || !entity.unit.empty || !entity.state_class.empty;
        if (numeric)
        {
            size_t taken;
            double number = parse_float(text, &taken);
            if (taken == text.length)
            {
                write_number(entity, number, timestamp);
                return;
            }
        }
        entity.state.value(text, timestamp);
    }

    static void write_number(ref HAEntity entity, double value, SysTime timestamp)
    {
        if (!entity.unit.empty)
        {
            ScaledUnit unit;
            float pre_scale;
            ptrdiff_t taken = unit.parse_unit(entity.unit[], pre_scale, false);
            if (taken == entity.unit.length)
            {
                entity.state.value(VarQuantity(value * pre_scale, unit), timestamp);
                return;
            }
        }
        entity.state.value(value, timestamp);
    }

    Variant evaluate_template(Expression* expression, ref const Variant value,
                              ref const Variant value_json)
    {
        if (_template_locals.empty)
        {
            _template_locals["value".makeString(defaultAllocator())] = Variant();
            _template_locals["value_json".makeString(defaultAllocator())] = Variant();
        }
        *_template_locals.get("value") = value;
        *_template_locals.get("value_json") = value_json;

        EvalContext context;
        context.locals = &_template_locals;
        return expression.evaluate(context);
    }

    static FormatId make_state_format(ref Variant config, const(char)[] domain,
                                      const(char)[] unit_text, const(char)[] state_class)
    {
        if (domain == "binary_sensor" || domain == "switch")
            return register_format(DataFormat(ValueType.bool_, SeriesKind.held));

        if (domain != "number" && unit_text.empty && state_class.empty)
        {
            DataFormat text = DataFormat(ValueType.char_, SeriesKind.held);
            text.count = 0;
            return register_format(text);
        }

        ScaledUnit unit;
        float pre_scale = 1;
        if (!unit_text.empty && unit.parse_unit(unit_text, pre_scale, false) != unit_text.length)
        {
            unit = ScaledUnit();
            pre_scale = 1;
        }

        DataFormat format = DataFormat(ValueType.f64, SeriesKind.held, unit);
        Constraint constraint;
        double number;
        if (json_number(config, "min", number))
        {
            constraint.min = Scalar.of(number * pre_scale);
            constraint.has |= Constraint.Has.min;
        }
        if (json_number(config, "max", number))
        {
            constraint.max = Scalar.of(number * pre_scale);
            constraint.has |= Constraint.Has.max;
        }
        if (json_number(config, "step", number))
        {
            constraint.step = Scalar.of(number * pre_scale);
            constraint.has |= Constraint.Has.step;
        }
        if (constraint.has)
            format.constraint = register_constraint(constraint);
        return register_format(format);
    }

    static const(VoidEnumInfo)* synth_select_enum(ref Variant config,
                                                   const(char)[] enum_name)
    {
        Variant* options = json_member(config, "options", "ops");
        if (!options || !options.isArray || options.length == 0 || options.length > ubyte.max)
            return null;

        Array!(const(char)[]) keys = Array!(const(char)[])(Reserve, options.length);
        Array!ushort values = Array!ushort(Reserve, options.length);
        foreach (ref option; options.asArray()[])
        {
            if (!option.isString)
                return null;
            const(char)[] key = option.asString();
            foreach (prior; keys)
                if (prior == key)
                    return null;
            ushort value = fnv1!(ushort, true)(cast(const(ubyte)[])key);
            foreach (prior; values)
                if (prior == value)
                    return null;
            keys ~= key;
            values ~= value;
        }

        VoidEnumInfo* created = make_enum_info(enum_name, keys[], values[]);
        return register_enum_info(enum_name, created);
    }

    static bool select_option(const(VoidEnumInfo)* info, ref const Variant value,
                              out const(char)[] option)
    {
        if (value.isString)
        {
            option = value.asString();
            return info.contains(option);
        }
        if (!value.is_enum)
            return false;
        option = info.key_for_raw(value.asLong);
        return option.ptr !is null;
    }

    static void mount_status_alias(Device device, ref Element source,
                                   const(char)[] source_id)
    {
        const(char)[] target_path = status_alias_path(source_id);
        if (target_path.empty)
            return;

        Element* target = device.find_element(target_path);
        bool created = target is null;
        if (created)
            target = device.find_or_create_element(target_path, source.format);
        else
        {
            bool ours;
            foreach (ref computation; device.computations)
            {
                if (computation.kind == ComputationKind.alias_ && computation.target == target)
                {
                    ours = true;
                    break;
                }
            }
            if (!ours)
                return;
        }

        Component status = device.find_component("status");
        if (status && status.template_.empty)
            status.template_ = "DeviceStatus".makeString(defaultAllocator());
        Component network = device.find_component("status.network");
        if (network && network.template_.empty)
            network.template_ = "Network".makeString(defaultAllocator());
        Component wifi = device.find_component("status.network.wifi");
        if (wifi && wifi.template_.empty)
            wifi.template_ = "Wifi".makeString(defaultAllocator());

        target.name = source.name;
        target.desc = source.desc;
        target.display_unit = source.display_unit;
        target.access = source.access;
        target.sampling_mode = SamplingMode.dependent;
        if (!created)
            return;

        Computation computation;
        computation.kind = ComputationKind.alias_;
        computation.device = device;
        computation.target = target;
        computation.link = g_app.create_link(target, null, &source, null);
        computation.bound = true;
        device.computations ~= computation;
    }

    static const(char)[] status_alias_path(const(char)[] source_id) pure
    {
        switch (source_id)
        {
            case "uptime":
            case "up_time":
            case "espuptime":
            case "esp_uptime":
                return "status.up_time";

            case "esptemp":
            case "esp_temp":
                return "status.temp";

            case "connected":
                return "status.connected";

            case "ssid":
            case "wifissid":
            case "wifi_ssid":
                return "status.network.wifi.ssid";

            case "bssid":
            case "wifibssid":
            case "wifi_bssid":
                return "status.network.wifi.bssid";

            case "rssi":
            case "wifirssi":
            case "wifi_rssi":
                return "status.network.wifi.rssi";

            case "wifistatus":
            case "wifi_status":
                return "status.network.wifi.status";

            case "wificonnected":
            case "wifi_connected":
                return "status.network.wifi.connected";

            case "wifichannel":
            case "wifi_channel":
                return "status.network.wifi.channel";

            case "wifimac":
            case "wifi_mac":
            case "wifimacaddress":
            case "wifi_mac_address":
                return "status.network.wifi.mac_address";

            case "wifiip":
            case "wifi_ip":
            case "wifiipaddress":
            case "wifi_ip_address":
                return "status.network.wifi.ip_address";

            default:
                return null;
        }
    }
}

unittest
{
    HADiscoveryTopic topic;
    assert(parse_ha_discovery_topic("homeassistant", "homeassistant/sensor/node/power/config", topic));
    assert(topic.domain == "sensor" && topic.node_id == "node" && topic.object_id == "power" && !topic.bundled);
    assert(parse_ha_discovery_topic("homeassistant", "homeassistant/device/meter/config", topic));
    assert(topic.bundled && topic.object_id == "meter");
    assert(!parse_ha_discovery_topic("homeassistant", "homeassistant/sensor/power/state", topic));
    assert(HADiscovery.status_alias_path("espuptime") == "status.up_time");
    assert(HADiscovery.status_alias_path("esptemp") == "status.temp");
    assert(HADiscovery.status_alias_path("wifissid") == "status.network.wifi.ssid");
    assert(HADiscovery.status_alias_path("wifibssid") == "status.network.wifi.bssid");
    assert(HADiscovery.status_alias_path("wifirssi") == "status.network.wifi.rssi");
    assert(HADiscovery.status_alias_path("unrecognised").empty);

    Variant json = parse_json(`{"energy":{"power":123.5},"enabled":true}`);
    Variant* value = walk_value_json(json, "value_json.energy.power");
    assert(value && value.isNumber && value.asDouble == 123.5);
    value = walk_value_json(json, `value_json["enabled"]`);
    assert(value && value.isBool && value.asBool);

    Application app = create_application();
    scope(exit) shutdown_application();

    String translated_source;
    Expression* translated_expression;
    assert(compile_jinja_template("{{ value | int / 10 if value | is_number else none }}",
                                  translated_source, translated_expression));
    scope(exit) translated_expression.free_expression();
    assert(translated_source[] == "$select($is_number($value), $to_int($value) / 10, null)");
    Map!(String, Variant) template_locals;
    String template_value_key = "value".makeString(defaultAllocator());
    template_locals[template_value_key] = Variant("250");
    EvalContext template_context;
    template_context.locals = &template_locals;
    Variant translated_value = translated_expression.evaluate(template_context);
    assert(translated_value.isNumber && translated_value.asDouble == 25);

    String chained_source;
    Expression* chained_expression;
    assert(compile_jinja_template("{{ value | float(0) | round(1) }}",
                                  chained_source, chained_expression));
    template_locals[template_value_key] = Variant("21.25");
    Variant chained_value = chained_expression.evaluate(template_context);
    assert(chained_value.isNumber && chained_value.asDouble == 21.2);
    chained_expression.free_expression();

    assert(compile_jinja_template("{{ value | float(0) | round(0, 'half') }}",
                                  chained_source, chained_expression));
    template_locals[template_value_key] = Variant("21.3");
    chained_value = chained_expression.evaluate(template_context);
    assert(chained_value.isNumber && chained_value.asDouble == 21.5);
    chained_expression.free_expression();

    DiscoveryTestSink sink;
    HADiscovery discovery;
    const(char)[][2] prefixes = [ "homeassistant", "alternate" ];
    discovery.configure(prefixes[], &sink.publish);

    static immutable string sensor_config =
        `{"dev":{"ids":"meter-01","name":"Main Meter","mf":"Acme","mdl":"M1"},` ~
        `"name":"Power","uniq_id":"meter_power","stat_t":"meter/state",` ~
        `"unit_of_meas":"W","val_tpl":"{{ value_json.power }}"}`;
    static immutable string frequency_config =
        `{"dev":{"ids":"meter-01","name":"Main Meter","mf":"Acme","mdl":"M1"},` ~
        `"name":"Frequency","obj_id":"meter_01_frequency","uniq_id":"meter_frequency","stat_t":"meter/state",` ~
        `"unit_of_meas":"Hz","val_tpl":"{{ value_json.frequency }}"}`;
    assert(discovery.handle_publish("homeassistant/sensor/meter/power/config", cast(const(ubyte)[])sensor_config, getTime()));
    assert(discovery.entity_count == 1);
    assert(discovery.handle_publish("alternate/sensor/meter/frequency/config", cast(const(ubyte)[])frequency_config, getTime()));
    assert(discovery.entity_count == 2);

    static immutable string current_config =
        `{"dev":{"ids":"meter-01","name":"Main Meter"},"name":"Current",` ~
        `"obj_id":"meter_01_current","uniq_id":"meter_current","stat_t":"meter/current",` ~
        `"cmd_t":"meter/current/set","unit_of_meas":"A","min":"0","max":"25",` ~
        `"mode":"slider","val_tpl":"{{ value | int / 10 if value | is_number else none }}",` ~
        `"cmd_tpl":"{{ value | int * 10 }}"}`;
    assert(discovery.handle_publish("homeassistant/number/meter/current/config",
                                    cast(const(ubyte)[])current_config, getTime()));
    assert(discovery.entity_count == 3);

    static immutable string colliding_config =
        `{"dev":{"ids":"meter-01","name":"Main Meter"},"name":"Power Switch",` ~
        `"uniq_id":"meter_power_switch","stat_t":"meter/power-switch",` ~
        `"cmd_t":"meter/power-switch/set"}`;
    assert(discovery.handle_publish("homeassistant/switch/meter/power/config",
                                    cast(const(ubyte)[])colliding_config, getTime()));
    assert(discovery.entity_count == 4);

    static immutable string mode_config =
        `{"dev":{"ids":"meter-01","name":"Main Meter"},"name":"Mode",` ~
        `"uniq_id":"meter_mode","stat_t":"meter/mode","cmd_t":"meter/mode/set",` ~
        `"ops":["Normal","Eco","Boost"]}`;
    assert(discovery.handle_publish("homeassistant/select/meter/mode/config",
                                    cast(const(ubyte)[])mode_config, getTime()));
    assert(discovery.entity_count == 5);

    static immutable string wifi_config =
        `{"dev":{"ids":"meter-01","name":"Main Meter"},"name":"WiFi SSID",` ~
        `"obj_id":"meter_01_wifi_ssid","uniq_id":"meter_wifi_ssid",` ~
        `"stat_t":"meter/wifi/ssid"}`;
    assert(discovery.handle_publish("homeassistant/sensor/meter/wifi_ssid/config",
                                    cast(const(ubyte)[])wifi_config, getTime()));
    assert(discovery.entity_count == 6);

    Device* device_slot = "meter_01" in app.devices;
    assert(device_slot && (*device_slot).name[] == "Main Meter");
    Device device = *device_slot;
    Element* manufacturer = device.find_element("info.manufacturer_name");
    assert(manufacturer && manufacturer.value.asString == "Acme");
    Element* power = device.find_element("ha.power");
    assert(power && power.name[] == "Power" && power.display_unit[] == "W");
    assert(device.find_element("ha.power2"));
    assert(device.find_element("ha.frequency"));
    Element* wifi_ssid = device.find_element("status.network.wifi.ssid");
    assert(wifi_ssid && wifi_ssid.sampling_mode == SamplingMode.dependent);
    assert(device.find_component("status").template_[] == "DeviceStatus");
    assert(device.find_component("status.network").template_[] == "Network");
    assert(device.find_component("status.network.wifi").template_[] == "Wifi");
    discovery.handle_publish("meter/wifi/ssid", cast(const(ubyte)[])"Test Network", getTime());
    assert(wifi_ssid.value.isString && wifi_ssid.value.asString == "Test Network");
    assert(!device.find_element("ha.meter_01_frequency"));
    assert(device.find_component("ha.sensor") is null);
    discovery.handle_publish("meter/current", cast(const(ubyte)[])"250", getTime());
    Element* current = device.find_element("ha.current");
    assert(current && current.value.isQuantity &&
           current.normalised_value > 24.99 && current.normalised_value < 25.01);
    assert(current.access == Access.read_write && current.data_format.constraint);
    assert((current.data_format.constraint.has & Constraint.Has.min) &&
           current.data_format.constraint.min.f64_ == 0);
    assert((current.data_format.constraint.has & Constraint.Has.max) &&
           current.data_format.constraint.max.f64_ == 25);
    discovery.handle_publish("meter/current", cast(const(ubyte)[])"not-a-number", getTime());
    assert(current.normalised_value > 24.99 && current.normalised_value < 25.01);
    current.value(20.0);
    assert(sink.topic[] == "meter/current/set" && sink.payload[] == "200");

    Element* mode = device.find_element("ha.mode");
    assert(mode && mode.access == Access.read_write);
    assert(mode.data_format.desc == DataFormat.Desc.enum_);
    const(VoidEnumInfo)* mode_info = mode.data_format.enum_info;
    assert(mode_info && mode_info.count == 3);
    discovery.handle_publish("meter/mode", cast(const(ubyte)[])"Eco", getTime());
    long eco_value = mode_info.value_for("Eco").asLong;
    assert(mode.value.is_enum && mode.value.get_enum_info() is mode_info &&
           mode.value.asLong == eco_value);
    discovery.handle_publish("meter/mode", cast(const(ubyte)[])"Invalid", getTime());
    assert(mode.value.is_enum && mode.value.asLong == eco_value);
    mode.value(mode_info.value_for("Boost"));
    assert(sink.topic[] == "meter/mode/set" && sink.payload[] == "Boost");

    static immutable string updated_mode_config =
        `{"dev":{"ids":"meter-01","name":"Main Meter"},"name":"Mode",` ~
        `"uniq_id":"meter_mode","stat_t":"meter/mode","cmd_t":"meter/mode/set",` ~
        `"options":["Boost","Eco","Normal","Away"]}`;
    assert(discovery.handle_publish("homeassistant/select/meter/mode/config",
                                    cast(const(ubyte)[])updated_mode_config, getTime()));
    assert(discovery.entity_count == 6);
    const(VoidEnumInfo)* updated_mode_info = mode.data_format.enum_info;
    assert(updated_mode_info && updated_mode_info.count == 4);
    assert(updated_mode_info.value_for("Eco").asLong == eco_value);
    assert(mode.value.is_enum && mode.value.get_enum_info() is updated_mode_info);

    static immutable string bundled_config =
        `{"dev":{"ids":["meter-01"],"name":"Main Meter"},"o":{"name":"meter-fw"},"cmps":{` ~
        `"voltage":{"p":"sensor","name":"Voltage","stat_t":"meter/state",` ~
        `"unit_of_meas":"V","val_tpl":"{{ value_json.voltage }}"},` ~
        `"relay":{"p":"switch","name":"Relay","stat_t":"meter/relay",` ~
        `"cmd_t":"meter/relay/set"}}}`;
    assert(discovery.handle_publish("homeassistant/device/meter/config", cast(const(ubyte)[])bundled_config, getTime()));
    assert(discovery.entity_count == 8);

    static immutable string meter_state = `{"power":123.5,"voltage":231.2}`;
    discovery.handle_publish("meter/state", cast(const(ubyte)[])meter_state, getTime());
    Element* voltage = device.find_element("ha.voltage");
    assert(power.value.isQuantity && power.normalised_value > 123.49 && power.normalised_value < 123.51);
    assert(voltage && voltage.value.isQuantity && voltage.normalised_value > 231.19 && voltage.normalised_value < 231.21);

    Element* relay = device.find_element("ha.relay");
    assert(relay && relay.access == Access.read_write);
    discovery.handle_publish("meter/relay", cast(const(ubyte)[])"OFF", getTime());
    assert(relay.value.isBool && !relay.value.asBool);
    relay.value(true);
    assert(sink.topic[] == "meter/relay/set" && sink.payload[] == "ON");

    DiscoveryTestSink second_sink;
    HADiscovery second_discovery;
    second_discovery.configure(prefixes[0 .. 1], &second_sink.publish);
    assert(second_discovery.handle_publish("homeassistant/sensor/meter/power/config",
                                           cast(const(ubyte)[])sensor_config, getTime()));
    Device* second_device_slot = "meter_012" in app.devices;
    assert(second_device_slot && *second_device_slot !is device);
    assert((*second_device_slot).find_element("ha.power"));

    second_discovery.suspend();
    discovery.suspend();
}

private:

version (unittest)
{
    struct DiscoveryTestSink
    {
        String topic;
        String payload;

        void publish(const(char)[] topic_value, const(ubyte)[] payload_value, MonoTime) nothrow @nogc
        {
            topic = topic_value.makeString(defaultAllocator());
            payload = (cast(const(char)[])payload_value).makeString(defaultAllocator());
        }
    }
}

Variant* json_member(ref Variant object, const(char)[] full, const(char)[] abbreviated)
{
    if (!object.isObject)
        return null;
    Variant* value = object.getMember(full);
    if (!value && abbreviated)
        value = object.getMember(abbreviated);
    return value;
}

const(char)[] json_string(ref Variant object, const(char)[] full, const(char)[] abbreviated)
{
    Variant* value = json_member(object, full, abbreviated);
    return value && value.isString ? value.asString() : null;
}

String safe_id(const(char)[] value)
{
    MutableString!0 result;
    bool separator;
    foreach (char c; value)
    {
        if (c.is_alpha || c.is_numeric || c == '_')
        {
            if (separator && !result.empty && result[$ - 1] != '_')
                result ~= '_';
            separator = false;
            result ~= c.is_alpha ? cast(char)(c | 0x20) : c;
        }
        else
            separator = true;
    }
    while (!result.empty && result[$ - 1] == '_')
        result.erase(-1, 1);
    if (result.empty)
        result ~= "entity";
    return result[].makeString(defaultAllocator());
}

bool json_number(ref Variant object, const(char)[] key, out double result)
{
    Variant* value = json_member(object, key, null);
    if (!value)
        return false;
    if (value.isNumber)
    {
        result = value.asDouble;
        return true;
    }
    if (!value.isString)
        return false;
    const(char)[] text = value.asString().trim();
    size_t taken;
    result = parse_float(text, &taken);
    return !text.empty && taken == text.length;
}

Variant* walk_value_json(ref Variant root, const(char)[] expression)
{
    if (!expression.startsWith("value_json"))
        return null;
    const(char)[] path = expression["value_json".length .. $].trim();
    Variant* current = &root;
    while (!path.empty)
    {
        if (path[0] == '.')
        {
            path = path[1 .. $];
            size_t end = 0;
            while (end < path.length && path[end] != '.' && path[end] != '[')
                ++end;
            const(char)[] key = path[0 .. end].trim();
            if (key.empty || !current.isObject)
                return null;
            current = current.getMember(key);
            if (!current)
                return null;
            path = path[end .. $];
            continue;
        }

        if (path[0] != '[')
            return null;
        size_t close = path.findFirst(']');
        if (close == path.length)
            return null;
        const(char)[] token = path[1 .. close].trim();
        if (token.length >= 2 && ((token[0] == '"' && token[$ - 1] == '"') ||
                                  (token[0] == '\'' && token[$ - 1] == '\'')))
        {
            if (!current.isObject)
                return null;
            current = current.getMember(token[1 .. $ - 1]);
        }
        else
        {
            size_t taken;
            ulong index = parse_uint_with_base(token, &taken);
            if (taken != token.length || !current.isArray || index >= current.length)
                return null;
            current = &(*current)[cast(size_t)index];
        }
        if (!current)
            return null;
        path = path[close + 1 .. $].trim();
    }
    return current;
}
