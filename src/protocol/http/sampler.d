module protocol.http.sampler;

import urt.array;
import urt.conv;
import urt.format.json;
import urt.lifetime;
import urt.log;
import urt.mem.temp;
import urt.string;
import urt.time;
import urt.variant;

import manager.element;
import manager.expression;
import manager.profile;
import manager.sampler;
import manager.subscriber;

import protocol.http.client;
import protocol.http.message : HTTPMessage, HTTPMethod, HTTPParam;

//version = DebugHTTPSampler;

nothrow @nogc:


struct HTTPSampleElement
{
    Element* element;
    ushort http_index;
    ushort sample_time_ms;
    MonoTime last_sample;
    bool sampled; // for constant elements: true after first sample
}

struct RequestState
{
    // TODO: success_expr needs to be freed!!

    String resolved_path;
    String resolved_body_template;
    Expression* success_expr;
    String resolved_root_path;
    String resolved_parse_template;
    ushort request_index;
    ushort min_sample_ms;
    MonoTime last_request;
    bool in_flight;
    bool write_dirty; // an element with a write: binding to this request changed
    bool is_batch;    // plural {keys}/{values} found in path or body template
    bool has_substitutions; // any {key}/{value}/{keys}/{values} present
    ushort[4] sub_offsets = ushort.max;

pure nothrow @nogc:
    ref ushort path_key_offset() => sub_offsets[0];
    ref ushort body_key_offset() => sub_offsets[1];
    ref ushort path_val_offset() => sub_offsets[2];
    ref ushort body_val_offset() => sub_offsets[3];
}

class HTTPSampler : Sampler
{
nothrow @nogc:

    this(HTTPClient client, Profile* profile)
    {
        _client = client;
        _profile = profile;
    }

    final void add_element(Element* element, ref const ElementDesc desc, ref const ElementDesc_HTTP http_desc, const(char)[][] param_names, const(char)[][] param_values)
    {
        HTTPSampleElement* e = &_elements.pushBack();
        e.element = element;
        e.http_index = cast(ushort)desc.element;

        switch (desc.update_frequency)
        {
            case Frequency.realtime:       e.sample_time_ms = 400;        break;
            case Frequency.high:           e.sample_time_ms = 1_000;      break;
            case Frequency.medium:         e.sample_time_ms = 10_000;     break;
            case Frequency.low:            e.sample_time_ms = 60_000;     break;
            case Frequency.constant:       e.sample_time_ms = 0;          break;
            case Frequency.configuration:  e.sample_time_ms = 0;          break;
            case Frequency.on_demand:      e.sample_time_ms = ushort.max; break;
            default: assert(false);
        }

        if (http_desc.request_index != ushort.max)
            build_request_state(http_desc.request_index, e.sample_time_ms, param_names, param_values);
        if (http_desc.write_request_index != ushort.max)
        {
            build_request_state(http_desc.write_request_index, ushort.max, param_names, param_values);
            element.add_subscriber(this);
        }
    }

    override void remove_element(Element* element)
    {
        foreach (i, ref e; _elements[])
        {
            if (e.element is element)
            {
                _elements.remove(i);
                return;
            }
        }
    }

    override void on_change(Element* e, ref const Variant val, SysTime timestamp, Subscriber who)
    {
        if (who is this)
            return; // don't write back values we just read

        foreach (ref se; _elements[])
        {
            if (se.element !is e)
                continue;

            ref const ElementDesc_HTTP http = _profile.get_http(se.http_index);
            if (http.write_request_index == ushort.max)
                continue;

            foreach (ref rs; _request_states[])
            {
                if (rs.request_index == http.write_request_index)
                {
                    rs.write_dirty = true;
                    break;
                }
            }
            break;
        }
    }

    override void update()
    {
        if (_client is null || !_client.running)
            return;

        MonoTime now = getTime();

        foreach (ref rs; _request_states[])
        {
            if (rs.in_flight)
                continue;

            if (rs.write_dirty)
            {
                send_request(rs, now, true);
                continue;
            }

            if (rs.min_sample_ms == ushort.max)
                continue;

            long elapsed_ms = (now - rs.last_request).as!"msecs";
            if (elapsed_ms < rs.min_sample_ms && rs.last_request != MonoTime.init)
                continue;

            send_request(rs, now, false);
        }
    }

private:
    HTTPClient _client;
    Profile* _profile;
    Array!HTTPSampleElement _elements;
    Array!RequestState _request_states;

    // TODO: DELETE THIS QUEUE THING; IT'S A HACK, HTTPClient NEEDS TO RETURN A HANDLE
    ushort[16] _in_flight_queue;
    ubyte _in_flight_head;
    ubyte _in_flight_count;

    void build_request_state(ushort req_idx, ushort sample_ms, const(char)[][] param_names, const(char)[][] param_values)
    {
        // check if it already exists
        foreach (ref rs; _request_states)
        {
            if (rs.request_index == req_idx)
            {
                if (sample_ms > 0 && sample_ms < rs.min_sample_ms)
                    rs.min_sample_ms = sample_ms;
                return;
            }
        }

        ref const RequestDesc req = _profile.get_request(req_idx);

        RequestState* rs = &_request_states.pushBack();
        rs.request_index = req_idx;
        rs.min_sample_ms = sample_ms > 0 ? sample_ms : ushort.max;

        bool sub_failed, unclosed_token;
        bool has_singular, has_plural;
        int is_body = 0;

        const(char)[] get_substitute(size_t, const(char)[] param)
        {
            foreach (i, v; param_names)
            {
                if (v[] != param[])
                    continue;
                return param_values[i];
            }
            sub_failed = true;
            return null;
        }

        const(char)[] get_sub_with_kv(size_t offset, const(char)[] param)
        {
            const(char)[] sub = get_substitute(offset, param);
            if (!sub_failed)
                return sub;
            int is_val = 0;
            if (param[] == "key")
                has_singular = true;
            else if (param[] == "keys")
                has_plural = true;
            else if (param[] == "value")
                has_singular = true, is_val = 2;
            else if (param[] == "values")
                has_plural = true, is_val = 2;
            else
            {
                writeWarning("HTTP profile: no parameter '", param, "' for substitution");
                return null;
            }
            ref ushort sub_offset = rs.sub_offsets[is_val | is_body];
            if (sub_offset != ushort.max)
                return null;
            sub_offset = cast(ushort)offset;
            sub_failed = false;
            return null;
        }

        MutableString!0 do_sub(const(char)[] text, scope const(char)[] delegate(size_t, const(char)[]) nothrow @nogc sub_fun)
        {
            auto subbed = substitute_parameters(text, sub_fun, unclosed_token);
            if (subbed[] == text[])
                return MutableString!0();
            return subbed;
        }

        rs.resolved_path = String(do_sub(req.get_path(*_profile), &get_sub_with_kv));
        is_body = 1;
        rs.resolved_body_template = String(do_sub(req.get_body_template(*_profile), &get_sub_with_kv));
        rs.resolved_root_path = String(do_sub(req.get_root_path(*_profile), &get_substitute));
        rs.resolved_parse_template = String(do_sub(req.get_parse_template(*_profile), &get_substitute));
        auto success_expr = substitute_parameters(req.get_success_expr(*_profile), &get_substitute, unclosed_token);

        if (sub_failed || unclosed_token)
        {
            if (unclosed_token)
                writeWarning("HTTP profile: un-closed placeholder token in request '", req.get_name(*_profile), '\'');
            _request_states.popBack();
        }
        else if (has_singular && has_plural)
        {
            writeWarning("HTTP profile: request '", req.get_name(*_profile), "' mixes singular and plural placeholders");
            _request_states.popBack();
        }
        else
        {
            if (!success_expr.empty)
            {
                const(char)[] success_text = success_expr[];
                try
                    rs.success_expr = parse_expression(success_text);
                catch (Exception)
                    writeWarning("HTTP profile: failed to parse success expression '", success_text, "'");
            }

            rs.is_batch = has_plural;
            rs.has_substitutions = has_singular || has_plural;
        }
    }

    void send_request(ref RequestState rs, MonoTime now, bool is_write)
    {
        if (rs.in_flight)
            return;
        if (is_write)
            rs.write_dirty = false;

        if (rs.has_substitutions && !rs.is_batch)
        {
            // per-element request
            foreach (i, ref se; _elements[])
            {
                ref const ElementDesc_HTTP http = _profile.get_http(se.http_index);
                ushort match_idx = is_write ? http.write_request_index : http.request_index;
                if (match_idx != rs.request_index)
                    continue;
                if (!element_is_due(se, now))
                    continue;
                send_batch(rs, now, is_write, (&se)[0..1]);

                // NOTE: just one per frame to mitigate flooding?
                // TODO: probably a bad strategy, the client should queue or dispatch many at once...?
                return;
            }
            return;
        }

        send_batch(rs, now, is_write, _elements[]);
    }

    void send_batch(ref RequestState rs, MonoTime now, bool is_write, HTTPSampleElement[] elements)
    {
        ref const RequestDesc req = _profile.get_request(rs.request_index);

        const(char)[] path_tmpl = rs.resolved_path ? rs.resolved_path[] : req.get_path(*_profile);
        const(char)[] body_tmpl = rs.resolved_body_template ? rs.resolved_body_template[] : req.get_body_template(*_profile);

        Array!char merged_path;
        Array!char form_buf;
        Variant merged_body;
        bool first = true;

        if (rs.path_key_offset < ushort.max)
            merged_path = path_tmpl[0 .. rs.path_key_offset];
        else if (rs.path_val_offset < ushort.max)
            merged_path = path_tmpl[0 .. rs.path_val_offset];

        if (req.format_type == RequestDesc.FormatType.form)
        {
            if (rs.body_key_offset < ushort.max)
                form_buf = body_tmpl[0 .. rs.body_key_offset];
            else if (rs.body_val_offset < ushort.max)
                form_buf = body_tmpl[0 .. rs.body_val_offset];
        }

        foreach (ref se; elements)
        {
            ref const ElementDesc_HTTP http = _profile.get_http(se.http_index);
            ushort match_idx = is_write ? http.write_request_index : http.request_index;
            if (match_idx != rs.request_index)
                continue;

            const(char)[] key = is_write ? http.get_write_key(*_profile) : null;
            if (key.empty)
                key = http.get_identifier(*_profile);
            const(char)[] value_str;

            void url_append(ref Array!char target, ushort key_offset, ushort val_offset, const(char)[] tmpl)
            {
                if (val_offset < ushort.max && !value_str)
                    value_str = format_element_value(se);

                if (val_offset == key_offset + 1 && tmpl[key_offset] == '=')
                {
                    // this is {key}={value} case...
                    target.append(first ? "" : "&", key, '=', value_str);
                }
                else if (key_offset < ushort.max || val_offset < ushort.max)
                {
                    assert(val_offset == ushort.max || elements.length == 1, "Only single element allowed with this path format");

                    // TODO: are there other grouped formats we should support?

                    if (key_offset < ushort.max)
                    {
                        target.append(first ? "" : ",", key);
                    }
                    if (val_offset < ushort.max)
                    {
                        if (key_offset < ushort.max)
                            target ~= tmpl[key_offset .. val_offset];
                        target ~= value_str;
                    }
                }
            }

            // append path elements
            url_append(merged_path, rs.path_key_offset, rs.path_val_offset, path_tmpl);

            // body aggregation
            if (req.format_type == RequestDesc.FormatType.form)
                url_append(form_buf, rs.body_key_offset, rs.body_val_offset, body_tmpl);
            else if (req.format_type == RequestDesc.FormatType.json)
            {
                if (rs.body_key_offset < ushort.max || rs.body_val_offset < ushort.max)
                {
                    Variant val = se.element.value;
                    char[256] json_val_buf = void;
                    ptrdiff_t json_len = write_json(val, json_val_buf[], true);
                    if (json_len <= 0)
                        continue;
                    const(char)[] json_val = json_val_buf[0 .. json_len];

                    Array!char expanded;
                    ushort bk = rs.body_key_offset;
                    ushort bv = rs.body_val_offset;
                    if (bk < ushort.max && bv < ushort.max)
                        expanded.append(body_tmpl[0 .. bk], '"', key, '"', body_tmpl[bk .. bv], json_val, body_tmpl[bv .. $]);
                    else if (bk < ushort.max)
                        expanded.append(body_tmpl[0 .. bk], '"', key, '"', body_tmpl[bk .. $]);
                    else
                        expanded.append(body_tmpl[0 .. bv], json_val, body_tmpl[bv .. $]);

                    Variant expansion = parse_json(expanded[]);
                    if (!expansion.isNull)
                    {
                        if (merged_body.isNull)
                            merged_body = expansion;
                        else
                            deep_merge(merged_body, expansion);
                    }
                }
            }

            first = false;
        }

        if (rs.path_val_offset < ushort.max)
            merged_path ~= path_tmpl[rs.path_val_offset .. $];
        else if (rs.path_key_offset < ushort.max)
            merged_path ~= path_tmpl[rs.path_key_offset .. $];

        const(char)[] path = path_tmpl[];
        if (!merged_path.empty)
            path = merged_path[];

        const(char)[] body;
        Array!char body_buf;
        if (req.format_type == RequestDesc.FormatType.form)
        {
            if (rs.body_val_offset < ushort.max)
                form_buf ~= body_tmpl[rs.body_val_offset .. $];
            else if (rs.body_key_offset < ushort.max)
                form_buf ~= body_tmpl[rs.body_key_offset .. $];
            body = form_buf[];
        }
        else if (req.format_type == RequestDesc.FormatType.json)
        {
            if (!merged_body.isNull)
            {
                ptrdiff_t len = write_json(merged_body, null, true);
                if (len > 0)
                {
                    body_buf.resize(len);
                    write_json(merged_body, body_buf[], true);
                    body = body_buf[];
                }
            }
        }

        rs.in_flight = true;
        rs.last_request = now;
        submit_request(rs.request_index, req.method, path, body, req.format_type);
    }

    void submit_request(ushort req_idx, HTTPMethod method, const(char)[] path, const(char)[] body = null, RequestDesc.FormatType fmt = RequestDesc.FormatType.none)
    {
        if (_in_flight_count >= _in_flight_queue.length)
            return;

        HTTPParam[1] ct_header;
        if (body.length > 0)
        {
            if (fmt == RequestDesc.FormatType.json)
                ct_header[0] = HTTPParam(StringLit!"Content-Type", StringLit!"application/json");
            else if (fmt == RequestDesc.FormatType.form)
                ct_header[0] = HTTPParam(StringLit!"Content-Type", StringLit!"application/x-www-form-urlencoded");
            else
                ct_header[0] = HTTPParam(StringLit!"Content-Type", StringLit!"text/plain");
        }

        version (DebugHTTPSampler)
        {
            import urt.meta.enuminfo;
            writeDebug("HTTP request: ", enum_key_from_value!HTTPMethod(method), " ", path,
                body.length > 0 ? " [body: " : "", body.length > 0 ? body : "", body.length > 0 ? "]" : "");
        }

        _client.request(method, path, &on_response, cast(const(void)[])body, null, body.length > 0 ? ct_header[] : null);

        ubyte tail = cast(ubyte)((_in_flight_head + _in_flight_count) % _in_flight_queue.length);
        _in_flight_queue[tail] = req_idx;
        ++_in_flight_count;
    }

    static bool element_is_due(ref const HTTPSampleElement se, MonoTime now)
    {
        if (se.sampled && se.sample_time_ms == 0)
            return false; // constant, already sampled
        if (se.sample_time_ms == ushort.max)
            return false; // on-demand only
        if (se.sampled)
        {
            long elapsed = (now - se.last_sample).as!"msecs";
            if (elapsed < se.sample_time_ms)
                return false;
        }
        return true;
    }

    const(char)[] format_element_value(ref const HTTPSampleElement se)
    {
        ref const ElementDesc_HTTP http = _profile.get_http(se.http_index);
        const Variant v = se.element.value;
        return format_value(v, http.value_desc);
    }

    int on_response(ref const HTTPMessage response)
    {
        if (_in_flight_count == 0)
            return 0;

        ushort req_idx = _in_flight_queue[_in_flight_head];
        _in_flight_head = cast(ubyte)((_in_flight_head + 1) % _in_flight_queue.length);
        --_in_flight_count;

        version (DebugHTTPSampler)
            writeDebug("HTTP response: status ", response.status_code, " (", response.content.length, " bytes)");

        RequestState* rs;
        foreach (ref req; _request_states[])
        {
            if (req.request_index == req_idx)
            {
                req.in_flight = false;
                rs = &req;
                break;
            }
        }

        // handle redirects
        if (response.status_code >= 300 && response.status_code < 400)
        {
            const(char)[] location;
            foreach (ref h; response.headers[])
            {
                if (h.key[].ieq("location"))
                {
                    location = h.value[];
                    break;
                }
            }

            if (location.empty)
            {
                writeWarning("HTTP sampler: redirect with no Location header");
            }
            else if (location[0] == '/')
            {
                // Relative path — same host, URI update
                // TODO: cache redirect and retry with new path
                writeWarning("HTTP sampler: URI redirect to '", location, "' — not yet implemented");
            }
            else
            {
                // Absolute URL — need to compare scheme and host against
                // client's current connection to classify as:
                //   1. protocol upgrade/downgrade (scheme differs)
                //   2. cross-host redirect (host differs)
                //   3. URI update (same scheme+host, different path)
                // TODO: parse Location URL, compare to client, handle case 3
                writeWarning("HTTP sampler: redirect to '", location, "' — not yet implemented");
            }
            return 0;
        }

        if (response.status_code < 200 || response.status_code >= 300)
        {
            writeWarning("HTTP sampler: request returned status ", response.status_code);
            return 0;
        }

        if (response.content.length == 0 || rs is null)
            return 0;

        ref const RequestDesc req = _profile.get_request(req_idx);

        if (req.parse_mode == RequestDesc.ParseMode.none)
            return 0;

        if (req.parse_mode == RequestDesc.ParseMode.regex)
        {
            foreach (ref se; _elements[])
            {
                ref const ElementDesc_HTTP http = _profile.get_http(se.http_index);
                if (http.request_index != req_idx)
                    continue;

                const(char)[] pattern = http.get_identifier(*_profile);
                if (pattern.empty)
                    continue;

                import urt.string.regex;
                RegexMatch rmatch;
                if (!regex_match(cast(char[])response.content[], pattern, rmatch))
                    continue;

                const(char)[] capture = rmatch.num_captures > 0 ? rmatch.captures[0] : rmatch.full;
                se.element.value(sample_value(capture, http.value_desc), response.timestamp);
                se.last_sample = getTime();
                se.sampled = true;
            }
            return 0;
        }

        Variant json = parse_json(cast(const(char)[])response.content[]);
        // TODO: we don't have a way to signal a parse error :/

        if (rs.success_expr)
        {
            if (!evaluate_success(json, rs.success_expr))
            {
                writeWarning("HTTP sampler: success check failed for request");
                return 0;
            }
        }

        Variant* data = &json;
        const(char)[] root_path = rs.resolved_root_path ? rs.resolved_root_path[] : req.get_root_path(*_profile);
        if (!root_path.empty)
        {
            data = walk_json_path(json, root_path);
            if (data is null)
            {
                writeWarning("HTTP sampler: root path '", root_path, "' not found in response");
                return 0;
            }
        }

        const(char)[] parse_tmpl = rs.resolved_parse_template ? rs.resolved_parse_template[] : req.get_parse_template(*_profile);

        foreach (ref se; _elements[])
        {
            ref const ElementDesc_HTTP http = _profile.get_http(se.http_index);
            if (http.request_index != req_idx)
                continue;

            const(char)[] identifier = http.get_identifier(*_profile);
            if (identifier.empty)
                continue;

            const(char)[] resp_path = http.get_response_path(*_profile);
            if (!resp_path.empty)
                identifier = resp_path;

            Variant* val;

            if (!parse_tmpl.empty)
                val = resolve_parse_template(*data, parse_tmpl, identifier, http.identifier_quoted);
            else if (http.identifier_quoted)
            {
                if (data.isObject)
                    val = data.getMember(identifier);
            }
            else
                val = walk_json_path(*data, identifier);

            if (val is null)
                continue;

            apply_value(se.element, *val, http.value_desc, response.timestamp);
            se.last_sample = getTime();
            se.sampled = true;

            version (DebugHTTPSampler)
                writeDebug("HTTP sampled: ", se.element.id, " = ", se.element.value);
        }

        return 0;
    }

    Variant* resolve_parse_template(ref Variant data, const(char)[] tmpl, const(char)[] key, bool key_quoted)
    {
        size_t key_start = tmpl.findFirst("{key}");
        if (key_start >= tmpl.length)
            return walk_json_path(data, tmpl);

        const(char)[] prefix = tmpl[0 .. key_start];
        const(char)[] suffix = tmpl[key_start + 5 .. $];

        Variant* current = &data;
        if (!prefix.empty)
        {
            if (prefix[$ - 1] == '.')
                prefix = prefix[0 .. $ - 1];
            if (!prefix.empty)
            {
                current = walk_json_path(*current, prefix);
                if (current is null)
                    return null;
            }
        }

        // Quoted = flat member lookup; unquoted = dot-walk
        if (key_quoted)
        {
            if (!current.isObject)
                return null;
            current = current.getMember(key);
        }
        else
            current = walk_json_path(*current, key);
        if (current is null)
            return null;

        // Walk suffix (if any)
        if (!suffix.empty)
        {
            // Strip leading dot from suffix
            if (suffix[0] == '.')
                suffix = suffix[1 .. $];
            if (!suffix.empty)
            {
                current = walk_json_path(*current, suffix);
                if (current is null)
                    return null;
            }
        }

        return current;
    }

}

bool evaluate_success(ref Variant json, Expression* expr)
{
    import urt.map : Map;

    if (!expr)
        return true;

    Map!(const(char)[], Variant) locals;
    if (json.isObject)
    {
        foreach (key, ref val; json)
            locals[key] = val;
    }

    EvalContext ctx;
    ctx.locals = &locals;
    Variant result = expr.evaluate(ctx);
    assert(result.isBool, "success expression must evaluate to a bool");
    return result.asBool;
}

Variant* walk_json_path(ref Variant root, const(char)[] path)
{
    Variant* current = &root;

    while (!path.empty)
    {
        if (current.isNull)
            return null;

        const(char)[] segment;
        size_t dot = path.findFirst('.');
        if (dot < path.length)
        {
            segment = path[0 .. dot];
            path = path[dot + 1 .. $];
        }
        else
        {
            segment = path;
            path = null;
        }
        if (segment.empty)
            continue;

        // check for array index: "name[0]"
        size_t bracket = segment.findFirst('[');
        if (bracket < segment.length)
        {
            const(char)[] name = segment[0 .. bracket];
            const(char)[] idx_str = segment[bracket + 1 .. $];

            if (!name.empty)
            {
                if (!current.isObject)
                    return null;
                current = current.getMember(name);
                if (current is null)
                    return null;
            }

            size_t close = idx_str.findFirst(']');
            if (close < idx_str.length)
                idx_str = idx_str[0 .. close];

            size_t taken;
            ulong idx = parse_uint_with_base(idx_str, &taken);
            if (taken == 0 || !current.isArray)
                return null;
            if (idx >= current.length)
                return null;

            current = &(*current)[cast(size_t)idx];
        }
        else
        {
            if (!current.isObject)
                return null;
            current = current.getMember(segment);
            if (current is null)
                return null;
        }
    }

    return current;
}

// merge `source` into `target`:
// - Object keys: recurse
// - Arrays: append source elements to target
// - Scalars: source overwrites target
void deep_merge(ref Variant target, ref Variant source)
{
    if (target.isObject && source.isObject)
    {
        foreach (key, ref val; source)
        {
            Variant* existing = target.getMember(key);
            if (existing !is null)
                deep_merge(*existing, val);
            else
                target[key] = val;
        }
    }
    else if (target.isArray && source.isArray)
    {
        ref arr = target.asArray();
        foreach (ref v; source.asArray()[])
            arr ~= v;
    }
    else
        target = source;
}

void apply_value(Element* element, ref Variant val, ref const TextValueDesc desc, SysTime timestamp)
{
    import urt.inet;

    if (val.isNull)
    {
        // clear the element value; is this the correct thing to do?
        element.value(Variant(), timestamp);
        return;
    }

    // push strings through `sample_value`
    if (val.isString)
    {
        val = sample_value(val.asString(), desc);
        element.value(val, timestamp);
        return;
    }

    final switch (desc.type) with (TextType)
    {
        case bool_:
            bool b = false;
            if (val.isBool)
                b = val.asBool;
            else if (val.isNumber)
                b = val.asInt != 0;
            element.value(Variant(b), timestamp);
            break;

        case num:
            import urt.si.quantity;

            if (val.isBool)
                element.value(Variant(val.asBool ? 1 : 0), timestamp);
            else if (!val.isNumber)
                return; // is there anything more we can do?
            else if (val.isQuantity)
            {
                // confirm compatible quantities
                VarQuantity q = val.asQuantity();
                if (q.unit.unit != desc.unit.unit)
                    return;
                q.adjust_scale(desc.unit);
                if (desc.pre_scale != 1)
                    q *= desc.pre_scale;
                element.value(Variant(q), timestamp);
            }
            else if (desc.pre_scale != 1)
            {
                double raw = val.asDouble;
                element.value(Variant(VarQuantity(raw * desc.pre_scale, desc.unit)), timestamp);
            }
            else if (desc.unit.pack)
            {
                Variant t = val;
                t.set_unit(desc.unit);
                element.value(t, timestamp);
            }
            else
                goto set_value;
            break;

        case str:
            assert(false, "TODO: should have been caught by the isString case above; do we want to do stringification?");
            break;

        case enum_:
        case bf:
            assert(desc.enum_info, "What case is there an enum without an enum type specified?");

            if (val.is_enum)
                goto set_value;
            else if (val.isUlong)
                element.value(Variant(val.asUlong, desc.enum_info), timestamp);
            else if (val.isLong)
                element.value(Variant(val.asLong, desc.enum_info), timestamp);
            else if (val.isBool)
                element.value(Variant(val.asBool ? 1 : 0, desc.enum_info), timestamp);
            else if (val.isDouble)
            {
                double d = val.asDouble;
                long l = cast(long)d;
                if (l == d)
                    element.value(Variant(l, desc.enum_info), timestamp);
            }
            else
                assert(false, "TODO: what other kind of thing can arrive here?");
            break;

        case dt:
            if (!val.isUser!DateTime && !val.isUser!SysTime)
                return;
            goto set_value;

        case inetaddr:
            if (!val.isUser!InetAddress)
                return;
            goto set_value;

        case ipaddr:
            if (!val.isUser!IPAddr)
                return;
            goto set_value;

        case ip6addr:
            if (!val.isUser!IPv6Addr)
                return;
            goto set_value;

        set_value:
            element.value(val, timestamp);
            break;
    }
}


unittest
{
    import urt.format.json : parse_json;

    // ── walk_json_path ──

    Variant json = parse_json(`{"a": {"b": {"c": 42}}, "arr": [10, 20, 30], "x": 1}`);

    // simple dotted path
    assert(*walk_json_path(json, "a.b.c") == 42);

    // single key
    assert(*walk_json_path(json, "x") == 1);

    // array indexing
    assert(*walk_json_path(json, "arr[0]") == 10);
    assert(*walk_json_path(json, "arr[2]") == 30);

    // array out of bounds
    assert(walk_json_path(json, "arr[5]") is null);

    // missing key
    assert(walk_json_path(json, "a.missing") is null);
    assert(walk_json_path(json, "nonexistent") is null);

    // nested path through object then array
    Variant json2 = parse_json(`{"data": {"items": [{"id": 1}, {"id": 2}]}}`);
    assert(*walk_json_path(json2, "data.items[1].id") == 2);

    // empty path returns root
    assert(walk_json_path(json, "") !is null);

    // ── deep_merge ──

    // object merge: non-overlapping keys
    Variant a = parse_json(`{"x": 1}`);
    Variant b = parse_json(`{"y": 2}`);
    deep_merge(a, b);
    assert(*a.getMember("x") == 1);
    assert(*a.getMember("y") == 2);

    // object merge: overlapping scalar — source wins
    Variant c = parse_json(`{"x": 1}`);
    Variant d = parse_json(`{"x": 99}`);
    deep_merge(c, d);
    assert(*c.getMember("x") == 99);

    // object merge: nested recursion
    Variant e = parse_json(`{"a": {"x": 1, "y": 2}}`);
    Variant f = parse_json(`{"a": {"y": 99, "z": 3}}`);
    deep_merge(e, f);
    Variant* ea = e.getMember("a");
    assert(*ea.getMember("x") == 1);
    assert(*ea.getMember("y") == 99);
    assert(*ea.getMember("z") == 3);

    // scalar overwrite
    Variant g = parse_json(`"hello"`);
    Variant h = parse_json(`42`);
    deep_merge(g, h);
    assert(g == 42);

    // array append — the API use case: {"paths": ["a"]} + {"paths": ["b"]} → {"paths": ["a", "b"]}
    Variant p1 = parse_json(`{"paths": ["inv.battery.voltage"]}`);
    Variant p2 = parse_json(`{"paths": ["inv.battery.current"]}`);
    deep_merge(p1, p2);
    Variant* paths = p1.getMember("paths");
    assert(paths !is null);
    assert(paths.isArray);
    assert(paths.length == 2);
    assert((*paths)[0] == Variant("inv.battery.voltage"));
    assert((*paths)[1] == Variant("inv.battery.current"));

    // ── evaluate_success ──

    Variant ok_json = parse_json(`{"result": "OK", "count": 5}`);
    Variant fail_json = parse_json(`{"result": "FAIL", "count": 0}`);

    try
    {
        // null expression — defaults to true
        assert(evaluate_success(ok_json, null));

        // string equality via $var
        const(char)[] program = `$result == "OK"`;
        auto expr1 = parse_expression(program);
        assert(evaluate_success(ok_json, expr1));
        assert(!evaluate_success(fail_json, expr1));

        // numeric comparison
        program = "$count > 0";
        auto expr2 = parse_expression(program);
        assert(evaluate_success(ok_json, expr2));
        assert(!evaluate_success(fail_json, expr2));
        program = "$count == 5";
        auto expr3 = parse_expression(program);
        assert(evaluate_success(ok_json, expr3));
        assert(!evaluate_success(fail_json, expr3));
    }
    catch (Exception)
        assert(false, "parse failed");

    // non-object JSON — locals empty
    Variant scalar = parse_json(`42`);
    assert(evaluate_success(scalar, null));
}
