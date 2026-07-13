module manager.syslog;

import urt.log;
import urt.mem.temp : tconcat;
import urt.string : contains;
import urt.time;

nothrow @nogc:


// A LogMessage maps onto the 5424 header as:
// hostname -> HOSTNAME, tag -> APP-NAME, object_name -> PROCID, timestamp -> TIMESTAMP (RFC3339), severity -> PRI.
// Syslog severity is 0..7 with `trace` being mapped as 7 (debug) + `[trace]` in structured data.

const(char)[] format_syslog(ref const LogMessage msg)
{
    uint pri = syslog_facility * 8 + to_syslog_severity(msg.severity);
    const(char)[] host = msg.hostname.length ? msg.hostname : "-";
    const(char)[] app  = msg.tag.length ? msg.tag : "-";
    const(char)[] proc = msg.object_name.length ? msg.object_name : "-";
    const(char)[] ts   = msg.timestamp.ticks ? tconcat(msg.timestamp)[] : "-";

    return tconcat("<", pri, ">1 ", ts, ' ', host, ' ', app, ' ', proc, msg.severity == Severity.trace ? " - [trace] " : " - - ", msg.message)[];
}

// Parses our own emission shape. Fields alias into `line`, so the LogMessage is
// only valid while `line` lives; copy anything retained past that (the sink
// fan-out consumes it synchronously, so re-injection is safe).
bool parse_syslog(const(char)[] line, out LogMessage msg)
{
    if (line.length < 3 || line[0] != '<')
        return false;

    size_t i = 1;
    uint pri = 0;
    while (i < line.length && line[i] >= '0' && line[i] <= '9')
        pri = pri * 10 + (line[i++] - '0');
    if (i >= line.length || line[i] != '>')
        return false;

    // VERSION + 6 SP-delimited header fields (TS HOST APP PROCID MSGID SD), then MSG.
    const(char)[] rest = line[i + 1 .. $];
    const(char)[][7] fields;
    size_t fi = 0;
    size_t start = 0;
    for (size_t j = 0; j < rest.length && fi < 7; ++j)
    {
        if (rest[j] == ' ')
        {
            fields[fi++] = rest[start .. j];
            start = j + 1;
        }
    }
    if (fi < 7)
        return false;

    msg.severity = from_syslog_severity(pri);
    msg.hostname = is_nil(fields[2]) ? null : fields[2];
    msg.tag = is_nil(fields[3]) ? null : fields[3];
    msg.object_name = is_nil(fields[4]) ? null : fields[4];
    if (!is_nil(fields[1]))
    {
        SysTime t;
        if (t.fromString(fields[1]) >= 0)
            msg.timestamp = t;
    }
    if (!is_nil(fields[6]) && fields[6].contains("[trace]"))
        msg.severity = Severity.trace;
    msg.message = rest[start .. $];
    return true;
}


private:

enum uint syslog_facility = 1; // user-level messages

uint to_syslog_severity(Severity s)
    => s >= Severity.trace ? Severity.debug_ : cast(uint)s;

Severity from_syslog_severity(uint pri)
    => cast(Severity)(pri & 7);

bool is_nil(const(char)[] field)
    => field.length == 1 && field[0] == '-';
