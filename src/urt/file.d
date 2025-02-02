module urt.file;

import urt.mem.allocator;
import urt.platform;
import urt.result;
import urt.string.uni;
import urt.time;

public import urt.result;

alias SystemTime = void;

version(Windows)
{
    import core.sys.windows.winbase;
    import core.sys.windows.windows;
    import core.sys.windows.windef : MAX_PATH;
    import core.sys.windows.winnt;
    import urt.string : twstringz;

    // TODO: remove this when LDC/GDC are up to date...
    version (DigitalMars) {} else {
        extern(Windows) DWORD GetFinalPathNameByHandleW(HANDLE hFile, LPWSTR lpszFilePath, DWORD cchFilePath, DWORD dwFlags) nothrow @nogc;
        enum FILE_NAME_OPENED = 8;
    }
}
else version (Posix)
{
    import core.stdc.errno;
    import core.sys.posix.dirent;
    import core.sys.posix.fcntl;
    import core.sys.posix.stdlib;
    import core.sys.posix.sys.stat;
    import core.sys.posix.unistd;
    import urt.mem.temp : tconcat;
    import urt.string : tstringz;

    enum SEEK_SET = 0;
    enum SEEK_CUR = 1;
    enum SEEK_END = 2;

    enum POSIX_FADV_NORMAL = 0;
    enum POSIX_FADV_RANDOM = 1;
    enum POSIX_FADV_SEQUENTIAL = 2;
    extern(C) int posix_fadvise(int fd, off_t offset, off_t len, int advice) nothrow @nogc;
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
    else version (Posix)
        int fd = -1;
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
    else version (Posix)
    {
        import core.sys.posix.sys.stat;
        stat_t st;
        return stat(path.tstringz, &st) == 0 && S_ISREG(st.st_mode);
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
    else version (Posix)
    {
        if (unlink(path.tstringz) == -1)
            return PosixResult(errno);
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
    else version (Posix)
    {
        import core.sys.posix.stdio;
        if (int result = rename(oldPath.tstringz, newPath.tstringz)!= 0)
           return PosixResult(result);
    }
    else
        static assert(0, "Not implemented");

    return Result.Success;
}

Result copy_file(const(char)[] oldPath, const(char)[] newPath, bool overwriteExisting = false)
{
    version (Windows)
    {
        if (!CopyFileW(oldPath.twstringz, newPath.twstringz, !overwriteExisting))
            return Win32Result(GetLastError());
    }
    else version (Posix)
    {
        // TODO
        assert(false);
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
    }
    else version (Darwin)
    {
        import urt.mem : strlen;

        char[PATH_MAX] src = void;
        int r = fcntl(file.fd, F_GETPATH, src.ptr);
        if (r == -1)
            return PosixResult(errno);
        size_t l = strlen(src.ptr);
        if (l > buffer.length)
            return InternalResult(InternalCode.BufferTooSmall);
        buffer[0..l] = src[0..l];
        buffer = buffer[0..l];
    }
    else version (Posix)
    {
        ptrdiff_t r = readlink(tconcat("/proc/self/fd/", file.fd, '\0').ptr, buffer.ptr, buffer.length);
        if (r == -1)
            return PosixResult(errno);
        if (r == buffer.length)
        {
            // TODO: if r == buffer.length, truncation MAY have occurred, but also maybe not...
            //       is there any way to fix this? for now, we'll just assume it did and return an error
            return InternalResult(InternalCode.BufferTooSmall);
        }
        buffer = buffer[0..r];
    }
    else
        static assert(0, "Not implemented");
    return Result.Success;
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
    else version (Posix)
    {
        // TODO
        assert(false);
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
    else version (Posix)
    {
        // TODO
        assert(false);
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
    }
    else version (Posix)
    {
        assert(file.fd == -1);

        int flags;
        switch (mode)
        {
            case FileOpenMode.Write:
                flags = O_WRONLY | O_CREAT;
                break;
            case FileOpenMode.ReadWrite:
                flags = O_RDWR | O_CREAT;
                break;
            case FileOpenMode.ReadExisting:
                flags = O_RDONLY;
                break;
            case FileOpenMode.ReadWriteExisting:
                flags = O_RDWR;
                break;
            case FileOpenMode.WriteTruncate:
                flags = O_WRONLY | O_CREAT | O_TRUNC;
                break;
            case FileOpenMode.ReadWriteTruncate:
                flags = O_RDWR | O_CREAT | O_TRUNC;
                break;
            case FileOpenMode.WriteAppend:
                flags = O_WRONLY | O_APPEND | O_CREAT;
                break;
            case FileOpenMode.ReadWriteAppend:
                flags = O_RDWR | O_APPEND | O_CREAT;
                break;
            default:
                return InternalResult(InternalCode.InvalidParameter);
        }

        flags |= O_CLOEXEC;

        version (Darwin) {} else {
            if (openFlags & FileOpenFlags.NoBuffering)
                flags |= O_DIRECT;
        }

        int fd = core.sys.posix.fcntl.open(path.tstringz, flags, 0b110_110_110);
        if (fd < 0)
            return PosixResult(errno);
        file.fd = fd;

        version (Darwin) {
            if (openFlags & FileOpenFlags.NoBuffering)
                fcntl(fd, F_NOCACHE, 1);
        }

        int advice = POSIX_FADV_NORMAL;
        if (openFlags & FileOpenFlags.RandomAccess)
            advice = POSIX_FADV_RANDOM;
        else if (openFlags & FileOpenFlags.Sequential)
            advice = POSIX_FADV_SEQUENTIAL;
        if (advice != POSIX_FADV_NORMAL)
        {
            // Not checking the error case because the file should continue
            // to operate correctly even if this fails.
            posix_fadvise(fd, 0, 0, advice);
        }

        if (mode == FileOpenMode.WriteAppend || mode == FileOpenMode.ReadWriteAppend)
            lseek(file.fd, 0, SEEK_END);
    }
    else
        static assert(0, "Not implemented");

    return Result.Success;
}

bool is_open(ref const File file)
{
    version (Windows)
        return file.handle != INVALID_HANDLE_VALUE;
    else version (Posix)
        return file.fd != -1;
    else
        static assert(0, "Not implemented");
}

void close(ref File file)
{
    version (Windows)
    {
        if (file.handle == INVALID_HANDLE_VALUE)
            return;
        CloseHandle(file.handle);
        file.handle = INVALID_HANDLE_VALUE;
    }
    else version (Posix)
    {
        if (file.fd == -1)
            return;
        core.sys.posix.unistd.close(file.fd);
        file.fd = -1;
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
    else version (Posix)
    {
        stat_t fs;
        if (fstat(file.fd, &fs))
            return 0;
        return fs.st_size;
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
    }
    else version (Posix)
    {
        if (ftruncate(file.fd, size))
            return PosixResult(errno);
    }
    else
        static assert(0, "Not implemented");
    return Result.Success;
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
    else version (Posix)
        return lseek(file.fd, 0, SEEK_CUR);
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
    }
    else version (Posix)
    {
        off_t rc = lseek(file.fd, offset, SEEK_SET);
        if (rc < 0)
            return PosixResult(errno);
    }
    else
        static assert(0, "Not implemented");
    return Result.Success;
}

Result read(ref File file, void[] buffer, out size_t bytesRead)
{
    version (Windows)
    {
        import urt.util : min;

        DWORD dwBytesRead;
        if (!ReadFile(file.handle, buffer.ptr, cast(uint)min(buffer.length, uint.max), &dwBytesRead, null))
        {
            DWORD lastError = GetLastError();
            return (lastError == ERROR_BROKEN_PIPE) ? Result.Success : Win32Result(lastError);
        }
        bytesRead = dwBytesRead;
    }
    else version (Posix)
    {
        ptrdiff_t n = core.sys.posix.unistd.read(file.fd, buffer.ptr, buffer.length);
        if (n < 0)
            return PosixResult(errno);
        bytesRead = n;
    }
    else
        static assert(0, "Not implemented");
    return Result.Success;
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
                return Win32Result(GetLastError());
        }
        bytesRead = dwBytesRead;
    }
    else version (Posix)
    {
        ssize_t n = pread(file.fd, buffer.ptr, buffer.length, offset);
        if (n < 0)
            return PosixResult(errno);
        bytesRead = n;
    }
    else
        static assert(0, "Not implemented");
    return Result.Success;
}

Result write(ref File file, const(void)[] data, out size_t bytesWritten)
{
    version (Windows)
    {
        DWORD dwBytesWritten;
        if (!WriteFile(file.handle, data.ptr, cast(uint)data.length, &dwBytesWritten, null))
            return Win32Result(GetLastError());
        bytesWritten = dwBytesWritten;
    }
    else version (Posix)
    {
        ptrdiff_t n = core.sys.posix.unistd.write(file.fd, data.ptr, data.length);
        if (n < 0)
            return PosixResult(errno);
        bytesWritten = n;
    }
    else
        static assert(0, "Not implemented");
    return Result.Success;
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
            return Win32Result(GetLastError());
        bytesWritten = dwBytesWritten;
    }
    else version (Posix)
    {
        ptrdiff_t n = pwrite(file.fd, data.ptr, data.length, offset);
        if (n < 0)
            return PosixResult(errno);
        bytesWritten = n;
    }
    else
        static assert(0, "Not implemented");
    return Result.Success;
}

Result flush(ref File file)
{
    version (Windows)
    {
        if (!FlushFileBuffers(file.handle))
            return Win32Result(GetLastError());
    }
    else version (Posix)
    {
        if (fsync(file.fd))
            return PosixResult(errno);
    }
    else
        static assert(0, "Not implemented");
    return Result.Success;
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
    else version (Posix)
    {
        static assert(EAGAIN == EWOULDBLOCK, "Expect EGAIN and EWOULDBLOCK are the same value");
        switch (result.systemCode)
        {
            case 0:         return FileResult.Success;
            case ENOSPC:    return FileResult.DiskFull;
            case EACCES:    return FileResult.AccessDenied;
            case EEXIST:    return FileResult.AlreadyExists;
            case ENOENT:    return FileResult.NotFound;
            case EAGAIN:    return FileResult.NoData;
            default:        return FileResult.Failure;
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
        resLen = tmp[((dstDir.length == 0 && tmp[0] == '\\') ? 1 : 0)..resLen].uniConvert(buffer);
        if (resLen == 0)
        {
            DeleteFileW(tmp.ptr);
            return InternalResult(InternalCode.BufferTooSmall);
        }
        buffer = buffer[0 .. resLen];
    }
    else version (Posix)
    {
        // Construct a format string which will be the supplied dir with prefix and 8 generated random characters
        char[] fn = tconcat(dstDir, (dstDir.length && dstDir[$-1] != '/') ? "/" : "", prefix, "XXXXXX\0");
        File file;
        file.fd = mkstemp(fn.ptr);
        if (file.fd == -1)
            return PosixResult(errno);
        Result r = get_path(file, buffer);
        core.sys.posix.unistd.close(file.fd);
        return r;
    }
    else
        static assert(0, "Not implemented");
    return Result.Success;
}

version (Windows)
{
    Result Win32Result(uint err)
        => Result(err);
}
else version (Posix)
{
    Result PosixResult(int err)
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
