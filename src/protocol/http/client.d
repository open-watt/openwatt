module protocol.http.client;

import urt.array;
import urt.conv;
import urt.encoding;
import urt.kvp;
import urt.lifetime;
import urt.mem.allocator;
import urt.meta;
import urt.string;
import urt.string.format : tconcat;
import urt.time;

import protocol.http;
import protocol.http.message;

import router.stream.tcp;

nothrow @nogc:

class HTTPClient
{
nothrow @nogc:

    String name;
    String host;
    Stream stream;
    HTTPVersion serverVersion = HTTPVersion.V1_1;

    HTTPParser parser;
    Array!(HTTPMessage*) requests;

    this(String name, Stream stream, String host)
    {
        this.name = name.move;
        this.stream = stream;
        this.host = host.move;

        this.parser = HTTPParser(&dispatchMessage);
    }

    HTTPMessage* request(HTTPMethod method, const(char)[] resource, int delegate(ref const HTTPMessage) nothrow @nogc responseHandler, const void[] content = null, HTTPParam[] params = null, HTTPParam[] additionalHeaders = null, String username = null, String password = null)
    {
        HTTPMessage* request = defaultAllocator().allocT!HTTPMessage();
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
        if (requests.empty)
            return;

        int result = parser.update(stream);
        if (result != 0)
        {
            stream.disconnect();
            return;
        }

        bool sendNext = false;
        // check for request timeouts...
        MonoTime now = getTime();
        for (size_t i = 0; i < requests.length; )
        {
            HTTPMessage* r = requests[i];
            if (now - r.requestTime > 5.seconds)
            {
                requests.remove(i);
                defaultAllocator().freeT(r);
                sendNext = true;
            }
            else
                ++i;
        }

       if (sendNext && requests.length > 0)
           sendRequest(*requests[0]);
    }

    bool connected()
        => stream.connected();


private:
    void sendRequest(ref HTTPMessage request)
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
        message.concat(EnumKeys!HTTPMethod[request.method], ' ', request.url, get, " HTTP/", request.httpVersion >> 4, '.', request.httpVersion & 0xF,
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
            writeDebug("HTTP: request to ", host, " - ", EnumKeys!HTTPMethod[request.method], " ", request.url, " (", request.content.length, " bytes)");
        }
    }

    int dispatchMessage(ref const HTTPMessage response)
    {
        version (DebugHTTPMessageFlow) {
            import urt.log;
            writeDebug("HTTP: response from ", host, " - ", response.statusCode, " (", response.content.length, " bytes)");
        }

        if (requests.empty)
            return -1;

        // if we should close the connection
        if (requests[0].httpVersion == HTTPVersion.V1_0 || requests[0].header("Connection") == "close")
            stream.disconnect();

        if (requests[0].responseHandler)
            requests[0].responseHandler(response);

        defaultAllocator().freeT(requests[0]);
        requests.popFront();

        if (requests.length > 0)
            sendRequest(*requests[0]);

        return 0;
    }
}
