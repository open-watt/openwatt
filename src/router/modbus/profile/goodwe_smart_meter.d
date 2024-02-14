module router.modbus.profile.goodwe_smart_meter;

import router.modbus.profile;

enum ModbusRegInfo[] goodWeSmartMeterRegs = [
	// Device Information Data Registers
	ModbusRegInfo(40306, "u16", "voltage", "0.1V", "V"),
	ModbusRegInfo(40307, "u16", "reg307"), // 71 - 74
	ModbusRegInfo(40308, "u16", "reg308"), // 0
	ModbusRegInfo(40309, "u16", "reg309"), // 0
	ModbusRegInfo(40310, "u16", "current", "10mA", "A"), // ~1000  +/- 400  (AMPS?)
	ModbusRegInfo(40311, "u16", "reg311"), // 0
	ModbusRegInfo(40312, "u16", "reg312"), // mostly 7 (rarely 8)
	ModbusRegInfo(40313, "u16", "reg313"), // 0
	ModbusRegInfo(40314, "u16", "reg314"), // 0
	ModbusRegInfo(40315, "i32", "power1_1"), // XX -9
	ModbusRegInfo(40317, "u16", "reg317"), // 0
	ModbusRegInfo(40318, "u16", "reg318"), // 0
	ModbusRegInfo(40319, "u16", "reg319"), // 0
	ModbusRegInfo(40320, "u16", "reg320"), // 0
	ModbusRegInfo(40321, "i32", "power1_2"), // XX -10
	ModbusRegInfo(40323, "i32", "reactive1_1"), // YY -2229
	ModbusRegInfo(40325, "u16", "reg325"), // 0
	ModbusRegInfo(40326, "u16", "reg326"), // 0
	ModbusRegInfo(40327, "u16", "reg327"), // 0
	ModbusRegInfo(40328, "u16", "reg328"), // 0
	ModbusRegInfo(40329, "i32", "reactive1_2"), // YY -2230 + 1
	ModbusRegInfo(40331, "u16", "reg331"), // 0
	ModbusRegInfo(40332, "u16", "apparent1_1", "W", "W"), // ZZ 2278   (WATTS) POWER APPARENT
	ModbusRegInfo(40333, "u16", "reg333"), // 0
	ModbusRegInfo(40334, "u16", "reg334"), // 0
	ModbusRegInfo(40335, "u16", "reg335"), // 0
	ModbusRegInfo(40336, "u16", "reg336"), // 0
	ModbusRegInfo(40337, "u16", "reg337"), // 0
	ModbusRegInfo(40338, "u16", "apparent1_2", "W", "W"), // ZZ 2279 + 1  (WATTS) POWER APPARENT
	ModbusRegInfo(40339, "i16", "pf1_1", "0.001", "1"), // WW 5
	ModbusRegInfo(40340, "i16", "reg340"), // 0 or -250 or -334
	ModbusRegInfo(40341, "u16", "reg341"), // 999
	ModbusRegInfo(40342, "i16", "pf1_2", "0.001", "1"), // WW 5
	ModbusRegInfo(40343, "u16", "freq", "0.01Hz", "Hz"), // 
];
