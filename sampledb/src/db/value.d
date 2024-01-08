module db.value;

struct ValueDesc
{
	enum Usage
	{
		Unknown,
		Voltage,
		Current,
		Power,
		Energy,
        PowerFactor,
		SOC, // state of charge
		SOH, // state of health
	}
	enum Unit
	{
        Bool,
        Integer,
        Float,
        String,
        Percentage,
		Volts,
		Amps,
		Watts,
		WattHours,
	}

	Usage usage;
	int usageIndex;
	Unit unit;
	string name;
	string description;
}

