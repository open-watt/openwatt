module router.modbus.profile.goodwe_ems;

import router.modbus.profile;

enum ModbusRegInfo[] goodWeEmsRegs = [
	// Device Information Data Registers
	ModbusRegInfo(45000, "u16", ""), // Modbus protocol version RO U16 N/A 1 1
	ModbusRegInfo(45001, "u16", ""), // Rated power RO U16 N/A 1 1
	ModbusRegInfo(45002, "u16", ""), // AC output type RO U16 N/A 1 1 0: single phase 1: three phase four wire system 2: three phase three wire system
	ModbusRegInfo(45003, "u16", ""), // Serial number RO STR N/A 1 8 ASCII，16 bytes
	ModbusRegInfo(45011, "u16", ""), // Device type RO STR N/A 1 5 ASCII，10 bytes
	ModbusRegInfo(45016, "u16", ""), // DSP1 software version RO U16 N/A 1 1
	ModbusRegInfo(45017, "u16", ""), // DSP2 software version RO U16 N/A 1 1
	ModbusRegInfo(45018, "u16", ""), // DSP SVN version RO U16 N/A 1 1
	ModbusRegInfo(45019, "u16", ""), // ARM software version RO U16 N/A 1 1
	ModbusRegInfo(45020, "u16", ""), // ARM SVN version RO U16 N/A 1 1
	ModbusRegInfo(45021, "u16", ""), // DSP Internal Firmware Ver. RO STR N/A 1 6 Example ‘04004-13-S01’
	ModbusRegInfo(45027, "u16", ""), // ARM Internal Firmware Ver. RO STR N/A 1 6 Example ‘02034-04-S01’
	ModbusRegInfo(45050, "u16", ""), // SIMCCID 10RO STR N/A 1 10 For GPRS module

	// Running Data Registers
	ModbusRegInfo(45100, "u16", ""), // RTC RO U16 N/A 1 1 Hbyte-year/Lbyte-month: 13-99/1-12
	ModbusRegInfo(45101, "u16", ""), // RO U16 N/A 1 1 Hbyte-day/Lbyte-hour: 1-31/0-23
	ModbusRegInfo(45102, "u16", ""), // RO U16 N/A 1 1 Hbyte-minute/Lbyte-second: 0-59/0-59
	ModbusRegInfo(45103, "u16", ""), // Vpv1 RO U16 V 10 1 PV1 voltage
	ModbusRegInfo(45104, "u16", ""), // Ipv1 RO U16 A 10 1 PV1 current
	ModbusRegInfo(45105, "u16", ""), // Ppv1 RO U32 W 10 2 PV1 Power
	ModbusRegInfo(45107, "u16", ""), // Vpv2 RO U16 V 10 1 PV2 voltage
	ModbusRegInfo(45108, "u16", ""), // Ipv2 RO U16 A 10 1 PV2 current
	ModbusRegInfo(45109, "u16", ""), // Ppv2 RO U32 W 10 2 PV2 Power
	ModbusRegInfo(45111, "u16", ""), // Vpv3 RO U16 V 10 1 PV3 voltage
	ModbusRegInfo(45112, "u16", ""), // Ipv3 RO U16 A 10 1 PV3 current
	ModbusRegInfo(45113, "u16", ""), // Ppv3 RO U32 W 10 2 PV3 Power
	ModbusRegInfo(45115, "u16", ""), // Vpv4 RO U16 V 10 1 PV4 voltage
	ModbusRegInfo(45116, "u16", ""), // Ipv4 RO U16 A 10 1 PV4 current
	ModbusRegInfo(45117, "u16", ""), // Ppv4 RO U32 W 10 2 PV4 Power
	ModbusRegInfo(45119, "u16", ""), // PV Mode RO U32 N/A 2 PV Module work mode, Table 8-3 8-4
	ModbusRegInfo(45121, "u16", ""), // Vgrid_R RO U16 V 10 1 R phase Grid voltage
	ModbusRegInfo(45122, "u16", ""), // Igrid_R RO U16 A 10 1 R phase Grid current
	ModbusRegInfo(45123, "u16", ""), // Fgrid_R RO U16 Hz 100 1 R phase Grid Frequency
	ModbusRegInfo(45124, "u16", ""), // Reversed 1 Reversed
	ModbusRegInfo(45125, "u16", ""), // Pgrid_R RO S16 W 1 1 R phase Grid Power
	ModbusRegInfo(45126, "u16", ""), // Vgrid_S RO U16 V 10 1 S phase Grid voltage
	ModbusRegInfo(45127, "u16", ""), // Igrid_S RO U16 A 10 1 S phase Grid current
	ModbusRegInfo(45128, "u16", ""), // Fgrid_S RO U16 Hz 100 1 S phase Grid Frequency
	ModbusRegInfo(45129, "u16", ""), // Reversed 1 Reversed
	ModbusRegInfo(45130, "u16", ""), // Pgrid_S RO S16 W 1 1 S phase Grid Power
	ModbusRegInfo(45131, "u16", ""), // Vgrid_T RO U16 V 10 1 T phase Grid voltage
	ModbusRegInfo(45132, "u16", ""), // Igrid_T RO U16 A 10 1 T phase Grid current
	ModbusRegInfo(45133, "u16", ""), // Fgrid_T RO U16 Hz 100 1 T phase Grid Frequency
	ModbusRegInfo(45134, "u16", ""), // Reversed Reversed
	ModbusRegInfo(45135, "u16", ""), // Pgrid_T RO S16 W 1 1 T phase Grid Power
	ModbusRegInfo(45136, "u16", ""), // Grid Mode RO U16 1 Grid mode, refer to Table 8-10
	ModbusRegInfo(45137, "u16", ""), // Reversed 1 Reversed
	ModbusRegInfo(45138, "u16", ""), // Total INV Power RO S16 W 1 1 Total Power of Inverter
	ModbusRegInfo(45139, "u16", ""), // Reversed 1 Reversed
	ModbusRegInfo(45140, "u16", ""), // AC ActivePower RO S16 W 1 1
	ModbusRegInfo(45141, "u16", ""), // Reversed 1 Reversed
	ModbusRegInfo(45142, "u16", ""), // AC ReactivePower RO S16 Var 1 1
	ModbusRegInfo(45143, "u16", ""), // Reversed 1 Reversed
	ModbusRegInfo(45144, "u16", ""), // AC ApparentPower RO S16 VA 1 1
	ModbusRegInfo(45145, "u16", ""), // Back-Up Vload_R RO U16 V 10 1 R phase Load voltage of Back-Up
	ModbusRegInfo(45146, "u16", ""), // Back-Up Iload_R RO U16 A 10 1 R phase Load current of Back-Up
	ModbusRegInfo(45147, "u16", ""), // Back-Up Fload_R RO U16 Hz 100 1 R phase Load Frequency of Back-Up
	ModbusRegInfo(45148, "u16", ""), // Load Mode_R RO U16 1 Load work mode, refer to Table 8-11
	ModbusRegInfo(45149, "u16", ""), // Reversed 1 Reversed
	ModbusRegInfo(45150, "u16", ""), // Back-Up Pload_R RO S16 W 1 1 R phase Load Power of Back-Up
	ModbusRegInfo(45151, "u16", ""), // Back-Up Vload_S RO U16 V 10 1 S phase Load voltage of Back-Up
	ModbusRegInfo(45152, "u16", ""), // Back-Up Iload_S RO U16 A 10 1 S phase Load current of Back-Up
	ModbusRegInfo(45153, "u16", ""), // Back-Up Fload_S RO U16 Hz 100 1 S phase Load Frequency of Back-Up
	ModbusRegInfo(45154, "u16", ""), // Load Mode_S RO U16 1 Load work mode, refer to Table 8-11
	ModbusRegInfo(45155, "u16", ""), // Reversed 1 Reversed
	ModbusRegInfo(45156, "u16", ""), // Back-Up Pload_S RO S16 W 1 1 S phase Load Power of Back-Up
	ModbusRegInfo(45157, "u16", ""), // Back-Up Vload_T RO U16 V 10 1 T phase Load voltage of Back-Up
	ModbusRegInfo(45158, "u16", ""), // Back-Up Iload_T RO U16 A 10 1 T phase Load current of Back-Up
	ModbusRegInfo(45159, "u16", ""), // Back-Up Fload_T RO U16 Hz 100 1 T phase Load Frequency of Back-Up
	ModbusRegInfo(45160, "u16", ""), // Load Mode_T RO U16 1 Load work mode, refer to Table 8-11
	ModbusRegInfo(45161, "u16", ""), // Reversed 1 Reversed
	ModbusRegInfo(45162, "u16", ""), // Back-Up Pload_T RO S16 W 1 1 T phase Load Power
	ModbusRegInfo(45163, "u16", ""), // Reversed 1 Reversed
	ModbusRegInfo(45164, "u16", ""), // PLoad_R RO S16 W 1 1 R phase Load Power
	ModbusRegInfo(45165, "u16", ""), // Reversed 1 Reversed
	ModbusRegInfo(45166, "u16", ""), // Pload_S RO S16 W 1 1 S phase Load Power
	ModbusRegInfo(45167, "u16", ""), // Reversed 1 Reversed
	ModbusRegInfo(45168, "u16", ""), // Pload_T RO S16 W 1 1 T phase Load Power
	ModbusRegInfo(45169, "u16", ""), // Reversed 1 Reversed
	ModbusRegInfo(45170, "u16", ""), // Total Back-Up Load RO S16 W 1 1 Load Power of Back-Up
	ModbusRegInfo(45171, "u16", ""), // Reversed 1 Reversed
	ModbusRegInfo(45172, "u16", ""), // Total Load Power RO S16 W 1 1 Total Power of load
	ModbusRegInfo(45173, "u16", ""), // Ups Load Percent RO U16 % 100 1
	ModbusRegInfo(45174, "u16", ""), // Air temperature RO S16 C 10 1 Inverter internal temperature
	ModbusRegInfo(45175, "u16", ""), // Module temperature RO S16 C 10 1
	ModbusRegInfo(45176, "u16", ""), // Radiator temperature RO S16 C 10 1
	ModbusRegInfo(45177, "u16", ""), // FunctionBitValue RO U16 1
	ModbusRegInfo(45178, "u16", ""), // BUSVoltage RO U16 V 10 1 BUS Voltage
	ModbusRegInfo(45179, "u16", ""), // NBUSVoltage RO U16 V 10 1 NBUS Voltage
	ModbusRegInfo(45180, "u16", ""), // Vbattery1 RO U16 V 10 1 First group battery voltage
	ModbusRegInfo(45181, "u16", ""), // Ibattery1 RO S16 V 10 1 First group battery current
	ModbusRegInfo(45182, "u16", ""), // Reversed 1 Reversed
	ModbusRegInfo(45183, "u16", ""), // Pbattery1 RO S16 W 1 1 First group battery power
	ModbusRegInfo(45184, "u16", ""), // Battery1 Mode RO U16 1 1st group battery work mode, Table 8-9
	ModbusRegInfo(45185, "u16", ""), // Warning code RO U16 1
	ModbusRegInfo(45186, "u16", ""), // SafetyCountry RO U16 1
	ModbusRegInfo(45187, "u16", ""), // Work Mode RO U16 1 refer to Table 8-1
	ModbusRegInfo(45188, "u16", ""), // Operation Mode RO U16 1 Storage Inverter work mode, Table 8-12
	ModbusRegInfo(45189, "u16", ""), // Error Message RO U32 2 Failure status description, Table 8-2
	ModbusRegInfo(45191, "u16", ""), // PV E-Total RO U32 1KW.Hr 10 2 Total PV Energy
	ModbusRegInfo(45193, "u16", ""), // PV E-Day RO U32 1KW.Hr 10 2 PV Energy in today
	ModbusRegInfo(45195, "u16", ""), // E-Total RO U32 1KW.Hr 10 2 Total Feed Energy to grid
	ModbusRegInfo(45197, "u16", ""), // h-Total RO U32 H 1 2 Total feeding hours
	ModbusRegInfo(45199, "u16", ""), // E-Day-Sell RO U16 1KW.Hr 10 1 Feed Energy to grid in today
	ModbusRegInfo(45200, "u16", ""), // E-Total-Buy RO U32 1KW.Hr 10 2
	ModbusRegInfo(45202, "u16", ""), // E-Day-Buy RO U16 1KW.Hr 10 1
	ModbusRegInfo(45203, "u16", ""), // E-Total-Load RO U32 1KW.Hr 10 2 Total Energy of Load
	ModbusRegInfo(45205, "u16", ""), // E-Load-Day RO U16 1KW.Hr 10 1 Energy of load in day
	ModbusRegInfo(45206, "u16", ""), // E-BatteryCharge RO U32 1KW.Hr 10 2 Charge energy
	ModbusRegInfo(45208, "u16", ""), // E-Charge-Day RO U16 1KW.Hr 10 1 Energy of charge in day
	ModbusRegInfo(45209, "u16", ""), // E-BatteryDischarge RO U32 1KW.Hr 10 2 Discharge energy
	ModbusRegInfo(45211, "u16", ""), // E-discharge-Day RO U16 1KW.Hr 10 1 Energy of discharge in day
	ModbusRegInfo(45212, "u16", ""), // BattStrings RO U16 Pcs 1 1
	ModbusRegInfo(45213, "u16", ""), // CPLD warning code RO U16 1
	ModbusRegInfo(45214, "u16", ""), // wChargerCtrlFlg RO U16 2
	ModbusRegInfo(45215, "u16", ""), // Derate Flag RO U16 1 Safety power curve flag
	ModbusRegInfo(45216, "u16", ""), // Derate frozen power RO S32 W 2 Safety curve power
	ModbusRegInfo(45218, "u16", ""), // DiagStatusH RO U32 2
	ModbusRegInfo(45220, "u16", ""), // DiagStatusL RO U32 2

	// External Communication Data (ARM)
	ModbusRegInfo(46000, "u16", ""), // commode RO U16 1
	ModbusRegInfo(46001, "u16", ""), // RSSI RO U16 1
	ModbusRegInfo(46002, "u16", ""), // ManufacturerCode RO U16 1 EMS protocol code
	ModbusRegInfo(46003, "u16", ""), // bMeterConnectStatus RO U16 1 1: connect correctly，2: connect reverse，3: connect incorrectly，0: not checked
	ModbusRegInfo(46004, "u16", ""), // Meter communicate Status RO U16 1 1: OK, 0: NG
	ModbusRegInfo(46005, "u16", ""), // MTActivepowerR RO S16 W 1 1 Pmeter R
	ModbusRegInfo(46006, "u16", ""), // MTActivepowerS RO S16 W 1 1 Pmeter S
	ModbusRegInfo(46007, "u16", ""), // MTActivepowerT RO S16 W 1 1 Pmeter T
	ModbusRegInfo(46008, "u16", ""), // MTTotalActivepower RO S16 W 1 1 Pmeter
	ModbusRegInfo(46009, "u16", ""), // MTTotalReactivepower RO U16 W 1 1
	ModbusRegInfo(46010, "u16", ""), // MeterPF_R RO U16 100 1 Meter power factor R
	ModbusRegInfo(46011, "u16", ""), // MeterPF_S RO U16 100 1 Meter power factor S
	ModbusRegInfo(46012, "u16", ""), // MeterPF_T RO U16 100 1 Meter power factor T
	ModbusRegInfo(46013, "u16", ""), // MeterPowerFactor RO U16 100 1 Meter power factor
	ModbusRegInfo(46014, "u16", ""), // MeterFrequence RO U16 100 1
	ModbusRegInfo(46015, "u16", ""), // E-Total-Sell RO float 1Kwh 10 2
	ModbusRegInfo(46017, "u16", ""), // E-Total-Buy RO float 1Kwh 10 2
	ModbusRegInfo(46019, "u16", ""), // MTActivepowerR RO S32 W 1 2 Pmeter R
	ModbusRegInfo(46021, "u16", ""), // MTActivepowerS RO S32 W 1 2 Pmeter S
	ModbusRegInfo(46023, "u16", ""), // MTActivepowerT RO S32 W 1 2 Pmeter T
	ModbusRegInfo(46025, "u16", ""), // MTTotalActivepower RO S32 W 1 2 Pmeter
	ModbusRegInfo(46027, "u16", ""), // MTReactivepowerR RO S32 W 1 2 Phase R reactive power
	ModbusRegInfo(46029, "u16", ""), // MTReactivepowerS RO S32 W 1 2 Phase S reactive power
	ModbusRegInfo(46031, "u16", ""), // MTReactivepowerT RO S32 W 1 2 Phase T reactive power
	ModbusRegInfo(46033, "u16", ""), // MTTotalReactivepower RO S32 W 1 2 Total reactive power
	ModbusRegInfo(46035, "u16", ""), // MTApparentpowerR RO S32 W 1 2 Phase R apparent power
	ModbusRegInfo(46037, "u16", ""), // MTApparentpowerR RO S32 W 1 2 Phase S apparent power
	ModbusRegInfo(46039, "u16", ""), // MTApparentpowerR RO S32 W 1 2 Phase T apparent power
	ModbusRegInfo(46041, "u16", ""), // MTTotalApparentpower RO S32 W 1 2 Total apparent power
	ModbusRegInfo(46043, "u16", ""), // Meter Type RO U16 NA 1 1
	ModbusRegInfo(46044, "u16", ""), // Meter software version RO U16 NA 1 1

	// Flash Information
	ModbusRegInfo(46900, "u16", ""), // FlashPgmParaVer RO U16 NA 1 1
	ModbusRegInfo(46901, "u16", ""), // FlashPgmWriteCount RO U32 NA 1 2
	ModbusRegInfo(46903, "u16", ""), // FlashSysParaVer RO U16 NA 1 1
	ModbusRegInfo(46904, "u16", ""), // FlashSysWriteCount RO U32 NA 1 2
	ModbusRegInfo(46906, "u16", ""), // FlashBatParaVer RO U16 NA 1 1
	ModbusRegInfo(46907, "u16", ""), // FlashBatWriteCount RO U32 NA 1 2
	ModbusRegInfo(46909, "u16", ""), // FlashEepromVer RO U16 NA 1 1
	ModbusRegInfo(46910, "u16", ""), // FlashEepromWriteCount RO U32 NA 1 2
	ModbusRegInfo(46912, "u16", ""), // WiFiDataSendCount RO U16 NA 1 1
	ModbusRegInfo(46913, "u16", ""), // WifiUpDataDebug RO U16 NA 1 1

	// BMS Information
	ModbusRegInfo(47000, "u16", ""), // DRMStatus RO U16 1 Refer Table 8-15
	ModbusRegInfo(47001, "u16", ""), // BattTypeIndex RO U16 1 1 Battery manufactor index setting
	ModbusRegInfo(47002, "u16", ""), // BMS Status RO U16 1 BMS Work Status
	ModbusRegInfo(47003, "u16", ""), // BMS Pack Temperature RO U16 10 1
	ModbusRegInfo(47004, "u16", ""), // BMS Charge Imax RO U16 1 1
	ModbusRegInfo(47005, "u16", ""), // BMS Discharge Imax RO U16 1 1
	ModbusRegInfo(47006, "u16", ""), // BMS Error Code L RO U16 1 Bit 0~15 refer to Table 8-7
	ModbusRegInfo(47007, "u16", ""), // SOC RO U16 % 1 1 First group battery capacity
	ModbusRegInfo(47008, "u16", ""), // BMS SOH RO U16 % 1 1
	ModbusRegInfo(47009, "u16", ""), // BMS Battery strings RO U16 Pcs 1 1
	ModbusRegInfo(47010, "u16", ""), // BMS Warning Code L RO U16 1 Bit 0~15 refer to Table 8-8
	ModbusRegInfo(47011, "u16", ""), // Battery protocol RO U16 1
	ModbusRegInfo(47012, "u16", ""), // BMS Error Code H RO U16 NA NA 1 Bit 16~31 refer to Table 8-7
	ModbusRegInfo(47013, "u16", ""), // BMS Warning Code H RO U16 NA NA 1 Bit 16~31 refer to Table 8-8
	ModbusRegInfo(47014, "u16", ""), // BMS Software Version RO U16 NA 1 1
	ModbusRegInfo(47015, "u16", ""), // Battery Hardware Version RO U16 NA 1 1
	ModbusRegInfo(47016, "u16", ""), // Maximum cell temperature ID RO U16 NA 1 1
	ModbusRegInfo(47017, "u16", ""), // Minimum cell temperature ID RO U16 NA 1 1
	ModbusRegInfo(47018, "u16", ""), // Maximum cell voltage ID RO U16 NA 1 1
	ModbusRegInfo(47019, "u16", ""), // Minimum cell voltage ID RO U16 NA 1 1
	ModbusRegInfo(47020, "u16", ""), // Maximum cell temperature RO U16 ℃ 10 1
	ModbusRegInfo(47021, "u16", ""), // Minimum cell temperature RO U16 ℃ 10 1
	ModbusRegInfo(47022, "u16", ""), // Maximum cell voltage RO U16 mV 1 1
	ModbusRegInfo(47023, "u16", ""), // Minimum cell voltage RO U16 mV 1 1
	ModbusRegInfo(47024, "u16", ""), // Pass Infomation1 RO U16 NA NA 1
	ModbusRegInfo(47025, "u16", ""), // Pass Infomation2 RO U16 NA NA 1
	ModbusRegInfo(47026, "u16", ""), // Pass Infomation3 RO U16 NA NA 1
	ModbusRegInfo(47027, "u16", ""), // Pass Infomation4 RO U16 NA NA 1
	ModbusRegInfo(47028, "u16", ""), // Pass Infomation5 RO U16 NA NA 1
	ModbusRegInfo(47029, "u16", ""), // Pass Infomation6 RO U16 NA NA 1
	ModbusRegInfo(47030, "u16", ""), // Pass Infomation7 RO U16 NA NA 1
	ModbusRegInfo(47031, "u16", ""), // Pass Infomation8 RO U16 NA NA 1
	ModbusRegInfo(47032, "u16", ""), // Pass Infomation9 RO U16 NA NA 1
	ModbusRegInfo(47033, "u16", ""), // Pass Infomation10 RO U16 NA NA 1
	ModbusRegInfo(47034, "u16", ""), // Pass Infomation11 RO U16 NA NA 1
	ModbusRegInfo(47035, "u16", ""), // Pass Infomation12 RO U16 NA NA 1
	ModbusRegInfo(47036, "u16", ""), // Pass Infomation13 RO U16 NA NA 1
	ModbusRegInfo(47037, "u16", ""), // Pass Infomation14 RO U16 NA NA 1
	ModbusRegInfo(47038, "u16", ""), // Pass Infomation15 RO U16 NA NA 1
	ModbusRegInfo(47039, "u16", ""), // Pass Infomation16 RO U16 NA NA 1
	ModbusRegInfo(47040, "u16", ""), // Pass Infomation17 RO U16 NA NA 1
	ModbusRegInfo(47041, "u16", ""), // Pass Infomation18 RO U16 NA NA 1
	ModbusRegInfo(47042, "u16", ""), // Pass Infomation19 RO U16 NA NA 1
	ModbusRegInfo(47043, "u16", ""), // Pass Infomation20 RO U16 NA NA 1
	ModbusRegInfo(47044, "u16", ""), // Pass Infomation21 RO U16 NA NA 1
	ModbusRegInfo(47045, "u16", ""), // Pass Infomation22 RO U16 NA NA 1
	ModbusRegInfo(47046, "u16", ""), // Pass Infomation23 RO U16 NA NA 1
	ModbusRegInfo(47047, "u16", ""), // Pass Infomation24 RO U16 NA NA 1
	ModbusRegInfo(47048, "u16", ""), // Pass Infomation25 RO U16 NA NA 1
	ModbusRegInfo(47049, "u16", ""), // Pass Infomation26 RO U16 NA NA 1
	ModbusRegInfo(47050, "u16", ""), // Pass Infomation27 RO U16 NA NA 1
	ModbusRegInfo(47051, "u16", ""), // Pass Infomation28 RO U16 NA NA 1
	ModbusRegInfo(47052, "u16", ""), // Pass Infomation29 RO U16 NA NA 1
	ModbusRegInfo(47053, "u16", ""), // Pass Infomation30 RO U16 NA NA 1
	ModbusRegInfo(47054, "u16", ""), // Pass Infomation31 RO U16 NA NA 1
	ModbusRegInfo(47055, "u16", ""), // Pass Infomation32 RO U16 NA NA 1

	// BMS Detailed Information
	ModbusRegInfo(47100, "u16", ""), // BMS Flag RO U16 NA NA 1
	ModbusRegInfo(47101, "u16", ""), // BMS Work Mode RO U16 NA NA 1
	ModbusRegInfo(47102, "u16", ""), // BMS Allow Charge Power RO U32 W 1 2
	ModbusRegInfo(47104, "u16", ""), // BMS Allow Discharge Power RO U32 W 1 2
	ModbusRegInfo(47106, "u16", ""), // BMS Relay Status RO U16 NA NA 1
	ModbusRegInfo(47107, "u16", ""), // Battery Module Number RO U16 NA NA 1
	ModbusRegInfo(47108, "u16", ""), // BMS Shutdown Fault Code RO U16 NA NA 1
	ModbusRegInfo(47109, "u16", ""), // Battery Ready Enable RO U16 NA NA 1
	ModbusRegInfo(47110, "u16", ""), // Alarm Under temperature ID RO U16 NA NA 1
	ModbusRegInfo(47111, "u16", ""), // Alarm Over temperature ID RO U16 NA NA 1
	ModbusRegInfo(47112, "u16", ""), // Alarm Differ temperature ID RO U16 NA NA 1
	ModbusRegInfo(47113, "u16", ""), // Alarm Charge Current ID RO U16 NA NA 1
	ModbusRegInfo(47114, "u16", ""), // Alarm Discharge Current ID RO U16 NA NA 1
	ModbusRegInfo(47115, "u16", ""), // Alarm Cell Over Voltage ID RO U16 NA NA 1
	ModbusRegInfo(47116, "u16", ""), // Alarm Cell Under Voltage ID RO U16 NA NA 1
	ModbusRegInfo(47117, "u16", ""), // Alarm SOC Lower ID RO U16 NA NA 1
	ModbusRegInfo(47118, "u16", ""), // Alarm Cell Voltage Differ ID RO U16 NA NA 1
	ModbusRegInfo(47119, "u16", ""), // Battery1 Current RO S16 A 10 1
	ModbusRegInfo(47120, "u16", ""), // Battery2 Current RO S16 A 10 1
	ModbusRegInfo(47121, "u16", ""), // Battery3 Current RO S16 A 10 1
	ModbusRegInfo(47122, "u16", ""), // Battery4 Current RO S16 A 10 1
	ModbusRegInfo(47123, "u16", ""), // Battery5 Current RO S16 A 10 1
	ModbusRegInfo(47124, "u16", ""), // Battery6 Current RO S16 A 10 1
	ModbusRegInfo(47125, "u16", ""), // Battery7 Current RO S16 A 10 1
	ModbusRegInfo(47126, "u16", ""), // Battery8 Current RO S16 A 10 1
	ModbusRegInfo(47127, "u16", ""), // Battery1 SOC RO U16 % 1 1
	ModbusRegInfo(47128, "u16", ""), // Battery2 SOC RO U16 % 1 1
	ModbusRegInfo(47129, "u16", ""), // Battery3 SOC RO U16 % 1 1
	ModbusRegInfo(47130, "u16", ""), // Battery4 SOC RO U16 % 1 1
	ModbusRegInfo(47131, "u16", ""), // Battery5 SOC RO U16 % 1 1
	ModbusRegInfo(47132, "u16", ""), // Battery6 SOC RO U16 % 1 1
	ModbusRegInfo(47133, "u16", ""), // Battery7 SOC RO U16 % 1 1
	ModbusRegInfo(47134, "u16", ""), // Battery8 SOC RO U16 % 1 1
	ModbusRegInfo(47135, "u16", ""), // Battery1 SN RO U32 NA NA 2
	ModbusRegInfo(47137, "u16", ""), // Battery2 SN RO U32 NA NA 2
	ModbusRegInfo(47139, "u16", ""), // Battery3 SN RO U32 NA NA 2
	ModbusRegInfo(47141, "u16", ""), // Battery4 SN RO U32 NA NA 2
	ModbusRegInfo(47143, "u16", ""), // Battery5 SN RO U32 NA NA 2
	ModbusRegInfo(47145, "u16", ""), // Battery6 SN RO U32 NA NA 2
	ModbusRegInfo(47147, "u16", ""), // Battery7 SN RO U32 NA NA 2
	ModbusRegInfo(47149, "u16", ""), // Battery8 SN RO U32 NA NA 2

	// For CEI Auto Test
	ModbusRegInfo(48000, "u16", ""), // Work Mode RO U16 NA NA 1
	ModbusRegInfo(48001, "u16", ""), // Error Message H RO U16 NA NA 1
	ModbusRegInfo(48002, "u16", ""), // Error Message L RO U16 NA NA 1
	ModbusRegInfo(48003, "u16", ""), // SimVoltage RO U16 V 10 1
	ModbusRegInfo(48004, "u16", ""), // SimFrequency RO U16 Hz 100 1
	ModbusRegInfo(48005, "u16", ""), // TestResult RO U16 NA NA 1
	ModbusRegInfo(48006, "u16", ""), // NA RO U16 NA 1
	ModbusRegInfo(48007, "u16", ""), // NA RO U16 NA 1
	ModbusRegInfo(48008, "u16", ""), // Vac1 RO U16 V 10 1
	ModbusRegInfo(48009, "u16", ""), // Fac1 RO U16 Hz 100 1
	ModbusRegInfo(48010, "u16", ""), // Pac 1 RO U16 W 1 2
	ModbusRegInfo(48012, "u16", ""), // Line1AvgFaultValue RO U16 V 10 1
	ModbusRegInfo(48013, "u16", ""), // Line1AvgFaultTime RO U16 s 1 1
	ModbusRegInfo(48014, "u16", ""), // Line1VHighfaultValue RO U16 V 10 1
	ModbusRegInfo(48015, "u16", ""), // Line1VHighfaultTime RO U16 ms 1 1
	ModbusRegInfo(48016, "u16", ""), // Line1VLowfaultValueS1 RO U16 V 10 1
	ModbusRegInfo(48017, "u16", ""), // Line1VLowfaultTimeS1 RO U16 ms 1 1
	ModbusRegInfo(48018, "u16", ""), // Line1VLowfaultValueS2 RO U16 V 10 1
	ModbusRegInfo(48019, "u16", ""), // Line1VLowfaultTimeS2 RO U16 ms 1 1
	ModbusRegInfo(48020, "u16", ""), // Line1FHighfaultValueCom RO U16 Hz 100 1
	ModbusRegInfo(48021, "u16", ""), // Line1FhighfaultTimeCom RO U16 ms 1 1
	ModbusRegInfo(48022, "u16", ""), // Line1FlowfaultValueCom RO U16 Hz 100 1
	ModbusRegInfo(48023, "u16", ""), // Line1FlowfaultTimeCom RO U16 ms 1 1
	ModbusRegInfo(48024, "u16", ""), // Line1FHighfaultValue RO U16 Hz 100 1
	ModbusRegInfo(48025, "u16", ""), // Line1FHighfaultTime RO U16 ms 1 1
	ModbusRegInfo(48026, "u16", ""), // Line1FLowfaultValue RO U16 Hz 100 1
	ModbusRegInfo(48027, "u16", ""), // Line1FLowfaultTime RO U16 ms 1 1
	ModbusRegInfo(48028, "u16", ""), // Vac2 RO U16 V 10 1
	ModbusRegInfo(48029, "u16", ""), // Fac2 RO U16 Hz 100 1
	ModbusRegInfo(48030, "u16", ""), // Pac 2 RO U16 W 1 2
	ModbusRegInfo(48032, "u16", ""), // Line2AvgFaultValue RO U16 V 10 1
	ModbusRegInfo(48033, "u16", ""), // Line2AvgFaultTime RO U16 s 1 1
	ModbusRegInfo(48034, "u16", ""), // Line2VHighfaultValue RO U16 V 10 1
	ModbusRegInfo(48035, "u16", ""), // Line2VHighfaultTime RO U16 ms 1 1
	ModbusRegInfo(48036, "u16", ""), // Line2VLowfaultValueS1 RO U16 V 10 1
	ModbusRegInfo(48037, "u16", ""), // Line2VLowfaultTimeS1 RO U16 ms 1 1
	ModbusRegInfo(48038, "u16", ""), // Line2VLowfaultValueS2 RO U16 V 10 1
	ModbusRegInfo(48039, "u16", ""), // Line2VLowfaultTimeS2 RO U16 ms 1 1
	ModbusRegInfo(48040, "u16", ""), // Line2FHighfaultValueCom RO U16 Hz 100 1
	ModbusRegInfo(48041, "u16", ""), // Line2FhighfaultTimeCom RO U16 ms 1 1
	ModbusRegInfo(48042, "u16", ""), // Line2FlowfaultValueCom RO U16 Hz 100 1
	ModbusRegInfo(48043, "u16", ""), // Line2FlowfaultTimeCom RO U16 ms 1 1
	ModbusRegInfo(48044, "u16", ""), // Line2FHighfaultValue RO U16 Hz 100 1
	ModbusRegInfo(48045, "u16", ""), // Line2FHighfaultTime RO U16 ms 1 1
	ModbusRegInfo(48046, "u16", ""), // Line2FLowfaultValue RO U16 Hz 100 1
	ModbusRegInfo(48047, "u16", ""), // Line2FLowfaultTime RO U16 ms 1 1
	ModbusRegInfo(48048, "u16", ""), // Vac3 RO U16 V 10 1
	ModbusRegInfo(48049, "u16", ""), // Fac3 RO U16 Hz 100 1
	ModbusRegInfo(48050, "u16", ""), // Pac 3 RO U16 W 1 2
	ModbusRegInfo(48052, "u16", ""), // Line3AvgFaultValue RO U16 V 10 1
	ModbusRegInfo(48053, "u16", ""), // Line3AvgFaultTime RO U16 s 1 1
	ModbusRegInfo(48054, "u16", ""), // Line3VHighfaultValue RO U16 V 10 1
	ModbusRegInfo(48055, "u16", ""), // Line3VHighfaultTime RO U16 ms 1 1
	ModbusRegInfo(48056, "u16", ""), // Line3VLowfaultValueS1 RO U16 V 10 1
	ModbusRegInfo(48057, "u16", ""), // Line3VLowfaultTimeS1 RO U16 ms 1 1
	ModbusRegInfo(48058, "u16", ""), // Line3VLowfaultValueS2 RO U16 V 10 1
	ModbusRegInfo(48059, "u16", ""), // Line3VLowfaultTimeS2 RO U16 ms 1 1
	ModbusRegInfo(48060, "u16", ""), // Line3FHighfaultValueCom RO U16 Hz 100 1
	ModbusRegInfo(48061, "u16", ""), // Line3FhighfaultTimeCom RO U16 ms 1 1
	ModbusRegInfo(48062, "u16", ""), // Line3FlowfaultValueCom RO U16 Hz 100 1
	ModbusRegInfo(48063, "u16", ""), // Line3FlowfaultTimeCom RO U16 ms 1 1
	ModbusRegInfo(48064, "u16", ""), // Line3FHighfaultValue RO U16 Hz 100 1
	ModbusRegInfo(48065, "u16", ""), // Line3FHighfaultTime RO U16 ms 1 1
	ModbusRegInfo(48066, "u16", ""), // Line3FLowfaultValue RO U16 Hz 100 1
	ModbusRegInfo(48067, "u16", ""), // Line3FLowfaultTime RO U16 ms 1 1

	// Power Limit
	ModbusRegInfo(48450, "u16", ""), // Feed Power Limit Coefficient RO U16 ‰ 1 1
	ModbusRegInfo(48451, "u16", ""), // L1 Power Limit RO U16 W 1 1
	ModbusRegInfo(48452, "u16", ""), // L2 Power Limit RO U16 W 1 1
	ModbusRegInfo(48453, "u16", ""), // L3 Power Limit RO U16 W 1 1
	ModbusRegInfo(48454, "u16", ""), // Inverter Power Factor RO S16 1 1000 1
	ModbusRegInfo(48455, "u16", ""), // PV MeterDC Power RO S32 W 1 2
	ModbusRegInfo(48457, "u16", ""), // Etotal Grid Charge RO U32 1KW.Hr 10 2
	ModbusRegInfo(48459, "u16", ""), // Dispatch Switch RO U16 NA 1 1
	ModbusRegInfo(48460, "u16", ""), // Dispatch Power R0 S32 W 1 2
	ModbusRegInfo(48462, "u16", ""), // Dispatch Soc RO U16 % 1 1
	ModbusRegInfo(48463, "u16", ""), // Dispatch Mode RO U16 NA 1 1
];

/+
Query reg: 0 <-- goodwe_ems :: ReadHoldingRegisters: 020001
Query reg: 2000 <-- goodwe_ems :: ReadHoldingRegisters: 023535
Query reg: 2001 <-- goodwe_ems :: ReadHoldingRegisters: 023030
Query reg: 2002 <-- goodwe_ems :: ReadHoldingRegisters: 023053
Query reg: 2003 <-- goodwe_ems :: ReadHoldingRegisters: 02504E
Query reg: 2004 <-- goodwe_ems :: ReadHoldingRegisters: 023232
Query reg: 2005 <-- goodwe_ems :: ReadHoldingRegisters: 024357
Query reg: 2006 <-- goodwe_ems :: ReadHoldingRegisters: 023030
Query reg: 2007 <-- goodwe_ems :: ReadHoldingRegisters: 023037
Query reg: 2008 <-- goodwe_ems :: ReadHoldingRegisters: 0200F7
Query reg: 2009 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2010 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2011 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2012 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2013 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2014 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2015 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2016 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2017 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2018 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2019 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2020 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2021 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2022 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2023 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2024 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2025 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2026 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2027 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2028 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2029 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2030 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2031 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2032 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2033 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2034 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2035 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2036 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2037 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2038 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2039 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2040 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2041 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2042 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2043 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2044 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2045 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2046 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2047 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2048 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2049 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2050 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2051 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2052 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2053 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2054 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2055 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2056 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2057 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2058 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2059 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2060 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2061 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2062 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2063 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2064 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2065 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2066 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2067 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2068 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2069 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2070 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2071 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2072 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2073 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2074 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2075 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2076 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2077 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2078 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2079 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2080 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2081 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2082 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2083 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2084 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2085 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2086 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2087 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2088 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2089 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2090 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2091 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2092 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2093 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2094 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2095 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2096 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2097 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2098 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2099 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2100 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2101 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2102 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2103 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2104 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2105 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2106 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2107 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2108 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2109 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2110 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2111 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2112 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2113 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2114 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2115 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2116 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2117 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2118 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2119 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2120 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2121 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2122 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2123 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2124 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2125 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2126 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2127 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2128 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2129 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2130 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2131 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2132 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2133 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2134 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2135 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2136 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2137 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2138 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2139 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2140 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2141 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2142 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2143 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 2151 <-- goodwe_ems :: ReadHoldingRegisters: 020003

Query reg: 10400 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10401 <-- goodwe_ems :: ReadHoldingRegisters: 020007
Query reg: 10402 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10403 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10404 <-- goodwe_ems :: ReadHoldingRegisters: 020001
Query reg: 10405 <-- goodwe_ems :: ReadHoldingRegisters: 020005
Query reg: 10406 <-- goodwe_ems :: ReadHoldingRegisters: 02001A
Query reg: 10407 <-- goodwe_ems :: ReadHoldingRegisters: 020001
Query reg: 10408 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10409 <-- goodwe_ems :: ReadHoldingRegisters: 020001
Query reg: 10410 <-- goodwe_ems :: ReadHoldingRegisters: 020001
Query reg: 10411 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10412 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10413 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10414 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10415 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10416 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10417 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10418 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10419 <-- goodwe_ems :: ReadHoldingRegisters: 020010
Query reg: 10420 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10421 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10422 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10423 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10424 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10425 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10426 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10427 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10428 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10429 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10430 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10431 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10432 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10433 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10434 <-- goodwe_ems :: ReadHoldingRegisters: 02138A
Query reg: 10435 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10436 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10437 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10438 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10439 <-- goodwe_ems :: ReadHoldingRegisters: 020000

Query reg: 10470 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10471 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10472 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10473 <-- goodwe_ems :: ReadHoldingRegisters: 020094
Query reg: 10474 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10475 <-- goodwe_ems :: exception: 2(ReadHoldingRegisters) - IllegalDataAddress
Query reg: 10476 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10477 <-- goodwe_ems :: ReadHoldingRegisters: 02141A
Query reg: 10478 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10479 <-- goodwe_ems :: ReadHoldingRegisters: 0206E6

Query reg: 10600 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10601 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10602 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10603 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10604 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10605 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10606 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10607 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10608 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10609 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10610 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10611 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10612 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10613 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10614 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10615 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10616 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10617 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10618 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10619 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10620 <-- goodwe_ems :: ReadHoldingRegisters: 020000

Query reg: 10669 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10670 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10671 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10672 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10673 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10674 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10675 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10676 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10677 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10678 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10679 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10680 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10681 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10682 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10683 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10684 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10685 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10686 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10687 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10688 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10689 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10690 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10691 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10692 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10693 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10694 <-- goodwe_ems :: ReadHoldingRegisters: 020000

Query reg: 10700 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10701 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10702 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10703 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10704 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10705 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10706 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10707 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10708 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10709 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10710 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10711 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10712 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10713 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10714 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10715 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10716 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10717 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10718 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10719 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10720 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10721 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10722 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10723 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10724 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10725 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10726 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10727 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10728 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10729 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10730 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10731 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10732 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10733 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10734 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10735 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10736 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10737 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10738 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10739 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10740 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10741 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10742 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10743 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10744 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10745 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10746 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10747 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10748 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10749 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10750 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10751 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10752 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10753 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10754 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10755 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10756 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10757 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10758 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10759 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10760 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10761 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10762 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10763 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10764 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10765 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10766 <-- goodwe_ems :: ReadHoldingRegisters: 020000

Query reg: 10800 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10801 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10802 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10803 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10804 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10805 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10806 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10807 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10808 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10809 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10810 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10811 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10812 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10813 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10814 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10815 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10816 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10817 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10818 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10819 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10820 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10821 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10822 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10823 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10824 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10825 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10826 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10827 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10828 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10829 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10830 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10831 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10832 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10833 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10834 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10835 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10836 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10837 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10838 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10839 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10840 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10841 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10842 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10843 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10844 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10845 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10846 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10847 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10848 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10849 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10850 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10851 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10852 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10853 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10854 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10855 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10856 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10857 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10858 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10859 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10860 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10861 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10862 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10863 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10864 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10865 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10866 <-- goodwe_ems :: ReadHoldingRegisters: 020000

Query reg: 10900 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10901 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10902 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10903 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10904 <-- goodwe_ems :: ReadHoldingRegisters: 0255AA
Query reg: 10905 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10906 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10907 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10908 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10909 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10910 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10911 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10912 <-- goodwe_ems :: ReadHoldingRegisters: 020001
Query reg: 10913 <-- goodwe_ems :: ReadHoldingRegisters: 020000

Query reg: 10980 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10981 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10982 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10983 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10984 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10985 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10986 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10987 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10988 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10989 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10990 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10991 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10992 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10993 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10994 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10995 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10996 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10997 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10998 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 10999 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 11000 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 11001 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 11002 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 11003 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 11004 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 11005 <-- goodwe_ems :: ReadHoldingRegisters: 020000

Query reg: 19995 <-- goodwe_ems :: exception: 2(ReadHoldingRegisters) - IllegalDataAddress
Query reg: 19996 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 19997 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 19998 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 19999 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20000 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20001 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20002 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20003 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20004 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20005 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20006 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20007 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20008 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20009 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20010 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20011 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20012 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20013 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20014 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20015 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20016 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20017 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20018 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20019 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20020 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20021 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20022 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20023 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20024 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20025 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20026 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20027 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20028 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20029 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20030 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20031 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20032 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20033 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20034 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20035 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20036 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20037 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20038 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20039 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20040 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20041 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20042 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20043 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20044 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20045 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20046 <-- goodwe_ems :: ReadHoldingRegisters: 020105
Query reg: 20047 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20048 <-- goodwe_ems :: exception: 2(ReadHoldingRegisters) - IllegalDataAddress

Query reg: 20300 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20301 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20302 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20303 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20304 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20305 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20306 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20307 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20308 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20309 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20310 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20311 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20312 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20313 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20314 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20315 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20316 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20317 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20318 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20319 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20320 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20321 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20322 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20323 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20324 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20325 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20326 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20327 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20328 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20329 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20330 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20331 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20332 <-- goodwe_ems :: ReadHoldingRegisters: 020000

Query reg: 20360 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20361 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 20362 <-- goodwe_ems :: ReadHoldingRegisters: 020000

Query reg: 20400 <-- goodwe_ems :: ReadHoldingRegisters: 02FFFF
Query reg: 20401 <-- goodwe_ems :: ReadHoldingRegisters: 020000

Query reg: 21000 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 21001 <-- goodwe_ems :: ReadHoldingRegisters: 020000
Query reg: 21002 <-- goodwe_ems :: ReadHoldingRegisters: 020000
+/
