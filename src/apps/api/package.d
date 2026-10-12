module apps.api;

import urt.array;
import urt.format.json;
import urt.lifetime;
import urt.log;
import urt.map;
import urt.mem;
import urt.mem.pagepool;
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
import manager.path : walk_elements;
import manager.plugin;
import manager.value : append_json;

import protocol.http.message;
import protocol.http.server;

import router.stream;

//version = DebugAPI;

nothrow @nogc:


alias APIHandler = int delegate(const(char)[] uri, ref const HTTPMessage request, ref Stream stream) nothrow @nogc;


final class APIManager : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("http-server", http_server),
                                 Prop!("uri", uri));
nothrow @nogc:

    ~this() {}

    enum type_name = "api";
    enum path = "/apps/api";
    enum collection_id = CollectionType.api;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!APIManager, id, flags);
    }

    HTTPServer http_server() const
        => _server_id.get_item!HTTPServer;
    void http_server(HTTPServer value)
    {
        _server_id = value.id;
        mark_set!(typeof(this), "http-server")();
    }

    const(char)[] uri() const pure
        => _uri[];
    void uri(const(char)[] value)
    {
        _uri = value.make_string();
        mark_set!(typeof(this), "uri")();
    }

protected:

    override bool validate() const pure
        => _server_id.get_item!HTTPServer !is null;

    override CompletionStatus startup()
    {
        HTTPServer _server = _server_id.get_item!HTTPServer;
        if (_uri)
        {
            _server.add_uri_handler(HTTPMethodSet.GET | HTTPMethodSet.POST | HTTPMethodSet.OPTIONS, _uri[], &handle_request);
        }
        else
            _default_handler = _server.hook_global_handler(&handle_request);

        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        foreach (cli; _cli)
            cli.command.request_cancel();
        update_commands();
        if (!_cli.empty)
            return CompletionStatus.continue_;

        // TODO: need to unlink these things...
        return CompletionStatus.complete;
    }

    override void update()
    {
        update_commands();
    }

private:
    CID _server_id;
    String _uri;
    HTTPServer.RequestHandler _default_handler;
    Array!(CliTx*) _cli;

    int handle_request(ref const HTTPMessage request, ref Stream stream, const(ubyte)[] leftover)
    {
        const(char)[] tail = request.request_target[_uri.length .. $];

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

        version (DebugAPI)
            writeDebug("API request: ", request.method, " ", request.request_target);

        foreach (handler; get_module!APIModule._custom_handlers[])
        {
            if (tail.startsWith(handler.key[]))
                return handler.value()(tail[handler.key.length .. $], request, stream);
        }

        if (_default_handler)
            _default_handler(request, stream, leftover);
        else if (_uri)
        {
            HTTPMessage response = create_response(request.http_version, 404, StringLit!"application/json", "{\"error\":\"Not Found\"}");
            add_cors(response, request);
            respond(stream, response);
        }

        return 0;
    }

    bool add_cors(ref HTTPMessage response, ref const HTTPMessage request)
        => add_cors(response, request.header("Origin")[]);

    bool add_cors(ref HTTPMessage response, const(char)[] origin)
    {
        HTTPServer server = _server_id.get_item!HTTPServer;
        return server ? server.add_cors(response, origin) : false;
    }

    int handle_options(ref const HTTPMessage request, ref Stream stream)
    {
        HTTPMessage response = create_response(request.http_version, 204, String(), null);
        if (add_cors(response, request))
        {
            response.headers ~= HTTPParam(StringLit!"Access-Control-Allow-Methods", StringLit!"GET, POST, PUT, DELETE, OPTIONS");
            response.headers ~= HTTPParam(StringLit!"Access-Control-Allow-Headers", StringLit!"Content-Type");
            response.headers ~= HTTPParam(StringLit!"Access-Control-Max-Age", StringLit!"86400");
        }
        respond(stream, response);
        return 0;
    }

    int handle_health(ref const HTTPMessage request, ref Stream stream)
    {
        version (DebugAPI)
            writeDebug("API request: ", request.method, " ", request.request_target);

        HTTPMessage response = create_response(request.http_version, 200, StringLit!"application/json", tconcat("{\"status\":\"healthy\",\"uptime\":", getAppTime().as!"seconds", "}"));
        add_cors(response, request);
        respond(stream, response);
        return 0;
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
            HTTPMessage response = create_response(request.http_version, 400, StringLit!"application/json", "{\"error\":\"Command body required\"}");
            add_cors(response, request);
            respond(stream, response);
            return 0;
        }

        // the output streams chunked, which HTTP/1.0 cannot frame; refuse before the command runs
        if (request.http_version < HTTPVersion.V1_1)
        {
            HTTPMessage response = create_response(request.http_version, 505, StringLit!"application/json", "{\"error\":\"HTTP/1.1 required\"}");
            add_cors(response, request);
            respond(stream, response);
            return 0;
        }

        ProducerSession session = g_app.console.createSession!ProducerSession();
        CliTx* cli = alloc!CliTx(stream, session);
        cli.text = "{\"output\":\"";
        cli.escape = JsonEscape(&session.produce);
        cli.command = g_app.console.execute(session, command_text, cli.result);
        cli.finished = cli.command is null;
        if (!cli.finished)
            _cli ~= cli;
        session.ready = &cli.wake;
        return respond_json(request, stream, &cli.produce, &cli.ended);
    }

    int respond_json(ref const HTTPMessage request, ref Stream stream, SendHandler body_, ResponseEnd ended)
    {
        HTTPMessage head = create_response(request.http_version, 200, StringLit!"application/json", null);
        add_cors(head, request);
        if (respond(stream, head, body_, unknown_length, ended))
            return 0;
        ended(false);
        return -1;
    }

    int handle_schema(ref const HTTPMessage request, ref Stream stream)
    {
        auto tx = alloc!(UnitProducer!SchemaUnits)(SchemaUnits(g_app.types.values));
        return respond_json(request, stream, &tx.produce, &tx.ended);
    }

    int handle_enum(ref const HTTPMessage request, ref Stream stream, const(char)[] name)
    {
        const(VoidEnumInfo)* e;
        if (!name.empty)
        {
            if (name[0] != '/')
            {
                HTTPMessage response = create_response(request.http_version, 404, StringLit!"application/json", "{\"error\":\"Not Found\"}");
                respond(stream, response);
                return 0;
            }
            name = name[1..$];

            import manager.sample : find_enum_info;
            e = find_enum_info(name);
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

        HTTPMessage response = create_response(request.http_version, 200, StringLit!"application/json", json[]);
        add_cors(response, request);
        respond(stream, response);
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
            HTTPMessage response = create_response(request.http_version, 400, StringLit!"application/json", "{\"error\":\"Invalid JSON\"}");
            add_cors(response, request);
            respond(stream, response);
            return 0;
        }

        const(Variant)* paths_var = json.getMember("paths");
        if (!paths_var || paths_var.isNull)
            paths_var = json.getMember("path");

        if (!paths_var || paths_var.isNull)
        {
            HTTPMessage response = create_response(request.http_version, 400, StringLit!"application/json", "{\"error\":\"Missing 'path' or 'paths' field\"}");
            add_cors(response, request);
            respond(stream, response);
            return 0;
        }

        auto tx = alloc!(UnitProducer!GetUnits)();
        if (paths_var.isArray)
        {
            for (size_t i = 0; i < paths_var.length(); ++i)
                tx.units.paths ~= (*paths_var)[i].asString().make_string();
        }
        else if (paths_var.isString)
            tx.units.paths ~= paths_var.asString().make_string();
        else
        {
            free(tx);
            HTTPMessage response = create_response(request.http_version, 400, StringLit!"application/json", "{\"error\":\"'path' or 'paths' must be string or array\"}");
            add_cors(response, request);
            respond(stream, response);
            return 0;
        }

        version (DebugAPI)
            writeDebug("API request: ", request.method, " ", request.request_target, " - ", tx.units.paths);

        foreach (dev; g_app.devices.values)
            tx.units.devices ~= dev.cid;
        return respond_json(request, stream, &tx.produce, &tx.ended);
    }

    int handle_set(ref const HTTPMessage request, ref Stream stream)
    {
        import urt.string;
        import urt.mem.temp;

        Variant json = parse_json(cast(char[])request.content[]);

        if (!json.isObject)
        {
            HTTPMessage response = create_response(request.http_version, 400, StringLit!"application/json", "{\"error\":\"Invalid JSON\"}");
            add_cors(response, request);
            respond(stream, response);
            return 0;
        }

        Variant* values_var = json.getMember("values");
        if (!values_var || !values_var.isObject)
        {
            HTTPMessage response = create_response(request.http_version, 400, StringLit!"application/json", "{\"error\":\"Missing 'values' object\"}");
            add_cors(response, request);
            respond(stream, response);
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

        HTTPMessage response = create_response(request.http_version, 200, StringLit!"application/json", response_json[]);
        add_cors(response, request);
        respond(stream, response);

        return 0;
    }

    int handle_list(ref const HTTPMessage request, ref Stream stream)
    {
        import urt.string;
        import urt.mem.temp;

        Variant json = parse_json(cast(char[])request.content[]);

        if (!json.isObject)
        {
            HTTPMessage response = create_response(request.http_version, 400, StringLit!"application/json", "{\"error\":\"Invalid JSON\"}");
            add_cors(response, request);
            respond(stream, response);
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

        auto tx = alloc!(UnitProducer!ListUnits)();
        tx.units.shallow = shallow;
        tx.units.rooted = !path.empty;
        if (path.empty)
        {
            foreach (dev; g_app.devices.values)
                tx.units.devices ~= dev.cid;
        }
        else
        {
            if (Device* dev = path.split!'.' in g_app.devices)
                tx.units.devices ~= dev.cid;
            tx.units.component = path.make_string();
        }
        return respond_json(request, stream, &tx.produce, &tx.ended);
    }

    void update_commands()
    {
        for (size_t i = 0; i < _cli.length; )
        {
            CliTx* cli = _cli[i];
            if (cli.command.update() < CommandCompletionState.finished)
            {
                ++i;
                continue;
            }
            cli.finished = true;
            _cli.remove(i);
            if (cli.ended_)
                cli.retire();
            else
                respond_more(cli.stream);
        }
    }
}


final class APIModule : Module
{
    mixin DeclareModule!"apps.api";
nothrow @nogc:

    Map!(String, APIHandler) _custom_handlers;

    override void init()
    {
        g_app.console.register_collection!APIManager();
    }

    override void update()
    {
        Collection!APIManager().update_all();
    }

    void register_api_handler(const(char)[] uri, APIHandler handler)
    {
        _custom_handlers.insert(uri.make_string(), handler);
    }
}


private:

__gshared immutable string[4] g_access_strings = [ "", "r", "w", "rw" ];

void append_element(ref Array!char json, ref bool listed, const(char)[] path, Element* elem)
{
    import urt.si.quantity;
    import urt.si.unit;

    if (listed)
        json ~= ',';
    listed = true;

    json.append('\"', path, "\":{\"value\":");

    Variant v = elem.value();
    if (v.isQuantity)
    {
        auto quantity = v.asQuantity!double();

        ScaledUnit su;
        float pre_scale;

        if (elem.display_unit && su.parseUnit(elem.display_unit[], pre_scale) > 0)
        {
            if (quantity.is_nan)
                json ~= "null";
            else
                json ~= quantity.adjust_scale(su).value / pre_scale;
            json.append(",\"unit\":\"", elem.display_unit[], '\"');
        }
        else
        {
            if (quantity.is_nan)
                json ~= "null";
            else
                json ~= quantity.value;

            if (quantity.unit.pack != 0)
                json.append(",\"unit\":\"", quantity.unit, '\"');
        }
    }
    else
        append_json(json, v);

    if (elem.sampling_mode != SamplingMode.constant)
    {
        ulong age = (getTime() - elem.last_update).as!"seconds";
        json.append(",\"age\":", age);
    }

    json ~= '}';
}

void build_component_list(Component comp, ref Array!char json, bool shallow, bool is_device = false, bool as_root = false)
{
    json.append('\"', comp.id[], "\":{\"type\":\"", is_device ? "device" : "component", "\",\"template\":\"", comp.template_[], '\"');
    if (comp.hidden)
        json ~= ",\"hidden\":true";

    bool prune = comp.hidden && !as_root;

    json.append(",\"components\":", shallow ? '[' : '{');

    bool first = true;
    if (!prune)
    {
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
    }

    json.append(shallow ? ']' : '}', ",\"elements\":{");

    first = true;
    if (!prune)
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

void emit_collection(ref Array!char json, ref const Application.RegisteredType col)
{
    bool is_collection = col.type_info.collection_root;
    json.append('\"', col.type_info.type[], "\":{\"collection_id\":", cast(uint)col.type_info.collection_id, ",\"path\":\"", col.path[], '\"');
    if (col.type_info.is_abstract)
        json ~= ",\"abstract\":true";
    if (is_collection)
        json ~= ",\"collection\":true";
    json ~= ",\"properties\":{";

    bool first_prop = true;
    foreach (prop; col.type_info.properties)
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
        {
            json ~= ",\"flags\":\"";
            if (prop.flags & 1)
                json ~= 'A';
            if (prop.flags & 2)
                json ~= 'D';
            if (prop.flags & 4)
                json ~= 'H';
            json ~= '\"';
        }

        if (prop.init_val)
        {
            Variant def = prop.init_val();
            json ~= ",\"default\":";
            append_json(json, def);
        }

        json ~= '}';
    }
    json ~= "}}";
}

// a JSON object made a unit at a time as the stream pulls it; it frees itself when its response ends
struct UnitProducer(Units)
{
nothrow @nogc:
    Units units;

    this(this) @disable;

    Page* produce(ref const TxRequest req, out TxStatus status)
    {
        while (sent == pending.length)
        {
            if (closed)
            {
                status = TxStatus.end;
                return null;
            }
            pending.clear();
            sent = 0;
            if (!opened)
                pending ~= '{';
            opened = true;
            if (!units.next(pending, listed))
            {
                pending ~= '}';
                closed = true;
            }
        }
        size_t take = pending.length - sent;
        if (take > req.bytes)
            take = req.bytes;
        Page* page = alloc_tx_page(req, take, status);
        if (!page)
            return null;
        (cast(char[])page.data)[] = pending[sent .. sent + take];
        sent += take;
        if (closed && sent == pending.length)
            status = TxStatus.end;
        return page;
    }

    void ended(bool)
    {
        free(&this);
    }

private:
    Array!char pending;
    size_t sent;
    bool opened;
    bool closed;
    bool listed;
}

struct SchemaUnits
{
nothrow @nogc:
    typeof(g_app.types.values()) types;

    bool next(ref Array!char json, ref bool listed)
    {
        if (types.empty)
            return false;
        if (listed)
            json ~= ',';
        listed = true;
        emit_collection(json, types.front);
        types.popFront();
        return true;
    }
}

struct GetUnits
{
nothrow @nogc:
    Array!String paths;
    Array!CID devices;
    size_t path;
    size_t device;

    bool next(ref Array!char json, ref bool listed)
    {
        if (path == paths.length || devices.empty)
            return false;
        if (Device dev = g_app.devices.container(devices[device]))
            walk_elements(dev, paths[path][], (Element* e, const(char)[] p) {
                append_element(json, listed, p, e);
            }, true);
        if (++device == devices.length)
        {
            device = 0;
            ++path;
        }
        return true;
    }
}

struct ListUnits
{
nothrow @nogc:
    Array!CID devices;
    String component;
    size_t device;
    bool shallow;
    bool rooted;

    this(this) @disable;

    bool next(ref Array!char json, ref bool listed)
    {
        if (device == devices.length)
            return false;
        Device dev = g_app.devices.container(devices[device++]);
        Component comp = !dev ? null : component.empty ? dev : dev.find_component(component[]);
        if (comp)
        {
            if (listed)
                json ~= ',';
            listed = true;
            build_component_list(comp, json, shallow, component.empty, rooted);
        }
        return true;
    }
}

// a command's output as it is made, then its result; it frees itself once both its response and its command are done
struct CliTx
{
nothrow @nogc:
    Stream stream;
    ProducerSession session;
    CommandState command;
    Variant result;
    JsonEscape escape;
    Array!char text;
    size_t sent;
    bool closing;
    bool finished;
    bool ended_;

    this(this) @disable;

    Page* produce(ref const TxRequest req, out TxStatus status)
    {
        if (sent == text.length && !closing)
        {
            Page* page = escape.produce(req, status);
            if (page || status != TxStatus.idle || !finished)
                return page;
            if (command)
                result = command.result;
            text.clear();
            sent = 0;
            text ~= "\",\"result\":";
            append_json(text, result);
            text ~= '}';
            closing = true;
        }
        size_t take = text.length - sent;
        if (take > req.bytes)
            take = req.bytes;
        Page* page = alloc_tx_page(req, take, status);
        if (!page)
            return null;
        (cast(char[])page.data)[] = text[sent .. sent + take];
        sent += take;
        if (closing && sent == text.length)
            status = TxStatus.end;
        return page;
    }

    void wake()
    {
        respond_more(stream);
    }

    void ended(bool)
    {
        ended_ = true;
        session.ready = null;
        if (finished)
            retire();
        else
            command.request_cancel();
    }

    void retire()
    {
        session.release();
        g_app.console.destroy_session(session);
        if (command)
            free(command);
        free(&this);
    }
}

// escapes in place as JSON string content; a byte may grow to six, so a sixth of the grant is payload
struct JsonEscape
{
nothrow @nogc:
    SendHandler inner;

    Page* produce(ref const TxRequest req, out TxStatus status)
    {
        size_t grant = req.bytes < max_tx_page ? req.bytes : max_tx_page;
        Page* page = inner(TxRequest(grant / 6, req.deadline, req.headroom, req.tailroom + grant - grant / 6), status);
        if (!page)
            return null;
        char[6] buffer = void;
        size_t n = page.length;
        size_t length = n;
        foreach (c; cast(const(char)[])page.data)
            length += escape(c, buffer).length - 1;
        page.length = cast(ushort)length;
        char[] text = cast(char[])page.data;
        while (n)
        {
            const(char)[] e = escape(text[--n], buffer);
            length -= e.length;
            text[length .. length + e.length] = e[];
        }
        return page;
    }

private:
    static const(char)[] escape(char c, return ref char[6] buffer)
    {
        buffer[0] = '\\';
        switch (c)
        {
            case '"':  buffer[1] = '"';  return buffer[0 .. 2];
            case '\\': buffer[1] = '\\'; return buffer[0 .. 2];
            case '\n': buffer[1] = 'n';  return buffer[0 .. 2];
            case '\r': buffer[1] = 'r';  return buffer[0 .. 2];
            case '\t': buffer[1] = 't';  return buffer[0 .. 2];
            default:
                if (c >= 0x20)
                {
                    buffer[0] = c;
                    return buffer[0 .. 1];
                }
                buffer[1 .. 4] = "u00";
                buffer[4] = "0123456789abcdef"[c >> 4];
                buffer[5] = "0123456789abcdef"[c & 0xF];
                return buffer[0 .. 6];
        }
    }
}
