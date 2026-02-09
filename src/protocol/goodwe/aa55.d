module protocol.goodwe.aa55;

import urt.array;
import urt.conv;
import urt.endian;
import urt.inet;
import urt.lifetime;
import urt.log;
import urt.mem.allocator;
import urt.meta;
import urt.result;
import urt.si;
import urt.socket;
import urt.string;
import urt.time;
import urt.variant;

import manager;
import manager.base;
import manager.collection;
import manager.sampler;

import protocol.goodwe : GoodWeModule;

import router.stream;

version = NegotiateAddress;
//version = DebugAA55;

nothrow @nogc:


enum GoodWeControlCode : ubyte
{
    register = 0x00,
    read = 0x01,
    execute = 0x03
}

enum GoodWeFunctionCode : ubyte
{
    // read:
    running_info = 0x01,
    id_info = 0x02,
    setting_info = 0x03,
    running_data = 0x06,
    status_data = 0x09,

    // register:
    offline_query = 0x00,
    register_request = 0x80,
    allocate_register_address = 0x01,
    address_confirm = 0x81,
    remove_register = 0x02,
    remove_confirm = 0x82,

    // execute:
    start_inverter = 0x1B,
    stop_inverter = 0x1C,
    disconnect_reconnect_grid = 0x1D,
    adjust_real_power = 0x1E
}

enum GoodWeBatteryMode : ubyte
{
    no_battery = 0,
    standby = 1,
    discharge = 2,
    charge = 3,
    to_be_charged = 4,
    to_be_discharged = 5,
}

enum GoodWeEnergyMode : ubyte
{
    check_mode = 0x00,
    wait_mode = 0x01,
    normal_on_grid = 0x02,
    normal_off_grid = 0x04,
    flash_mode = 0x08,
    fault_mode = 0x10,
    battery_standby = 0x20,
    battery_charging = 0x40,
    battery_discharging = 0x80
}

enum GoodWeGridMode : ubyte
{
    off_grid = 0,
    on_grid = 1,
    fault = 2
}

enum GodWeGridInOut : ubyte
{
    idle = 0,
    exporting = 1,
    importing = 2
}

enum GoodWeLoadMode : ubyte
{
    inverter_and_load_disconnected = 0,
    inverter_connected_to_load = 1
}

enum GoodWePVMode : ubyte
{
    not_connected = 0,
    no_power = 1,
    producing = 2
}

enum GoodWeWorkMode : ubyte
{
    wait = 0,
    normal = 1,
    error = 2,
    check = 3
}

enum GoodWeWorkModeET : ubyte
{
    wait = 0,
    on_grid = 1,
    off_grid = 2,
    fault = 3,
    flash = 4,
    check = 5
}

enum GoodWeWorkModeES : ubyte
{
    standby = 0,
    inverter_on = 1,
    abnormal = 2,
    severely_abnormal = 3 // O_o
}

enum GoodWeDiagStatusCode : uint
{
    battery_voltage_low             = 1 << 0,
    battery_soc_low                 = 1 << 1,
    battery_soc_in_back             = 1 << 2,
    bms_discharge_disabled          = 1 << 3,
    discharge_time_on               = 1 << 4,
    charge_time_on                  = 1 << 5,
    discharge_driver_on             = 1 << 6,
    bms_discharge_current_low       = 1 << 7,
    app_discharge_current_too_low   = 1 << 8,
    meter_communication_failure     = 1 << 9,
    meter_connection_reversed       = 1 << 10,
    self_use_load_light             = 1 << 11,
    ems_discharge_current_is_zero   = 1 << 12,
    discharge_bus_high_pv_voltage   = 1 << 13,
    battery_disconnected            = 1 << 14,
    battery_overcharged             = 1 << 15,
    bms_temperature_too_high        = 1 << 16,
    bms_charge_too_high             = 1 << 17,
    bms_charge_disabled             = 1 << 18,
    self_use_off                    = 1 << 19,
    soc_delta_too_volatile          = 1 << 20,
    battery_self_discharge_too_high = 1 << 21,
    battery_soc_low_off_grid        = 1 << 22,
    grid_wave_unstable              = 1 << 23,
    export_power_limit_set          = 1 << 24,
    pf_value_set                    = 1 << 25,
    real_power_limit_set            = 1 << 26,
    dc_output_on                    = 1 << 27,
    soc_protect_off                 = 1 << 28,
    bms_emergency_charging          = 1 << 30,
}


alias u_DeciVolt = Quantity!(ushort, ScaledUnit(Volt, -1));
alias u_Amp = Quantity!(short, ScaledUnit(Ampere));
alias u_DeciAmp = Quantity!(short, ScaledUnit(Ampere, -1));
alias u_MilliAmp = Quantity!(short, ScaledUnit(Ampere, -3));
alias u_Watts = Quantity!(short, ScaledUnit(Watt));
alias u_Seconds = Quantity!(ushort, ScaledUnit(Second));
alias U_Hours = Quantity!(uint, Hour);

struct RunningInfo
{
align(1):
    u_DeciVolt v_pv1;               // 0.1V PV1 voltage
    u_DeciVolt v_pv2;               // 0.1V PV2 voltage
    u_DeciAmp i_pv1;                // 0.1A PV1 current
    u_DeciAmp i_pv2;                // 0.1A PV2 current
    u_DeciVolt v_grid;               // 0.1V Phase L1 voltage
    u_DeciAmp i_grid;                // 0.1A Phase L1 current
    ushort f_grid;                   // 0.01Hz Phase L1 frequency
    u_Watts p_ac;                   // 1W Feeding power
    ubyte[2] unk_1;                // unknown / reserved
    ushort c_inverter_temp;
    ubyte[4] unk_2;                // error_codes ???
    uint e_total;                 // 0.1KW.Hr Total Feed Energy to grid
    U_Hours h_total;
    ubyte[12] unk_4;
    ushort e_day;
    u_DeciVolt v_bat;
    ubyte[2] res_0;
    ushort soc;
    u_DeciAmp i_bat;
    ubyte[6] unk_5;
    ushort e_load_day;
    uint e_load_total;
    ushort total_power;
    u_DeciVolt v_backup;
    u_DeciAmp i_backup;
    ubyte[6] unk_7;               // unknown / reserved
    ushort soh;
    ushort c_bat_temp;
    ubyte[10] unk_8;               // unknown / reserved
    ubyte[6] time;
    ubyte[8] unk_9;               // unknown / reserved
    ushort f_backup;
    ubyte[22] unk_10;               // unknown / reserved
/+
    u_DeciVolt v_ac1;               // 0.1V Phase L1 voltage
    u_DeciVolt v_ac2;               // 0.1V Phase L2 voltage
    u_DeciVolt v_ac3;               // 0.1V Phase L3 voltage
    u_DeciAmp i_ac1;                // 0.1A Phase L1 current
    u_DeciAmp i_ac2;                // 0.1A Phase L2 current
    u_DeciAmp i_ac3;                // 0.1A Phase L3 current
    ushort f_ac1;                   // 0.01Hz Phase L1 frequency
    ushort f_ac2;                   // 0.01Hz Phase L2 frequency
    ushort f_ac3;                   // 0.01Hz Phase L3 frequency
    u_Watts p_ac;                   // 1W Feeding power
    GoodWeWorkMode work_mode;       // Work Mode (Table3-6)
    short temperature;              // 0.1 degree C Inverter internal temperature
    ushort error_msg_h;             // Failure description for status 'failure' (Table3-7)
    ushort error_msg_l;             // Failure description for status 'failure' (Table3-7)
    uint e_total;                   // 0.1KW.Hr Total Feed Energy to grid
    U_Hours h_total;                // Hr Total feeding hours
    short tmp_fault_value;          // 0.1 Degree C Temperature fault value
    u_DeciVolt pv1_fault_value;     // 0.1V PV1 voltage fault value
    u_DeciVolt pv2_fault_value;     // 0.1V PV2 voltage fault value
    u_DeciVolt line1_v_fault_value; // 0.1V Phase L1 voltage fault value
    u_DeciVolt line2_v_fault_value; // 0.1V Phase L2 voltage fault value
    u_DeciVolt line3_v_fault_value; // 0.1V Phase L3 voltage fault value
    ushort line1_f_fault_value;     // 0.01Hz Phase L1 frequency fault value
    ushort line2_f_fault_value;     // 0.01Hz Phase L2 frequency fault value
    ushort line3_f_fault_value;     // 0.01Hz Phase L3 frequency fault value
    u_MilliAmp gfci_fault_value;    // 1mA GFCI fault value
    ushort e_day;                   // 0.1KW.Hr Feed Engery to grid in today
+/
}

struct RunningData
{
align(1):
    u_DeciVolt v_pv1;
    u_DeciAmp i_pv1;
    ubyte pv1_state; // 0: no power, 1: check, 2: power
    u_DeciVolt v_pv2;
    u_DeciAmp i_pv2;
    ubyte pv2_state; // 0: no power, 1: check, 2: power
    u_DeciVolt v_bat;
    ubyte[2] unk_3;
    ushort bat_status;
    short c_bat_temp;
    u_DeciAmp i_bat;
    u_Amp i_bat_charge;
    u_Amp i_bat_discharge;
    ushort bat_error;
    ubyte soc;
    ubyte[2] unk_4; // soc1/soc2??
    ubyte soh;
    GoodWeBatteryMode bat_mode;
    ushort bat_warning;
    ubyte meter_status;
    u_DeciVolt v_grid;
    u_DeciAmp i_grid;
    u_Watts p_grid_export;
    ushort f_grid;
    ubyte grid_mode;
    u_DeciVolt v_backup;
    u_DeciAmp i_backup;
    u_Watts p_load; // ON GRID POWER ??? ** export to grid/import from grid???
    ushort f_backup;
    ubyte load_mode;
    ubyte work_mode; // 0: check, 2: on-grid, 4: off-grid
    ushort c_inverter_temp;
    uint error_codes;
    uint e_total; // Total PV Generation
    U_Hours h_total; // Hours Total
    ushort e_day;
    ushort e_load_day;
    uint e_load_total;
    ushort total_power;
    ubyte effective_work_mode;
    ushort effective_relay_control;
    ubyte grid_in_out; // 0: standby, 1: exporting, 2: importing
    u_Watts p_backup;
    ushort meter_power_factor;
    ushort unk_10;
    short unk_11;
    uint diagnose_result;
    ubyte[2] unk_12;
    ubyte[6] time;
    ubyte[26] unk_13;
    u_Watts total_plant_consumption;
    ubyte[11] unk_14;
}

struct IDInfo
{
    char[5] firmware_version;
    char[10] model_name;
    void[16] reserved;
    char[16] serial_number;
    char[4] nom_vpv;            // 0.1V Nominal PV voltage
    char[12] software_version;
    ubyte safety_country_code;
}

struct SettingInfo
{
    u_DeciVolt vpv_start;   // 0.1V PV start-up voltage
    u_Seconds t_start;      // 1Sec Time to connect grid
    u_DeciVolt vac_min;     // 0.1V Minimum operational grid voltage
    u_DeciVolt vac_max;     // 0.1V Maximum operational grid voltage
    ushort fac_min;         // 0.01Hz Minimum operational grid Frequency
    ushort fac_max;         // 0.01Hz Maximum operational grid Frequency
}


alias AA55Response = void delegate(bool success, ref const AA55Request request, SysTime response_time, const(ubyte)[] response_data, void* user_data) nothrow @nogc;

struct AA55Request
{
    SysTime request_time;
    ubyte source_addr = 0xC0;
    ubyte dest_addr = 0x7F;
    GoodWeControlCode control_code;
    GoodWeFunctionCode function_code;

private:
    // TODO: multiple `read` requests can stack on to in-flight requests
    //       we should keep a list of callback/userdata and append for each request; and callback all waiting on response
    AA55Response callback;
    void* user_data;
}


class AA55Client : BaseObject
{
    __gshared Property[3] Properties = [ Property.create!("remote", remote)(),
                                         Property.create!("profile", profile)(),
                                         Property.create!("model", model)() ];
nothrow @nogc:

    enum type_name = "aa55";

    this(String name, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!AA55Client, name.move, flags);
    }

    // Properties

    ref const(String) remote() const pure
        => _host;
    void remote(InetAddress value)
    {
        _host = null;
        if (value == _remote)
            return;
        _remote = value;

        restart();
    }
    const(char)[] remote(String value)
    {
        if (value.empty)
            return "remote cannot be empty";
        if (value == _host)
            return null;

        _host = value.move;
        _remote = InetAddress();

        restart();
        return null;
    }

    ref const(String) profile() const pure
        => _profile;
    void profile(String value)
    {
        _host = null;
        if (value == _profile)
            return;
        _profile = value.move;

        restart();
    }

    ref const(String) model() const pure
        => _model;
    void model(String value)
    {
        _host = null;
        if (value == _model)
            return;
        _model = value.move;

        restart();
    }

    // API

    bool read_in_flight(GoodWeFunctionCode function_code)
    {
        foreach (ref req; _pending_requests)
        {
            if (req.control_code == GoodWeControlCode.read && req.function_code == function_code)
                return true;
        }
        return false;
    }

    bool match_server(ref const InetAddress sender) const pure
        => _remote._a.ipv4.addr == sender._a.ipv4.addr;

    bool send_request(GoodWeControlCode control_code, GoodWeFunctionCode function_code, const(ubyte)[] data, AA55Response callback, void* user_data = null)
    {
        if (!_active)
            return false;
        if (control_code == GoodWeControlCode.read && read_in_flight(function_code))
        {
            // TODO: if callback or user_data is different, push it on the list
            return true;
        }

        AA55Request req;
        req.source_addr = _source_addr;
        req.dest_addr = 0x7F;
        req.control_code = control_code;
        req.function_code = function_code;
        req.callback = callback;
        req.user_data = user_data;

        return send_request_internal(req, data);
    }

    override bool validate() const pure
        => !_host.empty || (_remote != InetAddress() && _remote.family == AddressFamily.ipv4);

    override CompletionStatus startup()
    {
        if (_remote._a.ipv4.port == 0)
        {
            // TODO: 48899 is also in use in some models; we should probably try both?

            if (_remote == InetAddress())
            {
                assert(_host, "valide shouldn't have succeeded if host is null");

                const(char)[] host = _host[];
                ushort port = 0;

                size_t colon = host.findFirst(":");
                if (colon != host.length)
                {
                    size_t taken;
                    long i = host[colon + 1 .. $].parse_int(&taken);
                    if (i > ushort.max || taken != host.length - colon - 1)
                        return CompletionStatus.error;
                    port = cast(ushort)i;
                    host = host[0 .. colon];
                }

                if (port == 0)
                    port = 8899;

                AddressInfo addrInfo;
                addrInfo.family = AddressFamily.ipv4;
                AddressInfoResolver results;
                get_address_info(host, null, &addrInfo, results);
                if (!results.next_address(addrInfo))
                    return CompletionStatus.continue_;

                _remote = InetAddress(addrInfo.address._a.ipv4.addr, port);
            }
            else
                _remote._a.ipv4.port = 8899;
        }

        // Check if we're active (received a response)
        if (_active)
            return CompletionStatus.complete;

        MonoTime now = getTime();

        if (!_handshake_in_progress)
        {
            _handshake_in_progress = true;
            _last_activity = now;

            version (NegotiateAddress)
            {
                AA55Request req;
                req.source_addr = _source_addr;
                req.dest_addr = 0x7F;
                req.control_code = GoodWeControlCode.register;
                req.function_code = GoodWeFunctionCode.offline_query;
                req.callback = &offline_response;
                send_request_internal(req, null);
            }
            else
            {
                AA55Request req;
                req.source_addr = _source_addr;
                req.dest_addr = 0x7F;
                req.control_code = GoodWeControlCode.read;
                req.function_code = GoodWeFunctionCode.id_info;
                req.callback = &id_response;
                send_request_internal(req, null);
            }

            version (DebugAA55)
            {
                if (_host)
                    writeInfo("aa55: '", name, "' begin handshake with ", _host[]);
                else
                    writeInfo("aa55: '", name, "' begin handshake with ", _remote);
            }
        }

        if (now - _last_activity >= 10.seconds)
        {
            version (DebugAA55)
                writeWarning("aa55: '", name, "' handshake timeout");
            return CompletionStatus.error;
        }
        return CompletionStatus.continue_;
    }

    override CompletionStatus shutdown()
    {
        SysTime now = getSysTime();
        foreach (ref req; _pending_requests)
            req.callback(false, req, now, null, req.user_data);
        _pending_requests.clear();

        _last_activity = MonoTime();
        _inverter_addr = 0x7F;
        _handshake_in_progress = false;
        _active = false;

        return CompletionStatus.complete;
    }

    override void update()
    {
        // Check watchdog
        if (getTime() - _last_activity >= 10.seconds)
        {
            version (DebugAA55)
                writeWarning("aa55: '", name, "' timeout, restarting...");
            restart();
            return;
        }

        // Timeout requests...
        SysTime now = getSysTime();
        for (size_t i = 0; i < _pending_requests.length; )
        {
            ref req = _pending_requests[i];

            if (now - req.request_time >= 1500.msecs)
            {
                version (DebugAA55)
                    writeWarning("aa55: '", name, "' request timeout after ", (now - req.request_time).as!"msecs", "ms");

                req.callback(false, req, now, null, req.user_data);
                _pending_requests.remove(i);
            }
            else
                ++i;
        }
    }

package:
    void incoming_message(const(ubyte)[] data, SysTime now)
    {
        _last_activity = getTime();

        if (data.length < 9 || data[0] != 0xAA || data[1] != 0x55)
        {
            version (DebugAA55)
                writeInfo("aa55: '", name, "' received invalid message: ", cast(void[])data);
            return;
        }

        GoodWeControlCode control_code = cast(GoodWeControlCode)data[4];
        if (control_code == GoodWeControlCode.execute)
        {
            version (DebugAA55)
                writeInfo("aa55: '", name, "' received execute response ", cast(void[])data, " - ignoring ");
            return;
        }
        else if (control_code >= 2)
        {
            version (DebugAA55)
                writeInfo("aa55: '", name, "' received unknown control code ", cast(ubyte)control_code, ": ", cast(void[])data, " - ignoring");
            return;
        }

        // validate the message (UDP should already validate this no?)
        ubyte data_len = data[6];
        const expect_len = 7 + data_len + 2;
        if (data.length != expect_len)
        {
            if (data.length > expect_len)
                data = data[0 .. expect_len]; // we'll trim the tail, and see if the checksum checks out...
            else
            {
                version (DebugAA55)
                    writeInfo("aa55: '", name, "' received truncated message - expect ", expect_len, " got ", data.length);
                return;
            }
        }

        ushort sum = 0;
        foreach (i; 0 .. 7 + data_len)
            sum += data[i];
        if (data[7 + data_len] != cast(ubyte)(sum >> 8) ||
            data[8 + data_len] != cast(ubyte)(sum & 0xFF))
        {
            version (DebugAA55)
                writeInfo("aa55: '", name, "' received message with invalid checksum");
            return;
        }

        // parse the message...
        ubyte source_addr = data[2];
        ubyte dest_addr = data[3];
        GoodWeFunctionCode function_code = cast(GoodWeFunctionCode)data[5];
        const(ubyte)[] payload = data[7 .. 7 + data_len];

        if (source_addr != _inverter_addr)
            return; // not for us!

        // confirm it's a response
        if ((function_code & 0x80) == 0)
        {
            version (DebugAA55)
                writeInfo("aa55: '", name, "' received message is not a response");
            return;
        }
        else
            function_code ^= 0x80; // clear the response bit for simplicity

        // dispatch to the user
        foreach (i; 0 .. _pending_requests.length)
        {
            ref req = _pending_requests[i];

            if (dest_addr != req.source_addr ||
                control_code != req.control_code ||
                function_code != req.function_code)
                continue;

            Duration elapsed = now - req.request_time;
            version (DebugAA55)
                writeInfo("aa55: '", name, "' received response after ", elapsed.as!"msecs", "ms");

            AA55Request t = _pending_requests[i];
            _pending_requests.remove(i);

            // TODO: there should be a list of callback/userdata's...
            req.callback(true, t, now, payload, req.user_data);
            return;
        }

        version (DebugAA55)
            writeDebug("aa55: '", name, "' received unsolicited message: control=", control_code, " function=", function_code, " len=", data_len);
    }


private:
    String _host;
    String _profile;
    String _model;
    InetAddress _remote;

    bool _handshake_in_progress;
    bool _active;
    ubyte _source_addr = 0xC0;
    ubyte _inverter_addr = 0x7F;

    MonoTime _last_activity;

    Array!AA55Request _pending_requests;

    // device details
    String firmware_version;
    String model_name;
    String serial_number;
    String software_version;
    ubyte dsp1_version;
    ubyte dsp2_version;
    ubyte arm_version;
    uint nom_vpv; // 0.1V Nominal PV voltage
//    ubyte safety_country_code; // not interesting?

    bool send_request_internal(ref AA55Request req, const(ubyte)[] data)
    {
        assert(data.length <= ubyte.max, "data length exceeds maximum");

        Socket socket = get_module!GoodWeModule.aa55_socket;
        if (!socket)
        {
            // TODO: if a re-start process for the socket is not in progress, we should stimulate one...
            version (DebugAA55)
                writeError("aa55: '", name, "' no socket available");
            return false;
        }

        ubyte[260] buffer = void;
        buffer[0] = 0xAA;
        buffer[1] = 0x55;
        buffer[2] = req.source_addr;
        buffer[3] = req.dest_addr;
        buffer[4] = req.control_code;
        buffer[5] = req.function_code;
        buffer[6] = cast(ubyte)data.length;

        if (data.length > 0)
            buffer[7 .. 7 + data.length] = data[];

        ushort sum = 0;
        foreach (i; 0 .. 7 + data.length)
            sum += buffer[i];
        buffer[7 + data.length] = cast(ubyte)(sum >> 8);
        buffer[8 + data.length] = cast(ubyte)(sum & 0xFF);

        size_t sent;
        Result r = socket.sendto(buffer[0 .. 9 + data.length], MsgFlags.none, &_remote, &sent);
        if (!r)
            return false;

        req.request_time = getSysTime();
        _pending_requests ~= req;

        version (DebugAA55)
            writeDebug("aa55: '", name, "' sent request: control=", req.control_code, " function=", req.function_code, " len=", data.length);

        return true;
    }

    void offline_response(bool success, ref const AA55Request request, SysTime response_time, const(ubyte)[] response, void* user_data)
    {
        if (!success)
            return;

        // validate response length

        ubyte[17] buffer = void;
        buffer[0..16] = response[];
        buffer[16] = 0x0D;

        AA55Request req;
        req.source_addr = 0xC0;
        req.dest_addr = 0x7F;
        req.control_code = GoodWeControlCode.register;
        req.function_code = GoodWeFunctionCode.allocate_register_address;
        req.callback = &reg_response;
        send_request_internal(req, buffer);

        _inverter_addr = 0x0D;
    }

    void reg_response(bool success, ref const AA55Request request, SysTime response_time, const(ubyte)[] response, void* user_data)
    {
        if (!success)
            return;

        AA55Request req;
        req.source_addr = 0xC0;
        req.dest_addr = 0x7F;
        req.control_code = GoodWeControlCode.read;
        req.function_code = GoodWeFunctionCode.id_info;
        req.callback = &id_response;
        send_request_internal(req, null);
    }

    void id_response(bool success, ref const AA55Request request, SysTime response_time, const(ubyte)[] response, void* user_data)
    {
        if (!success)
            return;

        ref IDInfo info = *cast(IDInfo*)response.ptr;
        _active = true;

        firmware_version = info.firmware_version.strlen_trim.makeString(defaultAllocator());
        model_name = info.model_name.strlen_trim.makeString(defaultAllocator());
        serial_number = info.serial_number.strlen_trim.makeString(defaultAllocator());
        software_version = info.software_version.strlen_trim.makeString(defaultAllocator());

        size_t taken;
        nom_vpv = cast(uint)info.nom_vpv[].parse_uint(&taken);
        if (taken != 4)
            nom_vpv = 0;

        if (firmware_version.length >= 2)
            dsp1_version = cast(ubyte)firmware_version[0..2].parse_int();
        if (firmware_version.length >= 4)
            dsp2_version = cast(ubyte)firmware_version[2..4].parse_int();
        if (firmware_version.length >= 5)
            arm_version = cast(ubyte)firmware_version[4..5].parse_int(null, 36);
    }
}


private:

inout(char)[] strlen_trim(inout(char)[] str)
    => str[0..str.strlen_s].trimBack;
