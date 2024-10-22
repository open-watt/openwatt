module urt.file;

import urt.mem.allocator;
import urt.result;

alias SystemTime = void;

version(Windows)
{
    import core.sys.windows.winbase;
    import core.sys.windows.winnt;

    import urt.string : twstringz;
}
else
{
    static assert(0, "Not implemented");
}

nothrow @nogc:


enum FileResult
{
    Success,
    Failure,
    AccessDenied,
    AlreadyExists,
    DiskFull,
    NotFound,
    NoData
}

enum FileOpenMode
{
    Write,
    ReadWrite,
    ReadExisting,
    ReadWriteExisting,
    WriteTruncate,
    ReadWriteTruncate,
    WriteAppend,
    ReadWriteAppend
}

enum FileOpenFlags
{
    None            = 0,
    NoBuffering     = (1 << 1), // The file or device is being opened with no system caching for data reads and writes.
    RandomAccess    = (1 << 2), // Access is intended to be random. The system can use this as a hint to optimize file caching. Mutually exclusive with `SequentialScan`.
    Sequential      = (1 << 3), // Access is intended to be sequential from beginning to end. The system can use this as a hint to optimize file caching. Mutually exclusive with `RandomAccess`.
}

enum FileAttributeFlag
{
    None            = 0,
    Directory       = (1 << 0),
    Hidden          = (1 << 1),
    ReadOnly        = (1 << 2),
}

struct FileAttributes
{
    FileAttributeFlag attributes;
    ulong size;

//    SystemTime createTime;
//    SystemTime accessTime;
//    SystemTime writeTime;
}

struct File
{
    version (Windows)
        void* handle = INVALID_HANDLE_VALUE;
    else
        static assert(0, "Not implemented");
}

bool file_exists(const(char)[] path);

Result remove_file(const(char)[] path);

//version (Desktop) {
Result rename_file(const(char)[] oldPath, const(char)[] newPath);

Result copy_file(const(char)[] oldPath, const(char)[] newPath, bool overrideExisting = true);

Result get_file_path(ref const File file, char[] buffer, out char[] path);

Result set_file_times(ref File file, const SystemTime* createTime, const SystemTime* accessTime, const SystemTime* writeTime);
//}

Result get_file_attributes(const(char)[] path, out FileAttributes outAttributes);
Result get_attributes(ref const File file, out FileAttributes outAttributes);

void[] load_file(const(char)[] path, NoGCAllocator allocator = defaultAllocator())
{
    File f;
    Result r = f.open(path, FileOpenMode.ReadExisting);
    assert(r, "TODO: handle error");
    ulong size = f.get_size();
    void[] buffer = allocator.alloc(size);
    size_t bytesRead;
    r = f.read(buffer[], bytesRead);
    assert(r, "TODO: handle error");
    f.close();
    return buffer[0..bytesRead];
}

Result open(ref File file, const(char)[] path, FileOpenMode mode, FileOpenFlags openFlags = FileOpenFlags.None)
{
    version (Windows)
    {
        assert(file.handle == INVALID_HANDLE_VALUE);

        uint dwDesiredAccess = 0;
        uint dwShareMode = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
        uint dwCreationDisposition = 0;

        switch (mode)
        {
            case FileOpenMode.Write:
                dwDesiredAccess = GENERIC_WRITE;
                dwCreationDisposition = OPEN_ALWAYS;
                break;
            case FileOpenMode.ReadWrite:
                dwDesiredAccess = GENERIC_READ | GENERIC_WRITE;
                dwCreationDisposition = OPEN_ALWAYS;
                break;
            case FileOpenMode.ReadExisting:
                dwDesiredAccess = GENERIC_READ;
                dwCreationDisposition = OPEN_EXISTING;
                break;
            case FileOpenMode.ReadWriteExisting:
                dwDesiredAccess = GENERIC_READ | GENERIC_WRITE;
                dwCreationDisposition = OPEN_EXISTING;
                break;
            case FileOpenMode.WriteTruncate:
                dwDesiredAccess = GENERIC_WRITE;
                dwCreationDisposition = CREATE_ALWAYS;
                break;
            case FileOpenMode.ReadWriteTruncate:
                dwDesiredAccess = GENERIC_READ | GENERIC_WRITE;
                dwCreationDisposition = CREATE_ALWAYS;
                break;
            case FileOpenMode.WriteAppend:
                dwDesiredAccess = GENERIC_WRITE;
                dwCreationDisposition = OPEN_ALWAYS;
                break;
            case FileOpenMode.ReadWriteAppend:
                dwDesiredAccess = GENERIC_READ | GENERIC_WRITE;
                dwCreationDisposition = OPEN_ALWAYS;
                break;
            default:
                return InternalResult(InternalCode.InvalidParameter);
        }

        uint dwFlagsAndAttributes = FILE_ATTRIBUTE_NORMAL;

        if (openFlags & FileOpenFlags.NoBuffering)
            dwFlagsAndAttributes |= FILE_FLAG_NO_BUFFERING;

        if (openFlags & FileOpenFlags.RandomAccess)
            dwFlagsAndAttributes |= FILE_FLAG_RANDOM_ACCESS;
        else if (openFlags & FileOpenFlags.Sequential)
            dwFlagsAndAttributes |= FILE_FLAG_SEQUENTIAL_SCAN;

        file.handle = CreateFileW(path.twstringz,
                                  dwDesiredAccess,
                                  dwShareMode,
                                  null,
                                  dwCreationDisposition,
                                  dwFlagsAndAttributes,
                                  null);

        if (file.handle == INVALID_HANDLE_VALUE)
            return Win32Result(GetLastError());

        if (mode == FileOpenMode.WriteAppend || mode == FileOpenMode.ReadWriteAppend)
            SetFilePointer(file.handle, 0, null, FILE_END);

        return Result.Success;
    }
    else
        static assert(0, "Not implemented");
}

bool is_open(ref const File file);

void close(ref File file)
{
    version (Windows)
    {
        if (file.handle != INVALID_HANDLE_VALUE)
        {
            CloseHandle(file.handle);
            file.handle = INVALID_HANDLE_VALUE;
        }
    }
    else
        static assert(0, "Not implemented");
}

ulong get_size(ref const File file)
{
    version (Windows)
    {
        LARGE_INTEGER fileSize;
        if (!GetFileSizeEx(cast(void*)file.handle, &fileSize))
            return 0;
        return fileSize.QuadPart;
    }
    else
        static assert(0, "Not implemented");
}

Result set_size(ref File file, ulong size);

ulong get_pos(ref const File file);

Result set_pos(ref File file, ulong offset);

Result read(ref File file, void[] buffer, out size_t bytesRead)
{
    version (Windows)
    {
        import urt.util : min;

        DWORD dwBytesRead;
        if (!ReadFile(file.handle, buffer.ptr, cast(uint)min(buffer.length, uint.max), &dwBytesRead, null))
        {
            bytesRead = 0;
            DWORD lastError = GetLastError();
            return (lastError == ERROR_BROKEN_PIPE) ? Result.Success : Win32Result(lastError);
        }
        bytesRead = dwBytesRead;
        return Result.Success;
    }
    else
        static assert(0, "Not implemented");
}

Result read_at(ref File file, void[] buffer, ulong offset, out size_t bytesRead);

Result write(ref File file, const(void)[] data, out size_t bytesWritten);

Result write_at(ref File file, const(void)[] data, ulong offset, out size_t bytesWritten);

Result flush(ref File file);

FileResult get_FileResult(Result result);

//version (Desktop) {
Result get_temp_filename(char[] buffer, const(char)[] dstDir, const(char)[] prefix);
//}

version (Windows)
{
    Result Win32Result(uint err)
        => Result(err);
}
