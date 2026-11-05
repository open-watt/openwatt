module protocol.goodwe.aa55;

import urt.array;
import urt.conv;
import urt.endian;
import urt.inet;
import urt.lifetime;
import urt.log;
import urt.mem;
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

import protocol.goodwe : GoodWeModule;
import protocol.goodwe.message;

import router.stream;

//version = DebugAA55;

nothrow @nogc:


enum GoodWeControlCode : ubyte
{
    register = 0x00,
    read = 0x01,
    write = 0x02,
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
    adjust_real_power = 0x1E,
    reset_inverter = 0x1D,
    clock = 0x02,
    read_registers = 0x1A,
    write_registers = 0x39,
    power_factor = 0x1F,
    export_limit = 0x26,
    backup_supply = 0x27,
    shadow_scan = 0x28,
    battery_activation = 0x37,
    export_power_limit = 0x35,
    ems_dispatch = 0x3A,
    soc_protection = 0x3B,
    battery_capacity = 0x50,
    battery_charge = 0x51,
    battery_discharge = 0x52
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
