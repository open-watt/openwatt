module driver.esp32.crash;

version (CoreDump):

import urt.file;
import urt.log;
import urt.mem;
import urt.string.ascii : is_numeric;

nothrow @nogc:


alias log = Log!"crash";

enum uint kept_dumps = 2;

void export_pending_crash_dump()
{
    uint number = next_dump_number();
    prune_dumps(number - 1);

    size_t size;
    if (!urt_crash_dump_size(&size) || size == 0)
        return;

    char[21] path = void;
    dump_path(path, number);

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
        if (!urt_crash_dump_read(offset, buffer.ptr, length) || !write_all(file, buffer[0 .. length]))
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

    char[10] sequence = void;
    write_number(sequence[], number);
    if (!save_file("crash.seq", sequence[]))
    {
        log.error("could not record crash dump sequence");
        return;
    }
    if (!urt_crash_dump_clear())
    {
        log.error("could not clear exported crash dump");
        return;
    }
    log.warning("saved crash dump ", path[], " (", size, " bytes)");
    prune_dumps(number);
}

private:

void dump_path(ref char[21] path, uint number)
{
    path[0 .. 6] = "crash-";
    write_number(path[6 .. 16], number);
    path[16 .. $] = ".core";
}

// the newest kept_dumps stay and every older one goes, whatever numbers are already missing
void prune_dumps(uint newest)
{
    if (newest <= kept_dumps)
        return;
    uint[16] stale = void;
    size_t count;
    do
    {
        count = 0;
        Directory dir;
        if (!dir.open(null))
            return;
        DirEntry entry;
        while (count < stale.length && dir.read(entry))
        {
            uint number;
            if (dump_number(entry.name, number) && number <= newest - kept_dumps)
                stale[count++] = number;
        }
        dir.close();
        char[21] path = void;
        foreach (number; stale[0 .. count])
        {
            dump_path(path, number);
            if (delete_file(path[]).failed)
                return;
        }
    }
    while (count == stale.length);
}

bool dump_number(const(char)[] name, out uint number)
{
    if (name.length != 21 || name[0 .. 6] != "crash-" || name[16 .. $] != ".core")
        return false;
    foreach (char c; name[6 .. 16])
    {
        if (!c.is_numeric)
            return false;
        number = number * 10 + cast(uint)(c - '0');
    }
    return true;
}

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
    void[] saved = load_file("crash.seq");
    scope (exit) free(saved);
    const(char)[] sequence = cast(const(char)[])saved;
    uint number;
    foreach (char c; sequence)
    {
        if (!c.is_numeric)
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
    bool urt_crash_dump_size(size_t* size);
    bool urt_crash_dump_read(size_t offset, void* buffer, size_t length);
    bool urt_crash_dump_clear();
}
