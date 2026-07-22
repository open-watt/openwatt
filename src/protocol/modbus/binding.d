module protocol.modbus.binding;

import urt.array;
import urt.endian;
import urt.log;
import urt.mem.temp : tconcat;
import urt.meta : AliasSeq;
import urt.si;
import urt.string;
import urt.time;
import urt.util : align_up;
import urt.variant;

import manager;
import manager.base;
import manager.binding;
import manager.collection;
import manager.device;
import manager.element;
import manager.plugin;
import manager.profile;
import manager.sampler;

import protocol.modbus;
import protocol.modbus.node;
import protocol.modbus.message;

import router.iface.packet : PCP, pcp_priority_map;

//version = DebugModbusBinding;
//version = DebugModbusBindingRegs;

private alias Access = manager.element.Access;

nothrow @nogc:


template modbus_data_type(const(char)[] str)
{
    private enum DataType value = parse_modbus_data_type(str);
    static assert(value != DataType.invalid, "invalid modbus data type: " ~ str);
    alias modbus_data_type = value;
}

DataType parse_modbus_data_type(const(char)[] desc)
{
    if (desc.length == 3 && desc[1] == '8')
    {
        // high/low byte of a register: occupies a full big-endian word on the wire, samples to one byte
        uint flags = DataType.u16 | DataType.big_endian;
        if (desc[0] == 'i')
            flags |= DataType.signed;
        else if (desc[0] != 'u')
            return DataType.invalid;
        if (desc[2] == 'h')
            return make_data_type(flags, DataKind.high_byte);
        else if (desc[2] == 'l')
            return make_data_type(flags, DataKind.low_byte);
        return DataType.invalid;
    }

    // TODO: this may be insufficient, but it's what we already model...
    DataType r = parse_data_type(desc);
    if (r == DataType.invalid)
        return DataType.invalid;

    // modbus strings are (normally?) space-padded (sign bit), and the length is in words
    if (r.data_kind == DataKind.string_)
    {
        DataType keep = r & (DataType.word_reverse | DataType.signed);
        return make_data_type(DataType.u16 | DataType.array | keep, DataKind.string_, r.data_count);
    }

    // assume big-endian if not given
    if ((r & (DataType.little_endian | DataType.big_endian)) == 0)
        r |= DataType.big_endian;

    return r;
}


class ModbusBinding : ProfileBinding
{
    alias Properties = AliasSeq!(Prop!("node", node),
                                 Prop!("slave", slave),
                                 Prop!("profile", binding_profile),
                                 Prop!("model", binding_model),
                                 Prop!("serve", serve));
nothrow @nogc:

    enum type_name = "mb-binding";
    enum path = "/binding/modbus";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!ModbusBinding, id, flags);
    }

    // Properties...

    final inout(ModbusNode) node() inout pure
        => _node.get;
    final void node(ModbusNode value)
    {
        if (_node.get is value)
            return;
        teardown_node_hooks();
        _node = value;
        mark_set!(typeof(this), "node")();
        restart();
    }

    final ref const(String) slave() const pure
        => _slave_name;
    final void slave(String value)
    {
        if (value == _slave_name)
            return;
        _slave_name = value.move;
        _slave_server = null;
        mark_set!(typeof(this), "slave")();
        restart();
    }

    final ref const(String) binding_profile() const pure
        => _profile_name_explicit;
    final void binding_profile(String value)
    {
        if (value == _profile_name_explicit)
            return;
        _profile_name_explicit = value.move;
        mark_set!(typeof(this), "profile")();
        restart();
    }

    final ref const(String) binding_model() const pure
        => _model_name_explicit;
    final void binding_model(String value)
    {
        if (value == _model_name_explicit)
            return;
        _model_name_explicit = value.move;
        mark_set!(typeof(this), "model")();
        restart();
    }

    final bool serve() const pure
        => _serve;
    final void serve(bool value)
    {
        if (_serve == value)
            return;
        _serve = value;
        mark_set!(typeof(this), "serve")();
        restart();
    }

    // Lifecycle...

    final override bool validate() const pure
    {
        if (!_node.get || _device.empty)
            return false;
        if (_slave_name.empty && _profile_name_explicit.empty)
            return false;
        return true;
    }

    override CompletionStatus startup()
    {
        if (_slave_name.length > 0 && !_slave_server)
        {
            _slave_server = get_module!ModbusProtocolModule.find_server_by_name(_slave_name[]);
            if (!_slave_server)
            {
                // fall through to local-node lookup: slave= may name a ModbusNode whose serving binding has a profile
                ModbusNode local = Collection!ModbusNode().get(_slave_name[]);
                if (local !is null)
                {
                    if (local.address == 0)
                        return CompletionStatus.continue_;
                    foreach (ModbusBinding b; Collection!ModbusBinding().values())
                    {
                        if (b is this || !b._serve || b._profile_name_explicit.empty)
                            continue;
                        if (b._node.get !is local)
                            continue;
                        _local_slave = ServerMap.init;
                        _local_slave.name = _slave_name;
                        _local_slave.local_address = local.address;
                        _local_slave.universal_address = local.address;
                        _local_slave.profile = b._profile_name_explicit;
                        _local_slave.model = b._model_name_explicit;
                        _slave_server = &_local_slave;
                        break;
                    }
                }
            }
            if (!_slave_server)
            {
                log.warning("slave '", _slave_name, "' not found");
                return CompletionStatus.error;
            }
            if (_slave_server.profile.empty)
            {
                log.warning("slave '", _slave_name, "' has no profile");
                return CompletionStatus.error;
            }
        }

        if (!materialise())
            return CompletionStatus.error;

        ModbusNode c = _node.get;
        if (!c || !c.running)
            return CompletionStatus.continue_;

        _snooping = c.isSnooping;
        if (_snooping)
        {
            if (!_slave_server)
            {
                log.warning("snooping requires slave=");
                return CompletionStatus.error;
            }
            c.setSnoopHandler(&snoop_handler);
        }

        if (_serve && !_snooping)
        {
            c.setRequestHandler(&request_handler);
            _serving_active = true;
        }

        c.subscribe(&node_state_change);
        _subscribed = true;

        if (_slave_server)
            subscribe_writable_elements();

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        unsubscribe_writable_elements();
        teardown_node_hooks();

        elements.clear();
        serve_elements.clear();
        needsSort = true;

        if (_serve_profile_data)
        {
            g_app.allocator.freeT(_serve_profile_data);
            _serve_profile_data = null;
        }
        return super.shutdown();
    }

    override void update()
    {
        if (needsSort)
        {
            import urt.algorithm : qsort;

            qsort!((ref a, ref b) => a.regKind != b.regKind ? (a.regKind < b.regKind ? -1 : 1)
                                                            : (a.register < b.register ? -1 : a.register > b.register ? 1 : 0))(elements[]);
            qsort!((ref a, ref b) => a.regKind != b.regKind ? (a.regKind < b.regKind ? -1 : 1)
                                                            : (a.register < b.register ? -1 : a.register > b.register ? 1 : 0))(serve_elements[]);
            needsSort = false;
        }

        flush_pending_writes();

        if (_snooping || !_slave_server)
            return;

        ModbusNode c = _node.get;

        enum MaxRegs = 128;
        enum MaxGapSize = 16;

        MonoTime now = getTime();

        size_t i = 0;
        for (; i < elements.length; )
        {
            ushort firstReg = elements[i].register;
            ushort count = elements[i].seqLen;

            if ((elements[i].flags & 3) || elements[i].sampleTimeMs == ushort.max || now - elements[i].lastUpdate < msecs(elements[i].sampleTimeMs))
            {
                ++i;
                continue;
            }

            elements[i].flags |= 1;

            PCP batch_pcp = elements[i].pcp;
            bool batch_dei = elements[i].dei;
            ubyte batch_rank = pcp_priority_map[batch_pcp];

            size_t j = i + 1;
            for (; j < elements.length; ++j)
            {
                if ((elements[j].flags & 3) ||
                    elements[j].sampleTimeMs == ushort.max ||
                    now - elements[j].lastUpdate < msecs(elements[j].sampleTimeMs))
                    continue;

                ushort nextReg = elements[j].register;
                int last = nextReg + elements[j].seqLen;

                if ((elements[j].regKind != elements[i].regKind) ||
                    (last - firstReg > MaxRegs) ||
                    (nextReg >= firstReg + count + MaxGapSize))
                    break;

                count = cast(ushort)(last - firstReg);

                ubyte j_rank = pcp_priority_map[elements[j].pcp];
                if (j_rank > batch_rank)
                {
                    batch_rank = j_rank;
                    batch_pcp = elements[j].pcp;
                }
                if (!elements[j].dei)
                    batch_dei = false;

                elements[j].flags |= 1;
            }

            ModbusPDU pdu = createMessage_Read(cast(RegisterType)elements[i].regKind, firstReg, count);
            // rejection invokes error_handler inline, which releases the batch's in-flight flags
            if (!c.sendRequest(_slave_server.universal_address, pdu, &response_handler, &error_handler, 0, retryTime, batch_pcp, batch_dei))
            {
                i = j;
                continue;
            }

            version (DebugModbusBinding)
                log.tracef("Request: {0} [{1}{2,04x}:{3}]", _slave_server.universal_address, elements[i].regKind, firstReg, count);

            i = j;
        }

        version (DebugModbusBinding)
        {
            if (++_diag_counter >= 100)
            {
                _diag_counter = 0;
                uint n_in_flight, n_const;
                foreach (ref e; elements)
                {
                    if (e.flags & 2) ++n_const;
                    else if (e.flags & 1) ++n_in_flight;
                }
                log.debugf("Binding {0}: {1} elements, {2} in-flight, {3} const-done",
                    _slave_server.universal_address, elements.length, n_in_flight, n_const);
            }
        }
    }

protected:
    final override const(char)[] profile_dir() const pure
        => "conf/modbus_profiles/";

    final override const(char)[] profile_name() const pure
    {
        if (_slave_server)
            return _slave_server.profile[];
        return _profile_name_explicit[];
    }
    final override const(char)[] model_name() const pure
    {
        if (_slave_server)
            return _slave_server.model[];
        return _model_name_explicit[];
    }

    override bool materialise()
    {
        _current_pass = Pass.primary;
        if (!super.materialise())
            return false;

        if (!_serve_profile_data && _serve && _slave_server && _profile_name_explicit.length > 0 && _profile_name_explicit[] != _slave_server.profile[])
        {
            import urt.file : load_file;
            const(char)[] pname = _profile_name_explicit[];
            void[] file = load_file(tconcat(profile_dir(), pname, ".conf"), g_app.allocator);
            scope (exit) g_app.allocator.free(file);
            if (!file)
            {
                log.warning(name[], ": failed to load serve profile '", pname, "'");
                return false;
            }
            _serve_profile_data = parse_profile(cast(char[])file, g_app.allocator);
            if (!_serve_profile_data)
            {
                log.warning(name[], ": failed to parse serve profile '", pname, "'");
                return false;
            }
            const(char)[] serve_model = _model_name_explicit[];
            _current_pass = Pass.serve;
            create_device_from_profile(*_serve_profile_data, serve_model, _device[], null, &add_handler);
        }

        return true;
    }

    final override void add_handler(Device device, Element* e, ref const ElementDesc desc, ubyte)
    {
        assert(desc.type == ElementType.modbus);

        Profile* prof = _current_pass == Pass.serve ? _serve_profile_data : _profile_data;
        ref const ElementDesc_Modbus mb = prof.get_mb(desc.element);

        ubyte[256] tmp = void;
        tmp[0 .. mb.value_desc.data_length] = 0;
        e.value = sample_value(tmp.ptr, mb.value_desc);

        add_register_entry(e, desc, mb);
        device.sample_elements ~= e;
    }


unittest
{
    // u8h/u8l sample one byte of a big-endian register word
    ubyte[2] word = [0xAB, 0xCD];
    ValueDesc hi = ValueDesc(parse_modbus_data_type("u8h"));
    ValueDesc lo = ValueDesc(parse_modbus_data_type("u8l"));
    assert(hi.data_length == 2 && lo.data_length == 2);
    assert(sample_value(word.ptr, hi) == 0xAB);
    assert(sample_value(word.ptr, lo) == 0xCD);
    assert(sample_value(word.ptr, ValueDesc(parse_modbus_data_type("i8h"))) == cast(byte)0xAB);
    assert(sample_value(word.ptr, ValueDesc(parse_modbus_data_type("i8l"))) == cast(byte)0xCD);

    ubyte[2] buf;
    assert(write_value(buf[], Variant(ulong(0xAB)), hi) == 2 && buf[] == [0xAB, 0x00]);
    assert(write_value(buf[], Variant(ulong(0xCD)), lo) == 2 && buf[] == [0x00, 0xCD]);

    // multi-register date stripe, as read from GoodWe RTC registers (YM, DH, MS)
    ubyte[6] rtc = [0x1A, 0x07, 0x03, 0x0C, 0x22, 0x38];
    DateTime dt = sample_value(rtc.ptr, ValueDesc(parse_modbus_data_type("dt48be"), DateFormat.yymmddhhmmss)).as!DateTime;
    assert(dt.year == 2026 && dt.month == Month.July && dt.day == 3);
    assert(dt.hour == 12 && dt.minute == 34 && dt.second == 56);
}


private:

    enum Pass : ubyte { primary, serve }

    ObjectRef!ModbusNode _node;
    String _slave_name;
    ServerMap* _slave_server;
    ServerMap _local_slave; // HACK: synthesized when slave= resolves to a local ModbusNode
    String _profile_name_explicit;
    String _model_name_explicit;
    bool _serve;

    Profile* _serve_profile_data;
    Pass _current_pass;

    bool _subscribed;
    bool _snooping;
    bool _serving_active;
    bool _writing_from_poll;
    bool _elements_subscribed;
    bool _has_dirty;

    Array!SampleElement elements;          // poll map (or shared single map)
    Array!SampleElement serve_elements;    // separate serve map when profile= differs from slave.profile
    ushort retryTime = 500;
    bool needsSort = true;

    version (DebugModbusBinding)
        ubyte _diag_counter;

    struct SampleElement
    {
        MonoTime lastUpdate;
        ushort register;
        ubyte regKind;
        ubyte flags; // 1 - in-flight (poll), 2 - constant-sampled, 4 - dirty (write pending), 8 - in-flight (write)
        ushort sampleTimeMs;
        PCP pcp;
        bool dei;
        Element* element;
        ValueDesc desc;
        ubyte seqLen() const pure nothrow @nogc
            => cast(ubyte)(desc.data_length / 2);
    }

    void add_register_entry(Element* element, ref const ElementDesc desc, ref const ElementDesc_Modbus reg_info)
    {
        Array!SampleElement* dest = _current_pass == Pass.serve ? &serve_elements : &elements;
        SampleElement* e = &dest.pushBack();
        e.element = element;
        e.register = reg_info.reg;
        e.regKind = reg_info.reg_type;
        e.desc = reg_info.value_desc;
        if (_current_pass == Pass.primary)
        {
            switch (desc.update_frequency)
            {
                case Frequency.realtime:       e.sampleTimeMs = 1;           e.pcp = PCP.bk; e.dei = true;  break;
                case Frequency.high:           e.sampleTimeMs = 1_000;       e.pcp = PCP.bk; e.dei = false; break;
                case Frequency.medium:         e.sampleTimeMs = 10_000;      e.pcp = PCP.be; e.dei = false; break;
                case Frequency.low:            e.sampleTimeMs = 60_000;      e.pcp = PCP.ee; e.dei = false; break;
                case Frequency.constant:       e.sampleTimeMs = 0;           e.pcp = PCP.ca; e.dei = false; break;
                case Frequency.configuration:  e.sampleTimeMs = 0;           e.pcp = PCP.ca; e.dei = false; break;
                case Frequency.on_demand:      e.sampleTimeMs = ushort.max;  e.pcp = PCP.ca; e.dei = false; break;
                default: assert(false);
            }
        }
        needsSort = true;
    }

    ref Array!SampleElement serving_entries() return
    {
        return serve_elements.length > 0 ? serve_elements : elements;
    }

    void teardown_node_hooks()
    {
        if (_elements_subscribed)
            unsubscribe_writable_elements();
        if (_subscribed)
        {
            _node.unsubscribe(&node_state_change);
            _subscribed = false;
        }
        if (_snooping)
        {
            if (_node.get)
                _node.setSnoopHandler(null);
            _snooping = false;
        }
        if (_serving_active)
        {
            if (_node.get)
                _node.setRequestHandler(null);
            _serving_active = false;
        }
    }

    void node_state_change(ActiveObject obj, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    void response_handler(ref const ModbusPDU request, ref ModbusPDU response, MonoTime request_time, MonoTime response_time)
    {
        const ubyte uni_addr = _slave_server.universal_address;
        ubyte kind = request.function_code == FunctionCode.read_holding_registers ? 4 :
                     request.function_code == FunctionCode.read_input_registers ? 3 :
                     request.function_code == FunctionCode.read_discrete_inputs ? 1 :
                     request.function_code == FunctionCode.read_coils ? 0 : ubyte.max;
        if (kind == ubyte.max)
            return; // snooped busses carry write traffic too; only read responses hold data we can sample
        ushort first = request.data[0..2].bigEndianToNative!ushort;
        ushort count = request.data[2..4].bigEndianToNative!ushort;

        if (response.function_code & 0x80)
        {
            const ubyte ex = response.data.length >= 1 ? response.data[0] : 0;
            const ex_name = get_exception_code_string(cast(ExceptionCode)ex);
            log.warningf("exception from {0} for fc={1} reg={2} count={3}: {4} ({5})",
                uni_addr, cast(ubyte)request.function_code, first, count, ex_name ? ex_name : "unknown", ex);
            release_in_flight(kind, first, count);
            return;
        }
        if (response.function_code != request.function_code)
        {
            log.warningf("function code mismatch from {0} expected={1} got={2}",
                uni_addr, cast(ubyte)request.function_code, cast(ubyte)response.function_code);
            release_in_flight(kind, first, count);
            return;
        }
        if (response.data.length == 0)
        {
            log.warningf("empty response from {0} for fc={1} reg={2} count={3}",
                uni_addr, cast(ubyte)request.function_code, first, count);
            release_in_flight(kind, first, count);
            return;
        }
        ushort response_bytes = response.data[0];
        if (response_bytes + 1 > response.data.length)
        {
            log.warningf("truncated response from {0} for fc={1} reg={2} count={3}: PDU byte_count={4} but only {5} data bytes in frame",
                uni_addr, cast(ubyte)request.function_code, first, count, response_bytes, response.data.length - 1);
            release_in_flight(kind, first, count);
            return;
        }
        if ((kind < 2 && response_bytes * 8 != count.align_up(8)) || (kind > 2 && response_bytes / 2 != count))
        {
            log.warningf("short response from {0} for fc={1} reg={2} count={3}: got {4} bytes (expected {5})",
                uni_addr, cast(ubyte)request.function_code, first, count, response_bytes, count*2);
            release_in_flight(kind, first, count);
            return;
        }

        version (DebugModbusBinding)
            log.tracef("Response: {0}, [{1}{2,04x}:{3}] - {4}", uni_addr, kind, first, count, response_time - request_time);

        ubyte[] data = response.data[1 .. 1 + response_bytes];

        foreach (ref e; elements)
        {
            // require the element's full span; snooped third-party reads may cover it only partially
            if (e.regKind != kind || e.register < first || e.register + e.seqLen > first + count)
                continue;

            e.lastUpdate = response_time;

            if (!_snooping)
            {
                e.flags &= 0xFE;
                if (e.sampleTimeMs == 0)
                    e.flags |= 2;
            }

            ushort offset = cast(ushort)(e.register - first);
            uint byte_offset = offset*2;
            if (kind <= 1)
            {
                bool value = ((data[offset >> 3] >> (offset & 7)) & 1) != 0;
                assert(false, "TODO: test this and store the value...");
            }
            else
            {
                _writing_from_poll = true;
                e.element.value(sample_value(data.ptr + byte_offset, e.desc), cast(SysTime)response_time);
                _writing_from_poll = false;
            }

            version (DebugModbusBindingRegs)
                log.tracef("Got reg {0,04x}: {1} = {2}", e.register, e.element.id, e.element.value);
        }
    }

    void error_handler(ModbusErrorType errorType, ref const ModbusPDU request, MonoTime request_time)
    {
        ubyte kind = request.function_code == FunctionCode.read_holding_registers ? 4 :
                     request.function_code == FunctionCode.read_input_registers ? 3 :
                     request.function_code == FunctionCode.read_discrete_inputs ? 1 :
                     request.function_code == FunctionCode.read_coils ? 0 : ubyte.max;
        ushort first = request.data[0..2].bigEndianToNative!ushort;
        ushort count = request.data[2..4].bigEndianToNative!ushort;

        version (DebugModbusBinding)
        {
            const(char)[] label = errorType == ModbusErrorType.Retrying ? "Retrying" :
                                  errorType == ModbusErrorType.Timeout ? "Timeout" : "Failed";
            log.debugf("{4}: [{0}{1,04x}:{2}] - {3}", kind, first, count, getTime()-request_time, label);
        }

        release_in_flight(kind, first, count);
    }

    void release_in_flight(ubyte kind, ushort first, ushort count)
    {
        if (_snooping)
            return;
        foreach (ref e; elements)
        {
            if (e.regKind != kind || e.register < first || e.register >= first + count)
                continue;
            e.flags &= 0xFE;
        }
    }

    void snoop_handler(ubyte server_addr, ref const ModbusPDU request, ref ModbusPDU response, MonoTime request_time, MonoTime response_time)
    {
        if (server_addr != _slave_server.universal_address)
            return;

        response_handler(request, response, request_time, response_time);
    }

    // server side: incoming request handling

    void request_handler(ubyte master_addr, ushort seq, ref const ModbusPDU request, MonoTime now)
    {
        ModbusPDU response;
        ExceptionCode ex = handle_request(request, response);
        if (ex != ExceptionCode.none)
        {
            ubyte[1] buf = [cast(ubyte)ex];
            response = ModbusPDU(cast(FunctionCode)(request.function_code | 0x80), buf[]);
        }
        if (auto c = _node.get)
            c.sendResponse(master_addr, seq, response);
    }

    ExceptionCode handle_request(ref const ModbusPDU req, ref ModbusPDU resp)
    {
        switch (req.function_code)
        {
            case FunctionCode.read_coils:
                return handle_read_bits(req, resp, RegisterType.coil);
            case FunctionCode.read_discrete_inputs:
                return handle_read_bits(req, resp, RegisterType.discrete_input);
            case FunctionCode.read_input_registers:
                return handle_read_regs(req, resp, RegisterType.input_register);
            case FunctionCode.read_holding_registers:
                return handle_read_regs(req, resp, RegisterType.holding_register);
            case FunctionCode.write_single_register:
                return handle_write_single_reg(req, resp);
            case FunctionCode.write_multiple_registers:
                return handle_write_multi_regs(req, resp);
            case FunctionCode.write_single_coil:
                return handle_write_single_coil(req, resp);
            case FunctionCode.write_multiple_coils:
                return handle_write_multi_coils(req, resp);
            default:
                return ExceptionCode.illegal_function;
        }
    }

    ExceptionCode handle_read_regs(ref const ModbusPDU req, ref ModbusPDU resp, RegisterType kind)
    {
        if (req.data.length < 4)
            return ExceptionCode.illegal_data_value;
        ushort start = req.data[0..2].bigEndianToNative!ushort;
        ushort count = req.data[2..4].bigEndianToNative!ushort;
        if (count < 1 || count > 125)
            return ExceptionCode.illegal_data_value;

        const ubyte byte_count = cast(ubyte)(count * 2);
        ubyte[1 + 250] tmpbuf;
        tmpbuf[0] = byte_count;
        // gaps in the served map come back as 0xFFFF, matching real-device convention
        for (size_t i = 0; i < byte_count; ++i)
            tmpbuf[1 + i] = 0xFF;

        bool any_overlap = false;
        auto ref entries = serving_entries();
        foreach (ref ent; entries)
        {
            if (ent.regKind != cast(ubyte)kind)
                continue;
            if (ent.register < start)
                continue;
            ushort end = cast(ushort)(ent.register + ent.seqLen);
            if (end > cast(uint)start + count)
                continue;
            const uint byte_offset = (ent.register - start) * 2;
            const Variant val = ent.element.value;
            write_value(tmpbuf[1 + byte_offset .. 1 + byte_count], val, ent.desc);
            any_overlap = true;
        }
        if (!any_overlap)
            return ExceptionCode.illegal_data_address;

        resp = ModbusPDU(req.function_code, tmpbuf[0 .. 1 + byte_count]);
        return ExceptionCode.none;
    }

    ExceptionCode handle_read_bits(ref const ModbusPDU req, ref ModbusPDU resp, RegisterType kind)
    {
        if (req.data.length < 4)
            return ExceptionCode.illegal_data_value;
        ushort start = req.data[0..2].bigEndianToNative!ushort;
        ushort count = req.data[2..4].bigEndianToNative!ushort;
        if (count < 1 || count > 2000)
            return ExceptionCode.illegal_data_value;

        const ubyte byte_count = cast(ubyte)((count + 7) / 8);
        ubyte[1 + 250] tmpbuf;
        tmpbuf[0] = byte_count;
        for (size_t i = 0; i < byte_count; ++i)
            tmpbuf[1 + i] = 0;

        bool any_overlap = false;
        auto ref entries = serving_entries();
        foreach (ref ent; entries)
        {
            if (ent.regKind != cast(ubyte)kind)
                continue;
            if (ent.register < start || ent.register >= cast(uint)start + count)
                continue;
            const ushort bit_index = cast(ushort)(ent.register - start);
            if (ent.element.value.asBool)
                tmpbuf[1 + (bit_index >> 3)] |= cast(ubyte)(1 << (bit_index & 7));
            any_overlap = true;
        }
        if (!any_overlap)
            return ExceptionCode.illegal_data_address;

        resp = ModbusPDU(req.function_code, tmpbuf[0 .. 1 + byte_count]);
        return ExceptionCode.none;
    }

    ExceptionCode handle_write_single_reg(ref const ModbusPDU req, ref ModbusPDU resp)
    {
        if (req.data.length < 4)
            return ExceptionCode.illegal_data_value;
        ushort reg = req.data[0..2].bigEndianToNative!ushort;

        SampleElement* ent = find_serve_entry(cast(ubyte)RegisterType.holding_register, reg);
        if (!ent || ent.seqLen != 1)
            return ExceptionCode.illegal_data_address;
        if (!(ent.element.access & Access.write))
            return ExceptionCode.illegal_function;

        Variant v = sample_value(req.data.ptr + 2, ent.desc);
        ent.element.value(v, getSysTime());
        flush_pending_writes();

        resp = ModbusPDU(FunctionCode.write_single_register, req.data[0..4]);
        return ExceptionCode.none;
    }

    ExceptionCode handle_write_multi_regs(ref const ModbusPDU req, ref ModbusPDU resp)
    {
        if (req.data.length < 5)
            return ExceptionCode.illegal_data_value;
        ushort start = req.data[0..2].bigEndianToNative!ushort;
        ushort count = req.data[2..4].bigEndianToNative!ushort;
        ubyte byte_count = req.data[4];
        if (count < 1 || count > 123 || byte_count != count * 2 || req.data.length < 5 + byte_count)
            return ExceptionCode.illegal_data_value;

        // first pass: refuse the whole write if any in-range entry is read-only
        bool any_overlap = false;
        auto ref entries = serving_entries();
        foreach (ref ent; entries)
        {
            if (ent.regKind != cast(ubyte)RegisterType.holding_register)
                continue;
            if (ent.register < start)
                continue;
            ushort end = cast(ushort)(ent.register + ent.seqLen);
            if (end > cast(uint)start + count)
                continue;
            if (!(ent.element.access & Access.write))
                return ExceptionCode.illegal_function;
            any_overlap = true;
        }
        if (!any_overlap)
            return ExceptionCode.illegal_data_address;

        const ubyte[] payload = req.data[5 .. 5 + byte_count];
        const SysTime ts = getSysTime();
        foreach (ref ent; entries)
        {
            if (ent.regKind != cast(ubyte)RegisterType.holding_register)
                continue;
            if (ent.register < start)
                continue;
            ushort end = cast(ushort)(ent.register + ent.seqLen);
            if (end > cast(uint)start + count)
                continue;
            const uint byte_offset = (ent.register - start) * 2;
            Variant v = sample_value(payload.ptr + byte_offset, ent.desc);
            ent.element.value(v, ts);
        }
        flush_pending_writes();

        resp = ModbusPDU(FunctionCode.write_multiple_registers, req.data[0..4]);
        return ExceptionCode.none;
    }

    ExceptionCode handle_write_single_coil(ref const ModbusPDU req, ref ModbusPDU resp)
    {
        if (req.data.length < 4)
            return ExceptionCode.illegal_data_value;
        ushort reg = req.data[0..2].bigEndianToNative!ushort;
        ushort raw = req.data[2..4].bigEndianToNative!ushort;
        if (raw != 0x0000 && raw != 0xFF00)
            return ExceptionCode.illegal_data_value;

        SampleElement* ent = find_serve_entry(cast(ubyte)RegisterType.coil, reg);
        if (!ent)
            return ExceptionCode.illegal_data_address;
        if (!(ent.element.access & Access.write))
            return ExceptionCode.illegal_function;

        ent.element.value(Variant(raw == 0xFF00), getSysTime());
        flush_pending_writes();

        resp = ModbusPDU(FunctionCode.write_single_coil, req.data[0..4]);
        return ExceptionCode.none;
    }

    ExceptionCode handle_write_multi_coils(ref const ModbusPDU req, ref ModbusPDU resp)
    {
        if (req.data.length < 5)
            return ExceptionCode.illegal_data_value;
        ushort start = req.data[0..2].bigEndianToNative!ushort;
        ushort count = req.data[2..4].bigEndianToNative!ushort;
        ubyte byte_count = req.data[4];
        if (count < 1 || count > 1968 || byte_count != (count + 7) / 8 || req.data.length < 5 + byte_count)
            return ExceptionCode.illegal_data_value;

        bool any_overlap = false;
        auto ref entries = serving_entries();
        foreach (ref ent; entries)
        {
            if (ent.regKind != cast(ubyte)RegisterType.coil)
                continue;
            if (ent.register < start || ent.register >= cast(uint)start + count)
                continue;
            if (!(ent.element.access & Access.write))
                return ExceptionCode.illegal_function;
            any_overlap = true;
        }
        if (!any_overlap)
            return ExceptionCode.illegal_data_address;

        const ubyte[] payload = req.data[5 .. 5 + byte_count];
        const SysTime ts = getSysTime();
        foreach (ref ent; entries)
        {
            if (ent.regKind != cast(ubyte)RegisterType.coil)
                continue;
            if (ent.register < start || ent.register >= cast(uint)start + count)
                continue;
            const ushort bit_index = cast(ushort)(ent.register - start);
            const bool b = ((payload[bit_index >> 3] >> (bit_index & 7)) & 1) != 0;
            ent.element.value(Variant(b), ts);
        }
        flush_pending_writes();

        resp = ModbusPDU(FunctionCode.write_multiple_coils, req.data[0..4]);
        return ExceptionCode.none;
    }

    SampleElement* find_serve_entry(ubyte kind, ushort reg)
    {
        auto ref entries = serving_entries();
        foreach (ref ent; entries)
        {
            if (ent.regKind == kind && ent.register == reg)
                return &ent;
        }
        return null;
    }

    // upstream write forwarding via Element subscription

    void subscribe_writable_elements()
    {
        if (_elements_subscribed)
            return;
        foreach (ref ent; elements)
        {
            if (ent.regKind != cast(ubyte)RegisterType.holding_register && ent.regKind != cast(ubyte)RegisterType.coil)
                continue;
            if (!(ent.element.access & Access.write))
                continue;
            ent.element.add_subscriber(&element_changed);
        }
        _elements_subscribed = true;
    }

    void unsubscribe_writable_elements()
    {
        if (!_elements_subscribed)
            return;
        foreach (ref ent; elements)
        {
            if (ent.regKind != cast(ubyte)RegisterType.holding_register && ent.regKind != cast(ubyte)RegisterType.coil)
                continue;
            if (!(ent.element.access & Access.write))
                continue;
            ent.element.remove_subscriber(&element_changed);
        }
        _elements_subscribed = false;
    }

    void element_changed(ref Element e, ref const Variant val, SysTime ts, ref const Variant, SysTime)
    {
        if (_writing_from_poll)
            return;
        if (!_node.get || !_slave_server)
            return;
        Element* el = &e;
        foreach (ref ent; elements)
        {
            if (ent.element !is el)
                continue;
            ent.flags |= 4;
            _has_dirty = true;
            return;
        }
    }

    void flush_pending_writes()
    {
        if (!_has_dirty)
            return;

        ModbusNode c = _node.get;
        if (!c || !_slave_server)
        {
            foreach (ref ent; elements)
                ent.flags &= ~cast(ubyte)4;
            _has_dirty = false;
            return;
        }

        // elements are sorted by (kind, register); walk dirty entries gathering adjacent runs.
        // entries with bit 8 (write in-flight) are deferred until their previous write completes.
        bool any_blocked = false;
        size_t i = 0;
        while (i < elements.length)
        {
            if (!(elements[i].flags & 4))
            {
                ++i;
                continue;
            }
            if (elements[i].flags & 8)
            {
                any_blocked = true;
                ++i;
                continue;
            }
            const ubyte kind = elements[i].regKind;
            const ushort first_reg = elements[i].register;
            size_t run_start = i;
            ushort total_words = elements[i].seqLen;
            elements[i].flags = cast(ubyte)((elements[i].flags & ~4) | 8);
            ++i;
            if (kind == cast(ubyte)RegisterType.holding_register)
            {
                while (i < elements.length
                       && (elements[i].flags & 4)
                       && !(elements[i].flags & 8)
                       && elements[i].regKind == kind
                       && elements[i].register == cast(ushort)(first_reg + total_words)
                       && total_words + elements[i].seqLen <= 123)
                {
                    total_words = cast(ushort)(total_words + elements[i].seqLen);
                    elements[i].flags = cast(ubyte)((elements[i].flags & ~4) | 8);
                    ++i;
                }
            }
            else if (kind == cast(ubyte)RegisterType.coil)
            {
                while (i < elements.length
                       && (elements[i].flags & 4)
                       && !(elements[i].flags & 8)
                       && elements[i].regKind == kind
                       && elements[i].register == cast(ushort)(first_reg + (i - run_start))
                       && (i - run_start + 1) <= 1968)
                {
                    elements[i].flags = cast(ubyte)((elements[i].flags & ~4) | 8);
                    ++i;
                }
            }
            emit_write_run(c, kind, first_reg, elements[run_start .. i]);
        }
        // keep _has_dirty set if some entries were blocked by in-flight writes; they'll flush again
        // once the response/error handler clears their in-flight bit and the next update() ticks.
        _has_dirty = any_blocked;
    }

    void emit_write_run(ModbusNode c, ubyte kind, ushort first_reg, SampleElement[] run)
    {
        if (kind == cast(ubyte)RegisterType.holding_register)
        {
            ushort[123] words = void;
            size_t word_idx = 0;
            ubyte[256] buf = void;
            foreach (ref ent; run)
            {
                const ubyte word_count = ent.seqLen;
                ptrdiff_t n = write_value(buf[0 .. word_count * 2], ent.element.value, ent.desc);
                if (n != word_count * 2)
                {
                    // abandoning the run; clear the in-flight bits or these elements can never write again
                    foreach (ref r; run)
                        r.flags &= ~cast(ubyte)8;
                    log.warning("can't encode value for reg ", ent.register, "; write dropped");
                    return;
                }
                for (size_t j = 0; j < word_count; ++j)
                    words[word_idx++] = cast(ushort)((buf[j*2] << 8) | buf[j*2 + 1]);
            }
            ModbusPDU pdu;
            if (word_idx == 1)
                pdu = createMessage_Write(RegisterType.holding_register, first_reg, words[0]);
            else
                pdu = createMessage_Write(RegisterType.holding_register, first_reg, words[0 .. word_idx]);
            c.sendRequest(_slave_server.universal_address, pdu, &write_response_handler, &write_error_handler);
        }
        else if (kind == cast(ubyte)RegisterType.coil)
        {
            if (run.length == 1)
            {
                const ushort v = run[0].element.value.asBool ? cast(ushort)1 : cast(ushort)0;
                ModbusPDU pdu = createMessage_Write(RegisterType.coil, first_reg, v);
                c.sendRequest(_slave_server.universal_address, pdu, &write_response_handler, &write_error_handler);
            }
            else
            {
                ubyte[1968 / 8] packed = 0;
                const size_t byte_count = (run.length + 7) / 8;
                foreach (j, ref ent; run)
                {
                    if (ent.element.value.asBool)
                        packed[j >> 3] |= cast(ubyte)(1 << (j & 7));
                }
                ModbusPDU pdu = createMessage_WriteCoils(first_reg, packed[0 .. byte_count], cast(ushort)run.length);
                c.sendRequest(_slave_server.universal_address, pdu, &write_response_handler, &write_error_handler);
            }
        }
    }

    void write_response_handler(ref const ModbusPDU req, ref ModbusPDU resp, MonoTime, MonoTime)
    {
        clear_write_in_flight(req);
        if (resp.function_code & 0x80)
            log.warning(name[], ": upstream write exception ", cast(ubyte)(resp.data.length >= 1 ? resp.data[0] : 0));
    }

    void write_error_handler(ModbusErrorType ty, ref const ModbusPDU req, MonoTime)
    {
        if (ty == ModbusErrorType.Failed || ty == ModbusErrorType.Timeout)
        {
            clear_write_in_flight(req);
            log.warning(name[], ": upstream write failed");
        }
    }

    void clear_write_in_flight(ref const ModbusPDU req)
    {
        ubyte kind;
        ushort count;
        switch (req.function_code)
        {
            case FunctionCode.write_single_register:
                kind = cast(ubyte)RegisterType.holding_register;
                count = 1;
                break;
            case FunctionCode.write_multiple_registers:
                kind = cast(ubyte)RegisterType.holding_register;
                count = req.data[2..4].bigEndianToNative!ushort;
                break;
            case FunctionCode.write_single_coil:
                kind = cast(ubyte)RegisterType.coil;
                count = 1;
                break;
            case FunctionCode.write_multiple_coils:
                kind = cast(ubyte)RegisterType.coil;
                count = req.data[2..4].bigEndianToNative!ushort;
                break;
            default:
                return;
        }
        const ushort start = req.data[0..2].bigEndianToNative!ushort;
        foreach (ref ent; elements)
        {
            if (ent.regKind != kind)
                continue;
            if (ent.register < start || ent.register >= cast(uint)start + count)
                continue;
            ent.flags &= ~cast(ubyte)8;
            if (ent.flags & 4)
                _has_dirty = true;  // re-arm so next update() ticks the deferred dirty bits
        }
    }
}
