module router.stream.file;

import urt.file;
import urt.lifetime;
import urt.mem.temp;
import urt.string;
import urt.string.format;

import manager.base;
import manager.collection;
import manager.console;
import manager.plugin;

import router.stream;

nothrow @nogc:


enum FileMode : ubyte
{
    truncate,  // overwrite tx file from the start
    append,    // append to existing tx file
}


class FileStream : Stream
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
        restart();
    }

    final ref const(String) rx_file() const pure => _rx_path;
    final void rx_file(String value)
    {
        if (value == _rx_path)
            return;
        _rx_path = value.move;
        restart();
    }

    final FileMode tx_mode() const pure => _tx_mode;
    final void tx_mode(FileMode value)
    {
        if (value == _tx_mode)
            return;
        _tx_mode = value;
        restart();
    }

    // API

    override const(char)[] remote_name()
    {
        if (_rx_path.length && _tx_path.length)
            return tconcat(_tx_path[], "<>", _rx_path[]);
        if (_tx_path.length)
            return _tx_path[];
        if (_rx_path.length)
            return _rx_path[];
        return "file";
    }

    override ptrdiff_t read(void[] buffer)
    {
        if (!_rx.is_open)
            return 0;
        size_t n;
        Result r = _rx.read(buffer, n);
        if (!r)
            return 0;
        if (n)
        {
            add_rx_bytes(n);
            if (_logging)
                write_to_log(true, buffer[0 .. n]);
        }
        return n;
    }

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

    override ptrdiff_t pending()
        => 0;

    override ptrdiff_t flush()
    {
        if (_tx.is_open)
            _tx.flush();
        return 0;
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


class FileStreamModule : Module
{
    mixin DeclareModule!"stream.file";
nothrow @nogc:

    override void init()
    {
        g_app.register_enum!FileMode();
        g_app.console.register_collection!FileStream();
    }
}
