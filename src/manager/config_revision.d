module manager.config_revision;

import urt.algorithm : qsort;
import urt.array : Array;
import urt.conv : parse_int_fast;
import urt.crc : calculate_crc, Algorithm;
import urt.file;
import urt.lifetime : move;
import urt.log;
import urt.mem;
import urt.result;
import urt.string;
import urt.string.format : tconcat;

nothrow @nogc:


enum retained_config_revisions = 5;
alias RevisionValidator = bool function(const(char)[]) nothrow @nogc;

char[] load_config_revision(const(char)[] base, RevisionValidator validate = null, bool rollback = false, int* loaded = null)
{
    auto revisions = list_revisions(base);
    foreach (revision; revisions[])
    {
        const(char)[] path = tconcat(base, '.', revision);
        char[] data = cast(char[])load_file(path);
        if (data is null)
            continue;
        if (!valid_revision(data) || (validate && !validate(data)) || rollback)
        {
            free(data);
            if (!rename_file(path, tconcat(path, ".bad")))
            {
                log_error("config", "cannot retire revision '", path, "'");
                return null;
            }
            log_warning("config", "retired revision '", path, "'; trying an older revision");
            rollback = false;
            continue;
        }
        log_info("config", "loaded revision '", path, "'");
        if (loaded)
            *loaded = revision;
        return data;
    }
    return null;
}

Result save_config_revision(const(char)[] base, const(char)[] data, out int revision)
{
    auto occupied = list_revisions(base, true);
    if (!occupied.empty && occupied[0] == int.max)
        return InternalResult.failed;
    revision = occupied.empty ? 1 : occupied[0] + 1;
    const(char)[] path = tconcat(base, '.', revision);
    const(char)[] pending = tconcat(path, ".tmp");
    File file;
    Result result = file.open(pending, FileOpenMode.WriteTruncate);
    if (!result)
        return result;
    scope(exit) delete_file(pending);
    {
        scope(exit) file.close();
        size_t written;
        result = file.write(cast(const(void)[])data, written);
        if (!result || written != data.length)
            return result ? InternalResult.failed : result;
        char[18] footer;
        revision_footer(data, footer);
        result = file.write(footer[], written);
        if (!result || written != footer.length)
            return result ? InternalResult.failed : result;
        result = file.flush();
        if (!result)
            return result;
    }
    version (Windows)
    {
        import urt.internal.sys.windows : MoveFileExW, MOVEFILE_WRITE_THROUGH;
        if (!MoveFileExW(pending.twstringz, path.twstringz, MOVEFILE_WRITE_THROUGH))
            return getlasterror_result();
    }
    else
    {
        result = rename_file(pending, path);
        if (!result)
            return result;
    }
    version (Posix)
    {
        File directory;
        result = directory.open(parent_path(base), FileOpenMode.ReadExisting);
        if (!result)
            return result;
        scope(exit) directory.close();
        result = directory.flush();
        if (!result)
            return result;
    }
    auto revisions = list_revisions(base);
    foreach (old; revisions[retained_config_revisions < revisions.length ? retained_config_revisions : revisions.length .. $])
    {
        const(char)[] old_path = tconcat(base, '.', old);
        if (!delete_file(old_path))
            log_warning("config", "could not prune revision '", old_path, "'");
    }
    return Result.success;
}

int newest_config_revision(const(char)[] base)
{
    auto revisions = list_revisions(base);
    return revisions.empty ? 0 : revisions[0];
}

bool has_config_revisions(const(char)[] base)
{
    auto revisions = list_revisions(base, true);
    foreach (revision; revisions[])
        if (file_exists(tconcat(base, '.', revision)) || file_exists(tconcat(base, '.', revision, ".bad")))
            return true;
    return false;
}

private:

const(char)[] parent_path(const(char)[] path)
{
    foreach_reverse (i, c; path)
        if (c == '/' || c == '\\')
            return i ? path[0 .. i] : path[0 .. 1];
    return ".";
}

Array!int list_revisions(const(char)[] base, bool include_incomplete = false)
{
    const(char)[] filename = base;
    foreach_reverse (i, c; base)
        if (c == '/' || c == '\\')
        {
            filename = base[i + 1 .. $];
            break;
        }
    Array!int revisions;
    Directory directory;
    if (!directory.open(parent_path(base)))
        return revisions.move;
    scope(exit) directory.close();
    DirEntry entry;
    while (directory.read(entry))
    {
        if (entry.is_directory || !entry.name.startsWith(filename) || entry.name.length <= filename.length || entry.name[filename.length] != '.')
            continue;
        const(char)[] suffix = entry.name[filename.length + 1 .. $];
        if (include_incomplete && (suffix.endsWith(".tmp") || suffix.endsWith(".bad")))
            suffix = suffix[0 .. $ - 4];
        int number;
        if (revision_number(suffix, number))
            revisions ~= number;
    }
    qsort!((a, b) => a > b)(revisions[]);
    return revisions.move;
}

bool revision_number(const(char)[] text, out int number) pure
{
    if (text.empty || text[0] < '1' || text[0] > '9')
        return false;
    bool success;
    number = text.parse_int_fast(success);
    return success && text.empty;
}

void revision_footer(const(char)[] data, ref char[18] footer) pure
{
    import urt.string.ascii : hex_digits;
    footer[0 .. 9] = "\n# crc32=";
    uint crc = calculate_crc!(Algorithm.crc32_iso_hdlc)(data);
    foreach (i; 0 .. 8)
        footer[9 + i] = hex_digits[(crc >> ((7 - i) * 4)) & 15];
    footer[17] = '\n';
}

bool valid_revision(const(char)[] data) pure
{
    char[18] footer;
    if (data.length < footer.length)
        return false;
    revision_footer(data[0 .. $ - footer.length], footer);
    return data[$ - footer.length .. $] == footer[];
}

unittest
{
    int number;
    assert(revision_number("1", number) && number == 1);
    assert(revision_number("2147483647", number) && number == int.max);
    foreach (invalid; [ "", "0", "01", "1.tmp", "1.bad", "-1", "+1", "1.0", "1e2", "2147483648", "9999999999" ])
        assert(!revision_number(invalid, number));
    char[18] footer;
    revision_footer("hello", footer);
    MutableString!0 data;
    data.append("hello", footer[]);
    assert(valid_revision(data[]));
    assert(!valid_revision(data[0 .. $ - 1]));
    assert(!valid_revision("jello\n# crc32=3610a686\n"));

    version (FreeStanding) {}
    else
    {
        char[256] buffer;
        char[] base = buffer[];
        assert(get_temp_filename(base, ".", "owr"));
        assert(save_file(base, "unnumbered"));
        assert(load_config_revision(base) is null);
        assert(delete_file(base));
        scope(exit)
        {
            auto revisions = list_revisions(base, true);
            foreach (revision; revisions[])
            {
                delete_file(tconcat(base, '.', revision));
                delete_file(tconcat(base, '.', revision, ".bad"));
                delete_file(tconcat(base, '.', revision, ".tmp"));
            }
        }
        assert(save_config_revision(base, "first", number) && number == 1);
        assert(save_config_revision(base, "second", number) && number == 2);
        char[] restored = load_config_revision(base, null, true);
        assert(restored.startsWith("first\n"));
        free(restored);
        assert(file_exists(tconcat(base, ".2.bad")));
        assert(save_config_revision(base, "third", number) && number == 3);
        assert(save_file(tconcat(base, ".3"), "partial"));
        restored = load_config_revision(base);
        assert(restored.startsWith("first\n"));
        free(restored);
        assert(file_exists(tconcat(base, ".3.bad")));
        assert(load_config_revision(base, null, true) is null);
        assert(has_config_revisions(base));
    }
}
