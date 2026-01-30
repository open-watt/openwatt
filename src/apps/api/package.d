module apps.api;

import urt.array;
import urt.format.json;
import urt.lifetime;
import urt.mem.allocator;
import urt.mem.temp;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.component;
import manager.console;
import manager.device;
import manager.element;
import manager.plugin;

import protocol.http.message;
import protocol.http.server;

import router.stream;

nothrow @nogc:


class APIManager : BaseObject
{
    __gshared Property[2] Properties = [ Property.create!("http-server", http_server)(),
                                         Property.create!("uri", uri)() ];
nothrow @nogc:

    alias TypeName = StringLit!"api";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!APIManager, name.move, flags);
    }

    // Properties

    inout(HTTPServer) http_server() inout pure
        => _server;
    void http_server(HTTPServer value)
    {
        _server = value;
    }

    const(char)[] uri() const pure
        => _uri[];
    void uri(const(char)[] value)
    {
        _uri = value.makeString(g_app.allocator);
    }

    // BaseObject overrides

    override bool validate() const pure
        => _server !is null;

    override CompletionStatus validating()
    {
        if (_server.detached)
        {
            import protocol.http;
            if (HTTPServer s = get_module!HTTPModule.servers.get(_server.name))
                _server = s;
        }
        return super.validating();
    }

    override CompletionStatus startup()
    {
        if (_uri)
        {
            _server.add_uri_handler(HTTPMethod.GET, _uri, &handle_request);
            _server.add_uri_handler(HTTPMethod.POST, _uri, &handle_request);
            _server.add_uri_handler(HTTPMethod.OPTIONS, _uri, &handle_request);
        }
        else
            _default_handler = _server.hook_global_handler(&handle_request);

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        // TODO: need to unlink these things...
        return CompletionStatus.complete;
    }

    override void update()
    {
        update_pending_requests();
    }

private:
    ObjectRef!HTTPServer _server;
    String _uri;

    HTTPServer.RequestHandler _default_handler;

    struct PendingRequest
    {
        HTTPVersion ver;
        Stream stream;
        StringSession session;
        CommandState command;
    }
    Array!PendingRequest _pending_requests;

    int handle_request(ref const HTTPMessage request, ref Stream stream)
    {
        const(char)[] tail = request.request_target[_uri.length .. $];

        // Handle CORS preflight OPTIONS requests
        if (request.method == HTTPMethod.OPTIONS)
            return handle_options(request, stream);

        if (tail == "/health")
            return handle_health(request, stream);
        if (tail == "/cli/execute")
            return handle_cli_execute(request, stream);
        if (tail == "/get")
            return handle_get(request, stream);
        if (tail == "/set")
            return handle_set(request, stream);
        if (tail == "/list")
            return handle_list(request, stream);

        if (_default_handler)
            _default_handler(request, stream);
        else if (_uri)
        {
            HTTPMessage response = create_response(request.http_version, 404, StringLit!"Not Found", StringLit!"application/json", "{\"error\":\"Not Found\"}");
            stream.write(response.format_message()[]);
        }

        return 0;
    }

    void add_cors_headers(ref HTTPMessage response)
    {
        response.headers ~= HTTPParam(StringLit!"Access-Control-Allow-Origin", StringLit!"*");
        response.headers ~= HTTPParam(StringLit!"Access-Control-Allow-Methods", StringLit!"GET, POST, PUT, DELETE, OPTIONS");
        response.headers ~= HTTPParam(StringLit!"Access-Control-Allow-Headers", StringLit!"Content-Type");
    }

    int handle_options(ref const HTTPMessage request, ref Stream stream)
    {
        HTTPMessage response = create_response(request.http_version, 204, StringLit!"No Content", String(), null);
        add_cors_headers(response);
        stream.write(response.format_message()[]);
        return 0;
    }

    int handle_health(ref const HTTPMessage request, ref Stream stream)
    {
        HTTPMessage response = create_response(request.http_version, 200, StringLit!"OK", StringLit!"application/json", tconcat("{\"status\":\"healthy\",\"uptime\":", getAppTime().as!"seconds", "}"));
        add_cors_headers(response);
        stream.write(response.format_message()[]);
        return 0;
    }

    int handle_cli_execute(ref const HTTPMessage request, ref Stream stream)
    {
        const(char)[] command_text;
        if (request.method == HTTPMethod.GET)
        {
            command_text = request.param("command")[];
        }
        else
        {
            Variant json = parse_json(cast(char[])request.content[]);
            command_text = json.getMember("command").asString();
        }

        if (command_text.length == 0)
        {
            HTTPMessage response = create_response(request.http_version, 400, StringLit!"Bad Request", StringLit!"application/json", "{\"error\":\"Command body required\"}");
            add_cors_headers(response);
            stream.write(response.format_message()[]);
            return 0;
        }

        StringSession session = g_app.console.createSession!StringSession();
        CommandState cmd = g_app.console.execute(session, command_text);
        if (cmd is null)
        {
            MutableString!0 output = session.takeOutput();
            send_cli_response(request.http_version, stream, output[]);
            defaultAllocator().freeT(session);
            return 0;
        }

        // TODO: if it's a persistent seession; we need a reference to the session to produce a response.
        //       if it's an ephemeral session, we need to take the stream from the session so we can produce a deferred response...?
        assert(false, "TODO: TEST THIS PATH, I'M NOT SURE THE HTTP REQUEST HANDLER CAN HANDLE HANDLE RELAYED RESPONSE?");
        _pending_requests ~= PendingRequest(request.http_version, stream, session, cmd);
        return 0;
    }

    void send_cli_response(HTTPVersion http_version, ref Stream stream, const(char)[] output)
    {
        HTTPMessage response = create_response(http_version, 200, StringLit!"OK", StringLit!"application/json", "{\"output\":");
        if (output.length > 0)
        {
            import urt.format.json;

            const v = Variant(output);
            size_t bytes = v.write_json(null);
            Array!char tmp;
            v.write_json(tmp.extend(bytes));
            response.content ~= tmp[];
            response.content ~= "}";
        }
        else
            response.content ~= "\"\"}";
        add_cors_headers(response);
        stream.write(response.format_message()[]);
    }

    int handle_get(ref const HTTPMessage request, ref Stream stream)
    {
        import urt.string;
        import urt.string.format;
        import urt.mem.temp;

        Variant json = parse_json(cast(char[])request.content[]);

        if (!json.isObject)
        {
            HTTPMessage response = create_response(request.http_version, 400, StringLit!"Bad Request", StringLit!"application/json", "{\"error\":\"Invalid JSON\"}");
            add_cors_headers(response);
            stream.write(response.format_message()[]);
            return 0;
        }

        const(Variant)* paths_var = json.getMember("paths");
        if (!paths_var || paths_var.isNull)
            paths_var = json.getMember("path");

        if (!paths_var || paths_var.isNull)
        {
            HTTPMessage response = create_response(request.http_version, 400, StringLit!"Bad Request", StringLit!"application/json", "{\"error\":\"Missing 'path' or 'paths' field\"}");
            add_cors_headers(response);
            stream.write(response.format_message()[]);
            return 0;
        }

        Array!(const(char)[]) paths;
        if (paths_var.isArray)
        {
            for (size_t i = 0; i < paths_var.length(); ++i)
                paths ~= (*paths_var)[i].asString();
        }
        else if (paths_var.isString)
            paths ~= paths_var.asString();
        else
        {
            HTTPMessage response = create_response(request.http_version, 400, StringLit!"Bad Request", StringLit!"application/json", "{\"error\":\"'path' or 'paths' must be string or array\"}");
            add_cors_headers(response);
            stream.write(response.format_message()[]);
            return 0;
        }

        // build response
        Array!char response_json;
        response_json.reserve(4096);
        response_json ~= '{';

        bool first = true;

        MutableString!0 prefix;
        prefix.reserve(256);

        foreach (i, path; paths[])
        {
            const(char)[] device_id = path.split!'.';

            if (device_id == "*")
            {
                foreach (dev; g_app.devices.values)
                    collect_with_wildcard(dev, path, response_json, first, prefix);
            }
            else
            {
                if (Device* dev = device_id in g_app.devices)
                    collect_elements_from_component(*dev, path, response_json, first, prefix);
            }
        }

        response_json ~= '}';

        HTTPMessage response = create_response(request.http_version, 200, StringLit!"OK", StringLit!"application/json", response_json[]);
        add_cors_headers(response);
        stream.write(response.format_message()[]);

        return 0;
    }

    void collect_elements_from_component(Component comp, const(char)[] path, ref Array!char json, ref bool first, ref MutableString!0 prefix)
    {
        import urt.mem.temp;

        if (path.empty)
            return;
        const(char)[] next = path.split!'.';

        if (next == "*")
        {
            collect_with_wildcard(comp, path, json, first, prefix);
        }
        else
        {
            size_t prefix_len = prefix.length;
            scope(exit) prefix.erase(prefix_len, prefix.length - prefix_len);

            if (prefix_len == 0)
                prefix = comp.id[];
            else
                prefix.append('.', comp.id[]);

            if (path.empty)
            {
                if (Element* elem = comp.find_element(next))
                    append_element(json, first, prefix, elem);
            }
            else
            {
                Component child = comp.find_component(next);
                if (!child)
                    return;

                collect_elements_from_component(child, path, json, first, prefix);
            }
        }
    }

    void collect_with_wildcard(Component comp, const(char)[] path, ref Array!char json, ref bool first, ref MutableString!0 prefix)
    {
        import urt.mem.temp;

        size_t prefix_len = prefix.length;
        scope(exit) prefix.erase(prefix_len, prefix.length - prefix_len);

        if (prefix_len == 0)
            prefix = comp.id[];
        else
            prefix.append('.', comp.id[]);

        if (path.empty)
        {
            foreach (ref Element* elem; comp.elements)
                append_element(json, first, prefix[], elem);
        }
        else
        {
            const(char)[] path_copy = path;
            const(char)[] next = path_copy.split!'.';

            if (next == "*")
            {
                foreach (Component child; comp.components)
                    collect_with_wildcard(child, path_copy, json, first, prefix);
            }
            else if (path_copy.empty)
            {
                if (Element* elem = comp.find_element(next))
                    append_element(json, first, prefix, elem);
            }
            else foreach (Component child; comp.components)
            {
                if (child.id[] == next)
                    collect_elements_from_component(child, path_copy, json, first, prefix);
            }
        }

        // recurse the tree
        foreach (Component child; comp.components)
            collect_with_wildcard(child, path, json, first, prefix);
    }

    void append_element(ref Array!char json, ref bool first, const(char)[] prefix, Element* elem)
    {
        import urt.si.quantity;
        import urt.si.unit;

        if (!first)
            json ~= ',';
        first = false;

        json.append('\"', prefix, '.', elem.id[], "\":{\"value\":");

        if (elem.latest.isQuantity)
        {
            auto quantity = elem.latest.asQuantity!double();

            ScaledUnit su;
            float pre_scale;

            if (elem.display_unit && su.parseUnit(elem.display_unit[], pre_scale) > 0)
            {
                // convert to display unit
                json ~= quantity.adjust_scale(su).value / pre_scale;
                json.append(",\"unit\":\"", elem.display_unit[], '\"');
            }
            else
            {
                json ~= quantity.value;

                // write the unit separately for quantities
                if (quantity.unit.pack != 0)
                    json.append(",\"unit\":\"", quantity.unit, '\"');
            }
        }
        else
        {
            size_t bytes = elem.latest.write_json(null);
            elem.latest.write_json(json.extend(bytes));
        }

        json ~= '}';
    }

    int handle_set(ref const HTTPMessage request, ref Stream stream)
    {
        import urt.string;
        import urt.mem.temp;

        Variant json = parse_json(cast(char[])request.content[]);

        if (!json.isObject)
        {
            HTTPMessage response = create_response(request.http_version, 400, StringLit!"Bad Request", StringLit!"application/json", "{\"error\":\"Invalid JSON\"}");
            add_cors_headers(response);
            stream.write(response.format_message()[]);
            return 0;
        }

        Variant* values_var = json.getMember("values");
        if (!values_var || !values_var.isObject)
        {
            HTTPMessage response = create_response(request.http_version, 400, StringLit!"Bad Request", StringLit!"application/json", "{\"error\":\"Missing 'values' object\"}");
            add_cors_headers(response);
            stream.write(response.format_message()[]);
            return 0;
        }

        Array!char response_json;
        response_json.reserve(1024);
        response_json ~= "{\"results\":{";

        bool first = true;
        size_t success_count = 0;
        size_t error_count = 0;

        foreach (key, ref value; *values_var)
        {
            if (!first)
                response_json ~= ',';
            first = false;

            const(char)[] path = key;

            response_json.append('\"', path, "\":");

            const(char)[] device_id = path.split!'.';
            if (Device* dev = device_id in g_app.devices)
            {
                if (path.empty)
                {
                    response_json ~= "{\"success\":false,\"error\":\"Cannot set device itself\"}";
                    ++error_count;
                }
                else
                {
                    Element* elem = dev.find_element(path);
                    if (!elem)
                    {
                        response_json ~= "{\"success\":false,\"error\":\"Element not found\"}";
                        ++error_count;
                    }
                    else if (elem.access == Access.read)
                    {
                        response_json ~= "{\"success\":false,\"error\":\"Element is read-only\"}";
                        ++error_count;
                    }
                    else
                    {
                        // TODO: is there any massaging for json type to data type we need to do here?
                        elem.value = value;
                        response_json ~= "{\"success\":true}";
                        ++success_count;
                    }
                }
            }
            else
            {
                response_json ~= "{\"success\":false,\"error\":\"Device not found\"}";
                ++error_count;
            }
        }

        response_json ~= '}';

        HTTPMessage response = create_response(request.http_version, 200, StringLit!"OK", StringLit!"application/json", response_json[]);
        add_cors_headers(response);
        stream.write(response.format_message()[]);

        return 0;
    }

    int handle_list(ref const HTTPMessage request, ref Stream stream)
    {
        import urt.string;
        import urt.mem.temp;

        Variant json = parse_json(cast(char[])request.content[]);

        if (!json.isObject)
        {
            HTTPMessage response = create_response(request.http_version, 400, StringLit!"Bad Request", StringLit!"application/json", "{\"error\":\"Invalid JSON\"}");
            add_cors_headers(response);
            stream.write(response.format_message()[]);
            return 0;
        }

        const(char)[] path;
        const(Variant)* path_var = json.getMember("path");
        if (path_var && !path_var.isNull)
            path = path_var.asString();

        bool shallow = false;
        const(Variant)* shallow_var = json.getMember("shallow");
        if (shallow_var && shallow_var.isBool)
            shallow = shallow_var.asBool();

        Array!char response_json;
        response_json.reserve(4096);
        response_json ~= '{';

        if (path.empty)
        {
            bool first = true;
            foreach (dev; g_app.devices.values)
            {
                if (!first)
                    response_json ~= ',';
                first = false;

                build_component_list(dev, response_json, shallow, true);
            }
        }
        else
        {
            const(char)[] device_id = path.split!'.';
            if (Device* dev = device_id in g_app.devices)
            {
                if (path.empty)
                    build_component_list(*dev, response_json, shallow, true);
                else
                {
                    Component comp = dev.find_component(path);
                    if (comp)
                        build_component_list(comp, response_json, shallow, false);
                }
            }
        }

        response_json ~= '}';

        HTTPMessage response = create_response(request.http_version, 200, StringLit!"OK", StringLit!"application/json", response_json[]);
        add_cors_headers(response);
        stream.write(response.format_message()[]);

        return 0;
    }

    void build_component_list(Component comp, ref Array!char json, bool shallow, bool is_device = false)
    {
        json.append('\"', comp.id[], "\":{\"type\":\"", is_device ? "device" : "component", "\",\"template\":\"", comp.template_[], "\",\"components\":", shallow ? '[' : '{');

        bool first = true;
        foreach (child; comp.components)
        {
            if (!first)
                json ~= ',';
            first = false;
            if (shallow)
                json.append('\"', child.id[], '\"');
            else
                build_component_list(child, json, false);
        }

        json.append(shallow ? ']' : '}', ",\"elements\":{");

        first = true;
        foreach (ref Element* elem; comp.elements)
        {
            import urt.si.quantity;
            import urt.si.unit;

            if (!first)
                json ~= ',';
            first = false;

            json.append('\"', elem.id[], "\":{");
            if (!elem.name.empty)
                json.append("\"name\":\"", elem.name[], "\",");
            if (!elem.desc.empty)
                json.append("\"desc\":\"", elem.desc[], "\",");
            json.append("\"access\":\"", g_access_strings[elem.access], '\"');

            if (!elem.display_unit.empty)
                json.append(",\"unit\":\"", elem.display_unit[], '\"');
            else if (elem.latest.isQuantity)
            {
                auto quantity = elem.latest.asQuantity!double();
                if (quantity.unit.pack != 0)
                    json.append(",\"unit\":\"", quantity.unit, '\"');
            }

            json ~= '}';
        }
        json ~= "}}";
    }

    void update_pending_requests()
    {
        size_t i = 0;
        while (i < _pending_requests.length)
        {
            ref PendingRequest req = _pending_requests[i];

            if (req.command.update() == CommandCompletionState.in_progress)
            {
                ++i;
                continue;
            }

            MutableString!0 output = req.session.takeOutput();
            send_cli_response(req.ver, req.stream, output[]);

            defaultAllocator().freeT(req.session);
            _pending_requests.remove(i);
        }
    }
}


class APIModule : Module
{
    mixin DeclareModule!"apps.api";
nothrow @nogc:

    Collection!APIManager managers;

    override void init()
    {
        g_app.console.register_collection("/apps/api", managers);
    }

    override void update()
    {
        managers.update_all();
    }
}


private:

__gshared immutable string[] g_access_strings = [ "r", "w", "rw" ];
