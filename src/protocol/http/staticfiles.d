module protocol.http.staticfiles;

import urt.array;
import urt.encoding;
import urt.file;
import urt.lifetime;
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
// PUT stores a file and DELETE removes one; cross-origin access is opt-in via
// the allowed-origin property.
class StaticFileServer : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("http-server", http_server),
                                 Prop!("uri", uri),
                                 Prop!("root", root),
                                 Prop!("allowed-origin", allowed_origin));
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
                remove_handlers(old);
                old.unsubscribe(&server_state_change);
            }
            _registered = false;
        }
        _server = value;
        mark_set!(typeof(this), "http-server")();
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
        mark_set!(typeof(this), "uri")();
        restart();
    }

    const(char)[] root() const pure
        => _root[];
    void root(const(char)[] value)
    {
        _root = value.makeString(g_app.allocator);
        mark_set!(typeof(this), "root")();
        restart();
    }

    // Cross-origin policy. Unset (the default) emits no CORS headers, so browsers only permit
    // same-origin pages to use the mount; this mount takes unauthenticated writes, so it must not
    // inherit the api module's wildcard. "*" allows any origin; anything else names the single
    // origin (scheme://host[:port]) that is allowed, echoed only when the request's Origin matches.
    const(char)[] allowed_origin() const pure
        => _allowed_origin[];
    void allowed_origin(const(char)[] value)
    {
        _allowed_origin = value.makeString(g_app.allocator);
        mark_set!(typeof(this), "allowed-origin")();
    }

protected:

    // An empty root is the filesystem's own origin: the process working
    // directory on a host, or no name prefix at all on a flat store.
    override bool validate() const pure
        => _server.get !is null;

    override CompletionStatus startup()
    {
        HTTPServer server = _server.get;
        if (!server)
            return CompletionStatus.continue_;

        bool ok = server.add_uri_handler(HTTPMethod.GET, _uri[], &handle_request);
        if (ok)
            ok = server.add_uri_handler(HTTPMethod.DELETE, _uri[], &handle_request);
        if (ok)
            ok = server.add_uri_handler(HTTPMethod.OPTIONS, _uri[], &handle_request);
        if (ok)
            ok = server.add_uri_handler(HTTPMethod.PUT, _uri[], &begin_upload);
        if (!ok)
        {
            remove_handlers(server);
            writeWarning("static: failed to register handlers for uri '", _uri[], "' (prefix conflict?)");
            return CompletionStatus.error;
        }
        server.subscribe(&server_state_change);
        _registered = true;
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        // in-flight uploads can't outlive the mount: the parser holds a delegate into freed
        // context if they do. Drop their connections; the freed handler is never called.
        while (!_uploads.empty)
        {
            Upload* u = _uploads[_uploads.length - 1];
            Stream s = u.stream;
            finish_upload(u);
            if (s)
                s.destroy();
        }
        while (!_downloads.empty)
        {
            Download* d = _downloads[_downloads.length - 1];
            Stream s = d.stream;
            finish_download(d);
            if (s)
                s.destroy();
        }

        if (_registered)
        {
            if (HTTPServer server = _server.get)
            {
                remove_handlers(server);
                server.unsubscribe(&server_state_change);
            }
            _registered = false;
        }
        return CompletionStatus.complete;
    }

    override void update()
    {
        for (size_t i = 0; i < _downloads.length; )
        {
            // on completion the entry is swap-removed; the same index then holds the next candidate
            if (!_downloads[i].pump())
                ++i;
        }
    }

private:
    ObjectRef!HTTPServer _server;
    String _uri;
    String _root;
    String _allowed_origin;
    bool _registered;
    Array!(Upload*) _uploads;
    Array!(Download*) _downloads;

    void remove_handlers(HTTPServer server)
    {
        server.remove_uri_handler(HTTPMethod.GET, &handle_request);
        server.remove_uri_handler(HTTPMethod.DELETE, &handle_request);
        server.remove_uri_handler(HTTPMethod.OPTIONS, &handle_request);
        server.remove_uri_handler(HTTPMethod.PUT, &begin_upload);
    }

    void server_state_change(ActiveObject, StateSignal signal)
    {
        // a destroy/recreate of the server gives us a fresh (empty) handler set; re-register
        if (signal == StateSignal.offline)
            restart();
    }

    int handle_request(ref const HTTPMessage request, ref Stream stream, const(ubyte)[] leftover)
    {
        HTTPVersion ver = request.http_version;

        if (request.method == HTTPMethod.OPTIONS)
            return handle_options(request, stream);

        Array!char fs_path;
        bool want_index;
        ushort status = map_target(request.request_target[], fs_path, want_index);
        if (status != 0)
            return send_status(ver, stream, status, request);

        if (request.method == HTTPMethod.DELETE)
        {
            if (want_index)
                return send_status(ver, stream, 405, request);
            return remove_file(fs_path[], ver, request, stream);
        }

        if (!want_index)
        {
            if (serve_file(fs_path[], ver, request, stream))
                return 0;
            return send_status(ver, stream, 404, request);
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

        return send_status(ver, stream, 404, request);
    }

    // PUT and DELETE are not CORS-safelisted, so a browser always preflights them
    int handle_options(ref const HTTPMessage request, ref Stream stream)
    {
        HTTPMessage response = create_response(request.http_version, 204, String(), null);
        if (add_cors(response, request))
        {
            response.headers ~= HTTPParam(StringLit!"Access-Control-Allow-Methods", StringLit!"GET, PUT, DELETE, OPTIONS");
            response.headers ~= HTTPParam(StringLit!"Access-Control-Allow-Headers", StringLit!"Content-Type");
            response.headers ~= HTTPParam(StringLit!"Access-Control-Max-Age", StringLit!"86400");
        }
        stream.write(response.format_message()[]);
        return 0;
    }

    // resolves a request target to a filesystem path beneath root; returns 0 and fills fs_path,
    // or the HTTP status the request should be refused with
    ushort map_target(const(char)[] target, ref Array!char fs_path, out bool want_index)
    {
        // the server dispatches on a path-boundary longest-prefix match, so `rel` is
        // always empty or starts with '/'.
        const(char)[] rel = target[_uri.length .. $];

        want_index = rel.length == 0 || rel[$-1] == '/';
        while (rel.length && rel[0] == '/')
            rel = rel[1 .. $];

        char[1024] decode_buf = void;
        if (url_decode_length(rel) > decode_buf.length)
            return 414;
        ptrdiff_t decoded_len = url_decode(rel, decode_buf[]);
        if (decoded_len < 0)
            return 400;
        const(char)[] decoded = decode_buf[0 .. decoded_len];

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
                return 403; // refuse to escape the root
            foreach (c; seg)
            {
                if (c == '\\' || c == '\0')
                    return 400;
            }
            fs_path ~= seg;
            if (p.length)
                fs_path ~= '/';
        }
        return 0;
    }

    bool serve_file(const(char)[] fs_path, HTTPVersion ver, ref const HTTPMessage request, ref Stream stream)
    {
        File f;
        if (!f.open(fs_path, FileOpenMode.ReadExisting, FileOpenFlags.Sequential))
            return false;

        ulong size = f.get_size();

        if (size > Download.stream_threshold)
        {
            // head first with the known length, then the body is pumped from update() as the
            // stream's tx queue drains, so the file is never resident in memory at once
            HTTPMessage response;
            response.http_version = ver;
            response.status_code = 200;
            response.reason = status_text(200);
            response.timestamp = getSysTime();
            response.headers ~= HTTPParam(StringLit!"Content-Type", mime_type(fs_path));
            response.headers ~= HTTPParam(StringLit!"Content-Length", tconcat(size).makeString(defaultAllocator()));
            add_cors(response, request);
            stream.write(format_message_head(response)[]);

            Download* d = defaultAllocator().allocT!Download();
            d.owner = this;
            d.stream = stream;
            d.file = f;
            d.remaining = size;
            stream.subscribe(&d.stream_state);
            _downloads ~= d;
            d.pump();
            return true;
        }

        HTTPMessage response;
        response.http_version = ver;
        response.status_code = 200;
        response.reason = status_text(200);
        response.timestamp = getSysTime();
        response.content_type = mime_type(fs_path);
        add_cors(response, request);

        if (size > 0)
        {
            response.content.resize(cast(size_t)size);
            size_t got;
            Result r = f.read(response.content[], got);
            f.close();
            if (!r)
                return send_status(ver, stream, 500, request) >= 0; // an existing file we failed to read

            if (got != size)
                response.content.resize(got);
        }
        else
            f.close();

        send_message(stream, response, &request);
        return true;
    }

    // PUT streams the body to disk as it arrives, so uploads aren't subject to the server's
    // max_buffered_body and never buffer in memory.
    //
    // Written to a temporary and swapped in, so a write that fails partway (or a connection
    // that dies mid-body) leaves the existing file untouched rather than truncated. SPIFFS
    // refuses to rename onto an existing name, so the swap is a delete then a rename; losing
    // power between those two leaves the complete upload as .tmp and no target, which the boot
    // guard survives. Truncating in place does not.
    //
    // A refused request (bad path, directory target, open failure) still returns a chunk sink:
    // the body is drained and the failure status sent at the end, so the client always reads a
    // real status rather than a dead connection.
    StreamingChunkHandler begin_upload(ref const HTTPMessage request, ref Stream stream)
    {
        Array!char fs_path;
        bool want_index;
        ushort status = map_target(request.request_target[], fs_path, want_index);
        if (status == 0 && want_index)
            status = 405; // a directory names no file to write

        if (status == 0)
        {
            foreach (existing; _uploads)
            {
                if (existing.target[] == fs_path[])
                {
                    status = 409; // concurrent upload to the same target would share the temporary
                    break;
                }
            }
        }

        Upload* u = defaultAllocator().allocT!Upload();
        u.owner = this;
        u.stream = stream;
        u.error = status;
        if (status == 0)
        {
            u.target = fs_path.move;
            u.tmp ~= u.target[];
            u.tmp ~= ".tmp";
            u.replaced = file_exists(u.target[]);
            Result o = u.file.open(u.tmp[], FileOpenMode.WriteTruncate);
            if (!o)
            {
                writeWarning("static: open '", u.tmp[], "' for write failed: ", o.system_code);
                u.error = 500;
            }
        }

        stream.subscribe(&u.stream_state);
        _uploads ~= u;

        if (request.http_version >= HTTPVersion.V1_1 && request.header("Expect")[] == "100-continue")
            stream.write("HTTP/1.1 100 Continue\r\n\r\n");

        return &u.on_chunk;
    }

    int remove_file(const(char)[] fs_path, HTTPVersion ver, ref const HTTPMessage request, ref Stream stream)
    {
        if (!file_exists(fs_path))
            return send_status(ver, stream, 404, request);

        Result r = delete_file(fs_path);
        if (!r)
        {
            writeWarning("static: delete '", fs_path, "' failed: ", r.system_code);
            return send_status(ver, stream, 500, request);
        }

        writeInfo("static: deleted '", fs_path, "'");
        return send_status(ver, stream, 200, request);
    }

    // returns true when the request's origin is permitted (headers were added)
    bool add_cors(ref HTTPMessage response, ref const HTTPMessage request)
    {
        if (_allowed_origin.empty)
            return false;
        if (_allowed_origin[] == "*")
        {
            response.headers ~= HTTPParam(StringLit!"Access-Control-Allow-Origin", StringLit!"*");
            return true;
        }
        if (request.header("Origin")[] != _allowed_origin[])
            return false;
        response.headers ~= HTTPParam(StringLit!"Access-Control-Allow-Origin", _allowed_origin);
        response.headers ~= HTTPParam(StringLit!"Vary", StringLit!"Origin");
        return true;
    }

    int send_status(HTTPVersion ver, ref Stream stream, ushort code, ref const HTTPMessage request)
    {
        HTTPMessage response = create_response(ver, code, StringLit!"text/plain; charset=utf-8", status_text(code)[]);
        add_cors(response, request);
        stream.write(response.format_message()[]);
        return 0;
    }

    void finish_upload(Upload* u)
    {
        u.discard();
        if (u.stream)
            u.stream.unsubscribe(&u.stream_state);
        _uploads.removeFirstSwapLast(u);
        defaultAllocator().freeT(u);
    }

    void finish_download(Download* d)
    {
        if (d.file.is_open)
            d.file.close();
        if (d.stream)
            d.stream.unsubscribe(&d.stream_state);
        _downloads.removeFirstSwapLast(d);
        defaultAllocator().freeT(d);
    }

    static struct Upload
    {
    nothrow @nogc:
        StaticFileServer owner;
        Stream stream;
        File file;
        Array!char target;
        Array!char tmp;
        ushort error;   // pending failure status; the body is drained and this is reported at the end
        bool replaced;

        int on_chunk(ref const HTTPMessage request, const(ubyte)[] chunk, bool final_chunk, ref Stream s)
        {
            if (!final_chunk)
            {
                if (error)
                    return 0;
                size_t written;
                Result r = file.write(chunk, written);
                if (!r || written != chunk.length)
                {
                    writeWarning("static: write '", tmp[], "' failed: ", r.system_code);
                    error = 500;
                    discard();
                }
                return 0;
            }

            ushort status = error ? error : commit();
            StaticFileServer o = owner;
            o.send_status(request.http_version, s, status, request);
            o.finish_upload(&this);
            return 0;
        }

        ushort commit()
        {
            file.close();
            if (replaced)
                delete_file(target[]);
            Result mv = rename_file(tmp[], target[]);
            if (!mv)
            {
                writeWarning("static: could not swap '", tmp[], "' into place: ", mv.system_code);
                return 500;
            }
            writeInfo("static: stored '", target[], "'");
            return replaced ? 200 : 201;
        }

        void discard()
        {
            if (file.is_open)
            {
                file.close();
                delete_file(tmp[]);
            }
        }

        void stream_state(ActiveObject, StateSignal signal)
        {
            // the connection died mid-body; the temporary is discarded, the target untouched
            if (signal != StateSignal.online)
                owner.finish_upload(&this);
        }
    }

    static struct Download
    {
    nothrow @nogc:
        enum stream_threshold = 64 * 1024;  // buffer smaller responses (they remain compressible)
        enum chunk_size = 16 * 1024;
        enum backlog_high = 64 * 1024;      // stop pumping while this much is queued on the stream

        StaticFileServer owner;
        Stream stream;
        File file;
        ulong remaining;

        // returns true when the transfer completed or died (and this context was freed)
        bool pump()
        {
            while (true)
            {
                if (!stream.running || remaining == 0)
                {
                    owner.finish_download(&this);
                    return true;
                }
                if (stream.tx_backlog() >= backlog_high)
                    return false;

                ubyte[chunk_size] buf = void;
                size_t take = remaining < chunk_size ? cast(size_t)remaining : chunk_size;
                size_t got;
                Result r = file.read(buf[0 .. take], got);
                if (r && got == take && stream.write(buf[0 .. got]) == cast(ptrdiff_t)got)
                {
                    remaining -= got;
                    continue;
                }

                // the Content-Length is already promised; drop the connection so the client
                // sees a broken transfer rather than a silently short file
                writeWarning("static: transfer failed mid-body, dropping connection");
                Stream s = stream;
                StaticFileServer o = owner;
                o.finish_download(&this);
                s.destroy();
                return true;
            }
        }

        void stream_state(ActiveObject, StateSignal signal)
        {
            if (signal != StateSignal.online)
                owner.finish_download(&this);
        }
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
        case "txt":
        case "conf":
        case "log":     return StringLit!"text/plain; charset=utf-8";
        case "yaml":
        case "yml":     return StringLit!"text/yaml; charset=utf-8";
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
