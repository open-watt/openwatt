module protocol.http.message;

import urt.array;
import urt.conv;
import urt.encoding;
import urt.kvp;
import urt.lifetime;
import urt.log;
import urt.string;
import urt.mem.allocator;
import urt.time;
import urt.zip;

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

    String username;                // Username
    String password;                // Password

    size_t contentLength;           // Length of the body, if applicable
    Array!ubyte content;            // Optional body for POST/PUT requests
    Array!HTTPParam headers;        // Array of additional headers
    Array!HTTPParam queryParams;    // Query parameters

    int delegate(ref const HTTPMessage) nothrow @nogc responseHandler;
    MonoTime requestTime;

    bool isRequest() => statusCode == 0;

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
    enum Flags : ubyte
    {
        None = 0,
        Chunked = 1,
        ReadingHeaders = 2,
        ReadingTailHeaders = 4
    }

    HTTPMessage message;
    bool messageInUse;

    int delegate(ref const HTTPMessage) nothrow @nogc messageHandler;

    Array!char tail;
    size_t pendingChunkLen;
    Flags flags;

    this(this) @disable;

    this(int delegate(ref const HTTPMessage) nothrow @nogc messageHandler)
    {
        this.messageHandler = messageHandler;
    }

    int update(Stream stream)
    {
        while (true)
        {
            ubyte[1024] buffer = void;
            const ptrdiff_t bytes = stream.read(buffer);
            if (bytes == 0)
                break;

            const(char)[] msg = cast(const(char)[])buffer[0 .. bytes];

            parse_outer: while (!msg.empty)
            {
                // Assuming response
                if (!messageInUse)
                {
                    if (isResponse(msg))
                    {
                        int result = readStatusLine(msg, message);
                        if (result != 0)
                            return -1;
                    }
                    else
                    {
                        // TODO readRequestLine
                        return -1;
                    }

                    messageInUse = true;
                }
                else
                {
                    if (tail.length)
                    {
                        tail ~= buffer[0 .. bytes];
                        msg = tail[];

                        assert(pendingChunkLen == 0, "How did this happen?");
                    }

                    if (!(flags & (Flags.ReadingHeaders | Flags.ReadingTailHeaders)))
                    {
                        if (pendingChunkLen)
                        {
                            if (pendingChunkLen > msg.length)
                            {
                                pendingChunkLen -= msg.length;
                                message.content ~= cast(ubyte[])msg;
                                msg = msg[$ .. $];
                                continue;
                            }

                            message.content ~= cast(ubyte[])msg[0 .. pendingChunkLen];
                            msg = msg[pendingChunkLen .. $];
                            pendingChunkLen = 0;

                            if (flags & Flags.Chunked)
                            {
                                if (message.content[$-2] != '\r' || message.content[$-1] != '\n')
                                    return -1;
                                message.content.resize(message.content.length - 2);
                            }
                        }
                    }
                }

            read_headers:
                if (flags & (Flags.ReadingHeaders | Flags.ReadingTailHeaders))
                {
                    int r = readHeaders(msg, message);
                    if (r < 0)
                        return -1;
                    else if (r == 0)
                    {
                        // incomplete data stream while reading headers
                        // store off the current header line and wait for more data...
                        tail = msg;
                        break parse_outer;
                    }
                    flags &= ~Flags.ReadingHeaders;

                    if (message.header("Transfer-Encoding") == "chunked")
                        flags |= Flags.Chunked;
                }

                if ((flags & Flags.ReadingTailHeaders) || message.method == HTTPMethod.HEAD)
                    goto message_done;

                // now the body...
                if (!(flags & Flags.Chunked))
                {
                    String val = message.header("Content-Length");
                    if (val)
                    {
                        bool success;
                        size_t contentLen = val.parseIntFast(success);
                        if (!success)
                            return -1; // bad content length
                        message.contentLength = contentLen;
                        if (message.content.length < contentLen)
                            pendingChunkLen = contentLen - message.content.length;
                    }
                }

                do
                {
                    if (flags & Flags.Chunked)
                    {
                        size_t newline = msg.findFirst("\r\n");
                        if (newline == msg.length)
                        {
                            // the buffer ended in the middle of the chunk-length line
                            // we'll have to stash this bit of text and wait for more data...
                            tail = msg;
                            assert(false, "TODO: test this case somehow!");
                            break parse_outer;
                        }
                        size_t taken;
                        pendingChunkLen = cast(size_t)msg[0 .. newline].parseInt(&taken, 16);
                        if (taken != newline)
                            return -1; // bad chunk length format!
                        msg = msg[newline + 2 .. $];

                        // a zero chunk informs the end of the data stream
                        if (pendingChunkLen == 0)
                        {
                            // jump back to read more headers...
                            flags |= Flags.ReadingTailHeaders;
                            goto read_headers;
                        }
                        message.contentLength += pendingChunkLen;
                        pendingChunkLen += 2; // expect `\r\n` to terminate the chunk
                    }

                    if (pendingChunkLen > msg.length)
                    {
                        // expect more data...
                        message.content = cast(ubyte[])msg[];
                        pendingChunkLen -= msg.length;
                        msg = msg[$..$];

                        tail.clear();
                        continue parse_outer;
                    }
                    else if (pendingChunkLen > 0)
                    {
                        message.content = cast(ubyte[])msg[0 .. pendingChunkLen];
                        msg = msg[pendingChunkLen .. $];
                        pendingChunkLen = 0;

                        if (flags & Flags.Chunked)
                        {
                            if (message.content[$-2] != '\r' || message.content[$-1] != '\n')
                                return -1;
                            message.content.resize(message.content.length - 2);
                        }
                    }

                    // a chunked message will return to the top for the next chunk, a non-chunked message is done now
                }
                while (flags & Flags.Chunked);

            message_done:

                int result = handleEncoding();
                if (result != 0)
                    return -1;

                 // message complete
                if (messageHandler(message) < 0)
                    return -1;

                if (!stream.connected())
                    msg = null;

                message = HTTPMessage();
                messageInUse = false;
            }

            if (bytes < buffer.length)
                break;
        }

        return 0;
    }

private:
    bool readHttpVersion(ref const(char)[] msg, ref HTTPMessage message)
    {
        string http = "HTTP/";
        if (msg[0..http.length] != http)
            return false;

        msg = msg[http.length..$];

        bool success;
        int major = msg.parseIntFast(success);
        if (!success || msg.empty || msg[0] != '.')
            return false;

        msg = msg[1..$];

        int minor = msg.parseIntFast(success);
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

    bool isResponse(const char[] msg)
    {
        string http = "HTTP/";
        return msg[0..http.length] == http;
    }

    int readStatusLine(ref const(char)[] msg, ref HTTPMessage message)
    {
        if(!readHttpVersion(msg, message))
           return -1;

        if (msg.empty || msg[0] != ' ')
            return -1;

        msg = msg[1..$];

        bool success;
        const int status = msg.parseIntFast(success);
        if (!success || msg.empty || msg[0] != ' ')
            return -1;

        const size_t newline = msg.findFirst('\n');
        if (newline == msg.length)
            return -1;

        const size_t endOfReason = msg[newline - 1] == '\r' ? newline - 1 : newline;

        message.reason = msg[1 .. endOfReason].makeString(defaultAllocator);

        msg = msg[newline + 1 .. $];

        message.statusCode = cast(ushort)status;
        flags = Flags.ReadingHeaders;

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

                if (gzip_uncompressed_length(message.content[], uncompressedLen) != error_code.OK)
                    return -1;
                uncompressed.resize(uncompressedLen);
                if (gzip_uncompress(message.content[], uncompressed[], uncompressedLen) != error_code.OK)
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

    int readHeaders(ref const(char)[] msg, ref HTTPMessage message)
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

package:

__gshared immutable string[] methodString = [ "GET", "HEAD", "OPTIONS", "POST", "PUT", "PATCH", "DELETE", "TRACE", "CONNECT" ];
