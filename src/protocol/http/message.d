module protocol.http.message;

import urt.array;
import urt.conv;
import urt.encoding;
import urt.kvp;
import urt.lifetime;
import urt.log;
import urt.meta;
import urt.string;
import urt.mem : memmove;
import urt.mem.allocator;
import urt.time;
import urt.zip;

import protocol.http;

import router.stream.tcp;

version = DebugHTTPMessageFlow;

nothrow @nogc:

alias HTTPParam = KVP!(String, String);

alias HTTPMessageHandler = int delegate(ref const HTTPMessage) nothrow @nogc;

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

struct HTTPMessage
{
nothrow @nogc:

    this(this) @disable;

    HTTPVersion httpVersion;        // HTTP version (e.g., "HTTP/1.1", "HTTP/2")
    HTTPMethod method;              // HTTP method (e.g., GET, POST, PUT, DELETE)
    HTTPFlags flags;                // Request flags

    ushort statusCode;              // Status code (e.g., 200, 404, 500) // TODO: Collapse with flags
    String reason;                  // Reason
    String url;                     // URL or path (e.g., "/index.html" or full "https://example.com")
    String requestTarget;

    String username;                // Username
    String password;                // Password

    size_t contentLength;           // Length of the body, if applicable
    Array!ubyte content;            // Optional body for POST/PUT requests
    Array!HTTPParam headers;        // Array of additional headers
    Array!HTTPParam queryParams;    // Query parameters

    HTTPMessageHandler responseHandler;
    SysTime requestTime;

    bool isRequest() const pure
        => statusCode == 0;

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

struct HTTPParser
{
nothrow @nogc:
    enum ParseState : ubyte
    {
        Pending,
        ReadingHeaders,
        ReadingBody,
        ReadingTailHeaders,
    }

    enum Flags : ubyte
    {
        None = 0,
        Chunked = 1,
    }

    HTTPMessage message;
    ParseState state;

    HTTPMessageHandler messageHandler;

    Array!ubyte tail;
    size_t pendingChunkLen;
    Flags flags;

    this() @disable;
    this(this) @disable;

    this(HTTPMessageHandler messageHandler)
    {
        this.messageHandler = messageHandler;
    }

    int update(Stream stream)
    {
        ubyte[1024] buffer = void;
        buffer[0 .. tail.length] = tail[];
        size_t readOffset = tail.length;
        tail.clear();

        while (true)
        {
            ptrdiff_t bytes = stream.read(buffer[readOffset .. $]);
            if (bytes == 0)
                break;

            bytes += readOffset;
            readOffset = 0;

            const(char)[] msg = cast(const(char)[])buffer[0 .. bytes];

            final switch (state)
            {
                case ParseState.Pending:
                    int r = isResponse(msg) ? readStatusLine(msg, message) : readRequestLine(msg, message);
                    // TODO: what if there is insufficient text to read the first line? we should stash the tail and wait for more data...
                    if (r != 0)
                        return -1;
                    state = ParseState.ReadingHeaders;
                    goto case ParseState.ReadingHeaders;

                case ParseState.ReadingHeaders:
                case ParseState.ReadingTailHeaders:
                    int r = readHeaders(msg, message);
                    if (r < 0)
                        return -1;
                    else if (r == 0)
                    {
                        // incomplete data stream while reading headers
                        // store off the current header line and wait for more data...
                        memmove(buffer.ptr, msg.ptr, msg.length);
                        readOffset = msg.length;
                        break;
                    }

                    if (state == ParseState.ReadingTailHeaders || message.method == HTTPMethod.HEAD)
                        goto message_done;

                    if (message.header("Transfer-Encoding") == "chunked")
                    {
                        flags |= Flags.Chunked;
                    }
                    else
                    {
                        String val = message.header("Content-Length");
                        if (val)
                        {
                            bool success;
                            size_t contentLen = val.parse_int_fast(success);
                            if (!success)
                                return -1; // bad content length
                            message.contentLength = contentLen;
                            if (message.content.length < contentLen)
                                pendingChunkLen = contentLen - message.content.length;
                        }

                        // TODO: what if there is no Content-Length??
                        //       do we just read bytes until the remote closes the stream?
                        // TODO: what if Content-Length is 0???
                        //       go straight to message_done?
                    }

                    state = ParseState.ReadingBody;
                    goto case ParseState.ReadingBody;

                case ParseState.ReadingBody:
                    if (pendingChunkLen)
                    {
                        if (pendingChunkLen > msg.length)
                        {
                            pendingChunkLen -= msg.length;
                            message.content ~= cast(ubyte[])msg;
                            msg = null;
                            break;
                        }

                        message.content ~= cast(ubyte[])msg[0 .. pendingChunkLen];
                        msg = msg[pendingChunkLen .. $];
                        pendingChunkLen = 0;

                        if (flags & Flags.Chunked)
                        {
                            // trim the newline from the end of the chunk
                            if (message.content.length < 2 || message.content[$-2] != '\r' || message.content[$-1] != '\n')
                                return -1;
                            message.content.resize(message.content.length - 2);
                        }
                    }

                    if (flags & Flags.Chunked)
                    {
                        // get the length for the next chunk...
                        size_t newline = msg.findFirst("\r\n");
                        // TODO: there should be some upper-limit to the length of the line that it will wait on...
                        //       it should just be an integer chunk length, so probably doesn't need to be too big!
                        if (newline == msg.length)
                        {
                            // the buffer ended in the middle of the chunk-length line
                            // we'll have to stash this bit of text and wait for more data...
                            memmove(buffer.ptr, msg.ptr, msg.length);
                            readOffset = msg.length;
                            assert(false, "TODO: test this case somehow!");
                            break;
                        }
                        size_t taken;
                        pendingChunkLen = cast(size_t)msg[0 .. newline].parse_int(&taken, 16);
                        if (taken != newline)
                            return -1; // bad chunk length format!
                        msg = msg[newline + 2 .. $];

                        // a zero chunk informs the end of the data stream
                        if (pendingChunkLen == 0)
                        {
                            // jump back to read more headers...
                            state = ParseState.ReadingTailHeaders;
                            goto case ParseState.ReadingTailHeaders;
                        }
                        message.contentLength += pendingChunkLen;
                        pendingChunkLen += 2; // expect `\r\n` to terminate the chunk

                        goto case ParseState.ReadingBody;
                    }

                message_done:
                    int result = handleEncoding();
                    if (result != 0)
                        return -1;

                    if (message.isRequest)
                        message.requestTime = getSysTime();

                    // message complete
                    if (messageHandler(message) < 0)
                        return -1;

                    if (!stream.running)
                        msg = null;

                    message = HTTPMessage();
                    state = ParseState.Pending;

                    if (!msg.empty)
                        goto case ParseState.Pending;
                    break;
            }

            if (bytes < buffer.length)
                break;
        }

        // stash the tail for later...
        if (readOffset > 0)
            tail = buffer[0 .. readOffset];

        return 0;
    }

private:
    static bool readHttpVersion(ref const(char)[] msg, ref HTTPMessage message)
    {
        string http = "HTTP/";
        if (msg[0..http.length] != http)
            return false;

        msg = msg[http.length..$];

        bool success;
        int major = msg.parse_int_fast(success);
        if (!success || msg.empty || msg[0] != '.')
            return false;

        msg = msg[1..$];

        int minor = msg.parse_int_fast(success);
        if (!success || msg.empty)
            return false;

        if (major >= 16 || minor >= 16)
        {
            writeError("Error writing session history.");
            return false;
        }

        message.httpVersion = cast(HTTPVersion)((major << 4) | minor);

        return true;
    }

    static bool isResponse(const char[] msg)
    {
        string http = "HTTP/";
        return msg[0..http.length] == http;
    }

    static int readStatusLine(ref const(char)[] msg, ref HTTPMessage message)
    {
        if(!readHttpVersion(msg, message))
           return -1;

        if (msg.empty || msg[0] != ' ')
            return -1;
        msg = msg[1..$];

        bool success;
        const int status = msg.parse_int_fast(success);
        if (!success || msg.empty || msg[0] != ' ')
            return -1;

        const size_t newline = msg.findFirst('\n');
        if (newline == msg.length)
            return -1;

        const size_t endOfReason = msg[newline - 1] == '\r' ? newline - 1 : newline;

        message.reason = msg[1 .. endOfReason].makeString(defaultAllocator);

        msg = msg[newline + 1 .. $];

        message.statusCode = cast(ushort)status;

        return 0;
    }

    static int readRequestLine(ref const(char)[] msg, ref HTTPMessage message)
    {
        HTTPMethod method = msg.split!(' ', false).enum_from_string!HTTPMethod;
        if (byte(method) == -1)
            return -1;

        if (int result = readRequestTarget(msg, message))
            return result;

        if (!readHttpVersion(msg, message))
            return -1;

        if (msg.takeLine.length != 0)
            return -1;

        return 0;
    }

    static int readRequestTarget(ref const(char)[] msg, ref HTTPMessage message)
    {
        const(char)[] requestTarget = msg.split!(' ', false);

        // authority-form
        if (message.method == HTTPMethod.CONNECT)
        {
            // CONNECT www.example.com:80 HTTP/1.1
            message.requestTarget = StringLit!"/";
            return 0;
        }

        // asterisk-form
        if (message.method == HTTPMethod.OPTIONS)
        {
            // OPTIONS * HTTP/1.1
            message.requestTarget = StringLit!"/";
            return 0;
        }

        const(char)[] query = requestTarget;
        requestTarget = query.split!('?', false);

        int result = readQueryParams(query, message);
        if (result != 0)
            return result;

        // absolute-form
        string schemeStr = "://";
        const size_t scheme = requestTarget.findFirst(schemeStr);
        if (scheme != requestTarget.length)
        {
            const(char)[] subStr = requestTarget[scheme + schemeStr.length..$];
            const size_t slash = subStr[0..$].findFirst('/');
            if (slash == subStr.length)
            {
                message.requestTarget = StringLit!"/";
                return 0;
            }

            message.requestTarget = subStr[slash..$].makeString(defaultAllocator);
            return 0;
        }

        // origin-form
        message.requestTarget = requestTarget.makeString(defaultAllocator);

        return 0;
    }

    static int readQueryParams(ref const(char)[] msg, ref HTTPMessage message)
    {
        while (msg.length > 0)
        {
            const(char)[] kvp = msg.split!('&', false);
            const(char)[] key = kvp.split!('=', false);
            message.queryParams ~= HTTPParam(key.makeString(defaultAllocator), kvp.makeString(defaultAllocator));
        }
        return 0;
    }

    int handleEncoding()
    {
        switch (message.header("Content-Encoding"))
        {
            case "":
            case "identity":
                break;

            case "gzip":
            case "x-gzip":
                Array!ubyte uncompressed;
                size_t uncompressedLen;

                if (!gzip_uncompressed_length(message.content[], uncompressedLen))
                    return -1;
                uncompressed.resize(uncompressedLen);
                if (!gzip_uncompress(message.content[], uncompressed[], uncompressedLen))
                    return -1;
                if (uncompressedLen != uncompressed.length)
                    return -1; // something went wrong!

                // update the message
                message.content = uncompressed.move;
                message.contentLength = message.content.length;
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

        return 0;
    }

    static int readHeaders(ref const(char)[] msg, ref HTTPMessage message)
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

            if (line[0].is_whitespace)
            {
                assert(false, "TODO: just check this path is correct...");

                // line continues last header value...
                if (message.headers.empty)
                    return -1; // bad header format
                MutableString!0 newVal = MutableString!0(Concat, message.headers[$ - 1].value, ' ', line.trim);
                message.headers[$ - 1].value = String(newVal.move);
            }
            else
            {
                // header field...
                size_t colon = line.findFirst(':');
                if (colon == line.length)
                    return -1; // bad header format

                const(char)[] key = line[0 .. colon];
                const(char)[] value = line[colon + 2 .. $].trim;

                message.headers ~= HTTPParam(key.makeString(defaultAllocator), value.makeString(defaultAllocator));
            }
        }
        return 1;
    }
}

void httpStatusLine(HTTPVersion httpVersion, ushort statusCode, const(char)[] reason, ref MutableString!0 str)
{
    str.append("HTTP/", httpVersion >> 4, '.', httpVersion & 0xF, ' ', statusCode, ' ', reason, "\r\n");
}

void httpFieldLines(scope const HTTPParam[] params, ref MutableString!0 str)
{
    foreach (ref const kvp; params)
        str.append( kvp.key, ':', kvp.value, "\r\n");
}

void httpDate(ref const DateTime date, ref MutableString!0 str)
{
    const(char)[] day = enum_keys!Day[date.wday];
    const(char)[] month = enum_keys!Month[date.month];

    // IMF-fixdate
    // Sun, 06 Nov 1994 08:49:37 GMT

    //                      wday  day  month year hours  mins   secs
    str.appendFormat("Date: {0}, {1,02} {2}, {3}, {4,02}:{5,02}:{6,02} GMT \r\n",
                     day[0..3], date.day, month[0..3], date.year, date.hour, date.minute, date.second);
}
