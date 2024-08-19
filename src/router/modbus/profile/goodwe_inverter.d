module router.modbus.profile.goodwe_inverter;

import router.modbus.profile;

ModbusRegInfo[] goodWeInverterRegs()
{
	return [
	ModbusRegInfo(40000, "u16", "reg0000"),
	ModbusRegInfo(42000, "str8", "serialNumber"),
	ModbusRegInfo(42008, "u16", "modbusAddress"),
	ModbusRegInfo(42009, "u16", "reg2009"),
	ModbusRegInfo(42010, "u16", "reg2010"),
	ModbusRegInfo(42011, "u16", "reg2011"),
	ModbusRegInfo(42012, "u16", "reg2012"),
	ModbusRegInfo(42013, "u16", "reg2013"),
/+
	ModbusRegInfo(42014, "u16", "reg2014"),
	ModbusRegInfo(42015, "u16", "reg2015"),
	ModbusRegInfo(42016, "u16", "reg2016"),
	ModbusRegInfo(42017, "u16", "reg2017"),
	ModbusRegInfo(42018, "u16", "reg2018"),
	ModbusRegInfo(42019, "u16", "reg2019"),
	ModbusRegInfo(42020, "u16", "reg2020"),
	ModbusRegInfo(42021, "u16", "reg2021"),
	ModbusRegInfo(42022, "u16", "reg2022"),
	ModbusRegInfo(42023, "u16", "reg2023"),
	ModbusRegInfo(42024, "u16", "reg2024"),
	ModbusRegInfo(42025, "u16", "reg2025"),
	ModbusRegInfo(42026, "u16", "reg2026"),
	ModbusRegInfo(42027, "u16", "reg2027"),
	ModbusRegInfo(42028, "u16", "reg2028"),
	ModbusRegInfo(42029, "u16", "reg2029"),
	ModbusRegInfo(42030, "u16", "reg2030"),
	ModbusRegInfo(42031, "u16", "reg2031"),
	ModbusRegInfo(42032, "u16", "reg2032"),
	ModbusRegInfo(42033, "u16", "reg2033"),
	ModbusRegInfo(42034, "u16", "reg2034"),
	ModbusRegInfo(42035, "u16", "reg2035"),
	ModbusRegInfo(42036, "u16", "reg2036"),
	ModbusRegInfo(42037, "u16", "reg2037"),
	ModbusRegInfo(42038, "u16", "reg2038"),
	ModbusRegInfo(42039, "u16", "reg2039"),
	ModbusRegInfo(42040, "u16", "reg2040"),
	ModbusRegInfo(42041, "u16", "reg2041"),
	ModbusRegInfo(42042, "u16", "reg2042"),
	ModbusRegInfo(42043, "u16", "reg2043"),
	ModbusRegInfo(42044, "u16", "reg2044"),
	ModbusRegInfo(42045, "u16", "reg2045"),
	ModbusRegInfo(42046, "u16", "reg2046"),
	ModbusRegInfo(42047, "u16", "reg2047"),
	ModbusRegInfo(42048, "u16", "reg2048"),
	ModbusRegInfo(42049, "u16", "reg2049"),
	ModbusRegInfo(42050, "u16", "reg2050"),
	ModbusRegInfo(42051, "u16", "reg2051"),
	ModbusRegInfo(42052, "u16", "reg2052"),
	ModbusRegInfo(42053, "u16", "reg2053"),
	ModbusRegInfo(42054, "u16", "reg2054"),
	ModbusRegInfo(42055, "u16", "reg2055"),
	ModbusRegInfo(42056, "u16", "reg2056"),
	ModbusRegInfo(42057, "u16", "reg2057"),
	ModbusRegInfo(42058, "u16", "reg2058"),
	ModbusRegInfo(42059, "u16", "reg2059"),
	ModbusRegInfo(42060, "u16", "reg2060"),
	ModbusRegInfo(42061, "u16", "reg2061"),
	ModbusRegInfo(42062, "u16", "reg2062"),
	ModbusRegInfo(42063, "u16", "reg2063"),
	ModbusRegInfo(42064, "u16", "reg2064"),
	ModbusRegInfo(42065, "u16", "reg2065"),
	ModbusRegInfo(42066, "u16", "reg2066"),
	ModbusRegInfo(42067, "u16", "reg2067"),
	ModbusRegInfo(42068, "u16", "reg2068"),
	ModbusRegInfo(42069, "u16", "reg2069"),
	ModbusRegInfo(42070, "u16", "reg2070"),
	ModbusRegInfo(42071, "u16", "reg2071"),
	ModbusRegInfo(42072, "u16", "reg2072"),
	ModbusRegInfo(42073, "u16", "reg2073"),
	ModbusRegInfo(42074, "u16", "reg2074"),
	ModbusRegInfo(42075, "u16", "reg2075"),
	ModbusRegInfo(42076, "u16", "reg2076"),
	ModbusRegInfo(42077, "u16", "reg2077"),
	ModbusRegInfo(42078, "u16", "reg2078"),
	ModbusRegInfo(42079, "u16", "reg2079"),
	ModbusRegInfo(42080, "u16", "reg2080"),
	ModbusRegInfo(42081, "u16", "reg2081"),
	ModbusRegInfo(42082, "u16", "reg2082"),
	ModbusRegInfo(42083, "u16", "reg2083"),
	ModbusRegInfo(42084, "u16", "reg2084"),
	ModbusRegInfo(42085, "u16", "reg2085"),
	ModbusRegInfo(42086, "u16", "reg2086"),
	ModbusRegInfo(42087, "u16", "reg2087"),
	ModbusRegInfo(42088, "u16", "reg2088"),
	ModbusRegInfo(42089, "u16", "reg2089"),
	ModbusRegInfo(42090, "u16", "reg2090"),
	ModbusRegInfo(42091, "u16", "reg2091"),
	ModbusRegInfo(42092, "u16", "reg2092"),
	ModbusRegInfo(42093, "u16", "reg2093"),
	ModbusRegInfo(42094, "u16", "reg2094"),
	ModbusRegInfo(42095, "u16", "reg2095"),
	ModbusRegInfo(42096, "u16", "reg2096"),
	ModbusRegInfo(42097, "u16", "reg2097"),
	ModbusRegInfo(42098, "u16", "reg2098"),
	ModbusRegInfo(42099, "u16", "reg2099"),
	ModbusRegInfo(42100, "u16", "reg2100"),
	ModbusRegInfo(42101, "u16", "reg2101"),
	ModbusRegInfo(42102, "u16", "reg2102"),
	ModbusRegInfo(42103, "u16", "reg2103"),
	ModbusRegInfo(42104, "u16", "reg2104"),
	ModbusRegInfo(42105, "u16", "reg2105"),
	ModbusRegInfo(42106, "u16", "reg2106"),
	ModbusRegInfo(42107, "u16", "reg2107"),
	ModbusRegInfo(42108, "u16", "reg2108"),
	ModbusRegInfo(42109, "u16", "reg2109"),
	ModbusRegInfo(42110, "u16", "reg2110"),
	ModbusRegInfo(42111, "u16", "reg2111"),
	ModbusRegInfo(42112, "u16", "reg2112"),
	ModbusRegInfo(42113, "u16", "reg2113"),
	ModbusRegInfo(42114, "u16", "reg2114"),
	ModbusRegInfo(42115, "u16", "reg2115"),
	ModbusRegInfo(42116, "u16", "reg2116"),
	ModbusRegInfo(42117, "u16", "reg2117"),
	ModbusRegInfo(42118, "u16", "reg2118"),
	ModbusRegInfo(42119, "u16", "reg2119"),
	ModbusRegInfo(42120, "u16", "reg2120"),
	ModbusRegInfo(42121, "u16", "reg2121"),
	ModbusRegInfo(42122, "u16", "reg2122"),
	ModbusRegInfo(42123, "u16", "reg2123"),
	ModbusRegInfo(42124, "u16", "reg2124"),
	ModbusRegInfo(42125, "u16", "reg2125"),
	ModbusRegInfo(42126, "u16", "reg2126"),
	ModbusRegInfo(42127, "u16", "reg2127"),
	ModbusRegInfo(42128, "u16", "reg2128"),
	ModbusRegInfo(42129, "u16", "reg2129"),
	ModbusRegInfo(42130, "u16", "reg2130"),
	ModbusRegInfo(42131, "u16", "reg2131"),
	ModbusRegInfo(42132, "u16", "reg2132"),
	ModbusRegInfo(42133, "u16", "reg2133"),
	ModbusRegInfo(42134, "u16", "reg2134"),
	ModbusRegInfo(42135, "u16", "reg2135"),
	ModbusRegInfo(42136, "u16", "reg2136"),
	ModbusRegInfo(42137, "u16", "reg2137"),
	ModbusRegInfo(42138, "u16", "reg2138"),
	ModbusRegInfo(42139, "u16", "reg2139"),
	ModbusRegInfo(42140, "u16", "reg2140"),
	ModbusRegInfo(42141, "u16", "reg2141"),
	ModbusRegInfo(42142, "u16", "reg2142"),
	ModbusRegInfo(42143, "u16", "reg2143"),
+/
	ModbusRegInfo(42151, "u16", "reg2151"),

	ModbusRegInfo(50400, "u16", "reg10400"),
	ModbusRegInfo(50401, "u16", "reg10401"),
	ModbusRegInfo(50402, "u16", "reg10402"),
	ModbusRegInfo(50403, "u16", "reg10403"),
	ModbusRegInfo(50404, "u16", "reg10404"),
	ModbusRegInfo(50405, "u16", "reg10405"),
	ModbusRegInfo(50406, "u16", "reg10406"),
	ModbusRegInfo(50407, "u16", "reg10407"),
	ModbusRegInfo(50408, "u16", "reg10408"),
	ModbusRegInfo(50409, "u16", "reg10409"),
	ModbusRegInfo(50410, "u16", "reg10410"),
	ModbusRegInfo(50411, "u16", "reg10411"),
	ModbusRegInfo(50412, "u16", "reg10412"),
	ModbusRegInfo(50413, "u16", "reg10413"),
	ModbusRegInfo(50414, "u16", "reg10414"),
	ModbusRegInfo(50415, "u16", "reg10415"),
	ModbusRegInfo(50416, "u16", "reg10416"),
	ModbusRegInfo(50417, "u16", "reg10417"),
	ModbusRegInfo(50418, "i32", "reg10418"),
	ModbusRegInfo(50420, "u16", "reg10420"),
	ModbusRegInfo(50421, "u16", "reg10421"),
	ModbusRegInfo(50422, "u16", "reg10422"),
	ModbusRegInfo(50423, "u16", "reg10423"),
	ModbusRegInfo(50424, "u16", "reg10424"),
	ModbusRegInfo(50425, "u16", "reg10425"),
	ModbusRegInfo(50426, "u16", "reg10426"),
	ModbusRegInfo(50427, "u16", "reg10427"),
	ModbusRegInfo(50428, "u16", "reg10428"),
	ModbusRegInfo(50429, "u16", "reg10429"),
	ModbusRegInfo(50430, "u16", "reg10430"),
	ModbusRegInfo(50431, "u16", "reg10431"),
	ModbusRegInfo(50432, "u16", "reg10432"),
	ModbusRegInfo(50433, "u16", "reg10433"),
	ModbusRegInfo(50434, "u16", "reg10434"),
	ModbusRegInfo(50435, "u16", "reg10435"),
	ModbusRegInfo(50436, "u16", "reg10436"),
	ModbusRegInfo(50437, "u16", "reg10437"),
	ModbusRegInfo(50438, "u16", "reg10438"),
	ModbusRegInfo(50439, "u16", "reg10439"),

	ModbusRegInfo(50470, "u16", "reg10470"),
	ModbusRegInfo(50471, "u16", "reg10471"),
	ModbusRegInfo(50472, "u16", "reg10472"),
	ModbusRegInfo(50473, "u16", "reg10473"),
	ModbusRegInfo(50474, "u16", "reg10474"),
	ModbusRegInfo(50475, "u16", "reg10475"),
	ModbusRegInfo(50476, "u16", "reg10476"),
	ModbusRegInfo(50477, "u16", "reg10477"),
	ModbusRegInfo(50478, "u16", "reg10478"),
	ModbusRegInfo(50479, "u16", "reg10479"),
/+
	ModbusRegInfo(50600, "u16", "reg10600"),
	ModbusRegInfo(50601, "u16", "reg10601"),
	ModbusRegInfo(50602, "u16", "reg10602"),
	ModbusRegInfo(50603, "u16", "reg10603"),
	ModbusRegInfo(50604, "u16", "reg10604"),
	ModbusRegInfo(50605, "u16", "reg10605"),
	ModbusRegInfo(50606, "u16", "reg10606"),
	ModbusRegInfo(50607, "u16", "reg10607"),
	ModbusRegInfo(50608, "u16", "reg10608"),
	ModbusRegInfo(50609, "u16", "reg10609"),
	ModbusRegInfo(50610, "u16", "reg10610"),
	ModbusRegInfo(50611, "u16", "reg10611"),
	ModbusRegInfo(50612, "u16", "reg10612"),
	ModbusRegInfo(50613, "u16", "reg10613"),
	ModbusRegInfo(50614, "u16", "reg10614"),
	ModbusRegInfo(50615, "u16", "reg10615"),
	ModbusRegInfo(50616, "u16", "reg10616"),
	ModbusRegInfo(50617, "u16", "reg10617"),
	ModbusRegInfo(50618, "u16", "reg10618"),
	ModbusRegInfo(50619, "u16", "reg10619"),
	ModbusRegInfo(50620, "u16", "reg10620"),

	ModbusRegInfo(50669, "u16", "reg10669"),
	ModbusRegInfo(50670, "u16", "reg10670"),
	ModbusRegInfo(50671, "u16", "reg10671"),
	ModbusRegInfo(50672, "u16", "reg10672"),
	ModbusRegInfo(50673, "u16", "reg10673"),
	ModbusRegInfo(50674, "u16", "reg10674"),
	ModbusRegInfo(50675, "u16", "reg10675"),
	ModbusRegInfo(50676, "u16", "reg10676"),
	ModbusRegInfo(50677, "u16", "reg10677"),
	ModbusRegInfo(50678, "u16", "reg10678"),
	ModbusRegInfo(50679, "u16", "reg10679"),
	ModbusRegInfo(50680, "u16", "reg10680"),
	ModbusRegInfo(50681, "u16", "reg10681"),
	ModbusRegInfo(50682, "u16", "reg10682"),
	ModbusRegInfo(50683, "u16", "reg10683"),
	ModbusRegInfo(50684, "u16", "reg10684"),
	ModbusRegInfo(50685, "u16", "reg10685"),
	ModbusRegInfo(50686, "u16", "reg10686"),
	ModbusRegInfo(50687, "u16", "reg10687"),
	ModbusRegInfo(50688, "u16", "reg10688"),
	ModbusRegInfo(50689, "u16", "reg10689"),
	ModbusRegInfo(50690, "u16", "reg10690"),
	ModbusRegInfo(50691, "u16", "reg10691"),
	ModbusRegInfo(50692, "u16", "reg10692"),
	ModbusRegInfo(50693, "u16", "reg10693"),
	ModbusRegInfo(50694, "u16", "reg10694"),
+/

//	ModbusRegInfo(5, "u16", "reg"),
//	ModbusRegInfo(5, "u16", "reg"),
//	ModbusRegInfo(5, "u16", "reg"),
//	ModbusRegInfo(5, "u16", "reg"),
//	ModbusRegInfo(5, "u16", "reg"),
//	ModbusRegInfo(5, "u16", "reg"),
//	ModbusRegInfo(5, "u16", "reg"),
//	ModbusRegInfo(5, "u16", "reg"),
];

}

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
