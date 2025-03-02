module protocol.http.client;

import urt.array;
import urt.conv;
import urt.encoding;
import urt.kvp;
import urt.lifetime;
import urt.mem.allocator;
import urt.string;
import urt.string.format : tconcat;
import urt.time;

import protocol.http;

import router.stream.tcp;

version = DebugHTTPMessageFlow;

nothrow @nogc:


alias HTTPParam = KVP!(String, String);

enum HTTPMethod : ubyte
{
    GET,
    HEAD,
    OPTIONS,

    POST,
    PUT,
    PATCH,
    DELETE,

    TRACE,
    CONNECT,

    // WebDAV stuff...
    SEARCH,
    PROPFIND,
    PROPPATCH,
    MKCOL,
    COPY,
    MOVE,
    LOCK,
    UNLOCK
}

enum HTTPVersion : ubyte
{
    V1_0 = 0x10,
    V1_1 = 0x11,
    V2_0 = 0x20
}

enum HTTPFlags : ubyte
{
    None = 0,
    ForceBody = 1,  // include body data, even if it's empty (ie: Content-Length: 0)
}

struct HTTPRequest
{
nothrow @nogc:

    this(this) @disable;

    HTTPVersion httpVersion;        // HTTP version (e.g., "HTTP/1.1", "HTTP/2")
    HTTPMethod method;              // HTTP method (e.g., GET, POST, PUT, DELETE)
    HTTPFlags flags;                // Request flags
    String url;                     // URL or path (e.g., "/index.html" or full "https://example.com")
    String username;                // Username
    String password;                // Password
    Array!ubyte content;            // Optional body for POST/PUT requests
    Array!HTTPParam headers;        // Array of additional headers
    Array!HTTPParam queryParams;    // Query parameters

    HTTPResponse* response;         // Response object
    void delegate(ref HTTPResponse response) responseHandler;
    MonoTime requestTime;

    const(char)[] host()
    {
        // parse host from the url (ie, example.com from "/example.com:1234/thing?wow=wee")
        assert(false);
        return null;
    }

    inout(String) header(const(char)[] name) inout
    {
        foreach (ref h; headers)
        {
            if (h.key[] == name[])
                return h.value;
        }
        return String();
    }

    inout(String) param(const(char)[] name) inout
    {
        foreach (ref p; queryParams)
        {
            if (p.key[] == name[])
                return p.value;
        }
        return String();
    }
}

struct HTTPResponse
{
nothrow @nogc:

    this(this) @disable;

    HTTPRequest* request;

    private Array!char tail;
    private size_t pendingChunkLen;
    private Flags flags;

    // response info
    HTTPVersion httpVersion;    // HTTP version (e.g., "HTTP/1.1", "HTTP/2")
    ushort statusCode;          // Status code (e.g., 200, 404, 500)
    ulong contentLength;        // Length of the body, if applicable
    Array!ubyte content;        // Response body (if any)
    Array!HTTPParam headers;    // Array of additional headers (or string[string] for key-value)

    inout(String) header(const(char)[] name) inout
    {
        foreach (ref h; headers)
        {
            if (h.key[] == name[])
                return h.value;
        }
        return String();
    }

private:
    enum Flags : ubyte
    {
        None = 0,
        Chunked = 1,
        ReadingHeaders = 2,
        ReadingTailHeaders = 4
    }
}


class HTTPClient
{
nothrow @nogc:

    String name;
    String host;
    Stream stream;
    HTTPVersion serverVersion = HTTPVersion.V2_0;

    Array!(HTTPRequest*) requests;

    this(String name, Stream stream, String host)
    {
        this.name = name.move;
        this.stream = stream;
        this.host = host.move;
    }

    HTTPRequest* request(HTTPMethod method, const(char)[] resource, void delegate(ref HTTPResponse response) nothrow @nogc responseHandler, const void[] content = null, HTTPParam[] params = null, HTTPParam[] additionalHeaders = null, String username = null, String password = null)
    {
        HTTPRequest* request = defaultAllocator().allocT!HTTPRequest();
        request.httpVersion = serverVersion;
        request.method = method;
        request.url = resource.makeString(defaultAllocator);
        request.username = username.move;
        request.password = password.move;
        request.content = cast(ubyte[])content;
        request.headers = additionalHeaders.move;
        request.queryParams = params.move;
        request.responseHandler = responseHandler;
        request.requestTime = getTime();

        if (requests.length == 0) // OR CONCURRENT REQUESTS...
            sendRequest(*request);

        requests ~= request;
        return request;
    }

    void update()
    {
        bool sendNext = false;

        while (true)
        {
            ubyte[1024] buffer;
            ptrdiff_t bytes = stream.read(buffer);
            if (bytes == 0)
                break;
            const(char)[] msg = cast(const(char)[])buffer[0 .. bytes];

            parse_outer: while (!msg.empty)
            {
                HTTPRequest* request = requests.empty ? null : requests[0];

                if (!request)
                {
                    // we have a response, but no associated request...?
                    goto error_out;
                }
                else
                {
                    HTTPResponse* response = request.response;
                    if (!response)
                    {
                        // parse the header stuff...
                        if (msg[0..5] != "HTTP/")
                            goto error_out;
                        msg = msg[5..bytes];

                        bool success;
                        int major = cast(ubyte)msg.parseIntFast(success);
                        if (!success || msg.empty || msg[0] != '.')
                            goto error_out;
                        msg = msg[1..$];
                        int minor = cast(ubyte)msg.parseIntFast(success);
                        if (!success || msg.empty || msg[0] != ' ')
                            goto error_out;
                        msg = msg[1..$];
                        int status = cast(int)msg.parseIntFast(success);
                        if (!success || msg.empty || msg[0] != ' ')
                            goto error_out;
                        size_t newline = msg.findFirst("\r\n");
                        if (newline == msg.length)
                            goto error_out;
                        const(char)[] reason = msg[1 .. newline];

                        msg = msg[newline + 2 .. $];

                        assert(major < 16 && minor < 16, "TODO: change version encoding scheme!");

                        response = defaultAllocator().allocT!HTTPResponse();
                        response.request = request;
                        response.httpVersion = cast(HTTPVersion)((major << 4) | minor);
                        response.statusCode = cast(ushort)status;
                        response.flags = HTTPResponse.Flags.ReadingHeaders;
                        request.response = response;
                    }
                    else
                    {
                        if (response.tail.length)
                        {
                            response.tail ~= buffer[0 .. bytes];
                            msg = response.tail[];

                            assert(response.pendingChunkLen == 0, "How did this happen?");
                        }

                        if (!(response.flags & (HTTPResponse.Flags.ReadingHeaders | HTTPResponse.Flags.ReadingTailHeaders)))
                        {
                            if (response.pendingChunkLen)
                            {
                                if (response.pendingChunkLen > msg.length)
                                {
                                    request.response.pendingChunkLen -= msg.length;
                                    response.content ~= cast(ubyte[])msg;
                                    msg = msg[$ .. $];
                                    continue;
                                }

                                response.content ~= cast(ubyte[])msg[0 .. response.pendingChunkLen];
                                msg = msg[response.pendingChunkLen .. $];
                                response.pendingChunkLen = 0;

                                if (response.flags & HTTPResponse.Flags.Chunked)
                                {
                                    if (response.content[$-2] != '\r' || response.content[$-1] != '\n')
                                        goto error_out;
                                    response.content.resize(response.content.length - 2);
                                }
                            }
                        }
                    }

                read_headers:
                    if (response.flags & (HTTPResponse.Flags.ReadingHeaders | HTTPResponse.Flags.ReadingTailHeaders))
                    {
                        int r = readHeaders(msg, response);
                        if (r < 0)
                            goto error_out;
                        else if (r == 0)
                        {
                            // incomplete data stream while reading headers
                            // store off the current header line and wait for more data...
                            response.tail = msg;
                            break parse_outer;
                        }
                        response.flags &= ~HTTPResponse.Flags.ReadingHeaders;

                        if (response.header("Transfer-Encoding") == "chunked")
                            response.flags |= HTTPResponse.Flags.Chunked;
                    }

                    if ((response.flags & HTTPResponse.Flags.ReadingTailHeaders) || request.method == HTTPMethod.HEAD)
                        goto message_done;

                    // now the body...
                    if (!(response.flags & HTTPResponse.Flags.Chunked))
                    {
                        String val = response.header("Content-Length");
                        if (val)
                        {
                            bool success;
                            long contentLen = val.parseIntFast(success);
                            if (!success)
                                goto error_out; // bad content length
                            response.contentLength = contentLen;
                            if (response.content.length < contentLen)
                                response.pendingChunkLen = contentLen - response.content.length;
                        }
                    }

                    do
                    {
                        if (response.flags & HTTPResponse.Flags.Chunked)
                        {
                            size_t newline = msg.findFirst("\r\n");
                            if (newline == msg.length)
                            {
                                // the buffer ended in the middle of the chunk-length line
                                // we'll have to stash this bit of text and wait for more data...
                                response.tail = msg;
                                assert(false, "TODO: test this case somehow!");
                                break parse_outer;
                            }
                            size_t taken;
                            response.pendingChunkLen = msg[0 .. newline].parseInt(&taken, 16);
                            if (taken != newline)
                                goto error_out; // bad chunk length format!
                            msg = msg[newline + 2 .. $];

                            // a zero chunk informs the end of the data stream
                            if (response.pendingChunkLen == 0)
                            {
                                // jump back to read more headers...
                                response.flags |= HTTPResponse.Flags.ReadingTailHeaders;
                                goto read_headers;
                            }
                            response.contentLength += response.pendingChunkLen;
                            response.pendingChunkLen += 2; // expect `\r\n` to terminate the chunk
                        }

                        if (response.pendingChunkLen > msg.length)
                        {
                            // expect more data...
                            response.content = cast(ubyte[])msg[];
                            response.pendingChunkLen -= msg.length;
                            msg = msg[$..$];

                            response.tail.clear();
                            continue parse_outer;
                        }
                        else if (response.pendingChunkLen > 0)
                        {
                            response.content = cast(ubyte[])msg[0 .. response.pendingChunkLen];
                            msg = msg[response.pendingChunkLen .. $];
                            response.pendingChunkLen = 0;

                            if (response.flags & HTTPResponse.Flags.Chunked)
                            {
                                if (response.content[$-2] != '\r' || response.content[$-1] != '\n')
                                    goto error_out;
                                response.content.resize(response.content.length - 2);
                            }
                        }

                        // a chunked message will return to the top for the next chunk, a non-chunked message is done now
                    }
                    while (response.flags & HTTPResponse.Flags.Chunked);

                message_done:
                    // message complete
                    if (dispatchMessage(*response) < 0)
                        assert(false, "TODO: what do we want to do with a corrupt packet?");
                    sendNext = true;

                    // if we should close the connection
                    if (response.request.httpVersion == HTTPVersion.V1_0 ||
                        response.header("Connection") == "close")
                    {
                        // close the connection
                        stream.disconnect();
                        msg = null;
                    }

                    // free the message data...
                    assert(response.request == requests.front); // this won't work if we accept concurrent messaging...
                    requests.popFront();
                    defaultAllocator().freeT(response.request);
                    defaultAllocator().freeT(response);
                }
            }

            if (bytes < buffer.length)
                break;
        }

        // check for request timeouts...
        {
            MonoTime now = getTime();
            for (size_t i = 0; i < requests.length; )
            {
                HTTPRequest* r = requests[i];
                if (now - r.requestTime > 5.seconds)
                {
                    requests.remove(i);
                    sendNext = true;

                    // free the message data...
                    if (r.response)
                        defaultAllocator().freeT(r.response);
                    defaultAllocator().freeT(r);
                }
                else
                    ++i;
            }
        }

        if (sendNext && requests.length > 0)
            sendRequest(*requests[0]);

        return;

    error_out:
        stream.disconnect();
    }

private:
    int readHeaders(ref const(char)[] msg, HTTPResponse* response)
    {
        // parse headers...
        while (true)
        {
            size_t newline = msg.findFirst("\r\n");
            if (newline == msg.length)
                return 0;

            const(char)[] line = msg[0 .. newline];
            msg = msg[newline + 2 .. $];
            if (newline == 0)
                break; // empty line marks end of header fields

            if (line[0].isWhitespace)
            {
                assert(false, "TODO: just check this path is correct...");

                // line continues last header value...
                if (response.headers.empty)
                    return -1; // bad header format
                MutableString!0 newVal = MutableString!0(Concat, response.headers[$ - 1].value, ' ', line.trim);
                response.headers[$ - 1].value = String(newVal.move);
            }
            else
            {
                // header field...
                size_t colon = line.findFirst(':');
                if (colon == line.length)
                    return -1; // bad header format

                const(char)[] key = line[0 .. colon];
                const(char)[] value = line[colon + 2 .. $].trim;

                response.headers ~= HTTPParam(key.makeString(defaultAllocator), value.makeString(defaultAllocator));
            }
        }
        return 1;
    }

    void sendRequest(ref HTTPRequest request)
    {
        bool includeBody = true;
        if (request.method == HTTPMethod.HEAD || request.method == HTTPMethod.TRACE || request.method == HTTPMethod.CONNECT)
            includeBody = false;
        if (includeBody && request.content.length == 0 && !(request.flags & HTTPFlags.ForceBody))
            includeBody = false;

        // build the query string
        MutableString!0 get;
        foreach (ref q; request.queryParams)
        {
            bool first = get.empty;

            size_t keyLen = q.key.url_encode_length();
            size_t valLen = q.value.url_encode_length();
            char[] ext = get.extend(keyLen + valLen + 2);

            if (first)
                ext[0] = '?';
            else
                ext[0] = '&';
            if (q.key.url_encode(ext[1 .. 1 + keyLen]) != keyLen)
                return; // bad encoding!
            ext = ext[1 + keyLen .. $];
            ext[0] = '=';
            if (q.value.url_encode(ext[1 .. 1 + valLen]) != valLen)
                return; // bad encoding!
        }

        MutableString!0 message;
        message.concat(methodString[request.method], ' ', request.url, get, " HTTP/", request.httpVersion >> 4, '.', request.httpVersion & 0xF,
                       "\r\nHost: ", host,
                       "\r\nUser-Agent: ENMS\r\nAccept-Encoding: gzip, deflate\r\n");
        if (request.httpVersion == HTTPVersion.V1_1)
            message.append("Connection: keep-alive\r\n");

        if (request.username || request.password)
        {
            if (!(request.username && request.password))
                return; // must have both or neither

            message ~= "Authorization: Basic ";

            const(char)[] auth = tconcat(request.username, ':', request.password);
            auth.base64_encode(message.extend(base64_encode_length(auth.length)));
        }

        if (includeBody)
        {
            message.append("Content-Length: ", request.content.length, "\r\n");
            // TODO: how do we determine the content type?
//            message.append("Content-Type: application/x-www-form-urlencoded\r\n");
        }
        foreach (ref h; request.headers)
            message.append(h.key, ": ", h.value, "\r\n");
        message ~= "\r\n";

        if (includeBody)
            message ~= cast(char[])request.content[];

        ptrdiff_t r = stream.write(message);
        if (r != message.length)
        {
            assert(false, "TODO: handle error!");
        }

        version (DebugHTTPMessageFlow) {
            import urt.log;
            writeDebug("HTTP: request to ", host, " - ", methodString[request.method], " ", request.url, " (", request.content.length, " bytes)");
        }
    }

    int dispatchMessage(ref HTTPResponse response)
    {
        import urt.zip;

        version (DebugHTTPMessageFlow) {
            import urt.log;
            writeDebug("HTTP: response from ", host, " - ", response.statusCode, " (", response.content.length, " bytes)");
        }

        switch (response.header("Content-Encoding"))
        {
            case "":
            case "identity":
                break;

            case "gzip":
            case "x-gzip":
                Array!ubyte uncompressed;
                size_t uncompressedLen;

                if (gzip_uncompressed_length(response.content[], uncompressedLen) != error_code.OK)
                    return -1;
                uncompressed.resize(uncompressedLen);
                if (gzip_uncompress(response.content[], uncompressed[], uncompressedLen) != error_code.OK)
                    return -1;
                if (uncompressedLen != uncompressed.length)
                    return -1; // something went wrong!

                // update the message
                response.content = uncompressed.move;
                response.contentLength = response.content.length;
                break;

            case "deflate":
                // trouble with deflate, is we don't know how big the uncompressed buffer should be!
                assert(false, "TODO");
                break;

            case "compress":    // LZW
            case "x-compress":  //  "
            case "br":          // Brotli compression
            case "zstd":        // Zstandard
                // we don't have decompression for these...
                assert(false, "Not supported!");

            default:
                assert(false, "Unknown encoding!");
        }

        if (response.request.responseHandler)
            response.request.responseHandler(response);

        return 0;
    }
}


private:

__gshared immutable string[] methodString = [ "GET", "HEAD", "OPTIONS", "POST", "PUT", "PATCH", "DELETE", "TRACE", "CONNECT" ];
