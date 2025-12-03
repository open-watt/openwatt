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
import manager.console;
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

    enum TypeName = StringLit!"api";

    this(String name, ObjectFlags flags = ObjectFlags.None)
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

        return CompletionStatus.Complete;
    }

    override CompletionStatus shutdown()
    {
        // TODO: need to unlink these things...
        return CompletionStatus.Complete;
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
            auto buf = cast(char[])talloc(bytes);
            v.write_json(buf);
            response.content ~= buf[];
            response.content ~= "}";
        }
        else
            response.content ~= "\"\"}";
        add_cors_headers(response);
        stream.write(response.format_message()[]);
    }

    void update_pending_requests()
    {
        size_t i = 0;
        while (i < _pending_requests.length)
        {
            ref PendingRequest req = _pending_requests[i];

            if (req.command.update() == CommandCompletionState.InProgress)
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
        g_app.console.registerCollection("/apps/api", managers);
    }

    override void update()
    {
        managers.update_all();
    }
}
