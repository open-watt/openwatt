module urt.log;

import urt.io;

enum Level
{
    Error = 0,
    Warning,
    Info,
    Debug
}

immutable string[] levelNames = [ "Error", "Warning", "Info", "Debug" ];

__gshared Level logLevel = Level.Info;

void writeDebug(T...)(ref T things) { writeLog(Level.Debug, things); }
void writeInfo(T...)(ref T things) { writeLog(Level.Info, things); }
void writeWarning(T...)(ref T things) { writeLog(Level.Warning, things); }
void writeError(T...)(ref T things) { writeLog(Level.Error, things); }

void writeDebugf(T...)(const(char)[] format, ref T things) { writeLogf(Level.Debug, format, things); }
void writeInfof(T...)(const(char)[] format, ref T things) { writeLogf(Level.Info, format, things); }
void writeWarningf(T...)(const(char)[] format, ref T things) { writeLogf(Level.Warning, format, things); }
void writeErrorf(T...)(const(char)[] format, ref T things) { writeLogf(Level.Error, format, things); }

void writeLog(T...)(Level level, ref T things)
{
    if (level > logLevel)
        return;
    writeln(levelNames[level], ": ", things);
}

void writeLogf(T...)(Level level, const(char)[] format, ref T things)
{
    if (level > logLevel)
        return;
    writelnf("{-2}: {@-1}", things, levelNames[level], format);
}
