module protocol.goodwe.binding;

import urt.array;
import urt.lifetime;
import urt.log;
import urt.meta : AliasSeq;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.base;
import manager.binding;
import manager.collection;
import manager.component;
import manager.device;
import manager.element;
import manager.profile;
import manager.sample;
import manager.series;

import protocol.goodwe.aa55;
import protocol.modbus : modbus_profile_section;
import protocol.modbus.binding : ElementDesc_Modbus;
import protocol.modbus.message : RegisterType;
import protocol.goodwe.client;
import protocol.goodwe.message : GoodWeFieldEncoding, goodwe_module_field, validate_goodwe_schedule, GoodWeCommitFormat, schedule_record_type, goodwe_ordered_commit, validate_goodwe_reactive, GoodWeModeStep, goodwe_native_mode_step, goodwe_record_matches, validate_goodwe_battery_low745, GoodWeLegacyModeStep, goodwe_legacy_mode_step;

import protocol.goodwe.module_config : goodwe_module_commit, goodwe_module_config_payload, GoodWeModuleCommand, goodwe_apn_payload;
import protocol.goodwe.message : goodwe_alarm_page_step;

//version = DebugGoodWeBinding;

nothrow @nogc:


struct ElementDesc_AA55
{
    uint invalid_raw;
    uint action;
    ushort action_payload;
    ushort desc = 0xFFFF;
    ushort address;
    ushort write_address;
    ushort bank_address;
    ubyte function_code;
    ubyte offset;
    ubyte length;
    GoodWeWire wire;
    ubyte write_count;
    ubyte write_offset;
    GoodWeWire write_wire;
    GoodWeFieldEncoding field_encoding;
    ubyte field_index;
    bool reject_invalid;
    GoodWeCommitFormat commit_format;
    ubyte action_control;
    ubyte action_response;
    ubyte record_type = ubyte.max;
    ubyte bank_count;
    ubyte bank_limit;
}

final class GoodWeBinding : ProfileBinding
{
    alias Properties = AliasSeq!(Prop!("client", client),
                                 Prop!("profile", profile),
                                 Prop!("model", model));
nothrow @nogc:
    ~this() {}


    enum type_name = "goodwe-binding";
    enum path = "/binding/goodwe";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!GoodWeBinding, id, flags);
    }

    final inout(GoodWeClient) client() inout pure
        => _client.get;
    final void client(GoodWeClient value)
    {
        if (_client.get is value)
            return;
        if (_subscribed)
        {
            detach_transport();
        }
        _client = value;
        mark_set!(typeof(this), "client")();
        restart();
    }

    final ref const(String) profile() const pure
        => _profile_name;
    final void profile(String value)
    {
        if (value == _profile_name)
            return;
        _profile_name = value.move;
        mark_set!(typeof(this), "profile")();
        restart();
    }

    final ref const(String) model() const pure
        => _model_name;
    final void model(String value)
    {
        if (value == _model_name)
            return;
        _model_name = value.move;
        mark_set!(typeof(this), "model")();
        restart();
    }

protected:

    final override bool validate() const pure
    {
        return _client.get !is null && !_profile_name.empty && !_device.empty;
    }

    override CompletionStatus startup()
    {
        GoodWeClient c = _client.get;
        if (!c || !c.running)
            return CompletionStatus.continue_;

        if (!materialise())
            return CompletionStatus.error;

        c.subscribe(&state_change);
        foreach (ref w; _writes)
        {
            elements[w.sample_index].element.subscribe(&setting_changed);
            if (w.commit)
                w.commit.subscribe(&commit_changed);
        }
        _subscribed = true;
        g_app.schedule(getTime(), &sample);
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        detach_transport();
        foreach (ref w; _writes)
            if (w.flags)
                restore_setting(w);
        _writes.clear();
        _write_phase = WritePhase.idle;
        _write_result = _write_pending = _write_address = null;
        elements.clear();
        return super.shutdown();
    }

    void sample(MonoTime now)
    {
        GoodWeClient c = _client.get;
        if (!c || !c.running)
            return;
        g_app.schedule(now + 400.msecs, &sample);
        if (_write_phase != WritePhase.idle)
            return;
        foreach (ref e; elements)
        {
            if ((e.flags & 3) || e.sample_time_ms == ushort.max ||
                (e.last_update != MonoTime() && now - e.last_update < msecs(e.sample_time_ms)))
                continue;
            ushort length;
            GoodWePriority priority = GoodWePriority.background;
            foreach (ref field; elements)
                if (same_block(e, field))
                {
                    if (field.offset + field.length > length)
                        length = cast(ushort)(field.offset + field.length);
                    if (field.sample_time_ms > 0 && field.sample_time_ms <= 1_000)
                        priority = GoodWePriority.realtime;
                }
            if (e.record_type != ubyte.max && length < 5)
                length = 5;
            bool sent;
            if (e.wire == GoodWeWire.modbus)
                sent = c.send_modbus(cast(ubyte)e.fn, e.address, cast(ushort)((length + 1) / 2), null, &response_handler, null, 0xF7, priority);
            else if (e.wire == GoodWeWire.module_)
            {
                ubyte[1] parameter = [cast(ubyte)(e.address - 1)];
                sent = c.send_module(cast(ubyte)e.fn, e.address ? parameter[] : null, &response_handler, null, priority);
            }
            else if (e.fn == GoodWeFunctionCode.read_registers)
            {
                ubyte[3] payload = [cast(ubyte)(e.address >> 8), cast(ubyte)e.address, cast(ubyte)((length + 1) / 2)];
                sent = c.send_request(GoodWeControlCode.read, e.fn, payload, &response_handler, null, -1, priority);
            }
            else
                sent = c.send_request(GoodWeControlCode.read, e.fn, null, &response_handler, null, -1, priority);
            if (sent)
            {
                foreach (ref field; elements)
                    if (same_block(e, field))
                    {
                        field.flags |= 1;
                        field.last_update = now;
                    }
            }
        }
    }

    static bool same_block(ref const SampleElement a, ref const SampleElement b)
    {
        return a.wire == b.wire && a.fn == b.fn && a.address == b.address;
    }

    final override const(char)[] profile_name() const pure
        => _profile_name[];

    final override const(char)[] model_name() const pure
        => _model_name[];

    final override bool materialise()
    {
        if (!super.materialise())
            return false;
        coalesce_native_reads();
        if (GoodWeClient c = _client.get)
        {
            if (!_bound_device)
                return true;
            DeviceBuilder builder = _bound_device.edit();
            builder.element("status.network.ip.address", register_value_format!(const(char)[])()).value = c.get_address();
            if (_writes.length)
            {
                Component status = builder.component("status.config_write");
                _write_result = bind_element(builder, status, "result", register_value_format!(const(char)[])());
                _write_pending = bind_element(builder, status, "pending", register_value_format!bool());
                _write_address = bind_element(builder, status, "address", register_value_format!ushort());
                _write_result.value("idle");
                _write_pending.value(false);
                foreach (ref w; _writes)
                    if (w.action)
                    {
                        Element* element = elements[w.sample_index].element;
                        if (!element.has_value)
                            element.value(Variant(cast(ushort)0), getSysTime(), &setting_changed);
                    }
                    else if (w.commit_format)
                    {
                        w.commit = bind_element(builder, elements[w.sample_index].element.parent, "apply", register_value_format!uint(), manager.element.Access.read_write);
                        w.commit.value(0u);
                        if (w.commit_format == GoodWeCommitFormat.native_alarm_page)
                            bind_element(builder, elements[w.sample_index].element.parent, "index", register_value_format!ushort(), manager.element.Access.read);
                    }
            }
        }
        return true;
    }

    final override FormatId add_handler(Device device, Element* e, ref const ElementDesc desc, ubyte)
    {
        import protocol.goodwe : goodwe_section;

        ElementDesc_AA55 aa55;
        if (!goodwe_profile_field(*_profile_data, desc, aa55))
            return FormatId.invalid;
        if (aa55.desc == 0xFFFF)
            return FormatId.invalid;

        SampleDesc sd = desc_by_index(aa55.desc);
        const(DataFormat)* fmt = sd.fmt;
        if (!e.format.valid)
            e.format = sd.format;
        SampleElement* se = &elements.pushBack();
        se.element = e;
        se.wire = aa55.wire;
        se.address = aa55.address;
        se.control = GoodWeControlCode.read;
        se.fn = cast(GoodWeFunctionCode)aa55.function_code;
        se.offset = aa55.offset;
        se.length = aa55.length;
        se.desc = sd;
        se.field_encoding = aa55.field_encoding;
        se.field_index = aa55.field_index;
        se.invalid_raw = aa55.invalid_raw;
        se.record_type = aa55.record_type;
        if (aa55.reject_invalid)
            se.flags |= 4;
        switch (desc.update_frequency)
        {
            case Frequency.realtime:       se.sample_time_ms = 400;         break;
            case Frequency.high:           se.sample_time_ms = 1_000;       break;
            case Frequency.medium:         se.sample_time_ms = 10_000;      break;
            case Frequency.low:            se.sample_time_ms = 60_000;      break;
            case Frequency.constant:       se.sample_time_ms = 0;           break;
            case Frequency.configuration:  se.sample_time_ms = 0;           break;
            case Frequency.on_demand:      se.sample_time_ms = ushort.max;  break;
            default: assert(false);
        }

        if (aa55.action)
        {
            se.sample_time_ms = ushort.max;
            se.fn = cast(GoodWeFunctionCode)6;
        }
        if (modbus_profile_section(desc.kind) && se.sample_time_ms != ushort.max)
            se.flags |= 8;

        if (aa55.write_count && (desc.access & manager.profile.Access.write))
            _writes ~= WriteElement(Variant(), Variant(), null, aa55.action, cast(ushort)(elements.length - 1),
                aa55.write_address, aa55.action_payload, aa55.bank_address, aa55.write_count, aa55.write_offset, aa55.write_wire, aa55.commit_format,
                aa55.action_control, aa55.action_response, aa55.record_type, aa55.bank_count, aa55.bank_limit);

        return sd.format;
    }

private:

    ObjectRef!GoodWeClient _client;
    String _profile_name;
    String _model_name;

    bool _subscribed;

    Array!SampleElement elements;

    enum WritePhase : ubyte { idle, read_wait, reading, write_wait, writing, verify_wait, verifying }
    struct WriteElement
    {
        Variant desired;
        Variant confirmed;
        Element* commit;
        uint action;
        ushort sample_index;
        ushort address;
        ushort action_payload;
        ushort bank_address;
        ubyte count;
        ubyte offset;
        GoodWeWire wire;
        GoodWeCommitFormat commit_format;
        ubyte action_control;
        ubyte action_response;
        ubyte record_type = ubyte.max;
        ubyte bank_count;
        ubyte bank_limit;
        ubyte flags; // 1: queued, 2: encoded, 4: staged until apply
    }
    Array!WriteElement _writes;
    align(8) ubyte[246] _after;
    Element* _write_result;
    Element* _write_pending;
    Element* _write_address;
    MonoTime _write_started;
    ushort _active_write;
    WritePhase _write_phase;
    ubyte _write_step;

    void detach_transport()
    {
        g_app.cancel(&sample);
        g_app.cancel(&flush_write);
        if (_client.get)
        {
            _client.cancel_requests(&response_handler);
            _client.cancel_requests(&write_response);
        }
        if (_subscribed)
        {
            if (_client.get)
                _client.unsubscribe(&state_change);
            foreach (ref w; _writes)
            {
                elements[w.sample_index].element.unsubscribe(&setting_changed);
                if (w.commit)
                    w.commit.unsubscribe(&commit_changed);
            }
            _subscribed = false;
        }
    }

    void setting_changed(ref const SampleUpdate update)
    {
        if (!update.value_ready)
            return;
        foreach (ref w; _writes)
        {
            if (elements[w.sample_index].element !is update.element)
                continue;
            if (!w.flags)
                w.confirmed = update.previous;
            if (!w.commit)
                w.desired = update.value;
            w.flags |= w.commit ? 4 : 1;
            if (!w.commit)
            {
                _write_pending.value(true);
                g_app.schedule(getTime(), &flush_write);
            }
        }
    }

    void commit_changed(ref const SampleUpdate update)
    {
        if (!update.value_ready)
            return;
        foreach (ref w; _writes)
            if (w.flags & 3)
            {
                _write_result.value("configuration write already pending");
                return;
            }
        foreach (ref w; _writes)
            if (w.commit is update.element && !elements[w.sample_index].element.has_value)
            {
                _write_result.value("configuration fields are incomplete");
                return;
            }
        GoodWeCommitFormat format;
        foreach (ref const w; _writes)
            if (w.commit is update.element)
            {
                if (format && format != w.commit_format)
                {
                    _write_result.value("inconsistent transaction format");
                    return;
                }
                format = w.commit_format;
            }
        if (format == GoodWeCommitFormat.reactive || format == GoodWeCommitFormat.battery_low745)
        {
            ubyte[28] words = void;
            size_t offset;
            foreach (ref const w; _writes)
                if (w.commit is update.element)
                {
                    Variant value = elements[w.sample_index].element.value;
                    if (offset == words.length || !encode_setting(w, value, words[offset .. offset + 2]))
                    {
                        _write_result.value("cannot encode configuration selection");
                        return;
                    }
                    offset += 2;
                }
            const(char)[] error = format == GoodWeCommitFormat.reactive ? validate_goodwe_reactive(words[0 .. offset]) :
                validate_goodwe_battery_low745(words[0 .. offset]);
            if (error.length)
            {
                _write_result.value(error);
                return;
            }
        }
        if (goodwe_module_commit(format) || format == GoodWeCommitFormat.native_apn)
        {
            const(char)[][8] fields;
            size_t length;
            ubyte[246] payload = void;
            GoodWeModuleCommand command;
            const(char)[] error = module_fields(update.element, false, fields, length);
            if (!error.length)
                error = format == GoodWeCommitFormat.native_apn ? goodwe_apn_payload(fields[0 .. length], payload[0 .. 50]) :
                    goodwe_module_config_payload(format, 0, fields[0 .. length], payload, command);
            if (error.length)
            {
                _write_result.value(error);
                return;
            }
        }
        foreach (ref w; _writes)
            if (w.commit is update.element)
            {
                if (!w.flags)
                    w.confirmed = elements[w.sample_index].element.value;
                w.desired = elements[w.sample_index].element.value;
                w.flags = (w.flags & ~cast(ubyte)4) | 1;
                _write_pending.value(true);
            }
        g_app.schedule(getTime(), &flush_write);
    }

    bool write_group(ref const WriteElement w)
    {
        ref const WriteElement active = _writes[_active_write];
        if (active.action)
            return w.sample_index == active.sample_index;
        return w.wire == active.wire && w.address == active.address && w.count == active.count &&
            w.commit is active.commit && w.action == active.action && w.record_type == active.record_type &&
            w.bank_address == active.bank_address && w.bank_count == active.bank_count && w.bank_limit == active.bank_limit;
    }

    void restore_setting(ref WriteElement w)
    {
        if (w.action)
            return;
        Element* element = elements[w.sample_index].element;
        if (!(element.access & manager.element.Access.read))
        {
            element.invalidate(getSysTime(), &setting_changed);
            return;
        }
        if (w.confirmed.isNull)
            element.invalidate(getSysTime(), &setting_changed);
        else
        {
            Variant value = w.confirmed;
            element.value(value, getSysTime(), &setting_changed);
        }
    }

    bool decode_setting(ref WriteElement w, const(ubyte)[] block)
    {
        if (w.record_type != ubyte.max && !goodwe_record_matches(block[4], w.record_type))
        {
            w.confirmed = Variant();
            return true;
        }
        ref SampleElement e = elements[w.sample_index];
        const(DataFormat)* fmt = e.desc.fmt;
        Scalar record;
        record.u = 0;
        if (!fmt.is_scalar || !sample_record(block[w.offset .. w.offset + e.length], e.desc, record.raw[0 .. fmt.stride]))
            return false;
        w.confirmed = box_record(record.raw.ptr, *fmt);
        return true;
    }

    bool encode_setting(ref const WriteElement w, ref const Variant value, ubyte[] image)
    {
        ref SampleElement e = elements[w.sample_index];
        Scalar record;
        record.u = 0;
        return unbox_scalar(value, *e.desc.fmt, record) &&
            emit_record(record.raw[0 .. e.desc.fmt.stride], e.desc, image);
    }

    bool reactive_neutral(ref const WriteElement w)
    {
        ubyte[2] word = void;
        if (!encode_setting(w, w.desired, word))
            return false;
        uint role;
        foreach (ref const candidate; _writes)
            if (candidate.commit is w.commit)
            {
                if (candidate.sample_index == w.sample_index)
                    return ((uint(word[0]) << 8) | word[1]) == (role == 2 ? 100 : 0);
                ++role;
            }
        return false;
    }

    const(char)[] module_fields(const(Element)* commit, bool desired, ref const(char)[][8] fields, out size_t length)
    {
        length = 0;
        foreach (ref const w; _writes)
            if (w.commit is commit)
            {
                Element* element = elements[w.sample_index].element;
                if (length == fields.length || (desired ? !w.desired.isString && !w.desired.isNull : !element.has_value || !element.data_format.is_text))
                    return "module configuration fields are incomplete";
                fields[length++] = desired ? w.desired.asString : element.text_value();
            }
        return null;
    }

    bool mode_step(out GoodWeModeStep step)
    {
        ref const WriteElement w = _writes[_active_write];
        ubyte[2] value = void;
        return encode_setting(w, w.desired, value) &&
            goodwe_native_mode_step(cast(ushort)((uint(value[0]) << 8) | value[1]), _write_step, step);
    }

    bool alarm_page_step(out GoodWeModeStep step)
    {
        ref const WriteElement w = _writes[_active_write];
        ubyte[2] value = void;
        return encode_setting(w, w.desired, value) &&
            goodwe_alarm_page_step(cast(ushort)((uint(value[0]) << 8) | value[1]), _write_step, step);
    }

    void prepare_mode_step(ref const GoodWeModeStep step)
    {
        _after[0] = cast(ubyte)(step.value >> 8);
        _after[1] = cast(ubyte)step.value;
        _after[2 .. 4] = 0;
        _write_address.value(step.address);
        _write_started = getTime();
        _write_phase = WritePhase.write_wait;
    }

    void finish_write(const(char)[] result, bool verified)
    {
        if (!verified && goodwe_ordered_commit(_writes[_active_write].commit_format))
            foreach (ref w; _writes)
                if (w.commit is _writes[_active_write].commit && !write_group(w))
                {
                    w.flags &= ~cast(ubyte)3;
                    if (!w.flags)
                        restore_setting(w);
                }
        foreach (ref w; _writes)
        {
            if (!write_group(w) || !w.flags)
                continue;
            bool encoded = (w.flags & 2) != 0;
            if (!encoded && _write_phase != WritePhase.reading)
                continue;
            w.flags &= ~cast(ubyte)2;
            if (!encoded)
                w.flags &= ~cast(ubyte)1;
            if (!w.flags)
                restore_setting(w);
            if (goodwe_module_commit(w.commit_format))
                w.desired = Variant();
            elements[w.sample_index].last_update = MonoTime();
            elements[w.sample_index].flags &= ~cast(ubyte)2;
        }
        _write_phase = WritePhase.idle;
        bool pending;
        foreach (ref w; _writes)
            pending |= (w.flags & 3) != 0;
        _write_pending.value(pending);
        _write_result.value(verified && pending ? "pending" : result);
        if (verified)
            note_activity();
        else
            log.warning("configuration write ", _writes[_active_write].address, ": ", result);
        if (pending)
            g_app.schedule(getTime(), &flush_write);
    }

    void flush_write(MonoTime now)
    {
        if (_write_phase == WritePhase.idle)
        {
            size_t index;
            while (index < _writes.length && !(_writes[index].flags & 1))
                ++index;
            if (index == _writes.length)
                return;
            if (_writes[index].commit_format == GoodWeCommitFormat.reactive && !reactive_neutral(_writes[index]))
                foreach (candidate, ref const w; _writes)
                    if ((w.flags & 1) && w.commit is _writes[index].commit && reactive_neutral(w))
                    {
                        index = candidate;
                        break;
                    }
            _active_write = cast(ushort)index;
            _write_step = 0;
            _write_started = now;
            _write_phase = WritePhase.read_wait;
            if (_writes[index].action && _writes[index].record_type == ubyte.max)
            {
                uint value = _writes[index].action - 1;
                _after[0] = cast(ubyte)(value >> 8);
                _after[1] = cast(ubyte)value;
                _writes[index].flags = (_writes[index].flags & ~cast(ubyte)1) | 2;
                _write_phase = WritePhase.write_wait;
            }
            _write_address.value(_writes[index].address);
            _write_result.value("pending");
            if (goodwe_module_commit(_writes[index].commit_format))
            {
                foreach (ref w; _writes)
                    if (write_group(w))
                        w.flags = (w.flags & ~cast(ubyte)1) | 2;
                _write_phase = WritePhase.write_wait;
            }
            if (_writes[index].commit_format == GoodWeCommitFormat.native_alarm_page)
            {
                _writes[index].flags = (_writes[index].flags & ~cast(ubyte)1) | 2;
                GoodWeModeStep step;
                if (!alarm_page_step(step))
                {
                    _write_phase = WritePhase.reading;
                    finish_write("cannot encode alarm page index", false);
                    return;
                }
            }
            if (_writes[index].commit_format == GoodWeCommitFormat.native_apn)
            {
                ref WriteElement w = _writes[index];
                const(char)[][1] fields;
                fields[0] = w.desired.asString;
                const(char)[] error = goodwe_apn_payload(fields, _after[0 .. 50]);
                if (error.length)
                {
                    _write_phase = WritePhase.reading;
                    finish_write(error, false);
                    return;
                }
                w.flags = (w.flags & ~cast(ubyte)1) | 2;
                _write_phase = WritePhase.write_wait;
            }
            if (_writes[index].commit_format == GoodWeCommitFormat.legacy_mode)
            {
                ref WriteElement w = _writes[index];
                if (!encode_setting(w, w.desired, _after[0 .. 2]) || _after[0] || _after[1] > 3)
                {
                    _write_phase = WritePhase.reading;
                    finish_write("unsupported legacy application mode", false);
                    return;
                }
                w.flags = (w.flags & ~cast(ubyte)1) | 2;
                _write_phase = WritePhase.write_wait;
            }
            if (_writes[index].commit_format == GoodWeCommitFormat.native_mode)
            {
                GoodWeModeStep step;
                if (!mode_step(step))
                {
                    _write_phase = WritePhase.reading;
                    finish_write("unsupported native application mode", false);
                    return;
                }
                _writes[index].flags = (_writes[index].flags & ~cast(ubyte)1) | 2;
                prepare_mode_step(step);
            }
        }
        if (_write_phase == WritePhase.reading || _write_phase == WritePhase.writing || _write_phase == WritePhase.verifying)
            return;
        if (now - _write_started > 10.seconds)
        {
            _write_phase = _write_phase == WritePhase.read_wait ? WritePhase.reading : _write_phase;
            finish_write("transport busy or unavailable", false);
            return;
        }
        GoodWeClient c = _client.get;
        ref const WriteElement w = _writes[_active_write];
        bool reading = _write_phase != WritePhase.write_wait;
        bool sent;
        if (c && c.running)
        {
            if (w.commit_format == GoodWeCommitFormat.native_alarm_page)
            {
                GoodWeModeStep step;
                alarm_page_step(step);
                _write_address.value(step.address);
                sent = c.send_modbus(_write_step == 1 ? 6 : 3, step.address,
                    _write_step == 1 ? step.value : step.count, null, &write_response);
            }
            else if (w.commit_format == GoodWeCommitFormat.legacy_mode)
            {
                if (reading)
                    sent = c.send_request(GoodWeControlCode.read, cast(GoodWeFunctionCode)9, null, &write_response);
                else
                {
                    GoodWeLegacyModeStep step;
                    goodwe_legacy_mode_step(_after[1], _write_step, step);
                    _write_address.value(step.function_code);
                    sent = c.send_request(cast(GoodWeControlCode)step.control, cast(GoodWeFunctionCode)step.function_code,
                        step.payload[0 .. step.length], &write_response);
                }
            }
            else if (goodwe_module_commit(w.commit_format))
            {
                const(char)[][8] fields;
                size_t length;
                ubyte[246] payload = void;
                GoodWeModuleCommand command;
                const(char)[] error = module_fields(w.commit, true, fields, length);
                if (!error.length)
                    error = goodwe_module_config_payload(w.commit_format, _write_step, fields[0 .. length], payload, command);
                if (error.length)
                {
                    finish_write(error, false);
                    return;
                }
                _write_address.value(command.function_code);
                sent = c.send_module(command.function_code, payload[0 .. command.length], &write_response,
                    null, GoodWePriority.realtime, command.family);
            }
            else if (w.action_control)
            {
                import urt.encoding : hex_decode;
                const(char)[] text = _profile_data.get_section_string(w.action_payload);
                ubyte[255] payload = void;
                size_t length = hex_decode(text, payload);
                sent = c.send_request(cast(GoodWeControlCode)w.action_control,
                    cast(GoodWeFunctionCode)(w.action - 1), payload[0 .. length], &write_response, null, w.action_response);
            }
            else if (w.wire == GoodWeWire.modbus)
            {
                bool guarded_action = w.action && w.record_type != ubyte.max;
                bool bank = _write_phase == WritePhase.read_wait && w.bank_count;
                ushort address = bank ? w.bank_address : reading && guarded_action ? elements[w.sample_index].address : w.address;
                ushort count = bank ? w.bank_count : reading && guarded_action ? 6 : w.count;
                if (w.commit_format == GoodWeCommitFormat.native_mode)
                {
                    GoodWeModeStep step;
                    mode_step(step);
                    address = step.address;
                    count = step.count;
                }
                ushort value = cast(ushort)((uint(_after[0]) << 8) | _after[1]);
                if (w.commit_format == GoodWeCommitFormat.load && _write_step == 1)
                {
                    address = 47509;
                    count = 1;
                    value = 0;
                }
                sent = c.send_modbus(reading ? 3 : count == 1 ? 6 : 16, address,
                    reading || count != 1 ? count : value,
                    reading || count == 1 ? null : _after[0 .. count * 2], &write_response);
            }
            else
            {
                ubyte[249] payload = void;
                payload[0] = cast(ubyte)(w.address >> 8);
                payload[1] = cast(ubyte)w.address;
                payload[2] = w.count;
                if (!reading)
                    payload[3 .. 3 + w.count * 2] = _after[0 .. w.count * 2];
                sent = c.send_request(reading ? GoodWeControlCode.read : GoodWeControlCode.write,
                    reading ? GoodWeFunctionCode.read_registers : GoodWeFunctionCode.write_registers,
                    payload[0 .. (reading ? 3 : 3 + w.count * 2)], &write_response);
            }
        }
        if (!sent)
            g_app.schedule(now + 50.msecs, &flush_write);
        else
            _write_phase = _write_phase == WritePhase.read_wait ? WritePhase.reading :
                _write_phase == WritePhase.write_wait ? WritePhase.writing : WritePhase.verifying;
    }

    void write_response(bool success, ref const GoodWeRequest request, MonoTime response_time, const(ubyte)[] response, void*)
    {
        ref const WriteElement active = _writes[_active_write];
        if (!success)
        {
            finish_write(_write_phase == WritePhase.reading ? "read failed" : "write or verification failed", false);
            return;
        }
        if (active.commit_format == GoodWeCommitFormat.native_alarm_page)
        {
            ubyte[2] index = void;
            encode_setting(active, active.desired, index);
            if (_write_step == 0)
            {
                if (response.length != 2)
                {
                    finish_write("invalid alarm page count", false);
                    return;
                }
                sample_block(request.wire, request.function_code, request.address, response_time, response);
                uint count = uint(response[0]) << 8 | response[1];
                if (!count)
                {
                    SysTime timestamp = cast(SysTime)response_time;
                    foreach (ref e; elements)
                        if (e.wire == GoodWeWire.modbus && e.fn == cast(GoodWeFunctionCode)3 && e.address == 55252)
                            e.element.invalidate(timestamp, &setting_changed);
                    elements[active.sample_index].element.parent.find_element("index").invalidate(timestamp, &setting_changed);
                    finish_write("no alarm pages", true);
                    return;
                }
                if ((uint(index[0]) << 8 | index[1]) >= count)
                {
                    finish_write("alarm page index outside current range", false);
                    return;
                }
            }
            else if (_write_step == 2)
            {
                if (response.length != 130)
                {
                    finish_write("invalid alarm page length", false);
                    return;
                }
                _after[0 .. 130] = response;
            }
            else if (_write_step == 3)
            {
                if (response != index)
                {
                    finish_write("alarm cursor changed during read", false);
                    return;
                }
                sample_block(GoodWeWire.modbus, cast(GoodWeFunctionCode)3, 55252, response_time, _after[0 .. 130]);
                elements[active.sample_index].element.parent.find_element("index").value(
                    Variant(cast(ushort)(uint(index[0]) << 8 | index[1])), cast(SysTime)response_time, &setting_changed);
                finish_write("verified", true);
                return;
            }
            ++_write_step;
            _write_phase = _write_step == 1 ? WritePhase.write_wait : WritePhase.verify_wait;
            _write_started = getTime();
            flush_write(getTime());
            return;
        }
        if (active.commit_format == GoodWeCommitFormat.legacy_mode)
        {
            if (_write_phase == WritePhase.writing)
            {
                if (response.length != 1 || response[0] != 6)
                {
                    finish_write("legacy mode step rejected", false);
                    return;
                }
                GoodWeLegacyModeStep step;
                _write_phase = goodwe_legacy_mode_step(_after[1], ++_write_step, step) ? WritePhase.write_wait : WritePhase.verify_wait;
                _write_started = getTime();
                flush_write(getTime());
            }
            else
            {
                bool matches = response.length >= 68 && response[66 .. 68] == _after[0 .. 2];
                if (response.length >= 68)
                    decode_setting(_writes[_active_write], response[66 .. 68]);
                finish_write(matches ? "verified" : "legacy mode readback mismatch", matches);
            }
            return;
        }
        if (goodwe_module_commit(active.commit_format))
        {
            if (++_write_step == (active.commit_format == GoodWeCommitFormat.module_password ? 2 : 3))
                finish_write("acknowledged; reconnect and readback required", true);
            else
            {
                _write_started = getTime();
                _write_phase = WritePhase.write_wait;
                flush_write(getTime());
            }
            return;
        }
        if (active.commit_format == GoodWeCommitFormat.native_mode)
        {
            if (_write_phase == WritePhase.writing)
                _write_phase = WritePhase.verify_wait;
            else
            {
                GoodWeModeStep step;
                if (!mode_step(step) || response != _after[0 .. step.count * 2])
                {
                    finish_write("native mode step readback mismatch", false);
                    return;
                }
                if (++_write_step == 4)
                {
                    decode_setting(_writes[_active_write], response);
                    finish_write("verified", true);
                    return;
                }
                mode_step(step);
                prepare_mode_step(step);
            }
            flush_write(getTime());
            return;
        }
        if (active.commit_format == GoodWeCommitFormat.load && _write_step == 1)
        {
            if (_write_phase == WritePhase.writing)
                _write_phase = WritePhase.verify_wait;
            else if (response.length != 2 || response[0] || response[1])
            {
                finish_write("load export-limiter readback mismatch", false);
                return;
            }
            else
            {
                _write_step = 2;
                _write_address.value(active.address);
                _write_started = getTime();
                _write_phase = WritePhase.write_wait;
            }
            flush_write(getTime());
            return;
        }
        if (_write_phase == WritePhase.reading && active.bank_count)
        {
            if (response.length != active.bank_count * 2)
            {
                finish_write("invalid schedule bank length", false);
                return;
            }
            size_t offset = (active.address - active.bank_address) * 2;
            if (response[offset + 4] == 85 || schedule_record_type(response[offset + 4]) == 0)
            {
                uint occupied;
                for (size_t index = 4; index < response.length; index += 12)
                    occupied += goodwe_record_matches(response[index], active.record_type);
                if (occupied >= active.bank_limit)
                {
                    foreach (ref w; _writes)
                        if (write_group(w))
                            w.confirmed = Variant();
                    finish_write("schedule type slot limit reached", false);
                    return;
                }
            }
            response = response[offset .. offset + active.count * 2];
        }
        if (_write_phase == WritePhase.writing)
        {
            if (active.wire == GoodWeWire.aa55 && (response.length != 1 || response[0] != 6))
            {
                finish_write("write rejected", false);
                return;
            }
            if (active.action)
            {
                finish_write("acknowledged", true);
                return;
            }
            _write_phase = WritePhase.verify_wait;
        }
        else if (response.length != (active.action && active.record_type != ubyte.max ? 12 : active.count * 2))
        {
            finish_write("invalid read length", false);
            return;
        }
        else if (active.record_type != ubyte.max &&
            (response.length < 5 || (!goodwe_record_matches(response[4], active.record_type) &&
             !(!active.action && _write_phase == WritePhase.reading && (response[4] == 85 || schedule_record_type(response[4]) == 0)))))
        {
            SysTime timestamp = getSysTime();
            foreach (ref e; elements)
                if (e.wire == active.wire && e.address == elements[active.sample_index].address &&
                    e.record_type == active.record_type && e.fn != cast(GoodWeFunctionCode)6)
                    e.element.invalidate(timestamp, &setting_changed);
            foreach (ref w; _writes)
                if (write_group(w))
                    w.confirmed = Variant();
            finish_write("schedule record has a different type", false);
            return;
        }
        else if (_write_phase == WritePhase.reading)
        {
            if (active.action)
            {
                uint value = active.action - 1;
                _after[0] = cast(ubyte)(value >> 8);
                _after[1] = cast(ubyte)value;
                _writes[_active_write].flags = (_writes[_active_write].flags & ~cast(ubyte)1) | 2;
                _write_phase = WritePhase.write_wait;
                flush_write(getTime());
                return;
            }
            _after[0 .. response.length] = response;
            foreach (ref w; _writes)
            {
                if (!write_group(w) || !(w.flags & 1))
                    continue;
                if (!decode_setting(w, response))
                {
                    finish_write("cannot decode current setting", false);
                    return;
                }
                if (!encode_setting(w, w.desired, _after[w.offset .. w.offset + elements[w.sample_index].length]))
                {
                    finish_write("cannot encode requested setting", false);
                    return;
                }
                w.flags = (w.flags & ~cast(ubyte)1) | 2;
            }
            if (active.record_type != ubyte.max && !goodwe_record_matches(_after[4], active.record_type))
            {
                finish_write("schedule record type is not selected", false);
                return;
            }
            if (active.commit_format && !goodwe_ordered_commit(active.commit_format))
            {
                if (active.commit_format == GoodWeCommitFormat.legacy || active.commit_format == GoodWeCommitFormat.load)
                    _after[10 .. 12] = 0;
                const(char)[] error = validate_goodwe_schedule(_after[0 .. active.count * 2], active.commit_format);
                if (error.length)
                {
                    finish_write(error, false);
                    return;
                }
            }
            _write_phase = WritePhase.write_wait;
            if (active.commit_format == GoodWeCommitFormat.load && schedule_record_type(_after[4]) == 2)
            {
                _write_step = 1;
                _write_address.value(47509);
            }
        }
        else
        {
            bool matches = response == _after[0 .. response.length];
            foreach (ref w; _writes)
                if (write_group(w) && (w.flags & 2) && active.commit_format != GoodWeCommitFormat.native_apn)
                    decode_setting(w, response);
            finish_write(matches ? "verified" : "readback mismatch", matches);
            return;
        }
        flush_write(getTime());
    }

    struct SampleElement
    {
        MonoTime last_update;
        ushort address;
        GoodWeWire wire;
        GoodWeControlCode control;
        GoodWeFunctionCode fn;
        ubyte offset;
        ubyte flags; // 1: in-flight, 2: constant-sampled, 4: raw sentinel, 8: unbatched native field
        ushort sample_time_ms;
        Element* element;
        ubyte length;
        SampleDesc desc;
        uint invalid_raw;
        GoodWeFieldEncoding field_encoding;
        ubyte field_index;
        ubyte record_type = ubyte.max;
    }

    void coalesce_native_reads()
    {
        foreach (ref e; elements)
            if (e.flags & 8)
                foreach (ref block; elements)
                    if (block.wire == e.wire && block.fn == e.fn && !block.offset &&
                        block.desc.fmt.type == ValueType.u8 && block.desc.fmt.count > 1 &&
                        block.address <= e.address && uint(e.address - block.address) * 2 + e.length <= block.length)
                    {
                        e.offset = cast(ubyte)((e.address - block.address) * 2);
                        e.address = block.address;
                        e.flags &= ~cast(ubyte)8;
                        break;
                    }
        for (;;)
        {
            uint start = uint.max;
            GoodWeFunctionCode fn;
            foreach (ref e; elements)
                if ((e.flags & 8) && e.address < start)
                {
                    start = e.address;
                    fn = e.fn;
                }
            if (start == uint.max)
                return;
            uint end = start;
            bool extended;
            do
            {
                extended = false;
                foreach (ref e; elements)
                {
                    uint stop = uint(e.address) + (e.length + 1) / 2;
                    if ((e.flags & 8) && e.fn == fn && e.address <= end + 16 &&
                        stop > end && stop - start <= 125)
                    {
                        end = stop;
                        extended = true;
                    }
                }
            } while (extended);
            foreach (ref e; elements)
                if ((e.flags & 8) && e.fn == fn && uint(e.address) + (e.length + 1) / 2 <= end)
                {
                    e.offset = cast(ubyte)((e.address - start) * 2);
                    e.address = cast(ushort)start;
                    e.flags &= ~cast(ubyte)8;
                }
        }
    }

    void state_change(ActiveObject obj, StateSignal signal)
    {
        if (signal == StateSignal.offline)
        {
            set_device_online(false);
            restart();
        }
    }

    static bool matches(ref const SampleElement element, ref const GoodWeRequest request)
    {
        return element.wire == request.wire && element.fn == request.function_code && element.address == request.address;
    }

    void response_handler(bool success, ref const GoodWeRequest request, MonoTime response_time, const(ubyte)[] response, void* user_data)
    {
        foreach (ref e; elements)
        {
            if (matches(e, request))
                e.flags &= 0xFE; // clear in-flight flag
        }
        report_poll(success);
        if (!success)
        {
            version (DebugGoodWeBinding)
                log.debug_("sample FAILED after ", (response_time - request.request_time).as!"msecs", "ms - '", _client.name, "' fn: ", request.function_code);
            return;
        }

        version (DebugGoodWeBinding)
            log.debug_("sample response after ", (response_time - request.request_time).as!"msecs", "ms - '", _client.name, "' fn: ", request.function_code);

        sample_block(request.wire, request.function_code, request.address, response_time, response);
    }

    void sample_block(GoodWeWire source_wire, GoodWeFunctionCode source_fn, ushort source_address, MonoTime response_time, const(ubyte)[] response)
    {
        foreach (ref e; elements)
        {
            if (e.wire != source_wire || e.fn != source_fn || e.address != source_address)
                continue;

            bool pending;
            foreach (ref w; _writes)
                if (elements[w.sample_index].element is e.element && w.flags)
                    pending = true;
            if (pending)
                continue;

            if (e.wire == GoodWeWire.module_ && e.length == 0)
            {
                if (e.field_encoding == GoodWeFieldEncoding.status)
                {
                    if (response.length == 1)
                    {
                        char[3] text;
                        uint value = response[0];
                        size_t begin = text.length;
                        do { text[--begin] = cast(char)('0' + value % 10); value /= 10; } while (value);
                        e.element.value(Variant(text[begin .. $]), cast(SysTime)response_time, &setting_changed);
                    }
                    else if (response.length)
                        e.element.value(Variant(cast(const(char)[])response), cast(SysTime)response_time, &setting_changed);
                    else
                        e.element.invalidate(cast(SysTime)response_time, &setting_changed);
                    continue;
                }
                const(ubyte)[] field;
                if (e.offset <= response.length && goodwe_module_field(response[e.offset .. $], e.field_encoding, e.field_index, field))
                    e.element.value(Variant(cast(const(char)[])field), cast(SysTime)response_time, &setting_changed);
                else
                    e.element.invalidate(cast(SysTime)response_time, &setting_changed);
                if (e.sample_time_ms == 0)
                    e.flags |= 2;
                continue;
            }
            if (uint(e.offset) + e.length > response.length)
                continue;
            if (e.sample_time_ms == 0)
                e.flags |= 2;
            const(void)[] wire = response[e.offset .. e.offset + e.length];
            SysTime t = cast(SysTime)response_time;

            Element* el = e.element;
            if (e.flags & 4)
            {
                uint raw;
                foreach (value; response[e.offset .. e.offset + e.length])
                    raw = (raw << 8) | value;
                if (raw == e.invalid_raw)
                {
                    el.invalidate(t, &setting_changed);
                    continue;
                }
            }
            if (e.record_type != ubyte.max && (response.length < 5 || !goodwe_record_matches(response[4], e.record_type)))
            {
                el.invalidate(t, &setting_changed);
                continue;
            }
            const(DataFormat)* fmt = e.desc.fmt;
            if (fmt.is_scalar)
            {
                Scalar s;
                s.u = 0;
                if (!sample_record(wire, e.desc, s.raw[0 .. fmt.stride]))
                    continue;
                if (el.format == e.desc.format)
                    el.write_record(s.raw[0 .. fmt.stride], t, &setting_changed);
                else
                    el.value(box_record(s.raw.ptr, *fmt), t, &setting_changed);
            }
            else if (fmt.type == ValueType.char_)
            {
                char[256] buf = void;
                el.value(Variant(sample_text(wire, e.desc, buf)), t);
            }
            else
            {
                align(8) ubyte[256] rec = void;
                if (fmt.stride <= rec.length && sample_record(wire, e.desc, rec[0 .. fmt.stride]))
                    el.value(box_record(rec.ptr, *fmt), t);
            }

            version (DebugGoodWeBinding)
                log.debugf("sample - offset: {0} element: {1} = {2}", e.offset, el.id, el.value);
        }
    }
}

bool goodwe_profile_field(ref const Profile profile, ref const ElementDesc desc, out ElementDesc_AA55 field)
{
    import protocol.goodwe : goodwe_section;
    if (goodwe_section(desc.kind))
    {
        field = profile.get_section!ElementDesc_AA55(desc.kind, desc.element);
        return true;
    }
    if (!modbus_profile_section(desc.kind))
        return false;
    ref const ElementDesc_Modbus source = profile.get_section!ElementDesc_Modbus(desc.kind, desc.element);
    if (source.reg_type != RegisterType.holding_register && source.reg_type != RegisterType.input_register)
        return false;
    field.desc = source.desc;
    field.address = source.reg;
    field.length = source.length;
    field.wire = GoodWeWire.modbus;
    field.function_code = source.reg_type == RegisterType.holding_register ? 3 : 4;
    if (source.reg_type == RegisterType.holding_register && (desc.access & manager.profile.Access.write))
    {
        field.write_address = source.reg;
        field.write_count = cast(ubyte)(source.length / 2);
        field.write_wire = GoodWeWire.modbus;
    }
    return true;
}
