module driver.esp32.crash;

version (CoreDump):

import urt.file;
import urt.log;

nothrow @nogc:


alias log = Log!"crash";

void export_pending_crash_dump()
{
    size_t size;
    if (!ow_crash_dump_size(&size) || size == 0)
        return;

    uint number = next_dump_number();
    char[21] path = void;
    path[0 .. 6] = "crash-";
    write_number(path[6 .. 16], number);
    path[16 .. $] = ".core";

    File file;
    if (!file.open(path[], FileOpenMode.WriteTruncate, FileOpenFlags.Sequential))
    {
        log.error("could not create crash dump ", path[]);
        return;
    }

    ubyte[1024] buffer = void;
    size_t offset;
    while (offset < size)
    {
        size_t length = size - offset;
        if (length > buffer.length)
            length = buffer.length;
        if (!ow_crash_dump_read(offset, buffer.ptr, length) || !write_all(file, buffer[0 .. length]))
        {
            file.close();
            log.error("could not save crash dump ", path[]);
            return;
        }
        offset += length;
    }

    if (!file.flush())
    {
        file.close();
        log.error("could not flush crash dump ", path[]);
        return;
    }
    file.close();

    char[11] sequence = void;
    write_number(sequence[0 .. 10], number);
    if (!save_file("crash.seq", sequence[]))
    {
        log.error("could not record crash dump sequence");
        return;
    }
    if (!ow_crash_dump_clear())
    {
        log.error("could not clear exported crash dump");
        return;
    }
    log.warning("saved crash dump ", path[], " (", size, " bytes)");
}

private:

bool write_all(ref File file, const(ubyte)[] data)
{
    while (data.length)
    {
        size_t written;
        if (!file.write(data, written) || written == 0)
            return false;
        data = data[written .. $];
    }
    return true;
}

uint next_dump_number()
{
    const(char)[] sequence = cast(const(char)[])load_file("crash.seq");
    uint number;
    foreach (char c; sequence)
    {
        if (c < '0' || c > '9')
            continue;
        if (number > (uint.max - cast(uint)(c - '0')) / 10)
            return uint.max;
        number = number * 10 + cast(uint)(c - '0');
    }
    return number < uint.max ? number + 1 : number;
}

void write_number(char[] destination, uint value)
{
    foreach_reverse (i; 0 .. destination.length)
    {
        destination[i] = cast(char)('0' + value % 10);
        value /= 10;
    }
}

private extern (C)
{
    bool ow_crash_dump_size(size_t* size);
    bool ow_crash_dump_read(size_t offset, void* buffer, size_t length);
    bool ow_crash_dump_clear();
}
