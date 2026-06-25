module driver.linux.system;

version (linux):

import urt.endian : LittleEndian;
import urt.internal.sys.posix : open, close, write, fsync, unlink, readlink, pread, ssize_t, mode_t, O_WRONLY, O_RDWR, O_CREAT, O_TRUNC;
import urt.log;
import urt.string.format : tconcat;
import urt.time : MonoTime, getTime, msecs;

nothrow @nogc:


enum mode_t mode_0755 = 0x1ED;
enum int exit_restart = 42; // child exit code that asks the supervisor to relaunch

const(char)[] install_dir()
{
    if (g_dir_len == 0)
    {
        ssize_t n = readlink("/proc/self/exe", g_dir.ptr, g_dir.length);
        if (n <= 0)
            return null;
        size_t end = cast(size_t)n;
        while (end > 0 && g_dir[end - 1] != '/')
            --end;
        g_dir_len = end;
    }
    return g_dir[0 .. g_dir_len];
}

int current_slot()
{
    char* s = getenv("OW_SLOT");
    return s ? atoi(s) : -1;
}

void system_reboot()
{
    g_reboot = true;
}

bool reboot_pending() => g_reboot;

bool ota_supported() => true;

size_t ota_partition_size() => 256 * 1024 * 1024;

int ota_begin(size_t image_size, ref uint handle)
{
    if (g_ota_fd >= 0)
        return -1;
    const(char)[] dir = install_dir();
    if (!dir.length)
        return -1;

    int slot = current_slot();
    g_ota_slot = (slot >= 0 ? slot : 0) + 1;

    const(char)* part = zpath(g_ota_part, tconcat("openwatt.", g_ota_slot, ".part"));
    if (!part)
        return -1;
    g_ota_fd = open(part, O_RDWR | O_CREAT | O_TRUNC, mode_0755);
    if (g_ota_fd < 0)
    {
        log_error("ota", "open ", g_ota_part.ptr[0 .. cstrlen(g_ota_part.ptr)], " failed");
        return -1;
    }
    handle = cast(uint)(g_ota_slot);
    return 0;
}

int ota_write(uint handle, const(ubyte)[] data)
{
    if (g_ota_fd < 0)
        return -1;
    size_t off = 0;
    while (off < data.length)
    {
        ssize_t n = write(g_ota_fd, data.ptr + off, data.length - off);
        if (n <= 0)
            return -1;
        off += n;
    }
    return 0;
}

int ota_end(uint handle)
{
    if (g_ota_fd < 0)
        return -1;
    fsync(g_ota_fd);
    if (!validate_elf(g_ota_fd))
    {
        log_error("ota", "uploaded image is not a compatible Linux ELF executable");
        close(g_ota_fd);
        g_ota_fd = -1;
        unlink(g_ota_part.ptr);
        return -1;
    }
    close(g_ota_fd);
    g_ota_fd = -1;

    char[4096] final_buf = void;
    const(char)* final_path = zpath(final_buf, tconcat("openwatt.", g_ota_slot));
    if (!final_path || rename(g_ota_part.ptr, final_path) != 0)
    {
        log_error("ota", "rename to slot ", g_ota_slot, " failed");
        return -1;
    }

    // hand the staged slot to the supervisor; it launches it on the next restart.
    char[4096] next_buf = void;
    const(char)* next_path = zpath(next_buf, "openwatt.next");
    if (next_path)
    {
        int fd = open(next_path, O_WRONLY | O_CREAT | O_TRUNC, mode_0755);
        if (fd >= 0)
        {
            const(char)[] txt = tconcat(g_ota_slot, '\n');
            write(fd, txt.ptr, txt.length);
            fsync(fd);
            close(fd);
        }
    }
    log_notice("ota", "staged slot ", g_ota_slot, "; restart to apply");
    return 0;
}

void ota_abort(uint handle)
{
    if (g_ota_fd >= 0)
    {
        close(g_ota_fd);
        g_ota_fd = -1;
        unlink(g_ota_part.ptr);
    }
}

void ignore_sigpipe()
{
    signal(SIGPIPE, cast(void*)1); // SIG_IGN
}

void supervisor_attach()
{
    char* s = getenv("OW_WATCHDOG_FD");
    if (!s)
        return;
    g_watchdog_fd = atoi(s);
}

void supervisor_heartbeat()
{
    if (g_watchdog_fd < 0)
        return;
    MonoTime now = getTime();
    if (g_last_feed != MonoTime.init && now - g_last_feed < msecs(500))
        return;
    g_last_feed = now;
    watchdog_write("h\n");
}

void ota_commit() {}

void ota_push_policy(uint commit_secs, uint watchdog_ms, uint max_fail)
{
    watchdog_write(tconcat("cfg commit=", commit_secs, " watchdog=", watchdog_ms, " maxfail=", max_fail, "\n"));
}


private:

enum int SIGPIPE = 13;

__gshared char[4096] g_dir;
__gshared size_t g_dir_len; // length incl. trailing '/'; 0 until resolved
__gshared int g_ota_fd = -1;
__gshared int g_ota_slot;
__gshared char[4096] g_ota_part; // null-terminated ".part" path of the in-progress write
__gshared int g_watchdog_fd = -1;
__gshared MonoTime g_last_feed;
__gshared bool g_reboot;

extern(C) nothrow @nogc
{
    void* signal(int signum, void* handler);
    char* getenv(scope const(char)* name);
    int chmod(scope const(char)* path, mode_t mode);
    int rename(scope const(char)* oldp, scope const(char)* newp);
    int atoi(scope const(char)* s);
}

void watchdog_write(const(char)[] s)
{
    if (g_watchdog_fd >= 0)
        write(g_watchdog_fd, s.ptr, s.length);
}

size_t cstrlen(const(char)* s)
{
    size_t n = 0;
    while (s[n])
        ++n;
    return n;
}

const(char)* zpath(char[] buf, const(char)[] name)
{
    const(char)[] dir = install_dir();
    if (dir.length + name.length + 1 > buf.length)
        return null;
    buf[0 .. dir.length] = dir[];
    buf[dir.length .. dir.length + name.length] = name[];
    buf[dir.length + name.length] = '\0';
    return buf.ptr;
}

bool validate_elf(int fd)
{
    enum ubyte elf_class_32 = 1;
    enum ubyte elf_class_64 = 2;
    enum ubyte elf_data_lsb = 1;
    enum ubyte elf_data_msb = 2;
    enum ushort et_exec = 2;
    enum ushort et_dyn = 3;

    ubyte[64] hdr = void;
    ssize_t n = pread(fd, hdr.ptr, hdr.length, 0);
    if (n < 24)
        return false;
    if (hdr[0] != 0x7f || hdr[1] != 'E' || hdr[2] != 'L' || hdr[3] != 'F')
        return false;

    ubyte expected_class = size_t.sizeof == 8 ? elf_class_64 : elf_class_32;
    if (hdr[4] != expected_class)
        return false;

    ubyte expected_data = LittleEndian ? elf_data_lsb : elf_data_msb;
    if (hdr[5] != expected_data || hdr[6] != 1)
        return false;

    ushort type = elf_u16(hdr, 16);
    if (type != et_exec && type != et_dyn)
        return false;

    return elf_u16(hdr, 18) == expected_elf_machine;
}

ushort elf_u16(ref const ubyte[64] hdr, size_t off)
{
    if (hdr[5] == 1)
        return cast(ushort)(hdr[off] | (hdr[off + 1] << 8));
    return cast(ushort)((hdr[off] << 8) | hdr[off + 1]);
}

ushort expected_elf_machine()
{
    version (X86)        return 3;   // EM_386
    else version (X86_64) return 62;  // EM_X86_64
    else version (ARM)    return 40;  // EM_ARM
    else version (AArch64) return 183; // EM_AARCH64
    else version (RISCV32) return 243; // EM_RISCV
    else version (RISCV64) return 243; // EM_RISCV
    else static assert(false, "Linux OTA ELF validation does not know this architecture");
}
