module apps.ota;

import urt.lifetime;
import urt.log;
import urt.mem.allocator;
import urt.string;
import urt.time;

import manager;
import manager.base;
import manager.collection;
import manager.cron : CronModule;
import manager.plugin;

import driver.system;

import protocol.http.message;
import protocol.http.server;

import router.stream;

nothrow @nogc:


class OTAUpdater : ActiveObject
{
    alias Properties = AliasSeq!(Prop!("http-server", http_server),
                                 Prop!("uri", uri),
                                 Prop!("method", method),
                                 Prop!("reboot-delay", reboot_delay));
nothrow @nogc:

    enum type_name = "ota";
    enum path = "/apps/ota";
    enum collection_id = CollectionType.ota;

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!OTAUpdater, id, flags);
        _reboot_delay = 500.msecs;
    }

    inout(HTTPServer) http_server() inout pure
        => _http_server.get();
    final void http_server(HTTPServer value)
    {
        if (_http_server is value)
            return;
        if (_subscribed)
        {
            _http_server.unsubscribe(&server_state_change);
            _subscribed = false;
        }
        _http_server = value;
        restart();
    }

    const(char)[] uri() const pure
        => _uri[];
    void uri(const(char)[] value)
    {
        _uri = value.makeString(defaultAllocator);
        restart();
    }

    HTTPMethod method() const pure
        => _method;
    void method(HTTPMethod value)
    {
        if (_method == value)
            return;
        _method = value;
        restart();
    }

    Duration reboot_delay() const pure
        => _reboot_delay;
    void reboot_delay(Duration value)
    {
        _reboot_delay = value;
    }

protected:
    mixin RekeyHandler;

    override bool validate() const
        => _http_server.get() !is null && _uri.length > 0 && ota_supported();

    override CompletionStatus startup()
    {
        if (!_http_server || !_http_server.running)
            return CompletionStatus.continue_;

        if (!_http_server.add_uri_handler(_method, _uri[], &begin_request))
        {
            log.error("failed to register handler at ", _uri);
            return CompletionStatus.error;
        }
        _registered = true;
        _http_server.subscribe(&server_state_change);
        _subscribed = true;
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        if (_subscribed)
        {
            _http_server.unsubscribe(&server_state_change);
            _subscribed = false;
        }
        if (_registered)
        {
            _http_server.remove_uri_handler(_method, &begin_request);
            _registered = false;
        }
        if (_handle != 0)
        {
            ota_abort(_handle);
            _handle = 0;
        }
        return CompletionStatus.complete;
    }


private:

    ObjectRef!HTTPServer _http_server;
    String _uri;
    HTTPMethod _method = HTTPMethod.PUT;
    Duration _reboot_delay;
    bool _registered;
    bool _subscribed;
    uint _handle;
    size_t _total;
    size_t _received;
    size_t _next_progress_log;
    size_t _chunks_since_progress;
    size_t _min_chunk_size;
    size_t _max_chunk_size;

    void server_state_change(ActiveObject, StateSignal signal)
    {
        if (signal == StateSignal.offline)
            restart();
    }

    StreamingChunkHandler begin_request(ref const HTTPMessage req, ref Stream stream)
    {
        if (_handle != 0)
            return reject(stream, req, 503, "OTA already in progress");

        size_t partition = ota_partition_size();
        if (req.contentLength == 0)
            return reject(stream, req, 411, "Content-Length required");
        if (req.contentLength > partition)
            return reject(stream, req, 413, "firmware too large for partition");

        int err = ota_begin(req.contentLength, _handle);
        if (err != 0)
        {
            log.error("ota_begin failed: ", err);
            return reject(stream, req, 500, "ota_begin failed");
        }

        _total = req.contentLength;
        _received = 0;
        _next_progress_log = _total / 10;
        _chunks_since_progress = 0;
        _min_chunk_size = size_t.max;
        _max_chunk_size = 0;

        log.notice("receiving ", req.contentLength, " bytes");
        return &on_chunk;
    }

    int on_chunk(ref const HTTPMessage req, const(ubyte)[] chunk, bool final_chunk, ref Stream stream)
    {
        if (chunk.length > 0)
        {
            int err = ota_write(_handle, chunk);
            if (err != 0)
            {
                log.error("ota_write failed: ", err);
                ota_abort(_handle);
                _handle = 0;
                send_response(stream, req, 500, "ota_write failed");
                return -1;
            }
            _received += chunk.length;
            ++_chunks_since_progress;
            if (chunk.length < _min_chunk_size) _min_chunk_size = chunk.length;
            if (chunk.length > _max_chunk_size) _max_chunk_size = chunk.length;
            while (_total > 0 && _received >= _next_progress_log && _next_progress_log < _total)
            {
                uint pct = cast(uint)((_received * 100) / _total);
                log.info("progress ", pct, "% (", _received, "/", _total, " bytes, ",
                         _chunks_since_progress, " chunks min=", _min_chunk_size, " max=", _max_chunk_size, ")");
                _next_progress_log += _total / 10;
                _chunks_since_progress = 0;
                _min_chunk_size = size_t.max;
                _max_chunk_size = 0;
            }
        }

        if (final_chunk)
        {
            int err = ota_end(_handle);
            _handle = 0;
            if (err != 0)
            {
                log.error("ota_end failed: ", err);
                send_response(stream, req, 500, "ota_end failed");
                return -1;
            }

            send_response(stream, req, 200, "OTA accepted, rebooting");
            log.notice("complete, rebooting in ", _reboot_delay);
            get_module!CronModule.schedule_oneshot(_reboot_delay, "/system/reboot");
        }
        return 0;
    }

    StreamingChunkHandler reject(ref Stream stream, ref const HTTPMessage req, ushort code, const(char)[] reason)
    {
        send_response(stream, req, code, reason);
        log.warning(code, " ", reason);
        return null;
    }

    void send_response(ref Stream stream, ref const HTTPMessage req, ushort code, const(char)[] body_)
    {
        HTTPMessage response = create_response(req.http_version, code, StringLit!"text/plain", body_);
        stream.write(response.format_message()[]);
    }
}


class OTAModule : Module
{
    mixin DeclareModule!"apps.ota";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!OTAUpdater();
    }

    override void update()
    {
        Collection!OTAUpdater().update_all();
    }
}
