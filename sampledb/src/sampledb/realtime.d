module sampledb.realtime;

import std.datetime : Date, DateTime;

struct RealTime
{
	ushort hundredthSecond;
	ushort minute;
	ushort day;
	ushort year;

	void Set(Date date)
	{
		hundredthSecond = 0;
		minute = 0;
		day = date.dayOfYear;
		year = date.year;
	}
	void Set(DateTime date)
	{
		hundredthSecond = date.second*100;
		minute = date.hour*60 + date.minute;
		day = date.dayOfYear;
		year = date.year;
	}

	void AddTicks(int ticks)
	{
		hundredthSecond += ticks;
		// TODO: not work for negative hundredthSecond...
		int minutes = hundredthSecond / 6000;
		if (minutes != 0)
		{
			hundredthSecond %= 6000;
			AddMinutes(minutes);
		}
	}
	void AddSeconds(int seconds)
	{
		hundredthSecond += seconds * 100;
		// TODO: not work for negative hundredthSecond...
		int minutes = hundredthSecond / 6000;
		if (minutes != 0)
		{
			hundredthSecond %= 6000;
			AddMinutes(minutes);
		}
	}
	void AddMinutes(int minutes)
	{
		minute += minutes;
		// TODO: not work for negative minute...
		int days = minute / (60*60*24);
		if (days != 0)
		{
			minutes %= 60*60*24;
			AddDays(days);
		}
	}
	void AddDays(int days)
	{
		day += days;
		do
		{
			// TODO: not work for negative day...
			const isLeapYear = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
			const daysInYear = isLeapYear ? 366 : 365;
			if (day >= daysInYear)
			{
				++year;
				day -= daysInYear;
			}
			else
				break;
		} while (1);
	}
	void AddYears(int years)
	{
		year += years;
		const isLeapYear = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
		if (!isLeapYear && day == 366)
		{
			++year;
			day = 0;
		}
	}

	static immutable RealTime min = RealTime(0, 0, 0, 0);
	static immutable RealTime max = RealTime(5999, 1439, 364, 65535);
}
