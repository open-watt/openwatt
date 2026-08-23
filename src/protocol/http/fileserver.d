module protocol.http.fileserver;

import urt.array;
import urt.encoding;
import urt.file;
import urt.lifetime;
import urt.log;
import urt.mem;
import urt.mem.temp : tconcat;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;

import protocol.http.message;
import protocol.http.server;

import router.stream;

version (Tiny) {} else version = WebDAV;

nothrow @nogc:


enum FileServerAccess : ubyte
{
    read,   // HEAD/GET only
    write,  // + PUT/DELETE
    webdav, // + PROPFIND/MKCOL/COPY/MOVE and granted-but-unenforced locks
}


// Serves files from a filesystem directory beneath a URI root on an HTTPServer.
// A request for "<uri>/a/b.css" maps to "<root>/a/b.css"; a directory request
// (the URI root itself, or any path ending in '/') serves index.html / index.htm.
// The access property sets how far the mount goes beyond that: write adds PUT
// and DELETE, webdav upgrades it to a WebDAV server that filesystem clients
// (davfs2, rclone, Explorer, Finder) can mount.
class FileServer : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("http-server", http_server),
                                 Prop!("uri", uri),
                                 Prop!("root", root),
                                 Prop!("access", access),
                                 Prop!("auth-required", auth_required),
                                 Prop!("allowed-origin", allowed_origin));
nothrow @nogc:

    enum type_name = "fileserver";
    enum path = "/protocol/http/fileserver";
    enum collection_id = CollectionType.http_fileserver;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!FileServer, id, flags);
    }

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
            _uri = value.make_string();
        else
            _uri = tconcat("/", value).make_string();
        mark_set!(typeof(this), "uri")();
        restart();
    }

    const(char)[] root() const pure
        => _root[];
    void root(const(char)[] value)
    {
        _root = value.make_string();
        mark_set!(typeof(this), "root")();
        restart();
    }

    const(char)[] allowed_origin() const pure
        => _allowed_origin[];
    void allowed_origin(const(char)[] value)
    {
        _allowed_origin = value.make_string();
        mark_set!(typeof(this), "allowed-origin")();
    }

    FileServerAccess access() const pure
        => _access;
    void access(FileServerAccess value)
    {
        if (_access == value)
            return;
        _access = value;
        mark_set!(typeof(this), "access")();
        restart();
    }

    // Requests must carry Basic credentials naming a Secret that is allowed
    // the "http" service. Pair with TLS: Basic credentials are plaintext.
    bool auth_required() const pure
        => _auth_required;
    void auth_required(bool value)
    {
        _auth_required = value;
        mark_set!(typeof(this), "auth-required")();
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

        version (WebDAV) {} else
        {
            if (_access == FileServerAccess.webdav)
                writeWarning("fileserver: webdav is not in this build; serving read-write");
        }

        HTTPMethodSet methods = HTTPMethodSet.GET | HTTPMethodSet.HEAD | HTTPMethodSet.OPTIONS;
        if (_access >= FileServerAccess.write)
            methods |= HTTPMethodSet.DELETE;
        version (WebDAV)
        {
            if (_access == FileServerAccess.webdav)
                methods |= HTTPMethodSet.PROPFIND | HTTPMethodSet.MKCOL | HTTPMethodSet.COPY |
                           HTTPMethodSet.MOVE | HTTPMethodSet.LOCK | HTTPMethodSet.UNLOCK;
        }

        bool ok = server.add_uri_handler(methods, _uri[], &handle_request);
        if (ok && _access >= FileServerAccess.write)
        {
            // PUT is registered apart from the rest: it streams its body
            ok = server.add_uri_handler(HTTPMethod.PUT, _uri[], &begin_upload);
        }
        if (!ok)
        {
            remove_handlers(server);
            writeWarning("fileserver: failed to register handlers for uri '", _uri[], "' (prefix conflict?)");
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
    bool _auth_required;
    FileServerAccess _access;
    version (WebDAV)
        uint _lock_seq;
    Array!(Upload*) _uploads;
    Array!(Download*) _downloads;

    void remove_handlers(HTTPServer server)
    {
        server.remove_uri_handler(HTTPMethodSet.any, &handle_request);
        server.remove_uri_handler(HTTPMethodSet.any, &begin_upload);
    }

    void server_state_change(ActiveObject, StateSignal signal)
    {
        // a destroy/recreate of the server gives us a fresh (empty) handler set; re-register
        if (signal == StateSignal.offline)
            restart();
    }

    // true when the target is the mount itself, which write methods must never touch
    bool is_mount_root(ref const HTTPMessage request) const pure
        => request.request_target.length <= _uri.length + 1;

    bool authorised(ref const HTTPMessage request)
    {
        if (!_auth_required)
            return true;
        if (!request.username)
            return false;

        bool ok;
        g_app.validate_login(request.username[], request.password[], "http",
                             (AuthResult result, const(char)[]) { ok = result == AuthResult.accepted; });
        return ok;
    }

    int handle_request(ref const HTTPMessage request, ref Stream stream, const(ubyte)[] leftover)
    {
        HTTPVersion ver = request.http_version;

        // preflights are excluded: they never carry credentials
        if (request.method == HTTPMethod.OPTIONS)
            return handle_options(request, stream);

        if (!authorised(request))
            return send_status(ver, stream, 401, request);

        Array!char fs_path;
        bool want_index;
        ushort status = map_target(request.request_target[], fs_path, want_index);
        if (status != 0)
            return send_status(ver, stream, status, request);

        version (WebDAV)
        {
            switch (request.method)
            {
                case HTTPMethod.PROPFIND:
                    return handle_propfind(request, stream, fs_path[]);
                case HTTPMethod.MKCOL:
                    return handle_mkcol(request, stream, fs_path[]);
                case HTTPMethod.COPY:
                case HTTPMethod.MOVE:
                    return handle_copy_move(request, stream, fs_path[]);
                case HTTPMethod.LOCK:
                    return handle_lock(request, stream);
                case HTTPMethod.UNLOCK:
                    return send_status(ver, stream, 204, request);
                default:
                    break;
            }
        }

        if (request.method == HTTPMethod.DELETE)
        {
            version (WebDAV)
            {
                if (_access == FileServerAccess.webdav)
                {
                    Directory probe;
                    if (probe.open(fs_path[]))
                    {
                        probe.close();
                        if (is_mount_root(request))
                            return send_status(ver, stream, 403, request);
                        Result r = remove_tree(fs_path[]);
                        if (!r)
                        {
                            writeWarning("fileserver: delete '", fs_path[], "' failed: ", r.system_code);
                            return send_status(ver, stream, 500, request);
                        }
                        writeInfo("fileserver: deleted '", fs_path[], "'");
                        return send_status(ver, stream, 204, request);
                    }
                }
            }
            if (want_index)
                return send_status(ver, stream, 405, request);
            return remove_file(fs_path[], ver, request, stream);
        }

        if (!want_index)
        {
            if (serve_file(fs_path[], ver, request, stream))
                return 0;
            // a directory named without its trailing slash redirects to it, so a
            // path that names a directory is always distinguishable from a file
            Directory probe;
            if (probe.open(fs_path[]))
            {
                probe.close();
                return send_redirect(ver, stream, request);
            }
            return send_status(ver, stream, 404, request);
        }

        // a JSON directory request is a listing even where an index exists; this
        // is how the web file browser enumerates, at every access level
        if (request.header("Accept")[].contains("application/json"))
            return send_listing(request, stream, fs_path[]);

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

        fs_path.resize(base_len);
        return send_listing(request, stream, fs_path[]);
    }

    // PUT and DELETE are not CORS-safelisted, so a browser always preflights them
    int handle_options(ref const HTTPMessage request, ref Stream stream)
    {
        HTTPMessage response = create_response(request.http_version, 204, String(), null);

        String allow = StringLit!"GET, HEAD, OPTIONS";
        if (_access >= FileServerAccess.write)
            allow = StringLit!"GET, HEAD, PUT, DELETE, OPTIONS";
        version (WebDAV)
        {
            if (_access == FileServerAccess.webdav)
            {
                allow = StringLit!"GET, HEAD, PUT, DELETE, OPTIONS, PROPFIND, MKCOL, COPY, MOVE, LOCK, UNLOCK";
                response.headers ~= HTTPParam(StringLit!"DAV", StringLit!"1, 2");
                response.headers ~= HTTPParam(StringLit!"MS-Author-Via", StringLit!"DAV");
            }
        }
        response.headers ~= HTTPParam(StringLit!"Allow", allow);

        if (add_cors(response, request))
        {
            response.headers ~= HTTPParam(StringLit!"Access-Control-Allow-Methods", allow);
            response.headers ~= HTTPParam(StringLit!"Access-Control-Allow-Headers", StringLit!"Content-Type, Depth, Destination, Overwrite");
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

        if (request.method == HTTPMethod.HEAD)
        {
            f.close();
            HTTPMessage response;
            response.http_version = ver;
            response.status_code = 200;
            response.reason = status_text(200);
            response.timestamp = getSysTime();
            response.headers ~= HTTPParam(StringLit!"Content-Type", mime_type(fs_path));
            response.headers ~= HTTPParam(StringLit!"Content-Length", tconcat(size).make_string());
            add_cors(response, request);
            stream.write(format_message_head(response)[]);
            return true;
        }

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
            response.headers ~= HTTPParam(StringLit!"Content-Length", tconcat(size).make_string());
            add_cors(response, request);
            stream.write(format_message_head(response)[]);

            Download* d = alloc!Download();
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
        ushort status = authorised(request) ? 0 : 401;
        if (status == 0)
            status = map_target(request.request_target[], fs_path, want_index);
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

        Upload* u = alloc!Upload();
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
                writeWarning("fileserver: open '", u.tmp[], "' for write failed: ", o.system_code);
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
            writeWarning("fileserver: delete '", fs_path, "' failed: ", r.system_code);
            return send_status(ver, stream, 500, request);
        }

        writeInfo("fileserver: deleted '", fs_path, "'");
        return send_status(ver, stream, 200, request);
    }

    version (WebDAV)
    {
        int handle_propfind(ref const HTTPMessage request, ref Stream stream, const(char)[] fs_path)
        {
            HTTPVersion ver = request.http_version;

            // an absent Depth means infinity per RFC 4918, and infinity is refused like
            // most servers do: clients walk Depth 1 instead
            String depth = request.header("Depth");
            if (depth.empty || depth[] == "infinity")
                return send_status(ver, stream, 403, request);
            bool list_children = depth[] != "0";

            // a collection is whatever the directory walk can open; this also covers
            // flat stores where a stat cannot tell a directory from a file
            const(char)[] dpath = fs_path.length ? fs_path : ".";
            Directory dir;
            bool is_dir = dir.open(dpath).succeeded;

            FileAttributes attr;
            bool have_attr = get_file_attributes(dpath, attr).succeeded;
            if (!is_dir && !have_attr)
                return send_status(ver, stream, 404, request);

            Array!char xml;
            xml ~= `<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">`;

            Array!char href;
            href ~= request.request_target[];
            if (is_dir && (href.empty || href[href.length - 1] != '/'))
                href ~= '/';

            append_response(xml, href[], is_dir, is_dir ? 0 : attr.size, have_attr ? &attr.writeTime : null,
                            is_dir ? String() : mime_type(fs_path));

            if (is_dir && list_children)
            {
                size_t href_base = href.length;
                Array!char child_path;
                DirEntry entry;
                while (dir.read(entry))
                {
                    href.resize(href_base);
                    append_href_segment(href, entry.name);
                    if (entry.is_directory)
                        href ~= '/';

                    child_path.clear();
                    if (fs_path.length)
                        child_path.append(fs_path, fs_path[$-1] == '/' ? "" : "/");
                    child_path ~= entry.name;

                    FileAttributes centry;
                    bool have_centry = get_file_attributes(child_path[], centry).succeeded;
                    append_response(xml, href[], entry.is_directory, entry.size, have_centry ? &centry.writeTime : null,
                                    entry.is_directory ? String() : mime_type(entry.name));
                }
            }
            if (is_dir)
                dir.close();

            xml ~= "</D:multistatus>";

            HTTPMessage response = create_response(ver, 207, StringLit!"application/xml; charset=utf-8", xml[]);
            add_cors(response, request);
            stream.write(response.format_message()[]);
            return 0;
        }

        int handle_mkcol(ref const HTTPMessage request, ref Stream stream, const(char)[] fs_path)
        {
            HTTPVersion ver = request.http_version;

            if (request.content.length)
                return send_status(ver, stream, 415, request); // request body formats are not supported
            if (is_mount_root(request))
                return send_status(ver, stream, 405, request);

            FileAttributes attr;
            if (get_file_attributes(fs_path, attr))
                return send_status(ver, stream, 405, request); // already exists

            Result r = create_directory(fs_path);
            if (r)
            {
                writeInfo("fileserver: created collection '", fs_path, "'");
                return send_status(ver, stream, 201, request);
            }

            // a missing intermediate collection is a 409 by spec
            const(char)[] parent;
            foreach_reverse (i, c; fs_path)
            {
                if (c == '/')
                {
                    parent = fs_path[0 .. i];
                    break;
                }
            }
            if (parent.length)
            {
                Directory probe;
                if (!probe.open(parent))
                    return send_status(ver, stream, 409, request);
                probe.close();
            }
            writeWarning("fileserver: mkcol '", fs_path, "' failed: ", r.system_code);
            return send_status(ver, stream, 500, request);
        }

        int handle_copy_move(ref const HTTPMessage request, ref Stream stream, const(char)[] fs_path)
        {
            HTTPVersion ver = request.http_version;
            bool is_move = request.method == HTTPMethod.MOVE;

            // absolute-URI destinations are stripped to their path
            const(char)[] dest = request.header("Destination")[];
            if (dest.length > 3)
            {
                foreach (i; 0 .. dest.length - 2)
                {
                    if (dest[i] == ':' && dest[i + 1] == '/' && dest[i + 2] == '/')
                    {
                        dest = dest[i + 3 .. $];
                        size_t slash = dest.length;
                        foreach (j, c; dest)
                        {
                            if (c == '/')
                            {
                                slash = j;
                                break;
                            }
                        }
                        dest = dest[slash .. $];
                        break;
                    }
                }
            }
            if (dest.length == 0 || dest[0] != '/')
                return send_status(ver, stream, 400, request);

            // a destination beyond this mount is a gateway role we refuse
            if (dest.length < _uri.length || dest[0 .. _uri.length] != _uri[] ||
                (dest.length > _uri.length && dest[_uri.length] != '/'))
                return send_status(ver, stream, 502, request);

            Array!char dest_path;
            bool dest_index;
            ushort status = map_target(dest, dest_path, dest_index);
            if (status != 0)
                return send_status(ver, stream, status, request);

            if (is_mount_root(request) || dest.length <= _uri.length + 1)
                return send_status(ver, stream, 403, request);

            Directory probe;
            bool src_is_dir = probe.open(fs_path).succeeded;
            if (src_is_dir)
                probe.close();
            else if (!file_exists(fs_path))
                return send_status(ver, stream, 404, request);

            // onto itself, or into its own subtree (which would recurse forever)
            if (dest_path[] == fs_path ||
                (dest_path.length > fs_path.length && dest_path[0 .. fs_path.length] == fs_path && dest_path[fs_path.length] == '/'))
                return send_status(ver, stream, 403, request);

            bool dest_is_dir = probe.open(dest_path[]).succeeded;
            if (dest_is_dir)
                probe.close();
            bool replaced = dest_is_dir || file_exists(dest_path[]);
            if (replaced)
            {
                if (request.header("Overwrite")[] == "F")
                    return send_status(ver, stream, 412, request);
                Result rd = dest_is_dir ? remove_tree(dest_path[]) : delete_file(dest_path[]);
                if (!rd)
                {
                    writeWarning("fileserver: could not replace '", dest_path[], "': ", rd.system_code);
                    return send_status(ver, stream, 500, request);
                }
            }

            Result r;
            if (is_move)
                r = rename_file(fs_path, dest_path[]);
            else if (src_is_dir)
                r = copy_tree(fs_path, dest_path[]);
            else
                r = copy_file(fs_path, dest_path[], true);
            if (!r)
            {
                writeWarning("fileserver: ", is_move ? "move" : "copy", " '", fs_path, "' -> '", dest_path[], "' failed: ", r.system_code);
                return send_status(ver, stream, 500, request);
            }

            writeInfo("fileserver: ", is_move ? "moved" : "copied", " '", fs_path, "' -> '", dest_path[], "'");
            return send_status(ver, stream, replaced ? 204 : 201, request);
        }

        // locks are granted but never enforced: single-user embedded storage has no
        // contention worth arbitrating, but Windows and macOS clients refuse to mount
        // read-write without a lock grant to hold
        int handle_lock(ref const HTTPMessage request, ref Stream stream)
        {
            Array!char token;
            token.append("opaquelocktoken:openwatt-", ++_lock_seq);

            Array!char xml;
            xml ~= `<?xml version="1.0" encoding="utf-8"?><D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock>` ~
                   "<D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope>" ~
                   "<D:depth>infinity</D:depth><D:timeout>Second-3600</D:timeout><D:locktoken><D:href>";
            xml ~= token[];
            xml ~= "</D:href></D:locktoken></D:activelock></D:lockdiscovery></D:prop>";

            HTTPMessage response = create_response(request.http_version, 200, StringLit!"application/xml; charset=utf-8", xml[]);
            response.headers ~= HTTPParam(StringLit!"Lock-Token", tconcat("<", token[], ">").make_string());
            add_cors(response, request);
            stream.write(response.format_message()[]);
            return 0;
        }
    }

    bool add_cors(ref HTTPMessage response, ref const HTTPMessage request)
    {
        HTTPServer server = _server.get;
        enum mask = ulong(1) << prop_index!(typeof(this), "allowed-origin");
        String* policy = (_props_set & mask) ? &_allowed_origin : null;
        return server ? server.add_cors(response, request, policy) : false;
    }

    int send_status(HTTPVersion ver, ref Stream stream, ushort code, ref const HTTPMessage request)
    {
        HTTPMessage response = request.method == HTTPMethod.HEAD
            ? create_response(ver, code, String(), null)
            : create_response(ver, code, StringLit!"text/plain; charset=utf-8", status_text(code)[]);
        if (code == 401)
            response.headers ~= HTTPParam(StringLit!"WWW-Authenticate", StringLit!`Basic realm="OpenWatt", charset="UTF-8"`);
        add_cors(response, request);
        stream.write(response.format_message()[]);
        return 0;
    }

    int send_listing(ref const HTTPMessage request, ref Stream stream, const(char)[] fs_path)
    {
        const(char)[] dpath = fs_path.length ? fs_path : ".";
        Directory dir;
        if (!dir.open(dpath))
            return send_status(request.http_version, stream, 404, request);

        Array!char json;
        json ~= `{"entries":[`;
        bool first = true;
        Array!char child_path;
        DirEntry entry;
        while (dir.read(entry))
        {
            if (!first)
                json ~= ',';
            first = false;
            json ~= `{"name":"`;
            append_json_escaped(json, entry.name);
            json.append(`","dir":`, entry.is_directory ? "true" : "false");
            if (!entry.is_directory)
                json.append(`,"size":`, entry.size);

            child_path.clear();
            if (fs_path.length)
                child_path.append(fs_path, fs_path[$-1] == '/' ? "" : "/");
            child_path ~= entry.name;
            FileAttributes attr;
            if (get_file_attributes(child_path[], attr) && attr.writeTime != SysTime())
                json.append(`,"mtime":`, attr.writeTime.unixTimeNs / 1_000_000_000);
            json ~= '}';
        }
        dir.close();
        json ~= "]}";

        // the +json suffix parses as JSON everywhere, but can never be mistaken
        // for a .json file fetched from disk
        HTTPMessage response = create_response(request.http_version, 200, StringLit!"application/vnd.openwatt.dir+json; charset=utf-8", json[]);
        add_cors(response, request);
        if (request.method == HTTPMethod.HEAD)
            stream.write(format_message_head(response)[]);
        else
            stream.write(response.format_message()[]);
        return 0;
    }

    int send_redirect(HTTPVersion ver, ref Stream stream, ref const HTTPMessage request)
    {
        HTTPMessage response = create_response(ver, 301, String(), null);
        response.flags = HTTPFlags.ForceBody; // a 301 without Content-Length reads as body-until-close
        response.headers ~= HTTPParam(StringLit!"Location", tconcat(request.request_target[], "/").make_string());
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
        free(u);
    }

    void finish_download(Download* d)
    {
        if (d.file.is_open)
            d.file.close();
        if (d.stream)
            d.stream.unsubscribe(&d.stream_state);
        _downloads.removeFirstSwapLast(d);
        free(d);
    }

    static struct Upload
    {
    nothrow @nogc:
        FileServer owner;
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
                    writeWarning("fileserver: write '", tmp[], "' failed: ", r.system_code);
                    error = 500;
                    discard();
                }
                return 0;
            }

            ushort status = error ? error : commit();
            FileServer o = owner;
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
                writeWarning("fileserver: could not swap '", tmp[], "' into place: ", mv.system_code);
                return 500;
            }
            writeInfo("fileserver: stored '", target[], "'");
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
        FileServer owner;
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
                writeWarning("fileserver: transfer failed mid-body, dropping connection");
                Stream s = stream;
                FileServer o = owner;
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


private void append_json_escaped(ref Array!char json, const(char)[] s)
{
    import urt.string.ascii : hex_digits;

    foreach (c; s)
    {
        if (c == '"' || c == '\\')
        {
            json ~= '\\';
            json ~= c;
        }
        else if (c < 0x20)
        {
            json ~= `\u00`;
            json ~= hex_digits[c >> 4];
            json ~= hex_digits[c & 0xF];
        }
        else
            json ~= c;
    }
}


version (WebDAV):
private:

void append_response(ref Array!char xml, const(char)[] href, bool is_dir, ulong size, const(SysTime)* mtime, String mime)
{
    xml ~= "<D:response><D:href>";
    xml ~= href;
    xml ~= "</D:href><D:propstat><D:prop><D:resourcetype>";
    if (is_dir)
        xml ~= "<D:collection/>";
    xml ~= "</D:resourcetype>";
    if (!is_dir)
    {
        xml.append("<D:getcontentlength>", size, "</D:getcontentlength>");
        if (!mime.empty)
            xml.append("<D:getcontenttype>", mime[], "</D:getcontenttype>");
    }
    if (mtime)
    {
        xml ~= "<D:getlastmodified>";
        http_date((*mtime).getDateTime(), xml);
        xml ~= "</D:getlastmodified>";
    }
    xml ~= "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>";
}

// percent-encodes one path segment into an href; the strict is_url set also
// escapes XML metacharacters, so hrefs need no separate XML escaping
void append_href_segment(ref Array!char href, const(char)[] name)
{
    import urt.string.ascii : is_url, hex_digits;

    foreach (c; name)
    {
        if (c.is_url)
            href ~= c;
        else
        {
            href ~= '%';
            href ~= hex_digits[c >> 4];
            href ~= hex_digits[c & 0xF];
        }
    }
}

Result remove_tree(const(char)[] path)
{
    Directory dir;
    if (!dir.open(path))
        return delete_file(path);

    Array!char child;
    DirEntry entry;
    while (dir.read(entry))
    {
        child.clear();
        child.append(path, '/', entry.name);
        Result r = entry.is_directory ? remove_tree(child[]) : delete_file(child[]);
        if (!r)
        {
            dir.close();
            return r;
        }
    }
    dir.close();
    return remove_directory(path);
}

Result copy_tree(const(char)[] src, const(char)[] dst)
{
    Result r = create_directory(dst);
    if (!r)
        return r;
    Directory dir;
    r = dir.open(src);
    if (!r)
        return r;

    Array!char from, to;
    DirEntry entry;
    while (dir.read(entry))
    {
        from.clear();
        from.append(src, '/', entry.name);
        to.clear();
        to.append(dst, '/', entry.name);
        Result cr = entry.is_directory ? copy_tree(from[], to[]) : copy_file(from[], to[], true);
        if (!cr)
        {
            dir.close();
            return cr;
        }
    }
    dir.close();
    return Result.success;
}
