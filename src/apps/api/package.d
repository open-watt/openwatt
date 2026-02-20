module apps.api;

import urt.array;
import urt.format.json;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem.allocator;
import urt.mem.temp;
import urt.meta.enuminfo;
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


alias APIHandler = int delegate(const(char)[] uri, ref const HTTPMessage request, ref Stream stream) nothrow @nogc;


class APIManager: BaseObject
{
    __gshared Property[2] Properties = [ Property.create!("http-server", http_server)(),
                                         Property.create!("uri", uri)() ];
nothrow @nogc:

    enum type_name = "api";

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
        if (tail == "/schema")
            return handle_schema(request, stream);
        if (tail.startsWith("/enum"))
            return handle_enum(request, stream, tail[5..$]);
        if (tail == "/get")
            return handle_get(request, stream);
        if (tail == "/set")
            return handle_set(request, stream);
        if (tail == "/list")
            return handle_list(request, stream);

        foreach (handler; get_module!APIModule._custom_handlers[])
        {
            if (tail.startsWith(handler.key[]))
                return handler.value()(tail[handler.key.length .. $], request, stream);
        }

        if (_default_handler)
            _default_handler(request, stream);
        else if (_uri)
        {
            HTTPMessage response = create_response(request.http_version, 404, StringLit!"Not Found", StringLit!"application/json", "{\"error\":\"Not Found\"}");
            stream.write(response.format_message()[]);
        }

        return 0;
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

        Variant result;
        StringSession session = g_app.console.createSession!StringSession();
        CommandState cmd = g_app.console.execute(session, command_text, result);
        if (cmd is null)
        {
            MutableString!0 output = session.takeOutput();
            send_cli_response(request.http_version, stream, output[], result);
            defaultAllocator().freeT(session);
            return 0;
        }

        // TODO: if it's a persistent seession; we need a reference to the session to produce a response.
        //       if it's an ephemeral session, we need to take the stream from the session so we can produce a deferred response...?
        assert(false, "TODO: TEST THIS PATH, I'M NOT SURE THE HTTP REQUEST HANDLER CAN HANDLE HANDLE RELAYED RESPONSE?");
        _pending_requests ~= PendingRequest(request.http_version, stream, session, cmd);
        return 0;
    }

    void send_cli_response(HTTPVersion http_version, ref Stream stream, const(char)[] output, ref Variant result)
    {
        HTTPMessage response = create_response(http_version, 200, StringLit!"OK", StringLit!"application/json", "{\"result\":");

        ptrdiff_t len = result.write_json(null, true, 0, 0);
        if (len > 0)
        {
            auto tmp = Array!char(Reserve, len);
            result.write_json(tmp.extend(len), true, 0, 0);
            response.content ~= tmp[];
        }
        else
            response.content ~= "null";
        response.content ~= ",\"output\":";

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

    int handle_schema(ref const HTTPMessage request, ref Stream stream)
    {
        Array!char json;
        json.reserve(4096);
        json ~= '{';

        bool first_col = true;
        foreach (col; g_app.collections.values)
        {
            if (!first_col)
                json ~= ',';
            first_col = false;

            json.append('\"', col.collection.type_info.type[], "\":{\"path\":\"", col.path[], "\",\"properties\":{");

            bool first_prop = true;
            foreach (prop; col.collection.type_info.properties)
            {
                if (!first_prop)
                    json ~= ',';
                first_prop = false;

                json.append('\"', prop.name[], "\":{\"access\":\"");
                if (prop.get && prop.set)
                    json ~= "rw";
                else if (prop.get)
                    json ~= "r";
                else if (prop.set)
                    json ~= "w";
                json ~= '\"';

                if (!prop.type[0].empty)
                {
                    json ~= ",\"type\":[";
                    json.append('\"', prop.type[0][], '\"');
                    if (!prop.type[1].empty)
                        json.append(",\"", prop.type[1][], '\"');
                    json ~= ']';
                }

                if (prop.category)
                    json.append(",\"category\":\"", prop.category[], '\"');

                if (prop.flags)
                    json.append(",\"flags\":\"", (prop.flags & 1) ? "H" : "", '\"');

                json ~= '}';
            }
            json ~= "}}";
        }
        json ~= '}';

        HTTPMessage response = create_response(request.http_version, 200, StringLit!"OK", StringLit!"application/json", json[]);
        add_cors_headers(response);
        stream.write(response.format_message()[]);
        return 0;
    }

    int handle_enum(ref const HTTPMessage request, ref Stream stream, const(char)[] name)
    {
        const(VoidEnumInfo)* e;
        if (!name.empty)
        {
            if (name[0] != '/')
            {
                HTTPMessage response = create_response(request.http_version, 404, StringLit!"Not Found", StringLit!"application/json", "{\"error\":\"Not Found\"}");
                stream.write(response.format_message()[]);
                return 0;
            }
            name = name[1..$];

            if (auto pe = name in g_app.enum_templates)
                e = *pe;
        }
        else
        {
            // parse json request for many enums...
            assert(false, "TODO");
        }

        Array!char json;
        if (!e)
        {
            writeWarning("API enum request for unknown enum: ", name);
            json = "{}";
        }
        else
        {
            json.reserve(512);
            json ~= '{';

            // TODO: just one for now...
//            bool first_enum = true;
//            foreach (kv; g_app.enums)
            {
//                if (!first_enum)
//                    json ~= ',';
//                first_enum = false;

                json.append('\"', name, "\":{");
                bool first_member = true;
                foreach (i; 0 .. e.count)
                {
                    if (!first_member)
                        json ~= ',';
                    first_member = false;

                    // TODO: return values and descriptions...
                    const(char)[] key = e.key_by_decl_index(i);
//                    json.append('\"', key, "\":", e.value_by_decl_index(i), '\"');
                    json.append('\"', key, "\":", e.value_for(key)); // TODO: there should be a function to fetch it by declaration index!
                }
                json ~= '}';
            }
            json ~= '}';
        }

        HTTPMessage response = create_response(request.http_version, 200, StringLit!"OK", StringLit!"application/json", json[]);
        add_cors_headers(response);
        stream.write(response.format_message()[]);
        return 0;
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

        ref const Variant v = elem.value();
        if (v.isQuantity)
        {
            auto quantity = v.asQuantity!double();

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
            size_t bytes = v.write_json(null);
            v.write_json(json.extend(bytes));
        }

        if (elem.sampling_mode != SamplingMode.constant)
        {
            ulong age = (getTime() - elem.last_update).as!"seconds";
            json.append(",\"age\":", age);
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
                        elem.value(value, request.timestamp);
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

            const(char)[] mode = enum_key_from_value!SamplingMode(elem.sampling_mode);
            if (mode)
                json.append(",\"mode\":\"", mode, '\"');

            if (!elem.display_unit.empty)
                json.append(",\"unit\":\"", elem.display_unit[], '\"');
            else if (elem.value.isQuantity)
            {
                auto quantity = elem.value.asQuantity!double();
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
            send_cli_response(req.ver, req.stream, output[], req.command.result);

            defaultAllocator().freeT(req.session);
            _pending_requests.remove(i);
        }
    }
}


class APIModule : Module
{
    mixin DeclareModule!"apps.api";
nothrow @nogc:

    Collection!APIManager _managers;

    Map!(String, APIHandler) _custom_handlers;

    override void init()
    {
        g_app.console.register_collection("/apps/api", _managers);
    }

    override void update()
    {
        _managers.update_all();
    }

    void register_api_handler(const(char)[] uri, APIHandler handler)
    {
        _custom_handlers.insert(uri.makeString(g_app.allocator), handler);
    }
}


private:

__gshared immutable string[] g_access_strings = [ "r", "w", "rw" ];
