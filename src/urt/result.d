module urt.result;

nothrow @nogc:


enum InternalCode
{
    Success = 0,
    BufferTooSmall,
    InvalidParameter,
    Unsupported
}

struct Result
{
nothrow @nogc:
    enum Success = Result();

    uint systemCode = 0;

    bool opCast(T : bool)() const
        => systemCode == 0;

    bool succeeded() const
        => systemCode == 0;
    bool failed() const
        => systemCode != 0;
}


version (Windows)
{
    import core.sys.windows.windows;

    Result InternalResult(InternalCode code)
    {
        switch (code)
        {
            case InternalCode.Success:
                return Result();
            case InternalCode.BufferTooSmall:
                return Result(ERROR_INSUFFICIENT_BUFFER);
            case InternalCode.InvalidParameter:
                return Result(ERROR_INVALID_PARAMETER);
            default:
                return Result(ERROR_INVALID_FUNCTION); // InternalCode.Unsupported
        }
    }

    Result Win32Result(uint err)
        => Result(err);
}
else version (Posix)
{
    import core.stdc.errno;
    Result InternalResult(InternalCode code)
    {
        switch (code)
        {
            case InternalCode.Success:
                return Result();
            case InternalCode.BufferTooSmall:
                return Result(ERANGE);
            case InternalCode.InvalidParameter:
                return Result(EINVAL);
            default:
                return Result(ENOTSUP); // InternalCode.Unsupported
        }
    }

    Result PosixResult(int err)
        => Result(err);
    Result ErrnoResult()
        => Result(errno);
}
