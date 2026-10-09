module router.stream.file;

import urt.file;
import urt.lifetime;
import urt.mem.pagepool : Page, page_free;
import urt.mem.temp;
import urt.result : Result;
import urt.string;
import urt.string.format;
import urt.time;

import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;

import router.stream;

nothrow @nogc:


// reads a file into the pages a sink pulls, ending after length bytes or at EOF; a read that fails aborts and keeps the result
struct FileProducer
{
nothrow @nogc:
    enum ulong to_eof = ulong.max;

    File file;
    ulong remaining;
    Result failure;

    this(ref File opened, ulong length)
    {
        file = opened.move;
        remaining = length;
    }

    Page* produce(ref const TxRequest req, out TxStatus status)
    {
        if (remaining == 0)
        {
            status = TxStatus.end;
            return null;
        }
        size_t take = remaining < req.bytes ? cast(size_t)remaining : req.bytes;
        if (take > max_tx_page)
            take = max_tx_page;
        Page* page = alloc_tx_page(req, take, status);
        if (!page)
            return null;
        size_t got;
        failure = file.read(page.data, got);
        if (!failure || got == 0 || (got != take && remaining != to_eof))
        {
            page_free(page);
            status = failure && got == 0 && remaining == to_eof ? TxStatus.end : TxStatus.abort;
            return null;
        }
        page.length = cast(ushort)got;
        if (remaining != to_eof && (remaining -= got) == 0)
            status = TxStatus.end;
        return page;
    }
}


enum FileMode : ubyte
{
    truncate,  // overwrite tx file from the start
    append,    // append to existing tx file
}


final class FileStream : Stream
{
    alias Properties = AliasSeq!(Prop!("tx-file", tx_file),
                                 Prop!("rx-file", rx_file),
                                 Prop!("tx-mode", tx_mode));
nothrow @nogc:

    enum type_name = "file";
    enum path = "/stream/file";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!FileStream, id, flags, StreamOptions.none);
    }

    ~this()
    {
        close_files();
    }

    // Properties

    final ref const(String) tx_file() const pure => _tx_path;
    final void tx_file(String value)
    {
        if (value == _tx_path)
            return;
        _tx_path = value.move;
        mark_set!(typeof(this), "tx-file")();
        restart();
    }

    final ref const(String) rx_file() const pure => _rx_path;
    final void rx_file(String value)
    {
        if (value == _rx_path)
            return;
        _rx_path = value.move;
        mark_set!(typeof(this), "rx-file")();
        restart();
    }

    final FileMode tx_mode() const pure => _tx_mode;
    final void tx_mode(FileMode value)
    {
        if (value == _tx_mode)
            return;
        _tx_mode = value;
        mark_set!(typeof(this), "tx-mode")();
        restart();
    }

    // API

    override size_t tx_request() const
        => _tx.is_open ? super.tx_request() : 0;

    override ptrdiff_t write(const(void[])[] data...)
    {
        if (!_tx.is_open)
            return 0;
        size_t total;
        foreach (d; data)
        {
            size_t n;
            Result r = _tx.write(d, n);
            total += n;
            if (!r || n < d.length)
                break;
        }
        if (total)
        {
            add_tx_bytes(total);
            if (_logging)
            {
                size_t remain = total;
                foreach (d; data)
                {
                    if (remain == 0)
                        break;
                    size_t chunk = d.length < remain ? d.length : remain;
                    write_to_log(false, d[0 .. chunk]);
                    remain -= chunk;
                }
            }
        }
        return total;
    }


protected:
    override bool validate() const pure
        => _tx_path.length != 0 || _rx_path.length != 0;

    override CompletionStatus startup()
    {
        if (_tx_path.length)
        {
            FileOpenMode mode = (_tx_mode == FileMode.append) ? FileOpenMode.WriteAppend : FileOpenMode.WriteTruncate;
            Result r = _tx.open(_tx_path[], mode, FileOpenFlags.Sequential);
            if (!r)
                return CompletionStatus.error;
        }
        if (_rx_path.length)
        {
            Result r = _rx.open(_rx_path[], FileOpenMode.ReadExisting, FileOpenFlags.Sequential);
            if (!r)
            {
                _tx.close();
                return CompletionStatus.error;
            }
        }
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        close_files();
        return CompletionStatus.complete;
    }

    // the rx file replays a chunk per poll until its end, so a large file takes many turns
    override Duration rx_poll_interval() const
        => _rx.is_open ? msecs(10) : Duration.zero;

    override void poll_rx(MonoTime now)
    {
        ubyte[1024] buffer = void;
        size_t n;
        if (!_rx.read(buffer[], n) || n == 0)
            return _rx.close();
        incoming(buffer[0 .. n], now);
    }

private:
    String _tx_path;
    String _rx_path;
    FileMode _tx_mode;
    File _tx;
    File _rx;

    void close_files()
    {
        if (_tx.is_open)
            _tx.close();
        if (_rx.is_open)
            _rx.close();
    }
}


final class FileStreamModule : Module
{
    mixin DeclareModule!"stream.file";
nothrow @nogc:

    override void init()
    {
        g_app.register_enum!FileMode();
        g_app.console.register_collection!FileStream();
    }
}


version (FreeStanding) {}
else unittest
{
    import urt.mem.pagepool : page_pool_deinit, page_pool_init;

    bool owns_pool = page_pool_init();
    scope (exit) if (owns_pool) page_pool_deinit();

    char[320] buffer = void;
    char[] name = buffer[];
    assert(get_temp_filename(name, "", "fileproducer"));
    char[3000] text = 'x';
    assert(save_file(name, text[]));
    scope (exit) delete_file(name);

    static size_t drain(ref FileProducer producer, out TxStatus status)
    {
        size_t total;
        do
        {
            Page* page = producer.produce(TxRequest(4096), status);
            if (!page)
                continue;
            total += page.length;
            page_free(page);
        }
        while (status == TxStatus.more);
        return total;
    }

    // a declared length bounds the read, and a file shorter than it aborts
    TxStatus status;
    File first, second, third;
    assert(first.open(name, FileOpenMode.ReadExisting));
    FileProducer bounded = FileProducer(first, 2000);
    assert(drain(bounded, status) == 2000 && status == TxStatus.end);
    bounded.file.close();
    assert(second.open(name, FileOpenMode.ReadExisting));
    FileProducer longer = FileProducer(second, 4000);
    drain(longer, status);
    assert(status == TxStatus.abort);
    longer.file.close();

    // read to EOF whatever the file claims
    assert(third.open(name, FileOpenMode.ReadExisting));
    FileProducer whole = FileProducer(third, FileProducer.to_eof);
    assert(drain(whole, status) == 3000 && status == TxStatus.end && whole.failure);
    whole.file.close();
}
