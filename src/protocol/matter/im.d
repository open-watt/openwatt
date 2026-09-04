module protocol.matter.im;

import protocol.matter.tlv;

nothrow @nogc:


enum interaction_model_revision = 11;

enum ImStatus : ubyte
{
    success = 0x00,
    failure = 0x01,
    invalid_subscription = 0x7D,
    unsupported_access = 0x7E,
    unsupported_endpoint = 0x7F,
    invalid_action = 0x80,
    unsupported_command = 0x81,
    invalid_command = 0x85,
    unsupported_attribute = 0x86,
    constraint_error = 0x87,
    unsupported_write = 0x88,
    resource_exhausted = 0x89,
    not_found = 0x8B,
    unreportable_attribute = 0x8C,
    invalid_data_type = 0x8D,
    unsupported_read = 0x8F,
    data_version_mismatch = 0x92,
    timeout = 0x94,
    busy = 0x9C,
    unsupported_cluster = 0xC3,
    no_upstream_subscription = 0xC5,
    needs_timed_interaction = 0xC6,
    unsupported_event = 0xC7,
    paths_exhausted = 0xC8,
    timed_request_mismatch = 0xC9,
    failsafe_required = 0xCA,
    invalid_in_state = 0xCB,
    no_command_response = 0xCC,
}

struct AttributePath
{
    enum wildcard_endpoint = ushort.max;
    enum wildcard_id = uint.max;

    ushort endpoint = wildcard_endpoint;
    uint cluster = wildcard_id;
    uint attribute = wildcard_id;

nothrow @nogc:
    bool wildcard() const pure
        => endpoint == wildcard_endpoint || cluster == wildcard_id || attribute == wildcard_id;
}

struct CommandPath
{
    ushort endpoint;
    uint cluster;
    uint command;
}

struct StatusIB
{
    ubyte status;
    ubyte cluster_status;
    bool has_cluster_status;
}

struct AttributeReport
{
    AttributePath path;
    uint data_version;
    bool has_data;
    StatusIB status;
    TLVReader data;
}

struct AttributeStatus
{
    AttributePath path;
    StatusIB status;
}

struct InvokeResponse
{
    CommandPath path;
    bool has_fields;
    StatusIB status;
    TLVReader fields;
}


bool write_attribute_path(ref TLVWriter w, TLVTag tag, ref const AttributePath path)
{
    w.start_list(tag);
    if (path.endpoint != AttributePath.wildcard_endpoint)
        w.put(TLVTag.context(2), path.endpoint);
    if (path.cluster != AttributePath.wildcard_id)
        w.put(TLVTag.context(3), path.cluster);
    if (path.attribute != AttributePath.wildcard_id)
        w.put(TLVTag.context(4), path.attribute);
    return w.end_container();
}

bool read_attribute_path(ref TLVReader r, out AttributePath path)
{
    if (r.type != TLVType.list)
        return false;
    while (r.next() && r.type != TLVType.end_of_container)
    {
        if (r.tag.is_context(2))
        {
            if (!r.get(path.endpoint))
                return false;
        }
        else if (r.tag.is_context(3))
        {
            if (!r.get(path.cluster))
                return false;
        }
        else if (r.tag.is_context(4))
        {
            if (!r.get(path.attribute))
                return false;
        }
        else if (!r.skip())
            return false;
    }
    return r.type == TLVType.end_of_container;
}

bool write_command_path(ref TLVWriter w, TLVTag tag, ref const CommandPath path)
{
    w.start_list(tag);
    w.put(TLVTag.context(0), path.endpoint);
    w.put(TLVTag.context(1), path.cluster);
    w.put(TLVTag.context(2), path.command);
    return w.end_container();
}

bool read_command_path(ref TLVReader r, out CommandPath path)
{
    if (r.type != TLVType.list)
        return false;
    while (r.next() && r.type != TLVType.end_of_container)
    {
        if (r.tag.is_context(0))
        {
            if (!r.get(path.endpoint))
                return false;
        }
        else if (r.tag.is_context(1))
        {
            if (!r.get(path.cluster))
                return false;
        }
        else if (r.tag.is_context(2))
        {
            if (!r.get(path.command))
                return false;
        }
        else if (!r.skip())
            return false;
    }
    return r.type == TLVType.end_of_container;
}

bool read_status_ib(ref TLVReader r, out StatusIB status)
{
    if (r.type != TLVType.structure)
        return false;
    while (r.next() && r.type != TLVType.end_of_container)
    {
        if (r.tag.is_context(0))
        {
            if (!r.get(status.status))
                return false;
        }
        else if (r.tag.is_context(1))
        {
            if (!r.get(status.cluster_status))
                return false;
            status.has_cluster_status = true;
        }
        else if (!r.skip())
            return false;
    }
    return r.type == TLVType.end_of_container;
}


ptrdiff_t encode_read_request(ubyte[] buffer, const(AttributePath)[] paths, bool fabric_filtered = false)
{
    TLVWriter w = TLVWriter(buffer);
    w.start_structure();
    w.start_array(TLVTag.context(0));
    foreach (ref p; paths)
        write_attribute_path(w, TLVTag.anonymous, p);
    w.end_container();
    w.put(TLVTag.context(3), fabric_filtered);
    w.put(TLVTag.context(255), cast(ubyte)interaction_model_revision);
    return finish(w);
}

ptrdiff_t encode_subscribe_request(ubyte[] buffer, const(AttributePath)[] paths, ushort min_interval, ushort max_interval,
                                   bool keep_subscriptions = false, bool fabric_filtered = false)
{
    TLVWriter w = TLVWriter(buffer);
    w.start_structure();
    w.put(TLVTag.context(0), keep_subscriptions);
    w.put(TLVTag.context(1), min_interval);
    w.put(TLVTag.context(2), max_interval);
    w.start_array(TLVTag.context(3));
    foreach (ref p; paths)
        write_attribute_path(w, TLVTag.anonymous, p);
    w.end_container();
    w.put(TLVTag.context(7), fabric_filtered);
    w.put(TLVTag.context(255), cast(ubyte)interaction_model_revision);
    return finish(w);
}

// data writes the attribute value with the context tag 2 it is handed.
ptrdiff_t encode_write_request(ubyte[] buffer, ref const AttributePath path, scope bool delegate(ref TLVWriter, TLVTag) nothrow @nogc data,
                               bool timed = false, bool suppress_response = false)
{
    TLVWriter w = TLVWriter(buffer);
    w.start_structure();
    w.put(TLVTag.context(0), suppress_response);
    w.put(TLVTag.context(1), timed);
    w.start_array(TLVTag.context(2));
    w.start_structure();
    write_attribute_path(w, TLVTag.context(1), path);
    if (!data(w, TLVTag.context(2)))
        return -1;
    w.end_container();
    w.end_container();
    w.put(TLVTag.context(3), false);
    w.put(TLVTag.context(255), cast(ubyte)interaction_model_revision);
    return finish(w);
}

// fields writes the command fields into an already-open structure; may be null for no fields.
ptrdiff_t encode_invoke_request(ubyte[] buffer, ref const CommandPath path, scope bool delegate(ref TLVWriter) nothrow @nogc fields,
                                bool timed = false, bool suppress_response = false)
{
    TLVWriter w = TLVWriter(buffer);
    w.start_structure();
    w.put(TLVTag.context(0), suppress_response);
    w.put(TLVTag.context(1), timed);
    w.start_array(TLVTag.context(2));
    w.start_structure();
    write_command_path(w, TLVTag.context(0), path);
    w.start_structure(TLVTag.context(1));
    if (fields && !fields(w))
        return -1;
    w.end_container();
    w.end_container();
    w.end_container();
    w.put(TLVTag.context(255), cast(ubyte)interaction_model_revision);
    return finish(w);
}

ptrdiff_t encode_timed_request(ubyte[] buffer, ushort timeout_ms)
{
    TLVWriter w = TLVWriter(buffer);
    w.start_structure();
    w.put(TLVTag.context(0), timeout_ms);
    w.put(TLVTag.context(255), cast(ubyte)interaction_model_revision);
    return finish(w);
}

ptrdiff_t encode_status_response(ubyte[] buffer, ImStatus status)
{
    TLVWriter w = TLVWriter(buffer);
    w.start_structure();
    w.put(TLVTag.context(0), cast(ubyte)status);
    w.put(TLVTag.context(255), cast(ubyte)interaction_model_revision);
    return finish(w);
}

bool decode_status_response(const(ubyte)[] message, out ImStatus status)
{
    TLVReader r = TLVReader(message);
    if (!r.next() || r.type != TLVType.structure)
        return false;
    bool found;
    while (r.next() && r.type != TLVType.end_of_container)
    {
        if (r.tag.is_context(0))
        {
            ubyte s;
            if (!r.get(s))
                return false;
            status = cast(ImStatus)s;
            found = true;
        }
        else if (!r.skip())
            return false;
    }
    return found;
}

bool decode_subscribe_response(const(ubyte)[] message, out uint subscription_id, out ushort max_interval)
{
    TLVReader r = TLVReader(message);
    if (!r.next() || r.type != TLVType.structure)
        return false;
    bool found;
    while (r.next() && r.type != TLVType.end_of_container)
    {
        if (r.tag.is_context(0))
        {
            if (!r.get(subscription_id))
                return false;
            found = true;
        }
        else if (r.tag.is_context(2))
        {
            if (!r.get(max_interval))
                return false;
        }
        else if (!r.skip())
            return false;
    }
    return found;
}


struct ReportDataReader
{
nothrow @nogc:
    uint subscription_id;
    bool has_subscription_id;
    bool more_chunks;
    bool suppress_response;

    this(const(ubyte)[] message)
    {
        _r = TLVReader(message);
        _ok = _r.next() && _r.type == TLVType.structure;
        while (_ok && _r.next() && _r.type != TLVType.end_of_container)
        {
            if (_r.tag.is_context(0))
                has_subscription_id = _r.get(subscription_id);
            else if (_r.tag.is_context(1) && _r.type == TLVType.array)
            {
                _in_reports = true;
                return;
            }
            else if (_r.tag.is_context(3))
                _r.get(more_chunks);
            else if (_r.tag.is_context(4))
                _r.get(suppress_response);
            else if (!_r.skip())
                _ok = false;
        }
    }

    bool valid() const pure
        => _ok;

    // Advances to the next AttributeReportIB; report.data is positioned on the value element when has_data.
    bool next(out AttributeReport report)
    {
        if (!_ok || !_in_reports)
            return false;
        if (!_r.next() || _r.type == TLVType.end_of_container)
        {
            _in_reports = false;
            finish_tail();
            return false;
        }
        if (_r.type != TLVType.structure)
            return fail();

        while (_r.next() && _r.type != TLVType.end_of_container)
        {
            if (_r.tag.is_context(0))
            {
                if (!read_attribute_status(report))
                    return fail();
            }
            else if (_r.tag.is_context(1))
            {
                if (!read_attribute_data(report))
                    return fail();
            }
            else if (!_r.skip())
                return fail();
        }
        return _r.type == TLVType.end_of_container;
    }

private:
    TLVReader _r;
    bool _ok;
    bool _in_reports;

    bool fail()
    {
        _ok = false;
        return false;
    }

    void finish_tail()
    {
        while (_r.next() && _r.type != TLVType.end_of_container)
        {
            if (_r.tag.is_context(3))
                _r.get(more_chunks);
            else if (_r.tag.is_context(4))
                _r.get(suppress_response);
            else if (!_r.skip())
            {
                _ok = false;
                return;
            }
        }
    }

    bool read_attribute_status(ref AttributeReport report)
    {
        if (_r.type != TLVType.structure)
            return false;
        while (_r.next() && _r.type != TLVType.end_of_container)
        {
            if (_r.tag.is_context(0))
            {
                if (!read_attribute_path(_r, report.path))
                    return false;
            }
            else if (_r.tag.is_context(1))
            {
                if (!read_status_ib(_r, report.status))
                    return false;
            }
            else if (!_r.skip())
                return false;
        }
        return _r.type == TLVType.end_of_container;
    }

    bool read_attribute_data(ref AttributeReport report)
    {
        if (_r.type != TLVType.structure)
            return false;
        while (_r.next() && _r.type != TLVType.end_of_container)
        {
            if (_r.tag.is_context(0))
            {
                if (!_r.get(report.data_version))
                    return false;
            }
            else if (_r.tag.is_context(1))
            {
                if (!read_attribute_path(_r, report.path))
                    return false;
            }
            else if (_r.tag.is_context(2))
            {
                report.data = _r;
                report.has_data = true;
                if (!_r.skip())
                    return false;
            }
            else if (!_r.skip())
                return false;
        }
        return _r.type == TLVType.end_of_container;
    }
}

struct WriteResponseReader
{
nothrow @nogc:
    this(const(ubyte)[] message)
    {
        _r = TLVReader(message);
        _ok = _r.next() && _r.type == TLVType.structure;
        while (_ok && _r.next() && _r.type != TLVType.end_of_container)
        {
            if (_r.tag.is_context(0) && _r.type == TLVType.array)
            {
                _in_list = true;
                return;
            }
            if (!_r.skip())
                _ok = false;
        }
    }

    bool valid() const pure
        => _ok;

    bool next(out AttributeStatus status)
    {
        if (!_ok || !_in_list)
            return false;
        if (!_r.next() || _r.type == TLVType.end_of_container)
        {
            _in_list = false;
            return false;
        }
        if (_r.type != TLVType.structure)
            return _ok = false;
        while (_r.next() && _r.type != TLVType.end_of_container)
        {
            if (_r.tag.is_context(0))
            {
                if (!read_attribute_path(_r, status.path))
                    return _ok = false;
            }
            else if (_r.tag.is_context(1))
            {
                if (!read_status_ib(_r, status.status))
                    return _ok = false;
            }
            else if (!_r.skip())
                return _ok = false;
        }
        return _r.type == TLVType.end_of_container;
    }

private:
    TLVReader _r;
    bool _ok;
    bool _in_list;
}

struct InvokeResponseReader
{
nothrow @nogc:
    bool suppress_response;
    bool more_chunks;

    this(const(ubyte)[] message)
    {
        _r = TLVReader(message);
        _ok = _r.next() && _r.type == TLVType.structure;
        while (_ok && _r.next() && _r.type != TLVType.end_of_container)
        {
            if (_r.tag.is_context(0))
                _r.get(suppress_response);
            else if (_r.tag.is_context(1) && _r.type == TLVType.array)
            {
                _in_list = true;
                return;
            }
            else if (_r.tag.is_context(2))
                _r.get(more_chunks);
            else if (!_r.skip())
                _ok = false;
        }
    }

    bool valid() const pure
        => _ok;

    // response.fields is positioned on the CommandFields structure when has_fields.
    bool next(out InvokeResponse response)
    {
        if (!_ok || !_in_list)
            return false;
        if (!_r.next() || _r.type == TLVType.end_of_container)
        {
            _in_list = false;
            return false;
        }
        if (_r.type != TLVType.structure)
            return _ok = false;
        while (_r.next() && _r.type != TLVType.end_of_container)
        {
            if (_r.tag.is_context(0))
            {
                if (!read_command_data(response))
                    return _ok = false;
            }
            else if (_r.tag.is_context(1))
            {
                if (!read_command_status(response))
                    return _ok = false;
            }
            else if (!_r.skip())
                return _ok = false;
        }
        return _r.type == TLVType.end_of_container;
    }

private:
    TLVReader _r;
    bool _ok;
    bool _in_list;

    bool read_command_data(ref InvokeResponse response)
    {
        if (_r.type != TLVType.structure)
            return false;
        while (_r.next() && _r.type != TLVType.end_of_container)
        {
            if (_r.tag.is_context(0))
            {
                if (!read_command_path(_r, response.path))
                    return false;
            }
            else if (_r.tag.is_context(1))
            {
                response.fields = _r;
                response.has_fields = true;
                if (!_r.skip())
                    return false;
            }
            else if (!_r.skip())
                return false;
        }
        return _r.type == TLVType.end_of_container;
    }

    bool read_command_status(ref InvokeResponse response)
    {
        if (_r.type != TLVType.structure)
            return false;
        while (_r.next() && _r.type != TLVType.end_of_container)
        {
            if (_r.tag.is_context(0))
            {
                if (!read_command_path(_r, response.path))
                    return false;
            }
            else if (_r.tag.is_context(1))
            {
                if (!read_status_ib(_r, response.status))
                    return false;
            }
            else if (!_r.skip())
                return false;
        }
        return _r.type == TLVType.end_of_container;
    }
}


private:

ptrdiff_t finish(ref TLVWriter w)
{
    if (!w.end_container() || w.overflow || w.depth != 0)
        return -1;
    return w.length;
}


unittest
{
    ubyte[256] buf;

    // read request for OnOff.OnOff on endpoint 1 and a wildcard attribute path
    AttributePath[2] paths;
    paths[0] = AttributePath(1, 0x0006, 0x0000);
    paths[1] = AttributePath(AttributePath.wildcard_endpoint, 0x0028, 0x0001);
    ptrdiff_t len = encode_read_request(buf[], paths[]);
    assert(len > 0);
    TLVReader r = TLVReader(buf[0 .. len]);
    assert(r.next() && r.type == TLVType.structure);
    assert(r.next() && r.tag.is_context(0) && r.type == TLVType.array);
    AttributePath p;
    assert(r.next() && read_attribute_path(r, p));
    assert(p.endpoint == 1 && p.cluster == 6 && p.attribute == 0 && !p.wildcard);
    assert(r.next() && read_attribute_path(r, p));
    assert(p.endpoint == AttributePath.wildcard_endpoint && p.cluster == 0x28 && p.wildcard);
    assert(r.next() && r.type == TLVType.end_of_container);
    assert(r.next() && r.tag.is_context(3) && !r.as_bool);
    assert(r.next() && r.tag.is_context(255) && r.as_uint == interaction_model_revision);

    // a ReportData with one data report and one status report
    TLVWriter w = TLVWriter(buf[]);
    w.start_structure();
    w.put(TLVTag.context(0), 0x12345678u);
    w.start_array(TLVTag.context(1));
    w.start_structure();
    w.start_structure(TLVTag.context(1));
    w.put(TLVTag.context(0), 7u);
    write_attribute_path(w, TLVTag.context(1), paths[0]);
    w.put(TLVTag.context(2), true);
    w.end_container();
    w.end_container();
    w.start_structure();
    w.start_structure(TLVTag.context(0));
    write_attribute_path(w, TLVTag.context(0), paths[1]);
    w.start_structure(TLVTag.context(1));
    w.put(TLVTag.context(0), cast(ubyte)ImStatus.unsupported_attribute);
    w.end_container();
    w.end_container();
    w.end_container();
    w.end_container();
    w.put(TLVTag.context(4), true);
    w.put(TLVTag.context(255), cast(ubyte)interaction_model_revision);
    assert(w.end_container() && !w.overflow);

    ReportDataReader reports = ReportDataReader(w.data);
    assert(reports.valid && reports.has_subscription_id && reports.subscription_id == 0x12345678);
    AttributeReport rep;
    assert(reports.next(rep));
    assert(rep.has_data && rep.data_version == 7);
    assert(rep.path.endpoint == 1 && rep.path.cluster == 6 && rep.path.attribute == 0);
    assert(rep.data.type == TLVType.true_ && rep.data.as_bool);
    assert(reports.next(rep));
    assert(!rep.has_data && rep.status.status == ImStatus.unsupported_attribute && rep.path.cluster == 0x28);
    assert(!reports.next(rep));
    assert(reports.valid && reports.suppress_response);

    // invoke OnOff.Toggle and parse a status-only response
    CommandPath cmd = CommandPath(1, 0x0006, 0x0002);
    len = encode_invoke_request(buf[], cmd, null);
    assert(len > 0);
    len = encode_invoke_request(buf[], CommandPath(1, 0x0008, 0x0004), (ref TLVWriter fw) {
        fw.put(TLVTag.context(0), cast(ubyte)128);
        fw.put(TLVTag.context(1), cast(ushort)10);
        return true;
    });
    assert(len > 0);

    w = TLVWriter(buf[]);
    w.start_structure();
    w.put(TLVTag.context(0), false);
    w.start_array(TLVTag.context(1));
    w.start_structure();
    w.start_structure(TLVTag.context(1));
    write_command_path(w, TLVTag.context(0), cmd);
    w.start_structure(TLVTag.context(1));
    w.put(TLVTag.context(0), cast(ubyte)0);
    w.end_container();
    w.end_container();
    w.end_container();
    w.end_container();
    w.put(TLVTag.context(255), cast(ubyte)interaction_model_revision);
    assert(w.end_container());
    InvokeResponseReader inv = InvokeResponseReader(w.data);
    InvokeResponse resp;
    assert(inv.valid && inv.next(resp));
    assert(!resp.has_fields && resp.status.status == ImStatus.success && resp.path.command == 2);
    assert(!inv.next(resp));

    // write request and a write response
    len = encode_write_request(buf[], paths[0], (ref TLVWriter dw, TLVTag tag) => dw.put(tag, true));
    assert(len > 0);
    w = TLVWriter(buf[]);
    w.start_structure();
    w.start_array(TLVTag.context(0));
    w.start_structure();
    write_attribute_path(w, TLVTag.context(0), paths[0]);
    w.start_structure(TLVTag.context(1));
    w.put(TLVTag.context(0), cast(ubyte)0);
    w.end_container();
    w.end_container();
    w.end_container();
    w.put(TLVTag.context(255), cast(ubyte)interaction_model_revision);
    assert(w.end_container());
    WriteResponseReader wr = WriteResponseReader(w.data);
    AttributeStatus st;
    assert(wr.valid && wr.next(st) && st.status.status == 0 && st.path.attribute == 0);
    assert(!wr.next(st));

    ImStatus status;
    len = encode_status_response(buf[], ImStatus.busy);
    assert(len > 0 && decode_status_response(buf[0 .. len], status) && status == ImStatus.busy);

    uint sub;
    ushort max_interval;
    w = TLVWriter(buf[]);
    w.start_structure();
    w.put(TLVTag.context(0), 42u);
    w.put(TLVTag.context(2), cast(ushort)60);
    w.put(TLVTag.context(255), cast(ubyte)interaction_model_revision);
    assert(w.end_container());
    assert(decode_subscribe_response(w.data, sub, max_interval) && sub == 42 && max_interval == 60);
}
