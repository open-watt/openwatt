module router.modbus.profile.goodwe_smart_meter;

import router.modbus.profile;

enum ModbusRegInfo[] goodWeSmartMeterRegs = [
	// Device Information Data Registers
	ModbusRegInfo(40000, RecordType.uint16, ""), // 
];
