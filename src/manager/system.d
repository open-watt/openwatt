module manager.system;

import urt.log;

import manager.console.session;

nothrow @nogc:


void log_level(Session session, Level level)
{
	logLevel = level;
}
