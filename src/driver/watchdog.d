module driver.watchdog;

version (Windows)        version = SoftwareWatchdog;
else version (linux)     version = SoftwareWatchdog;
else version (Espressif) public import driver.esp32.watchdog;
else                     public import driver.baremetal.watchdog;

version (SoftwareWatchdog):

import urt.atomic;
import urt.system : abort, sleep;
import urt.thread;
import urt.time;

version (linux) import driver.linux.system : supervisor_attach, supervisor_heartbeat;

nothrow @nogc:


private shared uint _last_feed;
private __gshared uint _timeout_ms;
private __gshared MonoTime _start;
private shared bool _running;
private __gshared Thread _thread;
private __gshared void delegate() nothrow @nogc _request_feed;

private uint elapsed_ms()
    => cast(uint)((getTime() - _start).as!"msecs");

void watchdog_init(Duration timeout)
{
    version (linux)
        supervisor_attach();

    // skipped in debug builds so a paused debugger doesn't trip the stall timeout
    debug {} else
    {
        if (_thread)
            return;
        _timeout_ms = cast(uint)timeout.as!"msecs";
        _start = getTime();
        atomicStore(_last_feed, 0u);
        atomicStore(_running, true);
        _thread = thread_spawn(() { monitor(); });
    }
}

void watchdog_feed()
{
    atomicStore(_last_feed, elapsed_ms());
    version (linux)
        supervisor_heartbeat();
}

void watchdog_set_feed_request(void delegate() nothrow @nogc request)
{
    _request_feed = request;
}

void watchdog_stop()
{
    if (!_thread)
        return;
    atomicStore(_running, false);
    thread_join(_thread);
    _thread = null;
}

private void monitor()
{
    while (atomicLoad(_running))
    {
        sleep(1.seconds);
        if (_request_feed !is null)
            _request_feed();     // ask the main thread to feed itself, then check
        if (elapsed_ms() - atomicLoad(_last_feed) > _timeout_ms)
            abort();
    }
}
