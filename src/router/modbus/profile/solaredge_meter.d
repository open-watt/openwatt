module router.modbus.profile.solaredge_meter;

import router.modbus.profile;


//
// WattNode® Wide-RaNge for Modbus®
// Model: WND-WR-MB, WND-M1-MB, WND-M0-MB
// https://www.onetemp.com.au/Attachment/DownloadFile?downloadId=3210
//
// Previously:
// WattNode® WNC/RWNC Power Meters for Modbus®
// Models: WNC-3Y-208-MB, WNC-3Y-400-MB, WNC-3Y-480-MB, WNC-3Y-600-MB, WNC-3D-240-MB, WNC-3D-400-MB, WNC-3D-480-MB
//         RWNC-3Y-208-MB, RWNC-3Y-400-MB, RWNC-3Y-480-MB, RWNC-3Y-600-MB, RWNC-3D-240-MB, RWNC-3D-400-MB, RWNC-3D-480-MB
// https://ctlsys.com/wp-content/uploads/2016/10/WNC-Modbus-Manual-V18c.pdf
//
// SolarEdge: SE-MTR-3Y-400V-A, SE-RGMTR-3D-208V-A, SE-WND-3Y400-MB-K2...
//

ModbusRegInfo[] WND_WR_MB_Regs()
{
	return [
	// FLOAT:
	// Energy Registers (preserved across power failures)
	ModbusRegInfo(41000, "f32le/RW", "EnergySum", "kWh", null, Frequency.Medium, "Total net (bidirectional) energy"),
	ModbusRegInfo(41004, "f32le",    "EnergySumNR", "kWh", null, Frequency.Medium, "Total net energy - non-resettable"),
	ModbusRegInfo(41100, "f32le/RW", "Energy1", "kWh", null, Frequency.Medium, "Net (bidirectional) energy, meter element 1"),
	ModbusRegInfo(41102, "f32le/RW", "Eneryg2", "kWh", null, Frequency.Medium, "Net (bidirectional) energy, meter element 2"),
	ModbusRegInfo(41104, "f32le/RW", "Energy3", "kWh", null, Frequency.Medium, "Net (bidirectional) energy, meter element 3"),
	ModbusRegInfo(41002, "f32le/RW", "EnergyPosSum", "kWh", null, Frequency.Medium, "Total positive energy"),
	ModbusRegInfo(41006, "f32le",    "EnergyPosSumNR", "kWh", null, Frequency.Medium, "Total positive energy - non-resettable"),
	ModbusRegInfo(41106, "f32le/RW", "EnergyPos1", "kWh", null, Frequency.Medium, "Positive energy, meter element 1"),
	ModbusRegInfo(41108, "f32le/RW", "EnergyPos2", "kWh", null, Frequency.Medium, "Positive energy, meter element 2"),
	ModbusRegInfo(41110, "f32le/RW", "EnergyPos3", "kWh", null, Frequency.Medium, "Positive energy, meter element 3"),
	ModbusRegInfo(41112, "f32le/RW", "EnergyNegSum", "kWh", null, Frequency.Medium, "Total negative energy"),
	ModbusRegInfo(41114, "f32le",    "EnergyNegSumNR", "kWh", null, Frequency.Medium, "Total negative energy - non-resettable"),
	ModbusRegInfo(41116, "f32le/RW", "EnergyNeg1", "kWh", null, Frequency.Medium, "Negative energy, meter element 1"),
	ModbusRegInfo(41118, "f32le/RW", "EnergyNeg2", "kWh", null, Frequency.Medium, "Negative energy, meter element 2"),
	ModbusRegInfo(41120, "f32le/RW", "EnergyNeg3", "kWh", null, Frequency.Medium, "Negative energy, meter element 3"),
	// Power Registers
	ModbusRegInfo(41008, "f32le", "PowerSum", "W", null, Frequency.Medium, "Total active power"),
	ModbusRegInfo(41010, "f32le", "Power1", "W", null, Frequency.Medium, "Active power, meter element 1"),
	ModbusRegInfo(41012, "f32le", "Power2", "W", null, Frequency.Medium, "Active power, meter element 2"),
	ModbusRegInfo(41014, "f32le", "Power3", "W", null, Frequency.Medium, "Active power, meter element 3"),
	ModbusRegInfo(41034, "f32le", "SecondsFast", "s", null, Frequency.Medium, "Seconds for last 24 hours, updates at 10 Hz. Rolls over at 86400."),
	ModbusRegInfo(41036, "f32le", "PowerFastSum", "W", null, Frequency.Medium, "Total active power, 10 Hz update, no averaging"),
	ModbusRegInfo(41038, "f32le", "PowerFast1", "W", null, Frequency.Medium, "Active power, meter element 1, 10 Hz update, no averaging"),
	ModbusRegInfo(41040, "f32le", "PowerFast2", "W", null, Frequency.Medium, "Active power, meter element 2, 10 Hz update, no averaging"),
	ModbusRegInfo(41042, "f32le", "PowerFast3", "W", null, Frequency.Medium, "Active power, meter element 3, 10 Hz update, no averaging"),
	// Reactive and Apparent Energy Registers (preserved across power failures)
	ModbusRegInfo(41122, "f32le/RW", "EnergyReacSum", "kVARh", null, Frequency.Medium, "Total reactive energy"),
	ModbusRegInfo(41124, "f32le/RW", "EnergyReac1", "kVARh", null, Frequency.Medium, "Net reactive energy, meter element 1"),
	ModbusRegInfo(41126, "f32le/RW", "EnergyReac2", "kVARh", null, Frequency.Medium, "Net reactive energy, meter element 2"),
	ModbusRegInfo(41128, "f32le/RW", "EnergyReac3", "kVARh", null, Frequency.Medium, "Net reactive energy, meter element 3"),
	ModbusRegInfo(41188, "f32le/RW", "EnergyReacPosSum", "kVARh", null, Frequency.Medium, "Total positive reactive energy"),
	ModbusRegInfo(41182, "f32le/RW", "EnergyReacPos1", "kVARh", null, Frequency.Medium, "Positive reactive energy, meter element 1"),
	ModbusRegInfo(41184, "f32le/RW", "EnergyReacPos2", "kVARh", null, Frequency.Medium, "Positive reactive energy, meter element 2"),
	ModbusRegInfo(41186, "f32le/RW", "EnergyReacPos3", "kVARh", null, Frequency.Medium, "Positive reactive energy, meter element 3"),
	ModbusRegInfo(41196, "f32le/RW", "EnergyReacNegSum", "kVARh", null, Frequency.Medium, "Total negative reactive energy"),
	ModbusRegInfo(41190, "f32le/RW", "EnergyReacNeg1", "kVARh", null, Frequency.Medium, "Negative reactive energy, meter element 1"),
	ModbusRegInfo(41192, "f32le/RW", "EnergyReacNeg2", "kVARh", null, Frequency.Medium, "Negative reactive energy, meter element 2"),
	ModbusRegInfo(41194, "f32le/RW", "EnergyReacNeg3", "kVARh", null, Frequency.Medium, "Negative reactive energy, meter element 3"),
	ModbusRegInfo(41130, "f32le/RW", "EnergyAppSum", "kVAh", null, Frequency.Medium, "Total apparent energy"),
	ModbusRegInfo(41132, "f32le/RW", "EnergyApp1", "kVAh", null, Frequency.Medium, "Apparent energy, meter element 1"),
	ModbusRegInfo(41134, "f32le/RW", "EnergyApp2", "kVAh", null, Frequency.Medium, "Apparent energy, meter element 2"),
	ModbusRegInfo(41136, "f32le/RW", "EnergyApp3", "kVAh", null, Frequency.Medium, "Apparent energy, meter element 3"),
	// Reactive and Apparent Power Registers
	ModbusRegInfo(41146, "f32le", "PowerReacSum", "var", null, Frequency.Medium, "Total reactive power"),
	ModbusRegInfo(41148, "f32le", "PowerReac1", "var", null, Frequency.Medium, "Reactive power, meter element 1"),
	ModbusRegInfo(41150, "f32le", "PowerReac2", "var", null, Frequency.Medium, "Reactive power, meter element 2"),
	ModbusRegInfo(41152, "f32le", "PowerReac3", "var", null, Frequency.Medium, "Reactive power, meter element 3"),
	ModbusRegInfo(41154, "f32le", "PowerAppSum", "VA", null, Frequency.Medium, "Total apparent power"),
	ModbusRegInfo(41156, "f32le", "PowerApp1", "VA", null, Frequency.Medium, "Apparent power, meter element 1"),
	ModbusRegInfo(41158, "f32le", "PowerApp2", "VA", null, Frequency.Medium, "Apparent power, meter element 2"),
	ModbusRegInfo(41160, "f32le", "PowerApp3", "VA", null, Frequency.Medium, "Apparent power, meter element 3"),
	// Voltage Registers
	ModbusRegInfo(41016, "f32le", "VoltAvgLN", "V", null, Frequency.Medium, "Average line-to-neutral voltage"),
	ModbusRegInfo(41018, "f32le", "VoltAN", "V", null, Frequency.Medium, "RMS voltage, phase A to neutral"),
	ModbusRegInfo(41020, "f32le", "VoltBN", "V", null, Frequency.Medium, "RMS voltage, phase B to neutral"),
	ModbusRegInfo(41022, "f32le", "VoltCN", "V", null, Frequency.Medium, "RMS voltage, phase C to neutral"),
	ModbusRegInfo(41024, "f32le", "VoltAvgLL", "V", null, Frequency.Medium, "Average line-to-line voltage"),
	ModbusRegInfo(41026, "f32le", "VoltAB", "V", null, Frequency.Medium, "RMS voltage, line-to-line, phase A to B"),
	ModbusRegInfo(41028, "f32le", "VoltBC", "V", null, Frequency.Medium, "RMS voltage, line-to-line, phase B to C"),
	ModbusRegInfo(41030, "f32le", "VoltCA", "V", null, Frequency.Medium, "RMS voltage, line-to-line, phase C to A"),
	// Current Registers
	ModbusRegInfo(41162, "f32le", "Current1", "A", null, Frequency.Realtime, "RMS current, CT1"),
	ModbusRegInfo(41164, "f32le", "Current2", "A", null, Frequency.Realtime, "RMS current, CT2"),
	ModbusRegInfo(41166, "f32le", "Current3", "A", null, Frequency.Realtime, "RMS current, CT3"),
	// Frequency Register
	ModbusRegInfo(41032, "f32le", "Freq", "Hz", null, Frequency.Medium, "Power line frequency"),
	// Power Factor Registers
	ModbusRegInfo(41138, "f32le", "PowerFactorAvg", null, null, Frequency.Medium, "Power factor, average"),
	ModbusRegInfo(41140, "f32le", "PowerFactor1", null, null, Frequency.Medium, "Power factor, meter element 1"),
	ModbusRegInfo(41142, "f32le", "PowerFactor2", null, null, Frequency.Medium, "Power factor, meter element 2"),
	ModbusRegInfo(41144, "f32le", "PowerFactor3", null, null, Frequency.Medium, "Power factor, meter element 3"),
	// Demand Registers
	ModbusRegInfo(41168, "f32le", "DemandSum", "W", null, Frequency.Medium, "Active power sum demand averaged over the demand period"),
	ModbusRegInfo(41170, "f32le", "DemandSumMin", "W", null, Frequency.Medium, "Minimum power sum demand"),	// (preserved across power failures)
	ModbusRegInfo(41172, "f32le", "DemandSumMax", "W", null, Frequency.Medium, "Maximum power sum demand"),	// (preserved across power failures)
	ModbusRegInfo(41174, "f32le", "DemandAppSum", "W", null, Frequency.Medium, "Apparent power sum demand"),
	ModbusRegInfo(41176, "f32le", "Demand1", "W", null, Frequency.Medium, "Active power demand, meter element 1"),
	ModbusRegInfo(41178, "f32le", "Demand2", "W", null, Frequency.Medium, "Active power demand, meter element 2"),
	ModbusRegInfo(41180, "f32le", "Demand3", "W", null, Frequency.Medium, "Active power demand, meter element 3"),

/+  TODO: these registers need to have a distinct name so they don't alias...
	// INTEGER:
	// Energy Registers (preserved across power failures)
	ModbusRegInfo(41200, "u32le/RW", "EnergySum", "0.1kWh", "kWh", Frequency.Medium, "Total net (bidirectional) energy"),
	ModbusRegInfo(41204, "u32le",    "EnergySumNR", "0.1kWh", "kWh", Frequency.Medium, "Total net energy - non-resettable"),
	ModbusRegInfo(41300, "u32le/RW", "Energy1", "0.1kWh", "kWh", Frequency.Medium, "Net (bidirectional) energy, meter element 1"),
	ModbusRegInfo(41302, "u32le/RW", "Eneryg2", "0.1kWh", "kWh", Frequency.Medium, "Net (bidirectional) energy, meter element 2"),
	ModbusRegInfo(41304, "u32le/RW", "Energy3", "0.1kWh", "kWh", Frequency.Medium, "Net (bidirectional) energy, meter element 3"),
	ModbusRegInfo(41202, "u32le/RW", "EnergyPosSum", "0.1kWh", "kWh", Frequency.Medium, "Total positive energy"),
	ModbusRegInfo(41206, "u32le",    "EnergyPosSumNR", "0.1kWh", "kWh", Frequency.Medium, "Total positive energy - non-resettable"),
	ModbusRegInfo(41306, "u32le/RW", "EnergyPos1", "0.1kWh", "kWh", Frequency.Medium, "Positive energy, meter element 1"),
	ModbusRegInfo(41308, "u32le/RW", "EnergyPos2", "0.1kWh", "kWh", Frequency.Medium, "Positive energy, meter element 2"),
	ModbusRegInfo(41310, "u32le/RW", "EnergyPos3", "0.1kWh", "kWh", Frequency.Medium, "Positive energy, meter element 3"),
	ModbusRegInfo(41312, "u32le/RW", "EnergyNegSum", "0.1kWh", "kWh", Frequency.Medium, "Total negative energy"),
	ModbusRegInfo(41314, "u32le",    "EnergyNegSumNR", "0.1kWh", "kWh", Frequency.Medium, "Total negative energy - non-resettable"),
	ModbusRegInfo(41316, "u32le/RW", "EnergyNeg1", "0.1kWh", "kWh", Frequency.Medium, "Negative energy, meter element 1"),
	ModbusRegInfo(41318, "u32le/RW", "EnergyNeg2", "0.1kWh", "kWh", Frequency.Medium, "Negative energy, meter element 2"),
	ModbusRegInfo(41320, "u32le/RW", "EnergyNeg3", "0.1kWh", "kWh", Frequency.Medium, "Negative energy, meter element 3"),
	// Power Registers
	ModbusRegInfo(41208, "u16", "PowerSum", null, null, Frequency.Medium, "Total active power"),
	ModbusRegInfo(41209, "u16", "Power1", null, null, Frequency.Medium, "Active power, meter element 1"),
	ModbusRegInfo(41210, "u16", "Power2", null, null, Frequency.Medium, "Active power, meter element 2"),
	ModbusRegInfo(41211, "u16", "Power3", null, null, Frequency.Medium, "Active power, meter element 3"),
	// Reactive and Apparent Energy Registers (preserved across power failures)
	ModbusRegInfo(41322, "u32le/RW", "EnergyReacSum", "0.1kVARh", "kVARh", Frequency.Medium, "Total reactive energy"),
	ModbusRegInfo(41324, "u32le/RW", "EnergyReac1", "0.1kVARh", "kVARh", Frequency.Medium, "Net reactive energy, meter element 1"),
	ModbusRegInfo(41326, "u32le/RW", "EnergyReac2", "0.1kVARh", "kVARh", Frequency.Medium, "Net reactive energy, meter element 2"),
	ModbusRegInfo(41328, "u32le/RW", "EnergyReac3", "0.1kVARh", "kVARh", Frequency.Medium, "Net reactive energy, meter element 3"),
	ModbusRegInfo(41388, "u32le/RW", "EnergyReacPosSum", "0.1kVARh", "kVARh", Frequency.Medium, "Total positive reactive energy"),
	ModbusRegInfo(41382, "u32le/RW", "EnergyReacPos1", "0.1kVARh", "kVARh", Frequency.Medium, "Positive reactive energy, meter element 1"),
	ModbusRegInfo(41384, "u32le/RW", "EnergyReacPos2", "0.1kVARh", "kVARh", Frequency.Medium, "Positive reactive energy, meter element 2"),
	ModbusRegInfo(41386, "u32le/RW", "EnergyReacPos3", "0.1kVARh", "kVARh", Frequency.Medium, "Positive reactive energy, meter element 3"),
	ModbusRegInfo(41396, "u32le/RW", "EnergyReacNegSum", "0.1kVARh", "kVARh", Frequency.Medium, "Total negative reactive energy"),
	ModbusRegInfo(41390, "u32le/RW", "EnergyReacNeg1", "0.1kVARh", "kVARh", Frequency.Medium, "Negative reactive energy, meter element 1"),
	ModbusRegInfo(41392, "u32le/RW", "EnergyReacNeg2", "0.1kVARh", "kVARh", Frequency.Medium, "Negative reactive energy, meter element 2"),
	ModbusRegInfo(41394, "u32le/RW", "EnergyReacNeg3", "0.1kVARh", "kVARh", Frequency.Medium, "Negative reactive energy, meter element 3"),
	ModbusRegInfo(41330, "u32le/RW", "EnergyAppSum", "0.1kVAh", "kVAh", Frequency.Medium, "Total apparent energy"),
	ModbusRegInfo(41332, "u32le/RW", "EnergyApp1", "0.1kVAh", "kVAh", Frequency.Medium, "Apparent energy, meter element 1"),
	ModbusRegInfo(41334, "u32le/RW", "EnergyApp2", "0.1kVAh", "kVAh", Frequency.Medium, "Apparent energy, meter element 2"),
	ModbusRegInfo(41336, "u32le/RW", "EnergyApp3", "0.1kVAh", "kVAh", Frequency.Medium, "Apparent energy, meter element 3"),
	// Reactive and Apparent Power Registers
	ModbusRegInfo(41342, "u16", "PowerReacSum", null, null, Frequency.Medium, "Total reactive power var"),
	ModbusRegInfo(41343, "u16", "PowerReac1", null, null, Frequency.Medium, "Reactive power var, meter element 1"),
	ModbusRegInfo(41344, "u16", "PowerReac2", null, null, Frequency.Medium, "Reactive power var, meter element 2"),
	ModbusRegInfo(41345, "u16", "PowerReac3", null, null, Frequency.Medium, "Reactive power var, meter element 3"),
	ModbusRegInfo(41346, "u16", "PowerAppSum", null, null, Frequency.Medium, "Total apparent power VA" ),
	ModbusRegInfo(41347, "u16", "PowerApp1", null, null, Frequency.Medium, "Apparent power VA, meter element 1"),
	ModbusRegInfo(41348, "u16", "PowerApp2", null, null, Frequency.Medium, "Apparent power VA, meter element 2"),
	ModbusRegInfo(41349, "u16", "PowerApp3", null, null, Frequency.Medium, "Apparent power VA, meter element 3"),
	// Voltage Registers
	ModbusRegInfo(41212, "u16", "VoltAvgLN", "0.1V", "V", Frequency.Medium, "Average line-to-neutral voltage"),
	ModbusRegInfo(41213, "u16", "VoltAN", "0.1V", "V", Frequency.Medium, "RMS voltage, phase A to neutral"),
	ModbusRegInfo(41214, "u16", "VoltBN", "0.1V", "V", Frequency.Medium, "RMS voltage, phase B to neutral"),
	ModbusRegInfo(41215, "u16", "VoltCN", "0.1V", "V", Frequency.Medium, "RMS voltage, phase C to neutral"),
	ModbusRegInfo(41216, "u16", "VoltAvgLL", "0.1V", "V", Frequency.Medium, "Average line-to-line voltage"),
	ModbusRegInfo(41217, "u16", "VoltAB", "0.1V", "V", Frequency.Medium, "RMS voltage, line-to-line, phase A to B"),
	ModbusRegInfo(41218, "u16", "VoltBC", "0.1V", "V", Frequency.Medium, "RMS voltage, line-to-line, phase B to C"),
	ModbusRegInfo(41219, "u16", "VoltCA", "0.1V", "V", Frequency.Medium, "RMS voltage, line-to-line, phase C to A"),
	// Current Registers
	ModbusRegInfo(41350, "u16", "Current1", null, null, Frequency.Realtime, "RMS current, CT1"),
	ModbusRegInfo(41351, "u16", "Current2", null, null, Frequency.Realtime, "RMS current, CT2"),
	ModbusRegInfo(41352, "u16", "Current3", null, null, Frequency.Realtime, "RMS current, CT3"),
	// Frequency Register
	ModbusRegInfo(41220, "u16", "Freq", "0.1Hz", null, Frequency.Medium, "Power line frequency"),
	// Power Factor Registers
	ModbusRegInfo(41338, "u16", "PowerFactorAvg", "0.1", null, Frequency.Medium, "Power factor, average"),
	ModbusRegInfo(41339, "u16", "PowerFactor1", "0.1", null, Frequency.Medium, "Power factor, meter element 1"),
	ModbusRegInfo(41340, "u16", "PowerFactor2", "0.1", null, Frequency.Medium, "Power factor, meter element 2"),
	ModbusRegInfo(41341, "u16", "PowerFactor3", "0.1", null, Frequency.Medium, "Power factor, meter element 3"),
	// Demand Registers
	ModbusRegInfo(41353, "u16", "DemandSum", null, null, Frequency.Medium, "Active power sum demand averaged over the demand period"),
	ModbusRegInfo(41354, "u16", "DemandSumMin", null, null, Frequency.Medium, "Minimum power sum demand"),	// (preserved across power failures)
	ModbusRegInfo(41355, "u16", "DemandSumMax", null, null, Frequency.Medium, "Maximum power sum demand"),	// (preserved across power failures)
	ModbusRegInfo(41356, "u16", "DemandAppSum", null, null, Frequency.Medium, "Apparent power sum demand"),
	ModbusRegInfo(41357, "u16", "Demand1", null, null, Frequency.Medium, "Active power demand, meter element 1"),
	ModbusRegInfo(41358, "u16", "Demand2", null, null, Frequency.Medium, "Active power demand, meter element 2"),
	ModbusRegInfo(41359, "u16", "Demand3", null, null, Frequency.Medium, "Active power demand, meter element 3"),
	ModbusRegInfo(41360, "u16", "IoPinState", null, null, Frequency.Medium, "I/O pin digital input or output state"), // WNC/RWNC meters
	ModbusRegInfo(41361, "u16", "PulseCount", null, null, Frequency.Medium, "I/O pin pulse count"),					  // WNC/RWNC meters
	+/
	// Configuration Register List
	ModbusRegInfo(41600, "u16/RW", "ConfigPasscode", null, null, Frequency.Configuration, "Optional passcode to prevent unauthorized changes to configuration"),
	ModbusRegInfo(41602, "u16/RW", "CtAmps", "A", null, Frequency.Configuration, "Assign global current transformer rated current"),
	ModbusRegInfo(41603, "u16/RW", "CtAmps1", "A", null, Frequency.Configuration, "CT1 rated current (0 to 30000)"),
	ModbusRegInfo(41604, "u16/RW", "CtAmps2", "A", null, Frequency.Configuration, "CT2 rated current (0 to 30000)"),
	ModbusRegInfo(41605, "u16/RW", "CtAmps3", "A", null, Frequency.Configuration, "CT3 rated current (0 to 30000)"),
	ModbusRegInfo(41606, "u16/RW", "CtDirections", null, null, Frequency.Configuration, "Optionally invert CT orientations (0 to 7)"),
	ModbusRegInfo(41607, "u16/RW", "Averaging", null, null, Frequency.Configuration, "Configure measurement averaging"),
	ModbusRegInfo(41608, "u16/RW", "PowerIntScale", "W", null, Frequency.Configuration, "Integer power register scaling (0 to 10000)"),
	ModbusRegInfo(41609, "u16/RW", "DemPerMins", "m", null, Frequency.Configuration, "Demand period (1 to 720)"),
	ModbusRegInfo(41610, "u16/RW", "DemSubints", null, null, Frequency.Configuration, "Number of demand subintervals (1 to 10)"),
	ModbusRegInfo(41611, "u16/RW", "GainAdjust1", "0.0001", null, Frequency.Configuration, "CT1 gain adjustment (5000 to 20000)"),
	ModbusRegInfo(41612, "u16/RW", "GainAdjust2", "0.0001", null, Frequency.Configuration, "CT2 gain adjustment (5000 to 20000)"),
	ModbusRegInfo(41613, "u16/RW", "GainAdjust3", "0.0001", null, Frequency.Configuration, "CT3 gain adjustment (5000 to 20000)"),
	ModbusRegInfo(41614, "u16/RW", "PhaseAdjust1", "0.001deg", "deg", Frequency.Configuration, "CT1 phase angle adjust (-8000 to 8000)"),
	ModbusRegInfo(41615, "u16/RW", "PhaseAdjust2", "0.001deg", "deg", Frequency.Configuration, "CT2 phase angle adjust (-8000 to 8000)"),
	ModbusRegInfo(41616, "u16/RW", "PhaseAdjust3", "0.001deg", "deg", Frequency.Configuration, "CT3 phase angle adjust (-8000 to 8000)"),
	ModbusRegInfo(41617, "u16/RW", "CreepLimit", "ppm", null, Frequency.Configuration, "Minimum current and power for readings"),
	ModbusRegInfo(41618, "u16/RW", "PhaseOffset", null, null, Frequency.Configuration, "Not used. Included for WNC compatibility."),
	ModbusRegInfo(41619, "u16/RW", "ZeroEnergy", null, null, Frequency.Configuration, "Write 1 to zero all resettable energy registers"),
	ModbusRegInfo(41620, "u16/RW", "ZeroDemand", null, null, Frequency.Configuration, "Write 1 to zero all demand values"),
	ModbusRegInfo(41621, "u16/RW", "CurrentIntScale", null, null, Frequency.Configuration, "Scale factor for integer currents (0 to 32767)"),
	ModbusRegInfo(41622, "u16/RW", "IoPinMode", null, null, Frequency.Configuration, "I/O pin mode for Option IO or SSR (0 to 8)"), // WNC/RWNC meters
	ModbusRegInfo(41623, "u16/RW", "MeterConfig1", null, null, Frequency.Configuration, "Configure voltage for meter element 1"),
	ModbusRegInfo(41624, "u16/RW", "MeterConfig2", null, null, Frequency.Configuration, "Configure voltage for meter element 2"),
	ModbusRegInfo(41625, "u16/RW", "MeterConfig3", null, null, Frequency.Configuration, "Configure voltage for meter element 3"),
	ModbusRegInfo(41627, "u16/RW", "ChangeCounter", null, null, Frequency.Configuration, "Count of configuration changes"),
	ModbusRegInfo(41628, "f32le/RW", "NominalCtVolts1", "V", null, Frequency.Configuration, "CT1, Voltage of full scale CT signal"),
	ModbusRegInfo(41630, "f32le/RW", "NominalCtVolts2", "V", null, Frequency.Configuration, "CT2, Voltage of full scale CT signal"),
	ModbusRegInfo(41632, "f32le/RW", "NominalCtVolts3", "V", null, Frequency.Configuration, "CT3, Voltage of full scale CT signal"),
	ModbusRegInfo(41635, "u16/RW", "ConnectionType", null, null, Frequency.Configuration, "Shortcut to set all three MeterConfig registers"),
	ModbusRegInfo(41636, "u16/RW", "VoltsNoiseFloor", "0.1%", "%", Frequency.Configuration, "Minimum voltage as a percentage."),
	ModbusRegInfo(41637, "u16/RW", "CtMonitoring", null, null, Frequency.Configuration, "Configure disconnected CT detection (0 to 2)"),
	ModbusRegInfo(41638, "f32le/RW", "PtRatio", null, null, Frequency.Configuration, "Potential transformer ratio (0.05 to 300.0)"),
	ModbusRegInfo(41684, "u16/RW", "OptSignedCurrent", null, null, Frequency.Configuration, "Report signed current. 0=current always positive, 1=current sign matches the sign of the active power."),
	ModbusRegInfo(41685, "u16/RW", "OptEnergySumMethod", null, null, Frequency.Configuration, "Option to specify how meter elements are summed."),
	// Communication Register List
	ModbusRegInfo(41650, "u16/RW", "ApplyComConfig", null, null, Frequency.Configuration, "Writing 1234 applies the configuration settings below. Reads 1 if pending changes not applied yet."),
	ModbusRegInfo(41651, "u16/RW", "Address", null, null, Frequency.Configuration, "Modbus address"),
	ModbusRegInfo(41652, "u16/RW", "BaudRate", null, null, Frequency.Configuration, "1 = 1200 baud, 2 = 2400 baud, 3 = 4800 baud, 4 = 9600 baud, 5 = 19200 baud, 6 = 38400 baud, 7 = 57600 baud, 8 = 76800 baud, 9 = 115200 baud"),
	ModbusRegInfo(41653, "u16/RW", "ParityMode", null, null, Frequency.Configuration, "0 = 8N1 (no parity, one stop bit) 1 = 8E1 (even parity, one stop bit) 2 = 8N2 (no parity, two stop bits)"),
	ModbusRegInfo(41654, "u16/RW", "ModbusMode", null, null, Frequency.Configuration, "0 = RTU"),
	ModbusRegInfo(41655, "u16/RW", "ReplyDelay", null, null, Frequency.Configuration, "Minimum Modbus reply delay: 0 to 20 ms (default: 5ms)"),
	ModbusRegInfo(41656, "u32le/RW", "SerialNumberKey", null, null, Frequency.Configuration, "Serial number of meter to change Modbus address"),
	ModbusRegInfo(41658, "u16/RW", "NewAddress", null, null, Frequency.Configuration, "New Modbus address for meter with SerialNumberKey"),
	// Diagnostic Register List
	ModbusRegInfo(41700, "u32le", "SerialNumber", null, null, Frequency.Constant, "The WattNode meter serial number"),
	ModbusRegInfo(41702, "u32le", "UptimeSecs", "s", null, Frequency.OnDemand, "Time in seconds since last power on"),
	ModbusRegInfo(41704, "u32le", "TotalSecs", "s", null, Frequency.OnDemand, "Seconds Total seconds of operation"), // (preserved across power failures)
	ModbusRegInfo(41706, "u16", "Model", null, null, Frequency.OnDemand, "Encoded WattNode model"),
	ModbusRegInfo(41707, "u16", "Version", null, null, Frequency.OnDemand, "Firmware version"),
	ModbusRegInfo(41709, "u16", "ErrorStatusQueue", null, null, Frequency.OnDemand, "List of recent errors and events"),
	ModbusRegInfo(41710, "u16", "PowerFailCount1", null, null, Frequency.OnDemand, "Power failure count"),
	ModbusRegInfo(41711, "u16", "CrcErrorCount", null, null, Frequency.OnDemand, "Count of Modbus CRC communication errors"),
	ModbusRegInfo(41712, "u16", "FrameErrorCount", null, null, Frequency.OnDemand, "Count of Modbus framing errors"),
	ModbusRegInfo(41713, "u16", "PacketErrorCount", null, null, Frequency.OnDemand, "Count of bad Modbus packets"),
	ModbusRegInfo(41714, "u16", "OverrunCount", null, null, Frequency.OnDemand, "Count of Modbus buffer overruns"),
	ModbusRegInfo(41715, "u16", "ErrorStatus1", null, null, Frequency.OnDemand, "Newest error or event (0 = no errors)"),
	ModbusRegInfo(41716, "u16", "ErrorStatus2", null, null, Frequency.OnDemand, "Next oldest error or event"),
	ModbusRegInfo(41717, "u16", "ErrorStatus3", null, null, Frequency.OnDemand, "Next oldest error or event"),
	ModbusRegInfo(41718, "u16", "ErrorStatus4", null, null, Frequency.OnDemand, "Next oldest error or event"),
	ModbusRegInfo(41719, "u16", "ErrorStatus5", null, null, Frequency.OnDemand, "Next oldest error or event"),
	ModbusRegInfo(41720, "u16", "ErrorStatus6", null, null, Frequency.OnDemand, "Next oldest error or event"),
	ModbusRegInfo(41721, "u16", "ErrorStatus7", null, null, Frequency.OnDemand, "Next oldest error or event"),
	ModbusRegInfo(41722, "u16", "ErrorStatus8", null, null, Frequency.OnDemand, "Oldest error or event"),
	ModbusRegInfo(41759, "u16", "CtStatus1", null, null, Frequency.OnDemand, "Status of CT1 disconnect detection: 0 = Normal or no monitoring, 1 = CT disconnected, 2 = CT reconnected (was disconnected)"),
	ModbusRegInfo(41760, "u16", "CtStatus2", null, null, Frequency.OnDemand, "Status of CT2 disconnect detection"),
	ModbusRegInfo(41761, "u16", "CtStatus3", null, null, Frequency.OnDemand, "Status of CT3 disconnect detection"),
	// Option Information Registers
	ModbusRegInfo(41708, "u16", "Options", null, null, Frequency.OnDemand, "Meter options as a bit field"),
	ModbusRegInfo(41723, "u16", "OptCtAmps1", null, null, Frequency.OnDemand, "Option CT - CT1 CtAmps"),
	ModbusRegInfo(41724, "u16", "OptCtAmps2", null, null, Frequency.OnDemand, "Option CT - CT2 CtAmps"),
	ModbusRegInfo(41725, "u16", "OptCtAmps3", null, null, Frequency.OnDemand, "Option CT - CT3 CtAmps"),
	ModbusRegInfo(41726, "u16", "OptModbusMode", null, null, Frequency.OnDemand, "Not supported on the WND-series WattNode"),
	ModbusRegInfo(41727, "u16", "OptAddress", null, null, Frequency.OnDemand, "Option AD - Factory assigned Modbus address"),
	ModbusRegInfo(41728, "u16", "OptBaudRate", null, null, Frequency.OnDemand, "Factory assigned baud rate"),
	ModbusRegInfo(41729, "u16", "OptParityMode", null, null, Frequency.OnDemand, "Option EP - Factory assigned even parity"),
	ModbusRegInfo(41730, "u16", "Opt232", null, null, Frequency.OnDemand, "Option 232 - RS-232 interface installed"),   // WNC/RWNC meters
	ModbusRegInfo(41731, "u16", "OptTTL", null, null, Frequency.OnDemand, "Option TTL - TTL interface installed"),	  // WNC/RWNC meters
	ModbusRegInfo(41732, "u16", "OptIO", null, null, Frequency.OnDemand, "Option IO - Digital I/O and pulse counter"),  // WNC/RWNC meters
	ModbusRegInfo(41733, "u16", "OptX5", null, null, Frequency.OnDemand, "Option X5 - 5 Vdc @ 60 mA power output"),	  // WNC/RWNC meters
	ModbusRegInfo(41734, "u16", "OptSSR", null, null, Frequency.OnDemand, "Option SSR - Solid-state relay output"),	  // WNC/RWNC meters
	ModbusRegInfo(41735, "u16", "OptIoPinMode", null, null, Frequency.OnDemand, "Option value for IoPinMode register"), // WNC/RWNC meters
	ModbusRegInfo(41736, "u16", "OptLockedConfig", null, null, Frequency.OnDemand, "Option L - Factory locked configuration settings"),
	ModbusRegInfo(41737, "u16", "OptFastPower", null, null, Frequency.OnDemand, "Not supported on the WND-series WattNode"),
	ModbusRegInfo(41738, "u16", "OptRs485Termination", null, null, Frequency.OnDemand, "DIP switch 7 controls RS-485 termination. This is standard on the WND-WR-MB."),
	ModbusRegInfo(41739, "u16", "OptOemFeatures", null, null, Frequency.OnDemand, "Factory option for OEM features"),
	ModbusRegInfo(41740, "u16", "OptNrEnergies", null, null, Frequency.OnDemand, "Factory option for all energies non-resettable"),
];

}
