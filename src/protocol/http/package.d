module protocol.http;

import urt.array;
import urt.conv;
import urt.inet;
import urt.kvp;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.meta.enuminfo;
import urt.meta.nullable;
import urt.string;
import urt.string.format : tconcat, tstring;
import urt.time;

import manager.base;
import manager.collection;
import manager.config : ConfItem;
import manager.console;
import manager.expression : NamedArgument;
import manager.plugin;
import manager.profile;
import manager.sample.spec : stream_le_context;

import protocol.http.client;
import protocol.http.message;
import protocol.http.binding;
import protocol.http.server;
import protocol.http.staticfiles;
import protocol.http.websocket;

import router.stream;
import protocol.ip.tcp_stream;
import protocol.tls;

nothrow @nogc:


package __gshared uint http_section_kind;
package __gshared uint http_requests_kind;

struct HTTPRequestDesc
{
pure nothrow @nogc:

    enum FormatType : ubyte
    {
        none, // no body formatting
        json, // JSON body template with {key}/{value} expansion
        form, // key=val&key=val body template with {key}/{value}
    }

    enum ParseMode : ubyte
    {
        json,  // walk the response by element paths
        regex, // element identifier is a capture pattern
        none,  // do not parse the response
    }

    const(char)[] get_name(ref const(Profile) profile) const
        => profile.get_section_string(_name);

    const(char)[] get_path(ref const(Profile) profile) const
        => profile.get_section_string(_path);

    const(char)[] get_body_template(ref const(Profile) profile) const
        => profile.get_section_string(_body_template);

    const(char)[] get_parse_template(ref const(Profile) profile) const
        => profile.get_section_string(_parse_template);

    const(char)[] get_root_path(ref const(Profile) profile) const
        => profile.get_section_string(_root_path);

    const(char)[] get_success_expr(ref const(Profile) profile) const
        => profile.get_section_string(_success_expr);

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

struct HTTPElementDesc
{
pure nothrow @nogc:
    const(char)[] get_identifier(ref const(Profile) profile) const
        => profile.get_section_string(_identifier);

    const(char)[] get_write_key(ref const(Profile) profile) const
        => profile.get_section_string(_write_key);

    const(char)[] get_response_path(ref const(Profile) profile) const
        => profile.get_section_string(_response_path);

    ushort request_index;
    ushort write_request_index;
    ushort desc = ushort.max;
    bool identifier_quoted;

private:
    ushort _identifier;
    ushort _write_key;
    ushort _response_path;
}

struct HttpUrl
{
    const(char)[] scheme;
    const(char)[] host;
    const(char)[] path;
}

HttpUrl decompose_http_url(const(char)[] url) pure
{
    HttpUrl r;
    auto sep = url.findFirst("://");
    if (sep < url.length)
    {
        r.scheme = url[0 .. sep];
        url = url[sep + 3 .. $];
    }
    auto slash = url.findFirst('/');
    if (slash < url.length)
    {
        r.path = url[slash .. $];
        url = url[0 .. slash];
    }
    r.host = url;
    return r;
}

bool http_request(const(char)[] url,
                  HTTPMessageHandler on_response,
                  HTTPMethod method = HTTPMethod.GET,
                  const(void)[] content = null,
                  HTTPParam[] headers = null,
                  String username = null,
                  String password = null,
                  HTTPFlags flags = HTTPFlags.None)
{
    if (on_response is null)
        return false;

    HttpUrl parsed = decompose_http_url(url);
    if (parsed.host.empty)
        return false;

    const(char)[] scheme = parsed.scheme.empty ? "http" : parsed.scheme;
    if (scheme.icmp("http") != 0 && scheme.icmp("https") != 0)
        return false;

    HTTPOneShot one = defaultAllocator.allocT!HTTPOneShot();
    one.user_handler = on_response;
    one.method = method;
    one.path = (parsed.path.empty ? "/" : parsed.path).makeString(defaultAllocator);
    if (content.length > 0)
        one.content ~= cast(const(ubyte)[])content;
    one.username = username.move;
    one.password = password.move;
    one.flags = flags;

    // copy caller's headers and force Connection: close so the client's temporary
    // flag tears the connection down after exactly one response.
    foreach (ref h; headers)
    {
        if (h.key[].icmp("Connection") == 0)
            continue;
        one.headers ~= HTTPParam(h.key, h.value);
    }
    one.headers ~= HTTPParam(StringLit!"Connection", StringLit!"close");

    String remote_str = tconcat(scheme, "://", parsed.host).makeString(defaultAllocator);
    const(char)[] client_name = Collection!HTTPClient().generate_name("http-req");
    HTTPClient c = Collection!HTTPClient().create(client_name, cast(ObjectFlags)(ObjectFlags.dynamic | ObjectFlags.temporary), NamedArgument("remote", remote_str));
    if (!c)
    {
        defaultAllocator.freeT(one);
        return false;
    }

    one.client = c;
    c.subscribe(&one.on_state);

    // HACK: create() advances the state machine one tick. The client is usually still
    // `starting` (waiting on TCP connect) at this point, but cover the case where
    // it became running synchronously.
    // TODO: clean this up when we stop this terrible eager update policy!
    if (c.running)
        one.on_state(c, StateSignal.online);

    return true;
}


class HTTPModule : Module, ProfileSections, ProfileRootSections
{
    mixin DeclareModule!"http";
nothrow @nogc:

    override void init()
    {
        http_section_kind = register_profile_section("http", this);
        http_requests_kind = register_profile_root_section("requests", this);

        g_app.register_enum!HTTPMethod();

        g_app.console.register_collection!HTTPClient();
        g_app.console.register_collection!HTTPServer();
        g_app.console.register_collection!StaticFileServer();
        g_app.console.register_collection!WebSocketServer();
        g_app.console.register_collection!WebSocket();
        g_app.console.register_collection!HTTPClientBinding();

        g_app.console.register_command!request("/protocol/http", this);
    }

    uint element_size(uint)
        => cast(uint)HTTPElementDesc.sizeof;

    void count_element(uint, ref const ConfItem item, ref ProfileCosts costs)
    {
        const(char)[] tail = item.value;
        tail.split!','.unQuote;
        costs.add_string(tail.split!','.unQuote);

        foreach (ref sub; item.sub_items)
        {
            if (sub.name == "write")
            {
                tail = sub.value;
                tail.split!','.unQuote;
                costs.add_string(tail.split!','.unQuote);
            }
            else if (sub.name == "response")
                costs.add_string(sub.value.unQuote);
        }
    }

    bool parse_element(uint, ref const ConfItem item, void[] slot, ref ProfileBuilder b)
    {
        HTTPElementDesc* http = cast(HTTPElementDesc*)slot.ptr;
        *http = HTTPElementDesc.init;

        const(char)[] tail = item.value;
        const(char)[] request_name = tail.split!','.unQuote;
        const(char)[] raw_identifier = tail.split!',';
        http.identifier_quoted = raw_identifier.length >= 2 &&
                                 raw_identifier[0] == '"' && raw_identifier[$ - 1] == '"';
        http._identifier = b.intern(raw_identifier.unQuote);

        const(char)[] type = tail.split!','.unQuote;
        const(char)[] following = tail.split!','.unQuote;

        http.write_request_index = ushort.max;
        http.request_index = find_request_index(*b.profile, request_name);
        if (http.request_index == ushort.max && !request_name.empty)
            writeWarning("Unknown request '", request_name, "' for http element: ", b.element_id);

        ubyte ignored_span;
        if (!b.compile_value(type, following, stream_le_context, http.desc, ignored_span))
            return false;

        foreach (ref sub; item.sub_items)
        {
            if (sub.name == "write")
            {
                const(char)[] write = sub.value;
                const(char)[] write_request = write.split!','.unQuote;
                const(char)[] write_key = write.split!','.unQuote;

                http.write_request_index = find_request_index(*b.profile, write_request);
                if (http.write_request_index == ushort.max)
                    writeWarning("Unknown write request '", write_request, "' for http element: ", b.element_id);
                if (!write_key.empty)
                    http._write_key = b.intern(write_key);
            }
            else if (sub.name == "response")
                http._response_path = b.intern(sub.value.unQuote);
        }

        bool has_read = http.request_index != ushort.max;
        bool has_write = http.write_request_index != ushort.max;
        if (has_read && has_write)
            b.access(Access.read_write);
        else if (has_write)
            b.access(Access.write);
        else
            b.access(Access.read);
        return true;
    }

    uint root_size(uint, ref const ConfItem item)
        => cast(uint)(ushort.sizeof + item.sub_items.length * HTTPRequestDesc.sizeof);

    void count_root(uint, ref const ConfItem item, ref ProfileCosts costs)
    {
        foreach (ref request; item.sub_items)
        {
            if (request.name != "request")
                continue;

            const(char)[] tail = request.value;
            costs.add_string(tail.split!','.unQuote);
            tail.split!','.unQuote;
            costs.add_string(tail.split!','.unQuote);

            foreach (ref sub; request.sub_items)
            {
                switch (sub.name)
                {
                    case "success":
                        costs.add_string(sub.value);
                        break;
                    case "root":
                    case "parse":
                        costs.add_string(sub.value.unQuote);
                        break;
                    case "format":
                        const(char)[] format = sub.value;
                        format.split!','.unQuote;
                        costs.add_string(format.unQuote);
                        break;
                    default:
                        break;
                }
            }
        }
    }

    bool parse_root(uint, ref const ConfItem item, void[] slot, ref ProfileBuilder b)
    {
        ushort* count = cast(ushort*)slot.ptr;
        *count = 0;
        HTTPRequestDesc[] requests = mutable_requests(slot);

        requests_loop: foreach (ref request; item.sub_items)
        {
            if (request.name != "request")
            {
                writeWarning("Expected 'request:' in requests block, got: ", request.name);
                continue;
            }

            const(char)[] tail = request.value;
            const(char)[] name = tail.split!','.unQuote;
            auto method = enum_from_key!HTTPMethod(tail.split!','.unQuote);
            if (method == null)
            {
                writeWarning("Unknown HTTP method in request '", name, "'");
                continue;
            }
            const(char)[] path = tail.split!','.unQuote;

            const(char)[] success_expr, root_path, parse_template, body_template;
            HTTPRequestDesc.FormatType format_type;
            HTTPRequestDesc.ParseMode parse_mode;

            foreach (ref sub; request.sub_items)
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
                        const(char)[] parse_tail = sub.value;
                        const(char)[] parse_type = parse_tail.split!','.unQuote;
                        if (parse_type == "regex")
                            parse_mode = HTTPRequestDesc.ParseMode.regex;
                        else if (parse_type == "none")
                            parse_mode = HTTPRequestDesc.ParseMode.none;
                        else if (parse_type == "json")
                            parse_template = parse_tail.unQuote;
                        else
                            parse_template = sub.value.unQuote;
                        break;
                    case "format":
                        const(char)[] format = sub.value;
                        const(char)[] format_type_name = format.split!','.unQuote;
                        if (format_type_name == "json")
                            format_type = HTTPRequestDesc.FormatType.json;
                        else if (format_type_name == "form")
                            format_type = HTTPRequestDesc.FormatType.form;
                        else
                        {
                            writeWarning("Unknown format type '", format_type_name, "' in request '", name, "'");
                            continue requests_loop;
                        }
                        body_template = format.unQuote;
                        break;
                    default:
                        writeWarning("Unknown sub-item '", sub.name, "' in request '", name, "'");
                        continue requests_loop;
                }
            }

            ref HTTPRequestDesc desc = requests[(*count)++];
            desc = HTTPRequestDesc.init;
            desc.method = *method;
            desc.format_type = format_type;
            desc.parse_mode = parse_mode;
            desc._name = b.intern(name);
            desc._path = b.intern(path);
            desc._success_expr = b.intern(success_expr);
            desc._root_path = b.intern(root_path);
            desc._parse_template = b.intern(parse_template);
            desc._body_template = b.intern(body_template);
        }
        return true;
    }

    override void update()
    {
        Collection!HTTPServer().update_all();
        Collection!HTTPClient().update_all();
        Collection!StaticFileServer().update_all();
        Collection!WebSocketServer().update_all();
    }

    static class HTTPRequestState : CommandState
    {
    nothrow @nogc:

        CommandCompletionState state = CommandCompletionState.in_progress;

        this(Session session)
        {
            super(session, null);
        }

        override CommandCompletionState update()
            => state;

        override void request_cancel()
        {
            // TODO: thread cancellation through to http_request's HTTPOneShot
        }

        int response_handler(ref const HTTPMessage response)
        {
            if (response.status_code == 0)
            {
                session.writef("HTTP request failed!");
                state = CommandCompletionState.error;
                return -1;
            }

            session.writef("HTTP response: {0}\n{1}", response.status_code, cast(const char[])response.content[]);
            state = CommandCompletionState.finished;
            return 0;
        }
    }

    HTTPRequestState request(Session session, const(char)[] url, HTTPMethod method = HTTPMethod.GET)
    {
        HTTPRequestState state = g_app.allocator.allocT!HTTPRequestState(session);
        if (!http_request(url, &state.response_handler, method))
        {
            session.writef("HTTP request setup failed for '{0}'", url);
            g_app.allocator.freeT(state);
            return null;
        }
        return state;
    }
}

const(HTTPRequestDesc)[] get_http_requests(ref const Profile profile)
{
    const(void)[] root = profile.get_root_section(http_requests_kind);
    if (root.length < ushort.sizeof)
        return null;
    ushort count = *cast(const(ushort)*)root.ptr;
    return (cast(const(HTTPRequestDesc)*)(cast(const(ubyte)*)root.ptr + ushort.sizeof))[0 .. count];
}

ref const(HTTPRequestDesc) get_http_request(ref const Profile profile, size_t index)
{
    const(HTTPRequestDesc)[] requests = get_http_requests(profile);
    assert(index < requests.length, "HTTP request index out of range");
    return requests[index];
}


private:

HTTPRequestDesc[] mutable_requests(void[] root) pure
{
    size_t count = (root.length - ushort.sizeof) / HTTPRequestDesc.sizeof;
    return (cast(HTTPRequestDesc*)(cast(ubyte*)root.ptr + ushort.sizeof))[0 .. count];
}

ushort find_request_index(ref const Profile profile, const(char)[] name)
{
    if (name.empty)
        return ushort.max;
    foreach (i, ref request; get_http_requests(profile))
        if (request.get_name(profile) == name)
            return cast(ushort)i;
    return ushort.max;
}

class HTTPOneShot
{
nothrow @nogc:

    HTTPClient client;
    HTTPMessageHandler user_handler;

    HTTPMethod method;
    String path;
    Array!ubyte content;
    Array!HTTPParam headers;
    String username;
    String password;
    HTTPFlags flags;

    bool submitted;
    bool fired;

    void on_state(ActiveObject, StateSignal sig)
    {
        final switch (sig)
        {
            case StateSignal.online:
                if (submitted)
                    return;
                submitted = true;
                HTTPMessage* req = client.request(method, path[], &on_response, content[], null, headers[], username.move, password.move);
                if (req !is null)
                    req.flags = flags;
                else
                {
                    fire_failure();
                    HTTPClient c = client;
                    c.destroy();
                }
                break;

            case StateSignal.offline:
                break;

            case StateSignal.destroyed:
                client.unsubscribe(&on_state);
                fire_failure();
                defaultAllocator.freeT(this);
                break;
        }
    }

    int on_response(ref const HTTPMessage response)
    {
        fire(response);
        if (response.status_code == 0)
        {
            // failure path (timeout); the success path triggers teardown via
            // the Connection: close header + temporary flag
            HTTPClient c = client;
            c.destroy();
        }
        return 0;
    }

    void fire(ref const HTTPMessage response)
    {
        if (fired || user_handler is null)
            return;
        fired = true;
        user_handler(response);
    }

    void fire_failure()
    {
        if (fired)
            return;
        HTTPMessage empty;
        fire(empty);
    }
}

unittest
{
    import manager.sample : desc_by_index, parse_record;
    import manager.series : box_record, Scalar, ValueType;
    import urt.si.quantity : VarQuantity;
    import urt.si.unit : Ampere, ScaledUnit;

    HTTPModule module_ = defaultAllocator().allocT!HTTPModule(null);
    http_section_kind = register_profile_section("http", module_);
    http_requests_kind = register_profile_root_section("requests", module_);

    static immutable string conf =
        "enum: Mode\n" ~
        "\toff: 0\n" ~
        "\teco: 1\n" ~
        "elements:\n" ~
        "\thttp: status, current, f64:100mA\tdesc: current\n" ~
        "\thttp: status, mode, enum8:Mode\tdesc: mode\n" ~
        "\thttp: status, label, str\tdesc: label\n" ~
        "\thttp: , target, u16, W\tdesc: target\n" ~
        "\t\twrite: update, requested\n" ~
        "requests:\n" ~
        "\trequest: status, GET, /status\n" ~
        "\trequest: update, POST, /update\n" ~
        "\t\tformat: json, payload\n" ~
        "device-template:\n" ~
        "\tcomponent:\n" ~
        "\t\tid: settings\n" ~
        "\t\telement-map: target, @target\n";

    Profile* profile = parse_profile(conf, "http-test");
    assert(profile !is null);
    assert(profile.find_element("current") == 0);
    assert(profile.find_element("mode") == 1);
    assert(profile.find_element("label") == 2);
    assert(profile.find_element("target") == 3);

    const(HTTPRequestDesc)[] requests = get_http_requests(*profile);
    assert(requests.length == 2);
    assert(requests[0].method == HTTPMethod.GET && requests[0].get_path(*profile) == "/status");
    assert(requests[1].format_type == HTTPRequestDesc.FormatType.json);
    assert(requests[1].get_body_template(*profile) == "payload");

    ref const HTTPElementDesc current = profile.get_section!HTTPElementDesc(http_section_kind, 0);
    assert(current.request_index == 0);
    auto current_desc = desc_by_index(current.desc);
    assert(current_desc.fmt.type == ValueType.f64);
    Scalar scalar;
    assert(parse_record("1", current_desc, scalar.raw[0 .. current_desc.fmt.stride]));
    VarQuantity value = box_record(scalar.raw.ptr, *current_desc.fmt).asQuantity();
    double amps = value.adjust_scale(ScaledUnit(Ampere)).value;
    assert(amps > 0.099 && amps < 0.101);

    ref const HTTPElementDesc mode = profile.get_section!HTTPElementDesc(http_section_kind, 1);
    assert(desc_by_index(mode.desc).fmt.enum_info is profile.find_enum_template("Mode"));
    ref const HTTPElementDesc label = profile.get_section!HTTPElementDesc(http_section_kind, 2);
    assert(desc_by_index(label.desc).fmt.is_text);

    ref const HTTPElementDesc target = profile.get_section!HTTPElementDesc(http_section_kind, 3);
    assert(target.request_index == ushort.max && target.write_request_index == 1);
    assert(target.get_write_key(*profile) == "requested");

    DeviceTemplate* device = profile.get_model_template(null);
    assert(device !is null);
    auto components = device.components(*profile);
    assert(!components.empty);
    auto elements = components.front().elements(*profile);
    assert(!elements.empty);
    assert(elements.front().get_element_desc(*profile).access == Access.write);
}
