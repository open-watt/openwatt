module manager.bootguard;

import urt.driver.nvs;
import urt.driver.reset : has_reset_record, reset_record_scratch;
import urt.file;
import urt.crc;
import urt.log;
import urt.result : SizeResult;
import urt.string.format : tconcat;
import urt.time;

import manager : g_app, TimerHandler;

import driver.system : ResetClass, ImageId, OtaImage, has_recovery_boot, reset_class, reset_reason, ota_running_image, ota_accept_image, ota_previous_image, ota_revert, system_reboot;

nothrow @nogc:


enum Rung : ubyte
{
    saved,      // the newest saved revision
    startup,    // startup.conf, the deployment
    defaults,   // default.conf, the board's bring-up state
}

struct BootDecision
{
    Rung rung;
    bool retire_revision;   // the newest saved revision struck out while on trial
    bool one_shot;          // the operator's gesture: defaults for this boot only
}

enum int max_strikes = 3;
enum int gesture_count = 5;
enum Duration gesture_window = 5.seconds;
enum Duration healthy_uptime = 60.seconds;


BootDecision boot_guard_begin(int newest_revision, bool has_startup)
{
    _begun = true;
    _has_saved = newest_revision > 0;
    _has_startup = has_startup;
    ResetClass reset = reset_class();
    if (!read_state())
    {
        // Without a trustworthy record, existing configurations are never disposable trials.
        _state.trusted_revision = newest_revision > 0 ? newest_revision : 0;
    }
    if (trial.rung > Rung.defaults || trial.strikes >= max_strikes)
        trial = Trial.init;
    version (Embedded) {}
    else
    {
        if (reset == ResetClass.unknown)
            reset = ResetClass.deliberate;    // a plain desktop run has no supervisor and is never a crash
    }

    OtaImage image;
    _image_known = ota_running_image(image);
    if (_image_known)
    {
        if (reconcile_image(_state, image))
            trial = Trial.init;
        _accept_pending = image.pending;
    }
    _trusted = newest_revision > 0 && newest_revision <= _state.trusted_revision;

    BootDecision d;
    final switch (reset)
    {
        case ResetClass.power:
            trial = Trial.init;
            if (++_state.gesture >= gesture_count)
            {
                _state.gesture = 0;
                d.one_shot = true;
                _why = "operator gesture";
            }
            break;

        case ResetClass.crash:
        case ResetClass.unknown:
            _state.gesture = 0;
            if (++trial.strikes >= max_strikes)
            {
                trial.strikes = 0;
                descend(d);
            }
            break;

        case ResetClass.deliberate:
            _state.gesture = 0;
            break;
    }
    d.rung = d.one_shot ? Rung.defaults : first_existing(cast(Rung)trial.rung);
    checkpoint();

    const(char)[] reason = reset_reason();
    log_info("system", "boot guard: reset ", reset_name(reset), reason ? tconcat(" (", reason, ')') : "", ", strikes ", trial.strikes, '/', max_strikes,
             ", gesture ", _state.gesture, '/', gesture_count, ", rung ", rung_name(d.rung), pending ? ", firmware on trial" : "");
    return d;
}

void boot_guard_loaded(Rung rung, int revision)
{
    _rung = rung;
    _revision = revision;
}

void boot_guard_update()
{
    if (!_begun || _healthy)
        return;
    Duration up = getAppTime();
    if (!_settled && up >= gesture_window)
    {
        _settled = true;
        if (_state.gesture)
        {
            _state.gesture = 0;
            checkpoint();
        }
    }
    if (up < healthy_uptime)
        return;
    _healthy = true;

    if (_rung == Rung.saved && _revision > _state.trusted_revision)
        _state.trusted_revision = _revision;
    bool top = _rung == first_existing(Rung.saved);
    if (pending && top && _state.rollback == ImageId.init)
        _state.pending = false;
    if (!pending)
        trial.rung = Rung.saved;
    trial.strikes = 0;
    checkpoint();
    if (!top)
        log_notice("system", "boot guard: healthy on ", rung_name(_rung), pending ? "; firmware stays on trial until the top rung is healthy" : "");
}

void boot_guard_config_saved()
{
    trial = Trial.init;
    checkpoint();
}

const(char)[] boot_guard_status()
{
    if (!_begun)
        return "--config";
    if (_why)
        return tconcat(rung_name(_rung), " (", _why, ')');
    return rung_name(_rung);
}


private:

version (Windows)         enum has_boot_store = true;
else version (Posix)      enum has_boot_store = true;
else version (UseLittleFS) enum has_boot_store = true;
else version (UseSpiffs)   enum has_boot_store = true;
else                      enum has_boot_store = has_nvs;

struct Trial
{
    ubyte strikes;
    ubyte rung;
}

// Retained RAM carries the crash trial where available; only power-persistent fields go to flash.
struct BootState
{
    uint trusted_revision;
    ImageId image;
    ImageId rollback;
    ubyte gesture;
    ubyte pending;
    static if (has_reset_record)
        ubyte[2] reserved;
    else
        Trial trial;
}

__gshared BootState _state;
__gshared BootState _stored;
__gshared const(char)[] _why;
__gshared Rung _rung;
__gshared int _revision;
__gshared bool _trusted;
__gshared bool _has_saved;
__gshared bool _has_startup;
__gshared bool _begun;
__gshared bool _settled;
__gshared bool _healthy;
__gshared bool _have_stored;
__gshared bool _image_known;
__gshared bool _accept_pending;
__gshared bool _recover;

static if (has_reset_record)
    ref Trial trial() => *cast(Trial*)reset_record_scratch().ptr;
else
    ref Trial trial() => _state.trial;

bool pending() => _image_known && _state.pending;

Rung first_existing(Rung r)
{
    if (r == Rung.saved && !_has_saved)
        r = Rung.startup;
    if (r == Rung.startup && !_has_startup)
        r = Rung.defaults;
    return r;
}

void descend(ref BootDecision d)
{
    final switch (first_existing(cast(Rung)trial.rung))
    {
        case Rung.saved:
            if (!_trusted)
            {
                d.retire_revision = true;
                _why = max_strikes.stringof ~ " crashes on a revision still on trial";
                return;
            }
            trial.rung = Rung.startup;
            _why = max_strikes.stringof ~ " crashes on the saved configuration";
            return;

        case Rung.startup:
            trial.rung = Rung.defaults;
            _why = max_strikes.stringof ~ " crashes on startup.conf";
            return;

        case Rung.defaults:
            _why = max_strikes.stringof ~ " crashes on bring-up defaults";
            if (pending)
            {
                log_error("system", "boot guard: firmware crashes on bring-up defaults; reverting to the previous image");
                if (ota_previous_image(_state.rollback) && _state.rollback != _state.image)
                    return;
                _state.rollback = ImageId.init;
                log_error("system", "boot guard: no previous image to revert to");
            }
            static if (has_recovery_boot)
            {
                log_error("system", "boot guard: nothing left to fall back to; rebooting into recovery");
                _recover = true;
            }
            return;
    }
}

const(char)[] rung_name(Rung r)
{
    final switch (r)
    {
        case Rung.saved:    return "saved configuration";
        case Rung.startup:  return "startup.conf";
        case Rung.defaults: return "bring-up defaults";
    }
}

const(char)[] reset_name(ResetClass c)
{
    final switch (c)
    {
        case ResetClass.unknown:    return "unknown";
        case ResetClass.power:      return "power";
        case ResetClass.crash:      return "crash";
        case ResetClass.deliberate: return "deliberate";
    }
}

bool reconcile_image(ref BootState state, ref const OtaImage image)
{
    if (state.image == image.id)
        return false;
    bool reverted = state.rollback != ImageId.init && state.rollback == image.id;
    state.image = image.id;
    state.rollback = ImageId.init;
    state.pending = !reverted && image.pending;
    return true;
}

TimerHandler retry_handler()
{
    return (MonoTime) { checkpoint(); };
}

void checkpoint()
{
    static if (!has_boot_store)
        return;
    g_app.cancel(retry_handler());
    if (commit_transition())
        return;
    log_error("system", "boot guard: recovery checkpoint failed; retrying in 5 seconds");
    g_app.schedule(getTime() + 5.seconds, retry_handler());
}

static if (has_recovery_boot)
    import driver.system : recovery_reboot = system_reboot_to_recovery;
else
    void recovery_reboot() {}

bool commit_transition(alias persist = write_state, alias accept = ota_accept_image, alias revert = ota_revert, alias reboot = system_reboot, alias recover = recovery_reboot)()
{
    if (!persist())
        return false;
    // Slot selection, recovery and bootloader acceptance must follow the durable recovery record.
    if (_image_known && _state.rollback != ImageId.init)
    {
        if (!revert(_state.rollback))
            return false;
        reboot();
        return true;
    }
    if (_recover)
    {
        _recover = false;
        recover();
        return true;
    }
    if (_accept_pending && !accept())
        return false;
    _accept_pending = false;
    return true;
}

struct BootRecord
{
nothrow @nogc:
    uint magic = 0x3142574f; // OWB1
    BootState state;
    uint crc;

    this(ref const BootState state)
    {
        this.state = state;
        crc = calculate_crc!(Algorithm.crc32_iso_hdlc)(bytes[0 .. crc.offsetof]);
    }

    const(ubyte)[] bytes() const => (cast(const(ubyte)*)&this)[0 .. BootRecord.sizeof];

    bool valid(size_t size = BootRecord.sizeof) const
    {
        if (size != BootRecord.sizeof || magic != BootRecord.init.magic || crc != calculate_crc!(Algorithm.crc32_iso_hdlc)(bytes[0 .. crc.offsetof]))
            return false;
        if (state.trusted_revision > int.max || state.gesture >= gesture_count || state.pending > 1)
            return false;
        static if (has_reset_record)
        {
            if (state.reserved != typeof(state.reserved).init)
                return false;
        }
        else if (state.trial.strikes >= max_strikes || state.trial.rung > Rung.defaults)
            return false;
        return (!state.pending || state.image != ImageId.init) && (state.rollback == ImageId.init || (state.pending && state.rollback != state.image));
    }
}

version (LittleEndian) {}
else static assert(false, "BootRecord requires little-endian storage");
static assert(BootState.sizeof == 72 && BootState.trusted_revision.offsetof == 0 && BootState.image.offsetof == 4 && BootState.rollback.offsetof == 36);
static assert(BootState.gesture.offsetof == 68 && BootState.pending.offsetof == 69);
static assert(BootRecord.sizeof == 80 && BootRecord.state.offsetof == 4 && BootRecord.crc.offsetof == 76);

bool read_state()
{
    BootRecord record;
    size_t size;
    static if (has_nvs)
    {
        Nvs nvs;
        if (!nvs_open(nvs, "openwatt", NvsOpenMode.read_only))
            return false;
        scope(exit) nvs_close(nvs);
        SizeResult r = nvs_read(nvs, "boot", (&record)[0 .. 1]);
        if (!r)
            return false;
        size = r.size;
    }
    else
    {
        File file;
        if (!file.open("conf/boot.state", FileOpenMode.ReadExisting))
            return false;
        scope(exit) file.close();
        if (file.get_size() != BootRecord.sizeof || !file.read((&record)[0 .. 1], size))
            return false;
    }
    if (!record.valid(size))
        return false;
    _state = _stored = record.state;
    _have_stored = true;
    return true;
}

bool write_state(alias persist = persist_state)()
{
    if (_have_stored && _state == _stored)
        return true;
    BootRecord record = BootRecord(_state);
    if (!persist(record.bytes))
        return false;
    _stored = _state;
    _have_stored = true;
    return true;
}

bool persist_state(const(ubyte)[] data)
{
    static if (has_nvs)
    {
        Nvs nvs;
        if (!nvs_open(nvs, "openwatt", NvsOpenMode.read_write))
            return false;
        scope(exit) nvs_close(nvs);
        if (!nvs_write(nvs, "boot", data) || !nvs_commit(nvs))
            return false;
    }
    else if (!replace_state_file("conf", data))
        return false;
    return true;
}

static if (!has_nvs)
{
    bool replace_state_file(const(char)[] directory, const(ubyte)[] data)
    {
        const(char)[] path = tconcat(directory, "/boot.state");
        const(char)[] temporary = tconcat(path, ".tmp");
        File file;
        if (!file.open(temporary, FileOpenMode.WriteTruncate))
            return false;
        scope(exit) file.close();
        size_t written;
        if (!file.write(data, written) || written != data.length || !file.flush())
            return false;
        file.close();
        version (Windows)
        {
            import urt.internal.sys.windows.winbase : MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH;
            import urt.string : twstringz;
            return MoveFileExW(temporary.twstringz, path.twstringz,
                              MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
        }
        else
        {
            if (!rename_file(temporary, path))
                return false;
            version (Posix)
            {
                if (!file.open(directory, FileOpenMode.ReadExisting) || !file.flush())
                    return false;
            }
            return true;
        }
    }
}

unittest
{
    BootState state;
    state.trusted_revision = 42;
    state.image[0] = 1;
    state.pending = true;
    BootRecord record = BootRecord(state);
    auto data = cast(ubyte[])record.bytes;
    assert(record.valid && record.state == state);
    foreach (i; 0 .. BootRecord.sizeof)
    {
        data[i] ^= 1;
        assert(!record.valid);
        data[i] ^= 1;
    }
    assert(!record.valid(data.length - 1));
    OtaImage image;
    image.id[0] = 2;
    image.pending = true;
    assert(reconcile_image(state, image) && state.pending && state.image == image.id);
    assert(!reconcile_image(state, image) && state.pending);
    image.pending = false;
    assert(!reconcile_image(state, image) && state.pending);
    state.rollback[0] = 3;
    assert(!reconcile_image(state, image) && state.rollback[0] == 3);
    image.id = state.rollback;
    image.pending = true;
    assert(reconcile_image(state, image) && !state.pending && state.rollback == ImageId.init);
    assert(!reconcile_image(state, image) && !state.pending);
    image.id[0] = 4;
    assert(reconcile_image(state, image) && state.pending);
}

unittest
{
    const old_state = _state;
    const old_stored = _stored;
    const old_have_stored = _have_stored;
    scope(exit)
    {
        _state = old_state;
        _stored = old_stored;
        _have_stored = old_have_stored;
    }
    _state = _stored = BootState.init;
    _have_stored = false;
    uint writes;
    bool succeeds;
    bool persist(const(ubyte)[] data)
    {
        ++writes;
        return succeeds;
    }
    assert(!write_state!persist() && !_have_stored && writes == 1);
    succeeds = true;
    assert(write_state!persist() && _have_stored && writes == 2);
    assert(write_state!persist() && writes == 2);
    _state.trusted_revision = 7;
    succeeds = false;
    assert(!write_state!persist() && _stored.trusted_revision == 0 && writes == 3);
    succeeds = true;
    assert(write_state!persist() && _stored.trusted_revision == 7 && writes == 4);

    version (FreeStanding) {}
    else static if (!has_nvs)
    {
        import urt.mem : free;
        char[256] buffer;
        char[] path = buffer[];
        assert(get_temp_filename(path, ".", "owb"));
        assert(delete_file(path));
        assert(create_directory(path));
        scope(exit) remove_directory(path);
        const(char)[] state_path = tconcat(path, "/boot.state");
        scope(exit) delete_file(state_path);
        BootRecord record = BootRecord(_state);
        auto data = record.bytes;
        assert(replace_state_file(path, data));
        _state.trusted_revision = 8;
        record = BootRecord(_state);
        assert(replace_state_file(path, data));
        assert(create_directory(tconcat(state_path, ".tmp")));
        scope(exit) remove_directory(tconcat(state_path, ".tmp"));
        assert(!replace_state_file(path, data));
        auto saved = cast(ubyte[])load_file(state_path);
        scope(exit) free(saved);
        assert(saved == data && record.valid && record.state.trusted_revision == 8);
    }
}

unittest
{
    const old_state = _state;
    const old_image_known = _image_known;
    const old_accept_pending = _accept_pending;
    scope(exit)
    {
        _state = old_state;
        _image_known = old_image_known;
        _accept_pending = old_accept_pending;
    }
    _state = BootState.init;
    _image_known = true;
    _accept_pending = true;
    uint saves, accepts, selections, reboots, recoveries;
    bool saved, accepted, selected;
    bool persist() { ++saves; return saved; }
    bool accept() { assert(saved); ++accepts; return accepted; }
    bool revert(ref const ImageId image) { assert(saved && image == _state.rollback); ++selections; return selected; }
    void reboot() { assert(selected); ++reboots; }
    void recover() { assert(saved); ++recoveries; }
    alias commit = commit_transition!(persist, accept, revert, reboot, recover);
    assert(!commit() && saves == 1 && accepts == 0 && selections == 0);
    saved = true;
    assert(!commit() && accepts == 1 && _accept_pending);
    accepted = true;
    assert(commit() && accepts == 2 && !_accept_pending);
    _state.rollback[0] = 5;
    saved = false;
    assert(!commit() && selections == 0 && reboots == 0);
    saved = true;
    assert(!commit() && selections == 1 && reboots == 0 && _state.rollback[0] == 5);
    selected = true;
    assert(commit() && selections == 2 && reboots == 1);
    _image_known = false;
    assert(commit() && selections == 2 && reboots == 1);
    _recover = true;
    saved = false;
    assert(!commit() && recoveries == 0 && _recover);
    saved = true;
    assert(commit() && recoveries == 1 && !_recover && accepts == 2);
}
