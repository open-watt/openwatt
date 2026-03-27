module protocol.ble.winrt;

version (Windows):

import urt.atomic;
import urt.array;
import urt.log;
import urt.mem.allocator : defaultAllocator;
import urt.string;

import urt.uuid;
import urt.internal.sys.windows.windef : HRESULT, BOOL, ULONG;

import manager.thread : ThreadSafePacketQueue;

import protocol.ble.device : ADSection, ADType;
import protocol.ble.iface;

import router.iface : MessageState;
import router.iface.mac : MACAddress;
import router.iface.packet : Packet, PacketType;
import router.iface.priority_queue;

nothrow @nogc:

alias log = Log!"ble";


// --- types and enums ---

alias HSTRING = void*;

struct EventRegistrationToken
{
    long value;
}

enum AsyncStatus : int
{
    started   = 0,
    completed = 1,
    canceled  = 2,
    error     = 3,
}

enum BluetoothLEScanningMode : int
{
    passive = 0,
    active  = 1,
}

enum GattCommunicationStatus : int
{
    success         = 0,
    unreachable     = 1,
    protocol_error  = 2,
    access_denied   = 3,
}

enum GattCharacteristicProperties : uint
{
    none                    = 0x0000,
    broadcast               = 0x0001,
    read                    = 0x0002,
    write_without_response  = 0x0004,
    write                   = 0x0008,
    notify                  = 0x0010,
    indicate                = 0x0020,
    authenticated_signed_writes = 0x0040,
    extended_properties     = 0x0080,
    reliable_write          = 0x0100,
    writable_auxiliaries    = 0x0200,
}

enum GattClientCharacteristicConfigurationDescriptorValue : int
{
    none        = 0,
    notify      = 1,
    indicate    = 2,
}


// --- GUIDs ---

static immutable IID_IUnknown                       = GUID(0x00000000, 0x0000, 0x0000, [0xC0,0x00,0x00,0x00,0x00,0x00,0x00,0x46]);
static immutable IID_IInspectable                   = GUID(0xAF86E2E0, 0xB12D, 0x4C6A, [0x9C,0x5A,0xD7,0xAA,0x65,0x10,0x1E,0x90]);
static immutable IID_IActivationFactory             = GUID(0x00000035, 0x0000, 0x0000, [0xC0,0x00,0x00,0x00,0x00,0x00,0x00,0x46]);
static immutable IID_IAgileObject                   = GUID(0x94EA2B94, 0xE9CC, 0x49E0, [0xC0,0xFF,0xEE,0x64,0xCA,0x8F,0x5B,0x90]);
static immutable IID_IAsyncInfo                     = GUID(0x00000036, 0x0000, 0x0000, [0xC0,0x00,0x00,0x00,0x00,0x00,0x00,0x46]);

static immutable IID_IBluetoothLEAdvertisementWatcher            = GUID(0xA6AC336F, 0xF3D3, 0x4297, [0x8D,0x6C,0xC8,0x1E,0xA6,0x62,0x3F,0x40]);
static immutable IID_IBluetoothLEAdvertisementReceivedEventArgs  = GUID(0x27987DDF, 0xE596, 0x41BE, [0x8D,0x43,0x9E,0x67,0x31,0xD4,0xA9,0x13]);
static immutable IID_IBluetoothLEAdvertisementReceivedEventArgs2 = GUID(0x12D9C87B, 0x0399, 0x5F0E, [0xA3,0x48,0x53,0xB0,0x2B,0x6B,0x16,0x2E]);
static immutable IID_IBluetoothLEAdvertisement                   = GUID(0x066FB2B7, 0x33D1, 0x4E7D, [0x83,0x67,0xCF,0x81,0xD0,0xF7,0x96,0x53]);

static immutable IID_IBluetoothLEDevice             = GUID(0xB5EE2F7B, 0x4AD8, 0x4642, [0xAC,0x48,0x80,0xA0,0xB5,0x00,0xE8,0x87]);
static immutable IID_IBluetoothLEDeviceStatics      = GUID(0xC8CF1A19, 0xF0B6, 0x4BF0, [0x86,0x89,0x41,0x30,0x3D,0xE2,0xD9,0xF4]);
static immutable IID_IBluetoothLEDevice3            = GUID(0xAEE9E493, 0x44AC, 0x40DC, [0xAF,0x33,0xB2,0xC1,0x3C,0x01,0xCA,0x46]);
static immutable IID_IBluetoothLEDeviceStatics2     = GUID(0x5F12C06B, 0x3BAC, 0x43E8, [0xAD,0x16,0x56,0x32,0x71,0xBD,0x41,0xC2]);

static immutable IID_IGattDeviceServicesResult      = GUID(0x171DD3EE, 0x016D, 0x419D, [0x83,0x8A,0x57,0x6C,0xF4,0x75,0xA3,0xD8]);
static immutable IID_IGattDeviceService             = GUID(0xAC7B7C05, 0xB33C, 0x47CF, [0x99,0x0F,0x6B,0x8F,0x55,0x77,0xDF,0x71]);
static immutable IID_IGattDeviceService3            = GUID(0xB293A950, 0x0C53, 0x437C, [0xA9,0xB3,0x5C,0x32,0x10,0xC6,0xE5,0x69]);
static immutable IID_IGattCharacteristicsResult     = GUID(0x1194945C, 0xB257, 0x4F3E, [0x9D,0xB7,0xF6,0x8B,0xC9,0xA9,0xAE,0xF2]);
static immutable IID_IGattCharacteristic            = GUID(0x59CB50C1, 0x5934, 0x4F68, [0xA1,0x98,0xEB,0x86,0x4F,0xA4,0x4E,0x6B]);
static immutable IID_IGattReadResult                = GUID(0x63A66F08, 0x1AEA, 0x4C4C, [0xA5,0x0F,0x97,0xBA,0xE4,0x74,0xB3,0x48]);

static immutable IID_IBluetoothLEAdvertisementPublisher     = GUID(0xCDE820F9, 0xD9FA, 0x43D6, [0xA2,0x64,0xDD,0xD8,0xB7,0xDA,0x8B,0x78]);

static immutable IID_IGattValueChangedEventArgs             = GUID(0xD21BDB54, 0x06E3, 0x4ED8, [0xA2,0x63,0xAC,0xFA,0xC8,0xBA,0x73,0x13]);

// TypedEventHandler<GattCharacteristic, GattValueChangedEventArgs>
static immutable IID_TypedEventHandler_Gatt_ValueChanged    = GUID(0xC1F420F6, 0x6292, 0x5760, [0xA2,0xC9,0x9D,0xDF,0x98,0x68,0x3C,0xFC]);

static immutable IID_IBufferByteAccess                      = GUID(0x905A0FEF, 0xBC53, 0x11DF, [0x8C,0x49,0x00,0x1E,0x4F,0xC6,0x86,0xDA]);
static immutable IID_IBluetoothLEManufacturerData           = GUID(0x912DBA18, 0x6963, 0x4533, [0xB0,0x61,0x46,0x94,0xDA,0xFB,0x34,0xE5]);
static immutable IID_IBluetoothLEAdvertisementDataSection   = GUID(0xD7213314, 0x3A43, 0x40F9, [0xB6,0xF0,0x92,0xBF,0xEF,0xC3,0x4A,0xE3]);

// TypedEventHandler<BluetoothLEAdvertisementWatcher, BluetoothLEAdvertisementReceivedEventArgs>
static immutable IID_TypedEventHandler_Watcher_Received     = GUID(0x90EB4ECA, 0xD465, 0x5EA0, [0xA6,0x1C,0x03,0x3C,0x8C,0x5E,0xCE,0xF2]);

// TypedEventHandler<BluetoothLEDevice, object>
static immutable IID_TypedEventHandler_Device_ConnectionStatus = GUID(0x24A901AD, 0x910F, 0x5C29, [0xB2,0x36,0x80,0x3C,0xC0,0x30,0x60,0xFE]);

// DeviceInformation / DeviceWatcher


// --- WinRT bootstrap ---

struct WinRT
{
nothrow @nogc:
    bool initialized;

    import urt.internal.sys.windows.windef : HMODULE;
    private HMODULE _lib;

    // function pointers loaded from combase.dll
    extern (Windows) HRESULT function(uint initType) RoInitialize;
    extern (Windows) HRESULT function(HSTRING classId, IInspectable* instance) RoActivateInstance;
    extern (Windows) HRESULT function(HSTRING classId, const(GUID)* iid, void** factory) RoGetActivationFactory;
    extern (Windows) HRESULT function(const(wchar)* str, uint len, HSTRING* out_) WindowsCreateString;
    extern (Windows) HRESULT function(HSTRING str) WindowsDeleteString;
    extern (Windows) const(wchar)* function(HSTRING str, uint* len) WindowsGetStringRawBuffer;

    bool init()
    {
        import urt.internal.sys.windows.winbase : LoadLibrary, FreeLibrary, GetProcAddress;

        auto lib = LoadLibrary("combase.dll");
        if (!lib)
        {
            log.error("failed to load combase.dll");
            return false;
        }

        RoInitialize            = cast(typeof(RoInitialize))            GetProcAddress(lib, "RoInitialize");
        RoActivateInstance      = cast(typeof(RoActivateInstance))      GetProcAddress(lib, "RoActivateInstance");
        RoGetActivationFactory  = cast(typeof(RoGetActivationFactory))  GetProcAddress(lib, "RoGetActivationFactory");
        WindowsCreateString     = cast(typeof(WindowsCreateString))     GetProcAddress(lib, "WindowsCreateString");
        WindowsDeleteString     = cast(typeof(WindowsDeleteString))     GetProcAddress(lib, "WindowsDeleteString");
        WindowsGetStringRawBuffer = cast(typeof(WindowsGetStringRawBuffer)) GetProcAddress(lib, "WindowsGetStringRawBuffer");

        if (!RoInitialize || !RoActivateInstance || !RoGetActivationFactory ||
            !WindowsCreateString || !WindowsDeleteString || !WindowsGetStringRawBuffer)
        {
            log.error("failed to resolve WinRT functions from combase.dll");
            FreeLibrary(lib);
            return false;
        }

        HRESULT hr = RoInitialize(1); // RO_INIT_MULTITHREADED
        if (hr < 0 && hr != cast(HRESULT)0x80010106) // RPC_E_CHANGED_MODE is ok
        {
            log.error("RoInitialize failed: ", hr);
            FreeLibrary(lib);
            return false;
        }

        _lib = lib;
        initialized = true;
        log.info("WinRT initialized");
        return true;
    }

    HSTRING make_string(const(wchar)[] s)
    {
        HSTRING h;
        HRESULT hr = WindowsCreateString(s.ptr, cast(uint)s.length, &h);
        if (hr < 0)
            return null;
        return h;
    }

    T activate(T : IInspectable)(const(wchar)[] className, const(GUID)* iid)
    {
        HSTRING cls = make_string(className);
        if (!cls)
            return null;
        scope(exit) WindowsDeleteString(cls);

        IInspectable inspectable;
        HRESULT hr = RoActivateInstance(cls, &inspectable);
        if (hr < 0 || inspectable is null)
            return null;
        scope(exit) inspectable.Release();

        void* result;
        hr = inspectable.QueryInterface(iid, &result);
        if (hr < 0)
            return null;
        return cast(T)cast(void*)result;
    }

    T get_factory(T)(const(wchar)[] className, const(GUID)* iid)
    {
        HSTRING cls = make_string(className);
        if (!cls)
            return null;
        scope(exit) WindowsDeleteString(cls);

        void* result;
        HRESULT hr = RoGetActivationFactory(cls, iid, &result);
        if (hr < 0)
            return null;
        return cast(T)cast(void*)result;
    }
}

__gshared WinRT g_winrt;


// --- helper functions ---

T qi(T)(IUnknown obj, const(GUID)* iid)
{
    if (obj is null)
        return null;
    void* result;
    HRESULT hr = obj.QueryInterface(iid, &result);
    if (hr < 0)
        return null;
    return cast(T)cast(void*)result;
}

void qi_probe(IUnknown obj)
{
    if (obj is null)
        return;

    void* result;
    HRESULT hr = obj.QueryInterface(&IID_IBluetoothLEAdvertisementReceivedEventArgs2, &result);
    log.warningf("  EventArgs2 QI returned: {0,08x}", hr);
    if (hr >= 0 && result !is null)
        (cast(IUnknown)cast(void*)result).Release();

    auto insp = qi!IInspectable(obj, &IID_IInspectable);
    if (insp !is null)
    {
        HSTRING class_name;
        insp.GetRuntimeClassName(&class_name);
        if (class_name !is null)
        {
            uint len;
            const(wchar)* raw = g_winrt.WindowsGetStringRawBuffer(class_name, &len);
            if (raw && len > 0)
            {
                char[128] buf = void;
                uint copy_len = len < 128 ? len : 128;
                foreach (i; 0 .. copy_len)
                    buf[i] = cast(char)raw[i];
                log.warning("  runtime class: ", buf[0 .. copy_len]);
            }
            g_winrt.WindowsDeleteString(class_name);
        }
        insp.Release();
    }
}

const(char)[] format_char_props(GattCharacteristicProperties props)
{
    import urt.mem.temp : tconcat;
    return tconcat(
        props & GattCharacteristicProperties.read ? "R" : "",
        props & GattCharacteristicProperties.write ? "W" : "",
        props & GattCharacteristicProperties.write_without_response ? "w" : "",
        props & GattCharacteristicProperties.notify ? "N" : "",
        props & GattCharacteristicProperties.indicate ? "I" : "",
        props & GattCharacteristicProperties.broadcast ? "B" : "");
}

void ble_addr_to_mac(ulong addr, ref ubyte[6] mac)
{
    mac[0] = cast(ubyte)(addr >> 40);
    mac[1] = cast(ubyte)(addr >> 32);
    mac[2] = cast(ubyte)(addr >> 24);
    mac[3] = cast(ubyte)(addr >> 16);
    mac[4] = cast(ubyte)(addr >> 8);
    mac[5] = cast(ubyte)(addr);
}

ulong mac_to_ble_addr(ref const ubyte[6] mac)
{
    return (cast(ulong)mac[0] << 40) | (cast(ulong)mac[1] << 32) |
           (cast(ulong)mac[2] << 24) | (cast(ulong)mac[3] << 16) |
           (cast(ulong)mac[4] << 8)  | mac[5];
}

const(ubyte)[] get_buffer_bytes(IBuffer buf)
{
    if (buf is null)
        return null;

    uint len;
    auto hr = buf.get_Length(&len);
    if (hr < 0)
    {
        log.warningf("IBuffer.get_Length failed: hr={0,08x}", hr);
        return null;
    }
    if (len == 0)
    {
        log.warning("IBuffer.get_Length returned 0");
        return null;
    }

    auto access = qi!IBufferByteAccess(buf, &IID_IBufferByteAccess);
    if (access is null)
    {
        log.warning("IBufferByteAccess QI failed");
        return null;
    }
    scope(exit) access.Release();

    ubyte* ptr;
    if (access.Buffer(&ptr) < 0 || ptr is null)
        return null;

    return ptr[0 .. len];
}

uint extract_ad_sections(IBluetoothLEAdvertisement adv, ADSection[] out_sections)
{
    if (adv is null || out_sections.length == 0)
        return 0;

    IInspectable sections_raw;
    adv.get_DataSections(&sections_raw);
    if (sections_raw is null)
        return 0;

    auto sections = cast(IVectorView_IInspectable)cast(void*)sections_raw;

    uint count;
    sections.get_Size(&count);

    uint written = 0;
    foreach (i; 0 .. count)
    {
        if (written >= out_sections.length)
            break;

        IInspectable item;
        sections.GetAt(i, &item);
        if (item is null)
            continue;

        auto section = cast(IBluetoothLEAdvertisementDataSection)cast(void*)item;

        ubyte dt;
        section.get_DataType(&dt);

        IBuffer buf;
        section.get_Data(&buf);

        const(ubyte)[] data = get_buffer_bytes(buf);
        if (buf !is null)
            buf.Release();

        out_sections[written++] = ADSection(dt, data);

        item.Release();
    }

    sections_raw.Release();
    return written;
}


// serialize WinRT advertisement COM object to standard BLE AD format [len][type][data]...
uint serialize_advertisement(IBluetoothLEAdvertisement adv, ubyte[] buf)
{
    uint offset = 0;

    // extract local name
    HSTRING hname;
    if (adv !is null)
        adv.get_LocalName(&hname);

    if (hname !is null)
    {
        uint len;
        const(wchar)* raw = g_winrt.WindowsGetStringRawBuffer(hname, &len);
        if (raw && len > 0)
        {
            uint copy_len = len < 64 ? len : 64;
            ubyte name_len = cast(ubyte)(copy_len + 1);
            if (offset + 1 + name_len <= buf.length)
            {
                buf[offset++] = name_len;
                buf[offset++] = ADType.complete_local_name;
                foreach (i; 0 .. copy_len)
                    buf[offset++] = cast(ubyte)raw[i];
            }
        }
        g_winrt.WindowsDeleteString(hname);
    }

    // extract and serialize AD sections
    ADSection[16] sections = void;
    uint num_sections = extract_ad_sections(adv, sections[]);
    foreach (ref s; sections[0 .. num_sections])
    {
        ubyte sec_len = cast(ubyte)(s.data.length + 1);
        if (offset + 1 + sec_len > buf.length)
            break;
        buf[offset++] = sec_len;
        buf[offset++] = s.type;
        if (s.data.length > 0)
        {
            buf[offset .. offset + s.data.length] = cast(const(ubyte)[])s.data[];
            offset += cast(uint)s.data.length;
        }
    }

    return offset;
}


// --- WinRTBackend ---
//
// Owns all WinRT async state (scanner, pending connect/discover/GATT ops, rx queue).
// Methods take what they need as arguments rather than reaching into interface internals.

struct WinRTBackend
{
nothrow @nogc:

    enum GattOpType : ubyte { read, write, write_no_response }

    struct ConnectResult
    {
        enum Status : ubyte { pending, failed, success }
        Status status;
        ubyte tag;
        MACAddress client;
        MACAddress peer;
    }

    enum DiscoverStatus : ubyte { in_progress, complete, failed }

    enum max_gatt_ops = 8;

    // --- poll ---

    void poll(BLEInterface iface)
    {
        winrt_poll_connect(iface);
        winrt_poll_discover();
        winrt_poll_gatt(iface);
    }

    void winrt_poll_connect(BLEInterface iface)
    {
        if (_pending_connect.result is null)
            return;

        auto result = poll_connect();
        final switch (result.status)
        {
            case WinRTBackend.ConnectResult.Status.pending:
                return;

            case WinRTBackend.ConnectResult.Status.failed:
                iface._queue.complete(result.tag, MessageState.failed);
                return;

            case WinRTBackend.ConnectResult.Status.success:
                auto session = defaultAllocator().allocT!BLESession;
                session.client = result.client;
                session.peer = result.peer;
                session.active = true;
                iface._sessions ~= session;

                setup_session(session);

                log.info("connected to ", result.peer);
                iface._queue.complete(result.tag, MessageState.complete);
                return;
        }
    }

    void winrt_poll_discover()
    {
        auto session = _discovering_session;
        if (session is null)
            return;

        auto status = poll_discover(session);

        if (status == WinRTBackend.DiscoverStatus.complete)
        {
            log.info("GATT discovery complete: ", session.num_chars, " characteristics");
            _discovering_session = null;
        }
        else if (status == WinRTBackend.DiscoverStatus.failed)
        {
            log.error("GATT discovery failed");
            _discovering_session = null;
        }
    }

    void winrt_poll_gatt(BLEInterface iface)
    {
        bool flushed = poll_gatt((ubyte tag, WinRTBackend.GattOpType op_type, bool success, ushort attr_handle, const(ubyte)[] data) {
            if (!success)
            {
                iface._queue.complete(tag, MessageState.failed);
                return;
            }

            if (op_type == WinRTBackend.GattOpType.read)
            {
                MACAddress client, peer;
                if (auto pm = tag in iface._pending)
                    client = pm.att.src;
                auto session = iface.find_session_by_client(client);
                if (session !is null)
                    peer = session.peer;

                Packet p;
                ref att = p.init!BLEATTFrame(data);
                att.src = peer;
                att.dst = client;
                att.opcode = ATTOpcode.read_rsp;
                iface.on_incoming(p);

                iface._queue.complete(tag, MessageState.complete);
            }
            else if (op_type == WinRTBackend.GattOpType.write)
            {
                MACAddress client, peer;
                if (auto pm = tag in iface._pending)
                    client = pm.att.src;
                auto session = iface.find_session_by_client(client);
                if (session !is null)
                    peer = session.peer;

                Packet p;
                ref att = p.init!BLEATTFrame(null);
                att.src = peer;
                att.dst = client;
                att.opcode = ATTOpcode.write_rsp;
                iface.on_incoming(p);

                iface._queue.complete(tag, MessageState.complete);
            }
            else
                iface._queue.complete(tag, MessageState.complete);
        });

        if (flushed)
            iface.send_queued_messages();
    }

    // --- scanner ---

    bool init_scanner(MACAddress iface_mac)
    {
        _iface_mac = iface_mac;

        if (!g_winrt.initialized && !g_winrt.init())
        {
            log.error("WinRT initialization failed");
            return false;
        }

        _watcher = g_winrt.activate!IBluetoothLEAdvertisementWatcher(
            "Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher"w,
            &IID_IBluetoothLEAdvertisementWatcher);

        if (_watcher is null)
        {
            log.error("failed to create advertisement watcher");
            return false;
        }

        _watcher.put_ScanningMode(BluetoothLEScanningMode.active);

        _adv_handler = defaultAllocator().allocT!AdvertisementReceivedHandler;
        _adv_handler.callback = &this.on_advertisement_received;

        EventRegistrationToken token;
        auto hr = _watcher.add_Received(cast(IUnknown)_adv_handler, &token);
        if (hr < 0)
        {
            log.error("failed to subscribe to advertisements: ", hr);
            return false;
        }
        _received_token = token;

        hr = _watcher.Start();
        if (hr < 0)
        {
            log.error("failed to start scanner: ", hr);
            return false;
        }

        return true;
    }

    void shutdown_scanner()
    {
        if (_watcher !is null)
        {
            _watcher.Stop();
            _watcher.remove_Received(_received_token);
            _watcher.Release();
            _watcher = null;
        }
        if (_adv_handler !is null)
        {
            defaultAllocator().freeT(_adv_handler);
            _adv_handler = null;
        }
    }

    // --- connect ---

    bool start_connect(MACAddress client, MACAddress peer, ubyte tag)
    {
        if (_pending_connect.result !is null)
        {
            log.warning("connection already in progress");
            return false;
        }

        if (_device_statics is null)
        {
            _device_statics = g_winrt.get_factory!IBluetoothLEDeviceStatics(
                "Windows.Devices.Bluetooth.BluetoothLEDevice"w,
                &IID_IBluetoothLEDeviceStatics);

            if (_device_statics is null)
            {
                log.error("failed to get BluetoothLEDevice statics");
                return false;
            }
        }

        ulong ble_addr = mac_to_ble_addr(peer.b);
        IInspectable async_op;
        auto hr = _device_statics.FromBluetoothAddressAsync(ble_addr, &async_op);
        if (hr < 0 || async_op is null)
        {
            log.error("FromBluetoothAddressAsync failed");
            return false;
        }

        _pending_connect.result = async_op;
        _pending_connect.client = client;
        _pending_connect.peer = peer;
        _pending_connect.tag = tag;

        log.info("connecting to ", peer, "...");
        return true;
    }

    ConnectResult poll_connect()
    {
        if (_pending_connect.result is null)
            return ConnectResult(ConnectResult.Status.pending);

        auto async_info = qi!IAsyncInfo(_pending_connect.result, &IID_IAsyncInfo);
        if (async_info is null)
            return ConnectResult(ConnectResult.Status.pending);
        scope(exit) async_info.Release();

        AsyncStatus status;
        async_info.get_Status(&status);

        if (status == AsyncStatus.started)
            return ConnectResult(ConnectResult.Status.pending);

        if (status != AsyncStatus.completed)
        {
            HRESULT err;
            async_info.get_ErrorCode(&err);
            log.error("connection to ", _pending_connect.peer, " failed: ", err);

            auto tag = _pending_connect.tag;
            cleanup_connect();
            return ConnectResult(ConnectResult.Status.failed, tag);
        }

        auto async_op = cast(IAsyncOperation_BluetoothLEDevice)cast(void*)_pending_connect.result;
        IBluetoothLEDevice device_raw;
        auto hr = async_op.GetResults(&device_raw);

        auto client = _pending_connect.client;
        auto peer = _pending_connect.peer;
        auto tag = _pending_connect.tag;
        cleanup_connect();

        if (hr < 0 || device_raw is null)
        {
            log.error("connection to ", peer, " failed");
            return ConnectResult(ConnectResult.Status.failed, tag);
        }

        _last_connect_device = device_raw;
        _last_connect_device3 = qi!IBluetoothLEDevice3(device_raw, &IID_IBluetoothLEDevice3);

        return ConnectResult(ConnectResult.Status.success, tag, client, peer);
    }

    void cleanup_connect()
    {
        if (_pending_connect.result !is null)
        {
            _pending_connect.result.Release();
            _pending_connect.result = null;
        }
    }

    // --- discover ---

    void start_discover(IBluetoothLEDevice3 device3)
    {
        if (device3 is null)
            return;

        IInspectable gatt_op;
        device3.GetGattServicesWithCacheModeAsync(1, &gatt_op); // 1 = Uncached
        if (gatt_op !is null)
        {
            _pending_discover.result = gatt_op;
            log.info("discovering GATT services...");
        }
    }

    DiscoverStatus poll_discover(BLESession* session)
    {
        if (_pending_discover.result is null && _pending_discover.services is null)
            return DiscoverStatus.complete;

        if (_pending_discover.result is null)
            return DiscoverStatus.in_progress;

        auto async_info = qi!IAsyncInfo(_pending_discover.result, &IID_IAsyncInfo);
        if (async_info is null)
            return DiscoverStatus.in_progress;
        scope(exit) async_info.Release();

        AsyncStatus status;
        async_info.get_Status(&status);

        if (status == AsyncStatus.started)
            return DiscoverStatus.in_progress;

        IInspectable result_raw;
        if (status == AsyncStatus.completed)
        {
            if (_pending_discover.services is null)
            {
                // phase 1: service discovery
                auto async_op = cast(IAsyncOperation_GattDeviceServicesResult)cast(void*)_pending_discover.result;
                IGattDeviceServicesResult svc_result;
                async_op.GetResults(&svc_result);
                result_raw = cast(IInspectable)cast(void*)svc_result;
            }
            else
            {
                // phase 2: characteristic discovery
                auto async_op = cast(IAsyncOperation_GattCharacteristicsResult)cast(void*)_pending_discover.result;
                IGattCharacteristicsResult chr_result;
                async_op.GetResults(&chr_result);
                result_raw = cast(IInspectable)cast(void*)chr_result;
            }
        }

        cleanup_discover_op();

        if (result_raw is null && _pending_discover.services is null)
            return DiscoverStatus.failed;

        if (_pending_discover.services is null)
        {
            // first phase: service list arrived
            auto services_result = cast(IGattDeviceServicesResult)cast(void*)result_raw;
            GattCommunicationStatus gatt_status;
            services_result.get_Status(&gatt_status);

            if (gatt_status != GattCommunicationStatus.success)
            {
                log.error("GATT service discovery failed: status=", cast(int)gatt_status);
                result_raw.Release();
                return DiscoverStatus.failed;
            }

            IInspectable services_raw;
            services_result.get_Services(&services_raw);
            result_raw.Release();

            if (services_raw is null)
            {
                log.warning("no GATT services found");
                return DiscoverStatus.complete;
            }

            auto services = cast(IVectorView_IInspectable)cast(void*)services_raw;
            uint count;
            services.get_Size(&count);
            log.info("found ", count, " GATT services");

            _pending_discover.services = services;
            _pending_discover.service_count = count;
            _pending_discover.current_service = 0;

            return discover_next_service();
        }
        else
        {
            // subsequent phase: characteristics for a service arrived
            if (result_raw !is null)
            {
                auto chars_result = cast(IGattCharacteristicsResult)cast(void*)result_raw;
                GattCommunicationStatus gatt_status;
                chars_result.get_Status(&gatt_status);

                GUID svc_uuid = _pending_discover.current_service_uuid;

                if (gatt_status == GattCommunicationStatus.success)
                {
                    IInspectable chars_raw;
                    chars_result.get_Characteristics(&chars_raw);

                    if (chars_raw !is null)
                    {
                        auto chars = cast(IVectorView_IInspectable)cast(void*)chars_raw;
                        uint count;
                        chars.get_Size(&count);

                        foreach (j; 0 .. count)
                        {
                            IInspectable char_raw;
                            chars.GetAt(j, &char_raw);
                            if (char_raw is null)
                                continue;

                            auto chr = cast(IGattCharacteristic)cast(void*)char_raw;
                            GUID char_uuid;
                            ushort handle;
                            GattCharacteristicProperties props;
                            chr.get_Uuid(&char_uuid);
                            chr.get_AttributeHandle(&handle);
                            chr.get_CharacteristicProperties(&props);

                            log.infof("    char {0,04x}: {1,08x}-{2,04x}-{3,04x}-{4,02x}{5,02x}-{6,02x}{7,02x}{8,02x}{9,02x}{10,02x}{11,02x} [{12}]",
                                handle,
                                char_uuid.data1, char_uuid.data2, char_uuid.data3,
                                char_uuid.data4[0], char_uuid.data4[1], char_uuid.data4[2], char_uuid.data4[3],
                                char_uuid.data4[4], char_uuid.data4[5], char_uuid.data4[6], char_uuid.data4[7],
                                format_char_props(props));

                            if (session !is null && session.num_chars < session.chars.length)
                            {
                                auto idx = session.num_chars++;
                                session.chars[idx].handle = handle;
                                session.chars[idx].service_uuid = svc_uuid;
                                session.chars[idx].char_uuid = char_uuid;
                                session.chars[idx].properties = props;
                                session.chars[idx].characteristic = chr;
                            }
                            else if (chr !is null)
                                (cast(IUnknown)chr).Release();
                        }

                        chars_raw.Release();
                    }
                }
                else
                    log.warning("GATT characteristic discovery failed for service");

                result_raw.Release();
            }

            _pending_discover.current_service++;
            auto next = discover_next_service();

            if (next == DiscoverStatus.complete && session !is null)
                subscribe_session_notifications(session);

            return next;
        }
    }

    void cleanup_discover()
    {
        cleanup_discover_op();
        if (_pending_discover.services !is null)
        {
            (cast(IUnknown)_pending_discover.services).Release();
            _pending_discover.services = null;
        }
    }

    // --- GATT operations ---

    bool submit_read(BLESession* session, ushort handle, ubyte tag)
    {
        if (_num_pending_gatt >= max_gatt_ops)
            return false;

        auto gc = session.find_char(handle);
        if (gc is null || gc.characteristic is null)
            return false;

        IInspectable async_op;
        gc.characteristic.ReadValueWithCacheModeAsync(1, &async_op); // 1 = Uncached
        if (async_op is null)
            return false;

        auto idx = _num_pending_gatt++;
        _pending_gatt[idx].result = async_op;
        _pending_gatt[idx].attr_handle = handle;
        _pending_gatt[idx].op_type = GattOpType.read;
        _pending_gatt[idx].tag = tag;
        return true;
    }

    bool submit_write(BLESession* session, ushort handle, const(ubyte)[] data, bool without_response, ubyte tag)
    {
        if (_num_pending_gatt >= max_gatt_ops)
            return false;

        auto gc = session.find_char(handle);
        if (gc is null || gc.characteristic is null)
            return false;

        auto buf = defaultAllocator().allocT!MemoryBuffer;
        if (buf is null)
            return false;

        // clone data since the packet payload may be freed before the async completes
        ubyte* data_copy = cast(ubyte*)defaultAllocator().alloc(data.length).ptr;
        if (data_copy is null && data.length > 0)
        {
            defaultAllocator().freeT(buf);
            return false;
        }
        data_copy[0 .. data.length] = data[];
        buf.set(data_copy[0 .. data.length]);

        IInspectable async_op;
        if (without_response)
            gc.characteristic.WriteValueWithOptionAsync(cast(IBuffer)buf, 1, &async_op); // 1 = WriteWithoutResponse
        else
            gc.characteristic.WriteValueAsync(cast(IBuffer)buf, &async_op);

        if (async_op is null)
        {
            defaultAllocator().free(data_copy[0 .. data.length]);
            defaultAllocator().freeT(buf);
            return false;
        }

        auto idx = _num_pending_gatt++;
        _pending_gatt[idx].result = async_op;
        _pending_gatt[idx].attr_handle = handle;
        _pending_gatt[idx].op_type = without_response ? GattOpType.write_no_response : GattOpType.write;
        _pending_gatt[idx].tag = tag;

        return true;
    }

    // polls pending GATT ops, calls on_complete for each finished op.
    // data slice in callback is only valid during the callback invocation.
    // returns true if any ops completed (caller should try to send more).
    bool poll_gatt(scope void delegate(ubyte tag, GattOpType op_type, bool success, ushort attr_handle, const(ubyte)[] data) nothrow @nogc on_complete)
    {
        bool flushed;
        uint i = 0;
        while (i < _num_pending_gatt)
        {
            auto pg = &_pending_gatt[i];

            auto async_info = qi!IAsyncInfo(pg.result, &IID_IAsyncInfo);
            if (async_info is null)
            {
                i++;
                continue;
            }

            AsyncStatus status;
            async_info.get_Status(&status);
            async_info.Release();

            if (status == AsyncStatus.started)
            {
                i++;
                continue;
            }

            bool success = false;
            const(ubyte)[] data;
            IBuffer value_buf;

            if (status == AsyncStatus.completed)
            {
                if (pg.op_type == GattOpType.read)
                {
                    auto async_op = cast(IAsyncOperation_GattReadResult)cast(void*)pg.result;
                    IGattReadResult read_result;
                    async_op.GetResults(&read_result);

                    if (read_result !is null)
                    {
                        GattCommunicationStatus gatt_status;
                        read_result.get_Status(&gatt_status);

                        if (gatt_status == GattCommunicationStatus.success)
                        {
                            read_result.get_Value(&value_buf);
                            data = get_buffer_bytes(value_buf);
                            if (data is null && value_buf !is null)
                                log.warning("read: got IBuffer but get_buffer_bytes returned null");
                            else if (value_buf is null)
                                log.warning("read: get_Value returned null IBuffer");
                            success = true;
                        }
                        else
                        {
                            const(char)[] status_str = "unknown";
                            switch (gatt_status)
                            {
                                case GattCommunicationStatus.unreachable: status_str = "unreachable"; break;
                                case GattCommunicationStatus.protocol_error: status_str = "protocol error"; break;
                                case GattCommunicationStatus.access_denied: status_str = "access denied"; break;
                                default: break;
                            }
                            log.warning("read failed: ", status_str);
                        }

                        read_result.Release();
                    }
                }
                else
                {
                    auto async_op = cast(IAsyncOperation_GattCommunicationStatus)cast(void*)pg.result;
                    GattCommunicationStatus gatt_status;
                    async_op.GetResults(&gatt_status);

                    success = gatt_status == GattCommunicationStatus.success;
                    if (!success)
                        log.warning("GATT write failed: status=", gatt_status);
                }
            }

            on_complete(pg.tag, pg.op_type, success, pg.attr_handle, data);

            if (value_buf !is null)
                value_buf.Release();
            pg.result.Release();

            --_num_pending_gatt;
            if (i < _num_pending_gatt)
                _pending_gatt[i] = _pending_gatt[_num_pending_gatt];
            flushed = true;
        }

        return flushed;
    }

    @property ubyte num_pending_gatt() const
    {
        return _num_pending_gatt;
    }

    // --- advertising ---

    IBluetoothLEAdvertisementPublisher start_advertising(const(ubyte)[] payload)
    {
        auto publisher = g_winrt.activate!IBluetoothLEAdvertisementPublisher(
            "Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementPublisher"w,
            &IID_IBluetoothLEAdvertisementPublisher);

        if (publisher is null)
        {
            log.error("failed to create advertisement publisher");
            return null;
        }

        IBluetoothLEAdvertisement adv;
        publisher.get_Advertisement(&adv);

        if (adv !is null)
        {
            uint offset = 0;
            while (offset < payload.length)
            {
                if (offset + 1 >= payload.length)
                    break;
                ubyte len = payload[offset++];
                if (len == 0 || offset + len > payload.length)
                    break;
                ubyte ad_type = payload[offset];
                const(ubyte)[] ad_data = payload[offset + 1 .. offset + len];
                offset += len;

                if (ad_type == ADType.complete_local_name || ad_type == ADType.shortened_local_name)
                {
                    wchar[64] wname = void;
                    uint wlen = cast(uint)ad_data.length;
                    if (wlen > 64) wlen = 64;
                    foreach (i; 0 .. wlen)
                        wname[i] = ad_data[i];
                    HSTRING hname = g_winrt.make_string(wname[0 .. wlen]);
                    if (hname !is null)
                    {
                        adv.put_LocalName(hname);
                        g_winrt.WindowsDeleteString(hname);
                    }
                }
            }

            adv.Release();
        }

        auto hr = publisher.Start();
        if (hr < 0)
        {
            log.error("failed to start advertising");
            publisher.Release();
            return null;
        }

        return publisher;
    }

    // --- session lifecycle ---

    void setup_session(BLESession* session)
    {
        session.device = _last_connect_device;
        session.device3 = _last_connect_device3;
        _last_connect_device = null;
        _last_connect_device3 = null;

        auto handler = defaultAllocator().allocT!ConnectionStatusHandler;
        handler.session = session;
        handler.callback = &this.on_connection_status_changed;

        EventRegistrationToken token;
        session.device.add_ConnectionStatusChanged(cast(IUnknown)handler, &token);
        session.conn_handler = handler;
        session.conn_status_token = token;

        if (session.device3 !is null)
        {
            start_discover(session.device3);
            _discovering_session = session;
        }
    }

    void release_session(BLESession* session)
    {
        if (session.device !is null && session.conn_handler !is null)
        {
            session.device.remove_ConnectionStatusChanged(session.conn_status_token);
            defaultAllocator().freeT(session.conn_handler);
            session.conn_handler = null;
        }

        foreach (ref gc; session.chars[0 .. session.num_chars])
        {
            if (gc.characteristic !is null)
            {
                gc.characteristic.Release();
                gc.characteristic = null;
            }
        }

        if (session.device3 !is null)
        {
            session.device3.Release();
            session.device3 = null;
        }
        if (session.device !is null)
        {
            session.device.Release();
            session.device = null;
        }
    }

    // --- rx queue ---

    void enqueue_rx(ref Packet p)
    {
        _rx_queue.enqueue(p.clone());
    }

    Packet* dequeue_rx()
    {
        return _rx_queue.dequeue();
    }

private:

    MACAddress _iface_mac;

    // last successful connection (consumed by setup_session)
    IBluetoothLEDevice _last_connect_device;
    IBluetoothLEDevice3 _last_connect_device3;
    BLESession* _discovering_session;

    // scanner
    IBluetoothLEAdvertisementWatcher _watcher;
    AdvertisementReceivedHandler _adv_handler;
    EventRegistrationToken _received_token;

    // device factory
    IBluetoothLEDeviceStatics _device_statics;

    // pending connection async
    struct PendingConnect
    {
        IInspectable result;
        MACAddress client;
        MACAddress peer;
        ubyte tag;
    }
    PendingConnect _pending_connect;

    // pending GATT discovery async
    struct PendingDiscover
    {
        IInspectable result;

        // for iterating services during characteristic discovery
        IVectorView_IInspectable services;
        uint service_count;
        uint current_service;
        GUID current_service_uuid;
    }
    PendingDiscover _pending_discover;

    // pending GATT operations
    struct PendingGattOp
    {
        IInspectable result;
        ushort attr_handle;
        GattOpType op_type;
        ubyte tag;
    }
    PendingGattOp[max_gatt_ops] _pending_gatt;
    ubyte _num_pending_gatt;

    // thread-safe rx queue
    ThreadSafePacketQueue!64 _rx_queue;

    void cleanup_discover_op()
    {
        if (_pending_discover.result !is null)
        {
            _pending_discover.result.Release();
            _pending_discover.result = null;
        }
    }

    DiscoverStatus discover_next_service()
    {
        auto services = _pending_discover.services;
        while (_pending_discover.current_service < _pending_discover.service_count)
        {
            IInspectable svc_raw;
            services.GetAt(_pending_discover.current_service, &svc_raw);
            if (svc_raw is null)
            {
                _pending_discover.current_service++;
                continue;
            }

            auto svc = cast(IGattDeviceService)cast(void*)svc_raw;
            GUID svc_uuid;
            svc.get_Uuid(&svc_uuid);

            log.infof("  service: {0,08x}-{1,04x}-{2,04x}-{3,02x}{4,02x}-{5,02x}{6,02x}{7,02x}{8,02x}{9,02x}{10,02x}",
                svc_uuid.data1, svc_uuid.data2, svc_uuid.data3,
                svc_uuid.data4[0], svc_uuid.data4[1], svc_uuid.data4[2], svc_uuid.data4[3],
                svc_uuid.data4[4], svc_uuid.data4[5], svc_uuid.data4[6], svc_uuid.data4[7]);

            _pending_discover.current_service_uuid = svc_uuid;

            auto svc3 = qi!IGattDeviceService3(svc_raw, &IID_IGattDeviceService3);
            svc_raw.Release();

            if (svc3 is null)
            {
                log.warning("IGattDeviceService3 QI failed");
                _pending_discover.current_service++;
                continue;
            }

            IInspectable chars_op;
            svc3.GetCharacteristicsAsync(&chars_op);
            svc3.Release();

            if (chars_op is null)
            {
                _pending_discover.current_service++;
                continue;
            }

            _pending_discover.result = chars_op;
            return DiscoverStatus.in_progress;
        }

        // all services done
        if (_pending_discover.services !is null)
        {
            (cast(IUnknown)_pending_discover.services).Release();
            _pending_discover.services = null;
        }

        return DiscoverStatus.complete;
    }

    void subscribe_session_notifications(BLESession* session)
    {
        foreach (ref gc; session.chars[0 .. session.num_chars])
        {
            bool wants = (gc.properties & (GattCharacteristicProperties.notify | GattCharacteristicProperties.indicate)) != 0;
            if (wants)
                subscribe_characteristic(gc.characteristic, gc.handle, session.peer, session.client);
        }
    }

    void subscribe_characteristic(IGattCharacteristic chr, ushort handle, MACAddress peer, MACAddress client)
    {
        auto handler = defaultAllocator().allocT!GattValueChangedHandler;
        handler.attr_handle = handle;
        handler.peer = peer;
        handler.client = client;
        handler.callback = &this.on_gatt_notification;

        EventRegistrationToken token;
        auto hr = chr.add_ValueChanged(cast(IUnknown)handler, &token);
        if (hr < 0)
        {
            log.warningf("failed to subscribe to ValueChanged for handle {0,04x}: {1,08x}", handle, hr);
            defaultAllocator().freeT(handler);
            return;
        }

        GattCharacteristicProperties props;
        chr.get_CharacteristicProperties(&props);

        auto cccd_value = (props & GattCharacteristicProperties.notify) != 0
            ? GattClientCharacteristicConfigurationDescriptorValue.notify
            : GattClientCharacteristicConfigurationDescriptorValue.indicate;

        IInspectable async_op;
        chr.WriteClientCharacteristicConfigurationDescriptorAsync(cccd_value, &async_op);
        if (async_op !is null)
            (cast(IUnknown)async_op).Release(); // fire and forget

        log.infof("subscribed to notifications for handle {0,04x}", handle);
    }

    // --- callbacks (invoked from WinRT threads) ---

    void on_advertisement_received(MACAddress addr, byte rssi, bool connectable, bool is_scan_response, const(ubyte)[] ad_payload)
    {
        Packet p;
        ref ll = p.init!BLELLFrame(ad_payload);
        ll.src = addr;
        ll.dst = MACAddress.broadcast;

        if (is_scan_response)
            ll.pdu_type = BLELLType.scan_rsp;
        else if (connectable)
            ll.pdu_type = BLELLType.adv_ind;
        else
            ll.pdu_type = BLELLType.adv_nonconn_ind;

        ll.rssi = rssi;
        _rx_queue.enqueue(p.clone());
    }

    void on_gatt_notification(MACAddress peer, MACAddress client, ushort attr_handle, const(ubyte)[] data)
    {
        // notification payload is [handle(2)][value...]
        import urt.endian;
        ubyte[256] buf = void;
        if (2 + data.length > buf.length)
            return;
        buf[0 .. 2] = attr_handle.nativeToLittleEndian;
        buf[2 .. 2 + data.length] = cast(const(ubyte)[])data[];

        Packet p;
        ref att = p.init!BLEATTFrame(buf[0 .. 2 + data.length]);
        att.src = peer;
        att.dst = client;
        att.opcode = ATTOpcode.notification;
        _rx_queue.enqueue(p.clone());
    }

    void on_connection_status_changed(BLESession* session)
    {
        if (session is null || !session.active)
            return;

        int conn_status;
        session.device.get_ConnectionStatus(&conn_status);

        if (conn_status == 0) // Disconnected
        {
            log.info("device ", session.peer, " disconnected");

            Packet p;
            ref ll = p.init!BLELLFrame(null);
            ll.src = _iface_mac;
            ll.dst = session.client;
            ll.pdu_type = BLELLType.disconnect_ind;
            _rx_queue.enqueue(p.clone());

            session.active = false;
        }
    }
}


// --- COM/WinRT interfaces ---

extern (Windows):

interface IUnknown
{
nothrow @nogc:
    HRESULT QueryInterface(const(GUID)* riid, void** ppv);
    ULONG AddRef();
    ULONG Release();
}

interface IInspectable : IUnknown
{
nothrow @nogc:
    HRESULT GetIids(uint* count, GUID** iids);
    HRESULT GetRuntimeClassName(HSTRING* name);
    HRESULT GetTrustLevel(int* level);
}

interface IActivationFactory : IInspectable
{
nothrow @nogc:
    HRESULT ActivateInstance(IInspectable* instance);
}

interface IAgileObject : IUnknown
{
}

// Async

interface IAsyncInfo : IInspectable
{
nothrow @nogc:
    HRESULT get_Id(uint* id);
    HRESULT get_Status(AsyncStatus* status);
    HRESULT get_ErrorCode(HRESULT* code);
    HRESULT Cancel();
    HRESULT Close();
}

// IAsyncOperation specializations — each has put_Completed, get_Completed, GetResults
// with different return types for GetResults

interface IAsyncOperation_BluetoothLEDevice : IInspectable
{
nothrow @nogc:
    HRESULT put_Completed(IUnknown handler);
    HRESULT get_Completed(IUnknown* handler);
    HRESULT GetResults(IBluetoothLEDevice* result);
}

interface IAsyncOperation_GattDeviceServicesResult : IInspectable
{
nothrow @nogc:
    HRESULT put_Completed(IUnknown handler);
    HRESULT get_Completed(IUnknown* handler);
    HRESULT GetResults(IGattDeviceServicesResult* result);
}

interface IAsyncOperation_GattCharacteristicsResult : IInspectable
{
nothrow @nogc:
    HRESULT put_Completed(IUnknown handler);
    HRESULT get_Completed(IUnknown* handler);
    HRESULT GetResults(IGattCharacteristicsResult* result);
}

interface IAsyncOperation_GattReadResult : IInspectable
{
nothrow @nogc:
    HRESULT put_Completed(IUnknown handler);
    HRESULT get_Completed(IUnknown* handler);
    HRESULT GetResults(IGattReadResult* result);
}

interface IAsyncOperation_GattCommunicationStatus : IInspectable
{
nothrow @nogc:
    HRESULT put_Completed(IUnknown handler);
    HRESULT get_Completed(IUnknown* handler);
    HRESULT GetResults(GattCommunicationStatus* result);
}

// BLE Advertisement

interface IBluetoothLEAdvertisementWatcher : IInspectable
{
nothrow @nogc:
    HRESULT get_MinSamplingInterval(long* value);
    HRESULT get_MaxSamplingInterval(long* value);
    HRESULT get_MinOutOfRangeTimeout(long* value);
    HRESULT get_MaxOutOfRangeTimeout(long* value);
    HRESULT get_Status(int* value);
    HRESULT get_ScanningMode(BluetoothLEScanningMode* value);
    HRESULT put_ScanningMode(BluetoothLEScanningMode value);
    HRESULT get_SignalStrengthFilter(IInspectable* value);
    HRESULT put_SignalStrengthFilter(IInspectable value);
    HRESULT get_AdvertisementFilter(IInspectable* value);
    HRESULT put_AdvertisementFilter(IInspectable value);
    HRESULT Start();
    HRESULT Stop();
    HRESULT add_Received(IUnknown handler, EventRegistrationToken* token);
    HRESULT remove_Received(EventRegistrationToken token);
    HRESULT add_Stopped(IUnknown handler, EventRegistrationToken* token);
    HRESULT remove_Stopped(EventRegistrationToken token);
}

interface IBluetoothLEAdvertisementReceivedEventArgs : IInspectable
{
nothrow @nogc:
    HRESULT get_RawSignalStrengthInDBm(short* value);
    HRESULT get_BluetoothAddress(ulong* value);
    HRESULT get_AdvertisementType(int* value);
    HRESULT get_Timestamp(long* value);
    HRESULT get_Advertisement(IBluetoothLEAdvertisement* value);
}

interface IBluetoothLEAdvertisementReceivedEventArgs2 : IInspectable
{
nothrow @nogc:
    HRESULT get_BluetoothAddressType(int* value);
    HRESULT get_TransmitPowerLevelInDBm(IInspectable* value); // IReference<short>
    HRESULT get_IsAnonymous(BOOL* value);
    HRESULT get_IsConnectable(BOOL* value);
    HRESULT get_IsScannable(BOOL* value);
    HRESULT get_IsDirected(BOOL* value);
    HRESULT get_IsScanResponse(BOOL* value);
}

interface IBluetoothLEAdvertisement : IInspectable
{
nothrow @nogc:
    HRESULT get_Flags(IInspectable* value);
    HRESULT put_Flags(IInspectable value);
    HRESULT get_LocalName(HSTRING* value);
    HRESULT put_LocalName(HSTRING value);
    HRESULT get_ServiceUuids(IInspectable* value);
    HRESULT get_ManufacturerData(IInspectable* value);
    HRESULT get_DataSections(IInspectable* value);
    HRESULT GetManufacturerDataByCompanyId(ushort companyId, IInspectable* dataList);
    HRESULT GetSectionsByType(ubyte type_, IInspectable* sectionList);
}

// IVector/IVectorView

interface IVectorView_IInspectable : IInspectable
{
nothrow @nogc:
    HRESULT GetAt(uint index, IInspectable* item);
    HRESULT get_Size(uint* size);
    HRESULT IndexOf(IInspectable value, uint* index, BOOL* found);
    HRESULT GetMany(uint startIndex, uint capacity, IInspectable* items, uint* actual);
}

// IBuffer

interface IBuffer : IInspectable
{
nothrow @nogc:
    HRESULT get_Capacity(uint* value);
    HRESULT get_Length(uint* value);
    HRESULT put_Length(uint value);
}

interface IBufferByteAccess : IUnknown
{
nothrow @nogc:
    HRESULT Buffer(ubyte** value);
}

interface IBluetoothLEManufacturerData : IInspectable
{
nothrow @nogc:
    HRESULT get_CompanyId(ushort* value);
    HRESULT put_CompanyId(ushort value);
    HRESULT get_Data(IBuffer* value);
    HRESULT put_Data(IBuffer value);
}

interface IBluetoothLEAdvertisementDataSection : IInspectable
{
nothrow @nogc:
    HRESULT get_DataType(ubyte* value);
    HRESULT put_DataType(ubyte value);
    HRESULT get_Data(IBuffer* value);
    HRESULT put_Data(IBuffer value);
}

// GATT

interface IGattDeviceServicesResult : IInspectable
{
nothrow @nogc:
    HRESULT get_Status(GattCommunicationStatus* value);
    HRESULT get_ProtocolError(IInspectable* value);
    HRESULT get_Services(IInspectable* value);
}

interface IGattDeviceService : IInspectable
{
nothrow @nogc:
    HRESULT GetCharacteristics(GUID characteristicUuid, IInspectable* value);
    HRESULT GetIncludedServices(GUID serviceUuid, IInspectable* value);
    HRESULT get_DeviceId(HSTRING* value);
    HRESULT get_Uuid(GUID* value);
    HRESULT get_AttributeHandle(ushort* value);
}

interface IGattDeviceService3 : IInspectable
{
nothrow @nogc:
    HRESULT get_DeviceAccessInformation(IInspectable* value);
    HRESULT get_Session(IInspectable* value);
    HRESULT get_SharingMode(int* value);
    HRESULT RequestAccessAsync(IInspectable* operation);
    HRESULT OpenAsync(int sharingMode, IInspectable* operation);
    HRESULT GetCharacteristicsAsync(IInspectable* operation);
    HRESULT GetCharacteristicsWithCacheModeAsync(int cacheMode, IInspectable* operation);
    HRESULT GetCharacteristicsForUuidAsync(GUID uuid, IInspectable* operation);
    HRESULT GetCharacteristicsForUuidWithCacheModeAsync(GUID uuid, int cacheMode, IInspectable* operation);
    HRESULT GetIncludedServicesAsync(IInspectable* operation);
    HRESULT GetIncludedServicesWithCacheModeAsync(int cacheMode, IInspectable* operation);
}

interface IGattCharacteristicsResult : IInspectable
{
nothrow @nogc:
    HRESULT get_Status(GattCommunicationStatus* value);
    HRESULT get_ProtocolError(IInspectable* value);
    HRESULT get_Characteristics(IInspectable* value);
}

interface IGattCharacteristic : IInspectable
{
nothrow @nogc:
    HRESULT GetDescriptors(GUID descriptorUuid, IInspectable* value);
    HRESULT get_CharacteristicProperties(GattCharacteristicProperties* value);
    HRESULT get_ProtectionLevel(int* value);
    HRESULT put_ProtectionLevel(int value);
    HRESULT get_UserDescription(HSTRING* value);
    HRESULT get_Uuid(GUID* value);
    HRESULT get_AttributeHandle(ushort* value);
    HRESULT get_PresentationFormats(IInspectable* value);
    HRESULT ReadValueAsync(IInspectable* operation);
    HRESULT ReadValueWithCacheModeAsync(int cacheMode, IInspectable* operation);
    HRESULT WriteValueAsync(IBuffer value, IInspectable* operation);
    HRESULT WriteValueWithOptionAsync(IBuffer value, int writeOption, IInspectable* operation);
    HRESULT ReadClientCharacteristicConfigurationDescriptorAsync(IInspectable* operation);
    HRESULT WriteClientCharacteristicConfigurationDescriptorAsync(GattClientCharacteristicConfigurationDescriptorValue value, IInspectable* operation);
    HRESULT add_ValueChanged(IUnknown handler, EventRegistrationToken* token);
    HRESULT remove_ValueChanged(EventRegistrationToken token);
}

interface IGattReadResult : IInspectable
{
nothrow @nogc:
    HRESULT get_Status(GattCommunicationStatus* value);
    HRESULT get_Value(IBuffer* value);
}

interface IGattValueChangedEventArgs : IInspectable
{
nothrow @nogc:
    HRESULT get_CharacteristicValue(IBuffer* value);
    HRESULT get_Timestamp(long* value);
}

// Advertisement Publishing

interface IBluetoothLEAdvertisementPublisher : IInspectable
{
nothrow @nogc:
    HRESULT get_Status(int* value);
    HRESULT get_Advertisement(IBluetoothLEAdvertisement* value);
    HRESULT Start();
    HRESULT Stop();
    HRESULT add_StatusChanged(IUnknown handler, EventRegistrationToken* token);
    HRESULT remove_StatusChanged(EventRegistrationToken token);
}

// BluetoothLEDevice

interface IBluetoothLEDeviceStatics : IInspectable
{
nothrow @nogc:
    HRESULT FromIdAsync(HSTRING deviceId, IInspectable* operation);
    HRESULT FromBluetoothAddressAsync(ulong bluetoothAddress, IInspectable* operation);
    HRESULT GetDeviceSelector(HSTRING* selector);
}

interface IBluetoothLEDeviceStatics2 : IInspectable
{
nothrow @nogc:
    HRESULT GetDeviceSelectorFromPairingState(BOOL pairingState, HSTRING* selector);
    HRESULT GetDeviceSelectorFromConnectionStatus(int status, HSTRING* selector);
    HRESULT GetDeviceSelectorFromDeviceName(HSTRING name, HSTRING* selector);
    HRESULT GetDeviceSelectorFromBluetoothAddress(ulong addr, HSTRING* selector);
    HRESULT GetDeviceSelectorFromBluetoothAddressWithType(ulong addr, int addrType, HSTRING* selector);
    HRESULT GetDeviceSelectorFromAppearance(IInspectable appearance, HSTRING* selector);
}

interface IBluetoothLEDevice : IInspectable
{
nothrow @nogc:
    HRESULT get_DeviceId(HSTRING* value);
    HRESULT get_Name(HSTRING* value);
    HRESULT get_GattServices(IInspectable* value);
    HRESULT get_ConnectionStatus(int* value);
    HRESULT get_BluetoothAddress(ulong* value);
    HRESULT GetGattService(GUID serviceUuid, IInspectable* service);
    HRESULT add_NameChanged(IUnknown handler, EventRegistrationToken* token);
    HRESULT remove_NameChanged(EventRegistrationToken token);
    HRESULT add_GattServicesChanged(IUnknown handler, EventRegistrationToken* token);
    HRESULT remove_GattServicesChanged(EventRegistrationToken token);
    HRESULT add_ConnectionStatusChanged(IUnknown handler, EventRegistrationToken* token);
    HRESULT remove_ConnectionStatusChanged(EventRegistrationToken token);
}

interface IBluetoothLEDevice3 : IInspectable
{
nothrow @nogc:
    HRESULT get_DeviceAccessInformation(IInspectable* value);
    HRESULT RequestAccessAsync(IInspectable* operation);
    HRESULT GetGattServicesAsync(IInspectable* operation);
    HRESULT GetGattServicesWithCacheModeAsync(int cacheMode, IInspectable* operation);
    HRESULT GetGattServicesForUuidAsync(GUID serviceUuid, IInspectable* operation);
    HRESULT GetGattServicesForUuidWithCacheModeAsync(GUID serviceUuid, int cacheMode, IInspectable* operation);
}

// Handler interfaces

interface IAdvertisementReceivedHandler : IUnknown
{
nothrow @nogc:
    HRESULT Invoke(IInspectable sender, IInspectable args);
}

interface IGattValueChangedHandler : IUnknown
{
nothrow @nogc:
    HRESULT Invoke(IInspectable sender, IInspectable args);
}

interface IConnectionStatusHandler : IUnknown
{
nothrow @nogc:
    HRESULT Invoke(IInspectable sender, IInspectable args);
}


// --- COM implementation classes ---

class ComObject : IInspectable
{
nothrow @nogc:
    private uint _ref_count = 1;

    HRESULT QueryInterface(const(GUID)* riid, void** ppv)
    {
        if (*riid == IID_IUnknown || *riid == IID_IInspectable || *riid == IID_IAgileObject)
        {
            *ppv = cast(void*)cast(IUnknown)this;
            AddRef();
            return 0; // S_OK
        }
        *ppv = null;
        return 0x80004002; // E_NOINTERFACE
    }

    ULONG AddRef()
    {
        return ++_ref_count;
    }

    ULONG Release()
    {
        if (--_ref_count == 0)
        {
            defaultAllocator().freeT(this);
            return 0;
        }
        return _ref_count;
    }

    // IInspectable stubs
    HRESULT GetIids(uint* count, GUID** iids) { *count = 0; *iids = null; return 0; }
    HRESULT GetRuntimeClassName(HSTRING* name) { *name = null; return 0; }
    HRESULT GetTrustLevel(int* level) { *level = 0; return 0; }
}


class MemoryBuffer : ComObject, IBuffer, IBufferByteAccess
{
nothrow @nogc:
    private ubyte* _data;
    private uint _length;
    private uint _capacity;

    void set(const(ubyte)[] data)
    {
        _data = cast(ubyte*)data.ptr;
        _length = cast(uint)data.length;
        _capacity = cast(uint)data.length;
    }

    override HRESULT QueryInterface(const(GUID)* riid, void** ppv)
    {
        if (*riid == IID_IBufferByteAccess)
        {
            *ppv = cast(void*)cast(IBufferByteAccess)this;
            AddRef();
            return 0;
        }
        return super.QueryInterface(riid, ppv);
    }

    // IBuffer
    HRESULT get_Capacity(uint* value) { *value = _capacity; return 0; }
    HRESULT get_Length(uint* value) { *value = _length; return 0; }
    HRESULT put_Length(uint value) { _length = value; return 0; }

    // IBufferByteAccess
    HRESULT Buffer(ubyte** value) { *value = _data; return 0; }
}


class AdvertisementReceivedHandler : ComObject, IAdvertisementReceivedHandler
{
nothrow @nogc:
    extern(D) void delegate(MACAddress addr, byte rssi, bool connectable, bool is_scan_response, const(ubyte)[] ad_payload) nothrow @nogc callback;

    override HRESULT QueryInterface(const(GUID)* riid, void** ppv)
    {
        if (*riid == IID_TypedEventHandler_Watcher_Received)
        {
            *ppv = cast(void*)cast(IUnknown)this;
            AddRef();
            return 0;
        }
        return super.QueryInterface(riid, ppv);
    }

    HRESULT Invoke(IInspectable sender, IInspectable args_raw)
    {
        if (!callback)
            return 0;

        auto args = qi!IBluetoothLEAdvertisementReceivedEventArgs(args_raw, &IID_IBluetoothLEAdvertisementReceivedEventArgs);
        if (args is null)
            return 0;
        scope(exit) args.Release();

        ulong addr;
        short rssi;
        IBluetoothLEAdvertisement adv;

        args.get_BluetoothAddress(&addr);
        args.get_RawSignalStrengthInDBm(&rssi);
        args.get_Advertisement(&adv);

        bool connectable = false;
        bool is_scan_response = false;
        auto args2 = qi!IBluetoothLEAdvertisementReceivedEventArgs2(args_raw, &IID_IBluetoothLEAdvertisementReceivedEventArgs2);
        if (args2 !is null)
        {
            BOOL conn, scan_rsp;
            args2.get_IsConnectable(&conn);
            args2.get_IsScanResponse(&scan_rsp);
            connectable = conn != 0;
            is_scan_response = scan_rsp != 0;
            args2.Release();
        }
        else
        {
            static bool warned;
            if (!warned)
            {
                log.warning("EventArgs2 QI failed -- GUID may be wrong");
                qi_probe(args_raw);
                warned = true;
            }
        }

        // extract and serialize advertisement data before calling back
        MACAddress mac_addr;
        ble_addr_to_mac(addr, mac_addr.b);

        ubyte[254] payload = void;
        uint payload_len = serialize_advertisement(adv, payload[]);

        if (adv !is null)
            adv.Release();

        callback(mac_addr, cast(byte)rssi, connectable, is_scan_response, payload[0 .. payload_len]);

        return 0;
    }
}


class ConnectionStatusHandler : ComObject, IConnectionStatusHandler
{
nothrow @nogc:
    extern (D) void delegate(BLESession*) nothrow @nogc callback;
    BLESession* session;

    override HRESULT QueryInterface(const(GUID)* riid, void** ppv)
    {
        if (*riid == IID_TypedEventHandler_Device_ConnectionStatus)
        {
            *ppv = cast(void*)cast(IUnknown)this;
            AddRef();
            return 0;
        }
        return super.QueryInterface(riid, ppv);
    }

    HRESULT Invoke(IInspectable sender, IInspectable args)
    {
        if (callback)
            callback(session);
        return 0;
    }
}


class GattValueChangedHandler : ComObject, IGattValueChangedHandler
{
nothrow @nogc:
    extern(D) void delegate(MACAddress peer, MACAddress client, ushort attr_handle, const(ubyte)[] data) nothrow @nogc callback;
    ushort attr_handle;
    MACAddress peer;
    MACAddress client;

    override HRESULT QueryInterface(const(GUID)* riid, void** ppv)
    {
        if (*riid == IID_TypedEventHandler_Gatt_ValueChanged)
        {
            *ppv = cast(void*)cast(IUnknown)this;
            AddRef();
            return 0;
        }
        return super.QueryInterface(riid, ppv);
    }

    HRESULT Invoke(IInspectable sender, IInspectable args_raw)
    {
        if (!callback)
            return 0;

        auto args = cast(IGattValueChangedEventArgs)cast(void*)args_raw;
        if (args is null)
            return 0;

        IBuffer value_buf;
        args.get_CharacteristicValue(&value_buf);
        const(ubyte)[] data = get_buffer_bytes(value_buf);

        callback(peer, client, attr_handle, data);

        if (value_buf !is null)
            value_buf.Release();

        return 0;
    }
}


