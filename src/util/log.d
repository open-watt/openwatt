module util.log;

import std.stdio;
import std.format;

enum Level
{
	Error = 0,
	Warning,
	Info,
	Debug
}

immutable string[] levelNames = [ "Error", "Warning", "Info", "Debug" ];

__gshared Level logLevel = Level.Info;

void writeDebug(T...)(T things) { writeLog(Level.Debug, things); }
void writeInfo(T...)(T things) { writeLog(Level.Info, things); }
void writeWarning(T...)(T things) { writeLog(Level.Warning, things); }
void writeError(T...)(T things) { writeLog(Level.Error, things); }

void writeDebugf(T...)(string format, T things) { writeLogf(Level.Debug, format, things); }
void writeInfof(T...)(string format, T things) { writeLogf(Level.Info, format, things); }
void writeWarningf(T...)(string format, T things) { writeLogf(Level.Warning, format, things); }
void writeErrorf(T...)(string format, T things) { writeLogf(Level.Error, format, things); }

void writeLog(T...)(Level level, T things)
{
	if (level > logLevel)
		return;
	writeln(levelNames[level], ": ", things);
}

void writeLogf(T...)(Level level, string format, T things)
{
	if (level > logLevel)
		return;
	format("%s: " ~ format, levelNames[level], things).writeln;
}
