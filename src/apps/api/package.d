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

import manager.secret;

import protocol.http;
import protocol.http.message;
import protocol.http.server;
import protocol.http.websocket;

import router.stream;

//version = DebugAPI;

nothrow @nogc:


alias APIHandler = int delegate(const(char)[] uri, ref const HTTPMessage request, ref Stream stream) nothrow @nogc;


class APIManager: BaseObject
{
    __gshared Property[4] Properties = [ Property.create!("http-server", http_server)(),
                                         Property.create!("uri", uri)(),
                                         Property.create!("ws-uri", ws_uri)(),
                                         Property.create!("allow-anonymous", allow_anonymous)() ];
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

    const(char)[] ws_uri() const pure
        => _ws_uri[];
    void ws_uri(const(char)[] value)
    {
        _ws_uri = value.makeString(g_app.allocator);
    }

    bool allow_anonymous() const pure
        => _allow_anonymous;
    void allow_anonymous(bool value)
    {
        _allow_anonymous = value;
    }

    // BaseObject overrides

    override bool validate() const pure
        => _server !is null;

    override CompletionStatus validating()
    {
        if (_server.detached)
        {
            import protocol.http;
            if (HTTPServer s = get_module!HTTPModule.servers.get(_server.name[]))
                _server = s;
        }
        return super.validating();
    }

    override CompletionStatus startup()
    {
        if (_uri)
        {
            _server.add_uri_handler(HTTPMethod.GET, _uri[], &handle_request);
            _server.add_uri_handler(HTTPMethod.POST, _uri[], &handle_request);
            _server.add_uri_handler(HTTPMethod.OPTIONS, _uri[], &handle_request);
        }
        else
            _default_handler = _server.hook_global_handler(&handle_request);

        if (_ws_uri)
        {
            import urt.mem.temp : tconcat;

            _ws_server = get_module!HTTPModule.ws_servers.create(
                tconcat(name[], "-ws"),
                cast(ObjectFlags)(ObjectFlags.dynamic));
            if (_ws_server)
            {
                _ws_server.http_server(_server);
                _ws_server.uri(_ws_uri[]);
                _ws_server.set_connection_callback(&on_ws_connect);
            }
        }

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        // Clean up all WebSocket clients
        foreach (client; _ws_clients[])
            cleanup_ws_client(client);
        _ws_clients.clear();
        _dirty_elements.clear();
        _dirty_items.clear();

        // TODO: need to unlink HTTP handlers and destroy _ws_server
        return CompletionStatus.complete;
    }

    override void update()
    {
        update_pending_requests();
        update_ws_clients();
    }

private:
    ObjectRef!HTTPServer _server;
    String _uri;
    String _ws_uri;
    bool _allow_anonymous;

    HTTPServer.RequestHandler _default_handler;

    // WebSocket state
    WebSocketServer _ws_server;
    Array!(WSClient*) _ws_clients;
    Array!(Element*) _dirty_elements;
    Map!(Element*, uint) _element_refs;
    Array!BaseObject _dirty_items;
    Map!(BaseObject, uint) _item_refs;

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

        if (!_allow_anonymous && !check_basic_auth(request))
            return send_unauthorized(request, stream);

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

        version (DebugAPI)
            writeDebug("API request: ", request.method, " ", request.request_target);

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
        if (!_allow_anonymous)
            response.headers ~= HTTPParam(StringLit!"Access-Control-Allow-Headers", StringLit!"Authorization");
        response.headers ~= HTTPParam(StringLit!"Access-Control-Max-Age", StringLit!"86400");
        stream.write(response.format_message()[]);
        return 0;
    }

    int handle_health(ref const HTTPMessage request, ref Stream stream)
    {
        version (DebugAPI)
            writeDebug("API request: ", request.method, " ", request.request_target);

        HTTPMessage response = create_response(request.http_version, 200, StringLit!"OK", StringLit!"application/json", tconcat("{\"status\":\"healthy\",\"uptime\":", getAppTime().as!"seconds", "}"));
        add_cors_headers(response);
        stream.write(response.format_message()[]);
        return 0;
    }

    int send_unauthorized(ref const HTTPMessage request, ref Stream stream)
    {
        HTTPMessage response = create_response(request.http_version, 401, StringLit!"Unauthorized", StringLit!"application/json", "{\"error\":\"Authentication required\"}");
        add_cors_headers(response);
        response.headers ~= HTTPParam(StringLit!"WWW-Authenticate", StringLit!"Basic realm=\"OpenWatt\"");
        stream.write(response.format_message()[]);
        return 0;
    }

    bool check_basic_auth(ref const HTTPMessage request)
    {
        import urt.encoding : base64_decode, base64_decode_length;

        const(char)[] auth = request.header("Authorization")[];
        if (auth.length < 6 || auth[0 .. 6] != "Basic ")
            return false;

        const(char)[] encoded = auth[6 .. $];
        if (encoded.length == 0)
            return false;

        ubyte[256] buf = void;
        size_t max_len = base64_decode_length(encoded.length);
        if (max_len > buf.length)
            return false;

        ptrdiff_t len = base64_decode(encoded, buf[0 .. max_len]);
        if (len <= 0)
            return false;

        const(char)[] credentials = cast(const(char)[])buf[0 .. len];

        size_t colon = credentials.length;
        foreach (i, c; credentials)
        {
            if (c == ':')
            {
                colon = i;
                break;
            }
        }
        if (colon >= credentials.length)
            return false;

        const(char)[] username = credentials[0 .. colon];
        const(char)[] password = credentials[colon + 1 .. $];

        Secret secret = g_app.secrets.get(username);
        if (!secret)
            return false;

        return secret.validate_password(password) && secret.allow_service("api");
    }

    int handle_cli_execute(ref const HTTPMessage request, ref Stream stream)
    {
        Variant json;
        const(char)[] command_text;
        if (request.method == HTTPMethod.GET)
        {
            command_text = request.param("command")[];
        }
        else
        {
            json = parse_json(cast(char[])request.content[]);
            command_text = json.getMember("command").asString();
        }

        version (DebugAPI)
            writeDebug("API request: ", request.method, " ", request.request_target, " - ", command_text);

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

        // TODO: if it's a persistent session; we need a reference to the session to produce a response.
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
                    json.append(",\"flags\":\"", (prop.flags & 1) ? "*" : "", (prop.flags & 2) ? "D" : "", (prop.flags & 4) ? "H" : "", '\"');

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

        version (DebugAPI)
            writeDebug("API request: ", request.method, " ", request.request_target, " - ", name);

        Array!char json;
        if (!e)
        {
            writeWarning("API enum request for unknown enum: ", name);
            json = "{}";
        }
        else
        {
            json.reserve(1024);
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

        version (DebugAPI)
            writeDebug("API request: ", request.method, " ", request.request_target, " - ", paths);

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
                    append_element(json, first, prefix[], elem);
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
                    append_element(json, first, prefix[], elem);
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

        version (DebugAPI)
            writeDebug("API request: ", request.method, " ", request.request_target, " - ", *values_var);

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

        response_json ~= "}}";

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

    // ---- WebSocket push API ----

    struct WSClient
    {
    nothrow @nogc:
        APIManager api;
        WebSocket socket;
        bool authenticated;
        Secret pending_secret;
        ubyte[16] challenge_salt;
        HashFunction challenge_algorithm;
        Map!(Element*, String) element_subs;
        Map!(BaseObject, String) item_subs;

        void on_message(const(ubyte)[] message, WSMessageType message_type)
        {
            api.process_ws_message(&this, message, message_type);
        }
    }

    void on_ws_connect(WebSocket ws, void*)
    {
        WSClient* client = defaultAllocator().allocT!WSClient();
        client.api = this;
        client.socket = ws;
        ws.set_message_handler(&client.on_message);
        _ws_clients ~= client;
    }

    void update_ws_clients()
    {
        // Remove disconnected clients
        size_t i = 0;
        while (i < _ws_clients.length)
        {
            WSClient* client = _ws_clients[i];
            if (!client.socket || !client.socket.running)
            {
                cleanup_ws_client(client);
                _ws_clients.remove(i);
            }
            else
                ++i;
        }

        // Push dirty element updates
        if (_dirty_elements.length > 0 && _ws_clients.length > 0)
            push_dirty_elements();
        _dirty_elements.clear();

        // Push dirty item updates
        if (_dirty_items.length > 0 && _ws_clients.length > 0)
            push_dirty_items();
        _dirty_items.clear();
    }

    void cleanup_ws_client(WSClient* client)
    {
        // Unsubscribe from elements
        foreach (kv; client.element_subs[])
        {
            Element* elem = cast(Element*)kv.key;
            if (uint* rc = elem in _element_refs)
            {
                if (--(*rc) == 0)
                {
                    elem.remove_subscriber(&on_element_change);
                    _element_refs.remove(elem);
                }
            }
        }

        // Unsubscribe from items
        foreach (kv; client.item_subs[])
        {
            BaseObject obj = cast(BaseObject)kv.key;
            if (uint* rc = obj in _item_refs)
            {
                if (--(*rc) == 0)
                {
                    obj.unsubscribe(&on_item_state_change);
                    _item_refs.remove(obj);
                }
            }
        }

        defaultAllocator().freeT(client);
    }

    void process_ws_message(WSClient* client, const(ubyte)[] message, WSMessageType message_type)
    {
        if (message_type != WSMessageType.text)
            return;

        Variant json = parse_json(cast(const(char)[])message);
        if (!json.isObject)
            return;

        const(char)[] msg_type = json.getMember("type").asString();

        if (msg_type == "hello")
            handle_ws_hello(client, json);
        else if (msg_type == "auth")
            handle_ws_auth(client, json);
        else if (msg_type == "subscribe")
            handle_ws_subscribe(client, json);
        else if (msg_type == "unsubscribe")
            handle_ws_unsubscribe(client, json);
    }

    void handle_ws_hello(WSClient* client, ref Variant json)
    {
        if (_allow_anonymous)
        {
            client.authenticated = true;
            client.socket.send_text("{\"type\":\"welcome\"}");
            return;
        }

        const(char)[] username = json.getMember("username").asString();
        if (username.empty)
        {
            client.socket.send_text("{\"type\":\"error\",\"message\":\"Username required\"}");
            return;
        }

        Secret secret = g_app.secrets.get(username);
        if (!secret)
        {
            client.socket.send_text("{\"type\":\"error\",\"message\":\"Authentication failed\"}");
            return;
        }

        client.pending_secret = secret;

        // Determine challenge parameters
        if (client.pending_secret.algorithm == HashFunction.plain_text)
        {
            // Generate random salt for plain_text secrets
            import urt.rand : rand;
            for (size_t i = 0; i < 16; i += uint.sizeof)
                *cast(uint*)&client.challenge_salt[i] = rand();
            client.challenge_algorithm = HashFunction.sha256;
        }
        else
        {
            client.challenge_salt = client.pending_secret.get_salt()[0 .. 16];
            client.challenge_algorithm = client.pending_secret.algorithm;
        }

        // Send challenge
        Array!char response;
        response.reserve(128);
        response ~= "{\"type\":\"auth_challenge\",\"salt\":\"";
        hex_encode(client.challenge_salt[], response);
        response ~= "\",\"algorithm\":\"";
        const(char)[] algo_name = enum_key_from_value!HashFunction(client.challenge_algorithm);
        response ~= algo_name;
        response ~= "\"}";
        client.socket.send_text(response[]);
    }

    void handle_ws_auth(WSClient* client, ref Variant json)
    {
        if (!client.pending_secret)
        {
            client.socket.send_text("{\"type\":\"error\",\"message\":\"No pending authentication\"}");
            return;
        }

        const(char)[] hash_hex = json.getMember("hash").asString();
        if (hash_hex.empty)
        {
            client.socket.send_text("{\"type\":\"error\",\"message\":\"Hash required\"}");
            return;
        }

        Array!ubyte client_hash = hex_decode(hash_hex);

        if (client.pending_secret.validate_challenge_response(
            client_hash[], client.challenge_salt[], client.challenge_algorithm))
        {
            if (client.pending_secret.allow_service("api"))
            {
                client.authenticated = true;
                client.pending_secret = null;
                client.socket.send_text("{\"type\":\"welcome\"}");
            }
            else
            {
                client.pending_secret = null;
                client.socket.send_text("{\"type\":\"error\",\"message\":\"No API access\"}");
            }
        }
        else
        {
            client.pending_secret = null;
            client.socket.send_text("{\"type\":\"error\",\"message\":\"Authentication failed\"}");
        }
    }

    void handle_ws_subscribe(WSClient* client, ref Variant json)
    {
        if (!client.authenticated)
        {
            client.socket.send_text("{\"type\":\"error\",\"message\":\"Not authenticated\"}");
            return;
        }

        // Handle element subscriptions
        const(Variant)* elements_var = json.getMember("elements");
        if (elements_var && elements_var.isArray)
        {
            Array!char snapshot;
            snapshot.reserve(4096);
            snapshot ~= "{\"type\":\"element_snapshot\",\"values\":{";
            bool first = true;

            for (size_t i = 0; i < elements_var.length(); ++i)
            {
                const(char)[] pattern = (*elements_var)[i].asString();
                if (!pattern.empty)
                    resolve_and_subscribe_elements(client, pattern, snapshot, first);
            }

            snapshot ~= "}}";
            client.socket.send_text(snapshot[]);
        }

        // Handle item subscriptions
        const(Variant)* items_var = json.getMember("items");
        if (items_var && items_var.isArray)
        {
            Array!char snapshot;
            snapshot.reserve(4096);
            snapshot ~= "{\"type\":\"item_snapshot\",\"items\":{";
            bool first = true;

            for (size_t i = 0; i < items_var.length(); ++i)
            {
                const(char)[] pattern = (*items_var)[i].asString();
                if (!pattern.empty)
                    resolve_and_subscribe_items(client, pattern, snapshot, first);
            }

            snapshot ~= "}}";
            client.socket.send_text(snapshot[]);
        }
    }

    void handle_ws_unsubscribe(WSClient* client, ref Variant json)
    {
        if (!client.authenticated)
            return;

        // Handle element unsubscriptions
        const(Variant)* elements_var = json.getMember("elements");
        if (elements_var && elements_var.isArray)
        {
            Array!(Element*) to_remove;
            foreach (kv; client.element_subs[])
            {
                for (size_t i = 0; i < elements_var.length(); ++i)
                {
                    const(char)[] pattern = (*elements_var)[i].asString();
                    if (path_matches_pattern(kv.value[], pattern))
                    {
                        to_remove ~= cast(Element*)kv.key;
                        break;
                    }
                }
            }
            foreach (elem; to_remove[])
            {
                client.element_subs.remove(elem);
                if (uint* rc = elem in _element_refs)
                {
                    if (--(*rc) == 0)
                    {
                        elem.remove_subscriber(&on_element_change);
                        _element_refs.remove(elem);
                    }
                }
            }
        }

        // Handle item unsubscriptions
        const(Variant)* items_var = json.getMember("items");
        if (items_var && items_var.isArray)
        {
            Array!BaseObject to_remove;
            foreach (kv; client.item_subs[])
            {
                for (size_t i = 0; i < items_var.length(); ++i)
                {
                    const(char)[] pattern = (*items_var)[i].asString();
                    if (path_matches_pattern(kv.value[], pattern))
                    {
                        to_remove ~= cast(BaseObject)kv.key;
                        break;
                    }
                }
            }
            foreach (obj; to_remove[])
            {
                client.item_subs.remove(obj);
                if (uint* rc = obj in _item_refs)
                {
                    if (--(*rc) == 0)
                    {
                        obj.unsubscribe(&on_item_state_change);
                        _item_refs.remove(obj);
                    }
                }
            }
        }
    }

    void resolve_and_subscribe_elements(WSClient* client, const(char)[] pattern, ref Array!char snapshot, ref bool first)
    {
        // Parse pattern: "device.component.element" with wildcard support
        const(char)[] path = pattern;
        const(char)[] device_id = path.split!'.';

        MutableString!0 prefix;
        prefix.reserve(256);

        if (device_id == "*")
        {
            foreach (dev; g_app.devices.values)
                subscribe_elements_from_component(client, dev, path, snapshot, first, prefix);
        }
        else
        {
            if (Device* dev = device_id in g_app.devices)
                subscribe_elements_from_component(client, *dev, path, snapshot, first, prefix);
        }
    }

    void subscribe_elements_from_component(WSClient* client, Component comp, const(char)[] path, ref Array!char snapshot, ref bool first, ref MutableString!0 prefix)
    {
        if (path.empty)
            return;
        const(char)[] next = path.split!'.';

        if (next == "*")
        {
            subscribe_elements_wildcard(client, comp, path, snapshot, first, prefix);
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
                    subscribe_single_element(client, elem, prefix[], snapshot, first);
            }
            else
            {
                Component child = comp.find_component(next);
                if (child)
                    subscribe_elements_from_component(client, child, path, snapshot, first, prefix);
            }
        }
    }

    void subscribe_elements_wildcard(WSClient* client, Component comp, const(char)[] path, ref Array!char snapshot, ref bool first, ref MutableString!0 prefix)
    {
        size_t prefix_len = prefix.length;
        scope(exit) prefix.erase(prefix_len, prefix.length - prefix_len);

        if (prefix_len == 0)
            prefix = comp.id[];
        else
            prefix.append('.', comp.id[]);

        if (path.empty)
        {
            foreach (ref Element* elem; comp.elements)
                subscribe_single_element(client, elem, prefix[], snapshot, first);
        }
        else
        {
            const(char)[] path_copy = path;
            const(char)[] next = path_copy.split!'.';

            if (next == "*")
            {
                foreach (Component child; comp.components)
                    subscribe_elements_wildcard(client, child, path_copy, snapshot, first, prefix);
            }
            else if (path_copy.empty)
            {
                if (Element* elem = comp.find_element(next))
                    subscribe_single_element(client, elem, prefix[], snapshot, first);
            }
            else foreach (Component child; comp.components)
            {
                if (child.id[] == next)
                    subscribe_elements_from_component(client, child, path_copy, snapshot, first, prefix);
            }
        }

        foreach (Component child; comp.components)
            subscribe_elements_wildcard(client, child, path, snapshot, first, prefix);
    }

    void subscribe_single_element(WSClient* client, Element* elem, const(char)[] prefix, ref Array!char snapshot, ref bool first)
    {
        // Build full path
        MutableString!0 full_path;
        full_path.append(prefix, '.', elem.id[]);

        // Skip if already subscribed
        if (elem in client.element_subs)
            return;

        // Add to client's subscriptions
        client.element_subs.insert(elem, full_path[].makeString(defaultAllocator()));

        // Bump global refcount, subscribe if new
        if (uint* rc = elem in _element_refs)
            ++(*rc);
        else
        {
            _element_refs.insert(elem, 1);
            elem.add_subscriber(&on_element_change);
        }

        // Add to snapshot
        append_element(snapshot, first, prefix, elem);
    }

    void resolve_and_subscribe_items(WSClient* client, const(char)[] pattern, ref Array!char snapshot, ref bool first)
    {
        // Parse pattern: "/collection/path/object_name" or "/collection/path/*"
        // Find last '/' to split collection path from object name
        size_t last_slash = 0;
        foreach (i, c; pattern)
        {
            if (c == '/')
                last_slash = i;
        }

        if (last_slash == 0)
            return;

        const(char)[] col_path = pattern[0 .. last_slash];
        const(char)[] obj_name = pattern[last_slash + 1 .. $];

        // Find collection by path
        BaseCollection* col = null;
        foreach (ref reg; g_app.collections.values)
        {
            if (reg.path[] == col_path)
            {
                col = reg.collection;
                break;
            }
        }

        if (!col)
            return;

        if (obj_name == "*")
        {
            foreach (obj; col.pool.values)
                subscribe_single_item(client, obj, col_path, snapshot, first);
        }
        else
        {
            if (BaseObject obj = col.get(obj_name))
                subscribe_single_item(client, obj, col_path, snapshot, first);
        }
    }

    void subscribe_single_item(WSClient* client, BaseObject obj, const(char)[] col_path, ref Array!char snapshot, ref bool first)
    {
        if (obj in client.item_subs)
            return;

        // Build full path: "/collection/path/object_name"
        MutableString!0 full_path;
        full_path.append(col_path, '/', obj.name[]);
        client.item_subs.insert(obj, full_path[].makeString(defaultAllocator()));

        // Bump global refcount, subscribe if new
        if (uint* rc = obj in _item_refs)
            ++(*rc);
        else
        {
            _item_refs.insert(obj, 1);
            obj.subscribe(&on_item_state_change);
        }

        // Add to snapshot
        append_item_snapshot(snapshot, first, col_path, obj);
    }

    void append_item_snapshot(ref Array!char json, ref bool first, const(char)[] col_path, BaseObject obj)
    {
        if (!first)
            json ~= ',';
        first = false;

        json.append('\"', col_path, '/', obj.name[], "\":{\"state\":\"");
        if (obj.running)
            json ~= "running";
        else
            json ~= "stopped";
        json ~= "\",\"properties\":{";

        // Emit readable properties
        bool first_prop = true;
        foreach (prop; obj.properties)
        {
            if (!prop.get)
                continue;

            if (!first_prop)
                json ~= ',';
            first_prop = false;

            json.append('\"', prop.name[], "\":");
            Variant val = prop.get(obj);
            size_t bytes = val.write_json(null);
            val.write_json(json.extend(bytes));
        }
        json ~= "}}";
    }

    // Element change callback (matches OnChangeCallback)
    void on_element_change(ref Element e, ref const Variant val, SysTime timestamp, ref const Variant prev, SysTime prev_timestamp)
    {
        foreach (d; _dirty_elements[])
            if (d == &e)
                return;
        _dirty_elements ~= &e;
    }

    // Item state change callback (matches StateSignalHandler)
    void on_item_state_change(BaseObject obj, StateSignal signal)
    {
        if (signal == StateSignal.online || signal == StateSignal.offline)
        {
            foreach (d; _dirty_items[])
                if (d is obj)
                    return;
            _dirty_items ~= obj;
        }
    }

    void push_dirty_elements()
    {
        // Build per-client update messages
        foreach (client; _ws_clients[])
        {
            if (!client.authenticated)
                continue;

            Array!char msg;
            bool first = true;

            foreach (elem; _dirty_elements[])
            {
                if (String* path = elem in client.element_subs)
                {
                    if (first)
                    {
                        msg.reserve(1024);
                        msg ~= "{\"type\":\"element_update\",\"values\":{";
                    }
                    // Extract prefix (path without last component which is element id)
                    const(char)[] full = (*path)[];
                    const(char)[] prefix = full;
                    size_t last_dot = 0;
                    foreach (j, c; full)
                    {
                        if (c == '.')
                            last_dot = j;
                    }
                    if (last_dot > 0)
                        prefix = full[0 .. last_dot];

                    append_element(msg, first, prefix, elem);
                }
            }

            if (!first)
            {
                msg ~= "}}";
                client.socket.send_text(msg[]);
            }
        }
    }

    void push_dirty_items()
    {
        foreach (client; _ws_clients[])
        {
            if (!client.authenticated)
                continue;

            Array!char msg;
            bool first = true;

            foreach (obj; _dirty_items[])
            {
                if (String* path = obj in client.item_subs)
                {
                    if (first)
                    {
                        msg.reserve(512);
                        msg ~= "{\"type\":\"item_update\",\"items\":{";
                    }

                    if (!first)
                        msg ~= ',';
                    first = false;

                    msg.append('\"', (*path)[], "\":{\"state\":\"");
                    if (obj.running)
                        msg ~= "running";
                    else
                        msg ~= "stopped";
                    msg ~= "\"}";
                }
            }

            if (!first)
            {
                msg ~= "}}";
                client.socket.send_text(msg[]);
            }
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

__gshared immutable string[4] g_access_strings = [ "", "r", "w", "rw" ];

void hex_encode(const(ubyte)[] data, ref Array!char output)
{
    static immutable char[16] hex_digits = "0123456789abcdef";
    foreach (b; data)
    {
        output ~= hex_digits[b >> 4];
        output ~= hex_digits[b & 0xf];
    }
}

Array!ubyte hex_decode(const(char)[] hex)
{
    Array!ubyte result;
    result.reserve(hex.length / 2);
    for (size_t i = 0; i + 1 < hex.length; i += 2)
    {
        result ~= cast(ubyte)((hex_val(hex[i]) << 4) | hex_val(hex[i + 1]));
    }
    return result;
}

ubyte hex_val(char c)
{
    if (c >= '0' && c <= '9') return cast(ubyte)(c - '0');
    if (c >= 'a' && c <= 'f') return cast(ubyte)(c - 'a' + 10);
    if (c >= 'A' && c <= 'F') return cast(ubyte)(c - 'A' + 10);
    return 0;
}

bool path_matches_pattern(const(char)[] path, const(char)[] pattern)
{
    if (pattern == path)
        return true;

    // Determine separator based on path type (items start with '/')
    if (path.length > 0 && path[0] == '/')
        return match_components!'/'(path, pattern);
    else
        return match_components!'.'(path, pattern);
}

bool match_components(char sep)(const(char)[] path, const(char)[] pattern)
{
    while (!pattern.empty && !path.empty)
    {
        const(char)[] pat_part = pattern.split!sep;
        const(char)[] path_part = path.split!sep;

        if (pat_part != "*" && pat_part != path_part)
            return false;
    }

    return pattern.empty && path.empty;
}
