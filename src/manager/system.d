module manager.system;

import urt.log;
import urt.mem.allocator;
import urt.string;

import manager.console.session;

nothrow @nogc:


String hostname = StringLit!("enms"); // TODO: we need to make this thing...


void log_level(Session session, Level level)
{
    logLevel = level;
}

void set_hostname(Session session, const(char)[] hostname)
{
    .hostname = hostname.makeString(defaultAllocator());
}
