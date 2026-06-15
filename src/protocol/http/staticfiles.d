module protocol.http.staticfiles;

import urt.array;
import urt.encoding;
import urt.file;
import urt.log;
import urt.mem.allocator;
import urt.mem.temp : tconcat;
import urt.string;
import urt.time : getSysTime;

import manager;
import manager.base;
import manager.collection;

import protocol.http.message;
import protocol.http.server;

import router.stream;

nothrow @nogc:


// Serves files from a filesystem directory beneath a URI root on an HTTPServer.
// A request for "<uri>/a/b.css" maps to "<root>/a/b.css"; a directory request
// (the URI root itself, or any path ending in '/') serves index.html / index.htm.
class StaticFileServer : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("http-server", http_server),
                                 Prop!("uri", uri),
                                 Prop!("root", root));
nothrow @nogc:

    enum type_name = "static";
    enum path = "/protocol/http/static";
    enum collection_id = CollectionType.http_static;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!StaticFileServer, id, flags);
    }

    // Properties

    inout(HTTPServer) http_server() inout
        => _server.get;
    void http_server(HTTPServer value)
    {
        if (_server.get is value)
            return;
        if (_registered)
        {
            if (HTTPServer old = _server.get)
            {
                old.remove_uri_handler(HTTPMethod.GET, &handle_request);
                old.unsubscribe(&server_state_change);
            }
            _registered = false;
        }
        _server = value;
        restart();
    }

    const(char)[] uri() const pure
        => _uri[];
    void uri(const(char)[] value)
    {
        // normalise to a leading-slash, no-trailing-slash prefix; "/" becomes empty (serve whole tree)
        while (value.length && value[$-1] == '/')
            value = value[0 .. $-1];
        if (value.length == 0)
            _uri = String();
        else if (value[0] == '/')
            _uri = value.makeString(g_app.allocator);
        else
            _uri = tconcat("/", value).makeString(g_app.allocator);
        restart();
    }

    const(char)[] root() const pure
        => _root[];
    void root(const(char)[] value)
    {
        _root = value.makeString(g_app.allocator);
        restart();
    }

protected:
    mixin RekeyHandler;

    override bool validate() const pure
        => _server.get !is null && !_root.empty;

    override CompletionStatus startup()
    {
        HTTPServer server = _server.get;
        if (!server)
            return CompletionStatus.continue_;

        if (!server.add_uri_handler(HTTPMethod.GET, _uri[], &handle_request))
        {
            writeWarning("static: failed to register handler for uri '", _uri[], "' (prefix conflict?)");
            return CompletionStatus.error;
        }
        server.subscribe(&server_state_change);
        _registered = true;
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_registered)
        {
            if (HTTPServer server = _server.get)
            {
                server.remove_uri_handler(HTTPMethod.GET, &handle_request);
                server.unsubscribe(&server_state_change);
            }
            _registered = false;
        }
        return CompletionStatus.complete;
    }

private:
    ObjectRef!HTTPServer _server;
    String _uri;
    String _root;
    bool _registered;

    void server_state_change(ActiveObject, StateSignal signal)
    {
        // a destroy/recreate of the server gives us a fresh (empty) handler set; re-register
        if (signal == StateSignal.offline)
            restart();
    }

    int handle_request(ref const HTTPMessage request, ref Stream stream, const(ubyte)[] leftover)
    {
        HTTPVersion ver = request.http_version;
        const(char)[] target = request.request_target[];

        // the server dispatches on a path-boundary longest-prefix match, so `rel` is
        // always empty or starts with '/'.
        const(char)[] rel = target[_uri.length .. $];

        bool want_index = rel.length == 0 || rel[$-1] == '/';
        while (rel.length && rel[0] == '/')
            rel = rel[1 .. $];

        char[1024] decode_buf = void;
        if (url_decode_length(rel) > decode_buf.length)
            return send_status(ver, stream, 414);
        ptrdiff_t decoded_len = url_decode(rel, decode_buf[]);
        if (decoded_len < 0)
            return send_status(ver, stream, 400);
        const(char)[] decoded = decode_buf[0 .. decoded_len];

        Array!char fs_path;
        fs_path ~= _root[];
        if (fs_path.length && fs_path[$-1] != '/' && fs_path[$-1] != '\\')
            fs_path ~= '/';

        const(char)[] p = decoded;
        while (p.length)
        {
            const(char)[] seg = p.split!'/';
            if (seg.length == 0 || seg == ".")
                continue;
            if (seg == "..")
                return send_status(ver, stream, 403); // refuse to escape the root
            foreach (c; seg)
            {
                if (c == '\\' || c == '\0')
                    return send_status(ver, stream, 400);
            }
            fs_path ~= seg;
            if (p.length)
                fs_path ~= '/';
        }

        if (!want_index)
        {
            if (serve_file(fs_path[], ver, request, stream))
                return 0;
            return send_status(ver, stream, 404);
        }

        if (fs_path.length && fs_path[$-1] != '/')
            fs_path ~= '/';

        static immutable string[2] index_names = [ "index.html", "index.htm" ];
        size_t base_len = fs_path.length;
        foreach (index; index_names)
        {
            fs_path.resize(base_len);
            fs_path ~= index;
            if (serve_file(fs_path[], ver, request, stream))
                return 0;
        }

        return send_status(ver, stream, 404);
    }

    bool serve_file(const(char)[] fs_path, HTTPVersion ver, ref const HTTPMessage request, ref Stream stream)
    {
        File f;
        if (!f.open(fs_path, FileOpenMode.ReadExisting, FileOpenFlags.Sequential))
            return false;

        ulong size = f.get_size();

        // TODO: above some threshold, stream the response (Transfer-Encoding: chunked)
        //       instead of buffering the whole file. The threshold should eventually be
        //       adaptive on free memory and detected link bandwidth. For now we always buffer.

        HTTPMessage response;
        response.http_version = ver;
        response.status_code = 200;
        response.reason = status_text(200);
        response.timestamp = getSysTime();
        response.content_type = mime_type(fs_path);

        if (size > 0)
        {
            response.content.resize(cast(size_t)size);
            size_t got;
            Result r = f.read(response.content[], got);
            f.close();
            if (!r)
                return send_status(ver, stream, 500) >= 0; // an existing file we failed to read

            if (got != size)
                response.content.resize(got);
        }
        else
            f.close();

        send_message(stream, response, &request);
        return true;
    }

    int send_status(HTTPVersion ver, ref Stream stream, ushort code)
    {
        HTTPMessage response = create_response(ver, code, StringLit!"text/plain; charset=utf-8", status_text(code)[]);
        stream.write(response.format_message()[]);
        return 0;
    }
}


String mime_type(const(char)[] path) pure
{
    size_t name_start = 0;
    foreach_reverse (i, c; path)
    {
        if (c == '/' || c == '\\')
        {
            name_start = i + 1;
            break;
        }
    }
    const(char)[] name = path[name_start .. $];

    size_t dot = name.length;
    foreach_reverse (i, c; name)
    {
        if (c == '.')
        {
            dot = i;
            break;
        }
    }
    if (dot == name.length)
        return StringLit!"application/octet-stream";

    const(char)[] ext = name[dot + 1 .. $];
    char[16] lower_buf = void;
    if (ext.length > lower_buf.length)
        return StringLit!"application/octet-stream";
    foreach (i, c; ext)
        lower_buf[i] = (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;

    switch (lower_buf[0 .. ext.length])
    {
        case "html":
        case "htm":     return StringLit!"text/html; charset=utf-8";
        case "css":     return StringLit!"text/css; charset=utf-8";
        case "js":
        case "mjs":     return StringLit!"text/javascript; charset=utf-8";
        case "json":    return StringLit!"application/json; charset=utf-8";
        case "map":     return StringLit!"application/json";
        case "xml":     return StringLit!"application/xml; charset=utf-8";
        case "txt":     return StringLit!"text/plain; charset=utf-8";
        case "csv":     return StringLit!"text/csv; charset=utf-8";
        case "md":      return StringLit!"text/markdown; charset=utf-8";
        case "svg":     return StringLit!"image/svg+xml";
        case "png":     return StringLit!"image/png";
        case "jpg":
        case "jpeg":    return StringLit!"image/jpeg";
        case "gif":     return StringLit!"image/gif";
        case "ico":     return StringLit!"image/x-icon";
        case "webp":    return StringLit!"image/webp";
        case "bmp":     return StringLit!"image/bmp";
        case "woff":    return StringLit!"font/woff";
        case "woff2":   return StringLit!"font/woff2";
        case "ttf":     return StringLit!"font/ttf";
        case "otf":     return StringLit!"font/otf";
        case "eot":     return StringLit!"application/vnd.ms-fontobject";
        case "wasm":    return StringLit!"application/wasm";
        case "pdf":     return StringLit!"application/pdf";
        default:        return StringLit!"application/octet-stream";
    }
}
