module urt.file;

import urt.mem.allocator;
import urt.result;
import urt.string.uni;
import urt.time;

alias SystemTime = void;

version(Windows)
{
    import core.sys.windows.winbase;
    import core.sys.windows.windows;
    import core.sys.windows.windef : MAX_PATH;
    import core.sys.windows.winnt;

    import urt.string : twstringz;

    enum FILE_NAME_OPENED = 0x8;
    extern(C) { nothrow @nogc: int GetFinalPathNameByHandleW(void *hFile, wchar *lpszFilePath, uint cchFilePath, uint dwFlags); }
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

    SysTime createTime;
    SysTime accessTime;
    SysTime writeTime;
}

struct File
{
    version (Windows)
        void* handle = INVALID_HANDLE_VALUE;
    else
        static assert(0, "Not implemented");
}

bool file_exists(const(char)[] path)
{
    version (Windows)
    {
        DWORD attr = GetFileAttributesW(path.twstringz);
        return attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY);
    }
    else
        static assert(0, "Not implemented");
}

Result delete_file(const(char)[] path)
{
    version (Windows)
    {
        if (!DeleteFileW(path.twstringz))
            return Win32Result(GetLastError());
    }
    else
        static assert(0, "Not implemented");

    return Result.Success;
}

Result rename_file(const(char)[] oldPath, const(char)[] newPath)
{
    version (Windows)
    {
        if (!MoveFileW(oldPath.twstringz, newPath.twstringz))
            return Win32Result(GetLastError());
    }
    else
        static assert(0, "Not implemented");

    return Result.Success;
}

Result copy_file(const(char)[] oldPath, const(char)[] newPath, bool overwriteExisting = true)
{
    version (Windows)
    {
        if (!CopyFileW(oldPath.twstringz, newPath.twstringz, !overwriteExisting))
            return Win32Result(GetLastError());
    }
    else
        static assert(0, "Not implemented");

    return Result.Success;
}

Result get_path(ref const File file, ref char[] buffer)
{
    version (Windows)
    {
        // TODO: waiting for the associated WINAPI functions to be merged into druntime...

        wchar[MAX_PATH] tmp = void;
        DWORD dwPathLen = tmp.length - 1;
        DWORD result = GetFinalPathNameByHandleW(cast(HANDLE)file.handle, tmp.ptr, dwPathLen, FILE_NAME_OPENED);
        if (result == 0 || result > dwPathLen)
            return Win32Result(GetLastError());

        size_t pathLen = tmp[0..result].uniConvert(buffer);
        if (!pathLen)
            return InternalResult(InternalCode.BufferTooSmall);
        if (buffer.length >= 4 && buffer[0..4] == `\\?\`)
            buffer = buffer[4..pathLen];
        else
            buffer = buffer[0..pathLen];
        return Result.Success;
    }
    else
        static assert(0, "Not implemented");

    return InternalResult(InternalCode.Unsupported);
}

Result set_file_times(ref File file, const SystemTime* createTime, const SystemTime* accessTime, const SystemTime* writeTime);

Result get_file_attributes(const(char)[] path, out FileAttributes outAttributes)
{
    version (Windows)
    {
        WIN32_FILE_ATTRIBUTE_DATA attrData = void;
        if (!GetFileAttributesExW(path.twstringz, GET_FILEEX_INFO_LEVELS.GetFileExInfoStandard, &attrData))
            return Win32Result(GetLastError());

        outAttributes.attributes = FileAttributeFlag.None;
        if ((attrData.dwFileAttributes & FILE_ATTRIBUTE_HIDDEN) == FILE_ATTRIBUTE_HIDDEN)
            outAttributes.attributes |= FileAttributeFlag.Hidden;
        if ((attrData.dwFileAttributes & FILE_ATTRIBUTE_READONLY) == FILE_ATTRIBUTE_READONLY)
            outAttributes.attributes |= FileAttributeFlag.ReadOnly;
        if ((attrData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == FILE_ATTRIBUTE_DIRECTORY)
        {
            outAttributes.attributes |= FileAttributeFlag.Directory;
            outAttributes.size = 0;
        }
        else
            outAttributes.size = cast(ulong)attrData.nFileSizeHigh << 32 | attrData.nFileSizeLow;

        outAttributes.createTime = SysTime(cast(ulong)attrData.ftCreationTime.dwHighDateTime << 32 | attrData.ftCreationTime.dwLowDateTime);
        outAttributes.accessTime = SysTime(cast(ulong)attrData.ftLastAccessTime.dwHighDateTime << 32 | attrData.ftLastAccessTime.dwLowDateTime);
        outAttributes.writeTime = SysTime(cast(ulong)attrData.ftLastWriteTime.dwHighDateTime << 32 | attrData.ftLastWriteTime.dwLowDateTime);
    }
    else
        static assert(0, "Not implemented");

    return Result.Success;
}

Result get_attributes(ref const File file, out FileAttributes outAttributes)
{
    version (Windows)
    {
        // TODO: waiting for the associated WINAPI functions to be merged into druntime...
/+
        FILE_BASIC_INFO basicInfo = void;
        FILE_STANDARD_INFO standardInfo = void;
        if (!GetFileInformationByHandleEx(cast(HANDLE)file.handle, FILE_INFO_BY_HANDLE_CLASS.FileBasicInfo, &basicInfo, FILE_BASIC_INFO.sizeof))
            return Win32Result(GetLastError());
        if (!GetFileInformationByHandleEx(cast(HANDLE)file.handle, FILE_INFO_BY_HANDLE_CLASS.FileStandardInfo, &standardInfo, FILE_STANDARD_INFO.sizeof))
            return Win32Result(GetLastError());

        outAttributes.attributes = FileAttributeFlag.None;
        if ((basicInfo.FileAttributes & FILE_ATTRIBUTE_HIDDEN) == FILE_ATTRIBUTE_HIDDEN)
            outAttributes.attributes |= FileAttributeFlag.Hidden;
        if ((basicInfo.FileAttributes & FILE_ATTRIBUTE_READONLY) == FILE_ATTRIBUTE_READONLY)
            outAttributes.attributes |= FileAttributeFlag.ReadOnly;
        if (standardInfo.Directory == TRUE)
        {
            outAttributes.attributes |= FileAttributeFlag.Directory;
            outAttributes.size = 0;
        }
        else
            outAttributes.size = standardInfo.EndOfFile.QuadPart;

        outAttributes.createTime = SysTime(basicInfo.CreationTime.QuadPart);
        outAttributes.accessTime = SysTime(basicInfo.LastAccessTime.QuadPart);
        outAttributes.writeTime = SysTime(basicInfo.LastWriteTime.QuadPart);

        return Result.Success;
+/
    }
    else
        static assert(0, "Not implemented");

    return InternalResult(InternalCode.Unsupported);
}

void[] load_file(const(char)[] path, NoGCAllocator allocator = defaultAllocator())
{
    File f;
    Result r = f.open(path, FileOpenMode.ReadExisting);
    if (!r && r.get_FileResult == FileResult.NotFound)
        return null;
    assert(r, "TODO: handle error");
    ulong size = f.get_size();
    assert(size <= size_t.max, "File is too large");
    void[] buffer = allocator.alloc(cast(size_t)size);
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

        file.handle = CreateFileW(path.twstringz, dwDesiredAccess, dwShareMode, null, dwCreationDisposition, dwFlagsAndAttributes, null);
        if (file.handle == INVALID_HANDLE_VALUE)
            return Win32Result(GetLastError());

        if (mode == FileOpenMode.WriteAppend || mode == FileOpenMode.ReadWriteAppend)
            SetFilePointer(file.handle, 0, null, FILE_END);

        return Result.Success;
    }
    else
        static assert(0, "Not implemented");
}

bool is_open(ref const File file)
{
    return file.handle != INVALID_HANDLE_VALUE;
}

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

Result set_size(ref File file, ulong size)
{
    version (Windows)
    {
        ulong curPos = file.get_pos();
        scope(exit)
            file.set_pos(curPos);

        ulong curFileSize = file.get_size();
        if (size > curFileSize)
        {
            if (!file.set_pos(curFileSize))
                return Win32Result(GetLastError());

            // zero-fill
            char[4096] buf = void;
            ulong n = size - curFileSize;
            uint bufSize = buf.sizeof;
            if (bufSize > n)
                bufSize = cast(uint)n;
            buf[0..bufSize] = 0;

            while (n)
            {
                uint bytesToWrite = n >= buf.sizeof ? buf.sizeof : cast(uint)n;
                size_t bytesWritten;
                Result result = file.write(buf[0..bytesToWrite], bytesWritten);
                if (!result)
                    return result;
                n -= bytesWritten;
            }
        }
        else
        {
            if (!file.set_pos(size))
                return Win32Result(GetLastError());
            if (!SetEndOfFile(file.handle))
                return Win32Result(GetLastError());
        }

        return Result.Success;
    }
    else
        static assert(0, "Not implemented");
}

ulong get_pos(ref const File file)
{
    version (Windows)
    {
        LARGE_INTEGER liDistanceToMove = void;
        LARGE_INTEGER liResult = void;
        liDistanceToMove.QuadPart = 0;
        SetFilePointerEx(cast(HANDLE)file.handle, liDistanceToMove, &liResult, FILE_CURRENT);
        return liResult.QuadPart;
    }
    else
        static assert(0, "Not implemented");
}

Result set_pos(ref File file, ulong offset)
{
    version (Windows)
    {
        LARGE_INTEGER liDistanceToMove = void;
        liDistanceToMove.QuadPart = offset;
        if (!SetFilePointerEx(file.handle, liDistanceToMove, null, FILE_BEGIN))
            return Win32Result(GetLastError());
        return Result.Success;
    }
    else
        static assert(0, "Not implemented");
}

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

Result read_at(ref File file, void[] buffer, ulong offset, out size_t bytesRead)
{
    version (Windows)
    {
        if (buffer.length > DWORD.max)
            return InternalResult(InternalCode.InvalidParameter);

        OVERLAPPED o;
        o.Offset = cast(DWORD)offset;
        o.OffsetHigh = cast(DWORD)(offset >> 32);

        DWORD dwBytesRead;
        if (!ReadFile(file.handle, buffer.ptr, cast(DWORD)buffer.length, &dwBytesRead, &o))
        {
            if (GetLastError() != ERROR_HANDLE_EOF)
            {
                bytesRead = 0;
                return Win32Result(GetLastError());
            }
        }
        bytesRead = dwBytesRead;
        return Result.Success;
    }
    else
        static assert(0, "Not implemented");
}

Result write(ref File file, const(void)[] data, out size_t bytesWritten)
{
    version (Windows)
    {
        DWORD dwBytesWritten;
        if (!WriteFile(file.handle, data.ptr, cast(uint)data.length, &dwBytesWritten, null))
        {
            bytesWritten = 0;
            return Win32Result(GetLastError());
        }
        bytesWritten = dwBytesWritten;
        return Result.Success;
    }
    else
        static assert(0, "Not implemented");
}

Result write_at(ref File file, const(void)[] data, ulong offset, out size_t bytesWritten)
{
    version (Windows)
    {
        if (data.length > DWORD.max)
            return InternalResult(InternalCode.InvalidParameter);

        OVERLAPPED o;
        o.Offset = cast(DWORD)offset;
        o.OffsetHigh = cast(DWORD)(offset >> 32);

        DWORD dwBytesWritten;
        if (!WriteFile(file.handle, data.ptr, cast(DWORD)data.length, &dwBytesWritten, &o))
        {
            bytesWritten = 0;
            return Win32Result(GetLastError());
        }
        bytesWritten = dwBytesWritten;
        return Result.Success;
    }
    else
        static assert(0, "Not implemented");
}

Result flush(ref File file)
{
    version (Windows)
    {
        if (!FlushFileBuffers(file.handle))
            return Win32Result(GetLastError());
        return Result.Success;
    }
    else
        static assert(0, "Not implemented");
}

FileResult get_FileResult(Result result)
{
    version (Windows)
    {
        switch (result.systemCode)
        {
            case ERROR_SUCCESS:         return FileResult.Success;
            case ERROR_DISK_FULL:       return FileResult.DiskFull;
            case ERROR_ACCESS_DENIED:   return FileResult.AccessDenied;
            case ERROR_ALREADY_EXISTS:  return FileResult.AlreadyExists;
            case ERROR_FILE_NOT_FOUND:  return FileResult.NotFound;
            case ERROR_PATH_NOT_FOUND:  return FileResult.NotFound;
            case ERROR_NO_DATA:         return FileResult.NoData;
            default:                    return FileResult.Failure;
        }
    }
    else
        static assert(0, "Not implemented");
}

Result get_temp_filename(ref char[] buffer, const(char)[] dstDir, const(char)[] prefix)
{
    version (Windows)
    {
        import urt.mem : wcslen;

        wchar[MAX_PATH] tmp = void;
        if (!GetTempFileNameW(dstDir.twstringz, prefix.twstringz, 0, tmp.ptr))
            return Win32Result(GetLastError());
        size_t resLen = wcslen(tmp.ptr);
        resLen = tmp[0..resLen].uniConvert(buffer);
        if (resLen == 0)
        {
            DeleteFileW(tmp.ptr);
            return InternalResult(InternalCode.BufferTooSmall);
        }
        buffer = buffer[0 .. resLen];
        return Result.Success;
    }
    else
        static assert(0, "Not implemented");
}

version (Windows)
{
    Result Win32Result(uint err)
        => Result(err);
}


unittest
{
    import urt.string;

    char[320] buffer = void;
    char[] filename = buffer[];
    assert(get_temp_filename(filename, "", "pre"));

    File file;
    assert(file.open(filename, FileOpenMode.ReadWriteTruncate));
    assert(file.is_open);

    char[320] buffer2 = void;
    char[] path = buffer2[];
    assert(file.get_path(path));
    assert(path.endsWith(filename));

    file.close();
    assert(!file.is_open);

    assert(filename.delete_file());
}
