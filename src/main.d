module main;

import urt.io;
import urt.log;
import urt.mem.string;
import urt.string;
import urt.string.format;
import urt.system;
import urt.time;

import manager;
import manager.component;
import manager.console.session;
import manager.config;
import manager.device;
import manager.element;
import manager.units;

import protocol.mqtt.broker;

import router.modbus.coding;
import router.modbus.message;
import router.modbus.profile;
import router.stream;


void main()
{
    // init the string heap with 1mb!
//    initStringHeap(1024*1024); // TODO: uncomment when remove the module constructor...

    // TODO: prime the string cache with common strings, like unit names and common variable names
    //       the idea is to make dedup lookups much faster...

    Application app = createApplication();

    // execute startup script
    const(char)[] conf;
    try
    {
        import urt.file : load_file;
        conf = cast(char[])"conf/startup.conf".load_file();
    }
    catch (Exception e)
    {
        // TODO: warn user that can't load profile...
        assert(false);
    }
    ConsoleSession s = new ConsoleSession(g_app.console);
    s.setInput(conf);

    // stop the computer from sleeping while this application is running...
    setSystemIdleParams(IdleParams.SystemRequired);

    /+
-    35000 - 33  Device infio
-    37000 - 15  BMS info
-    47504 - 11  Export power control
-    37060 - 16  Battery SN
-    write multiple: 45200 - 3 [6148, 1550, 8461]  UPDATE THE CLOCK
    47504 - 11
-    47595 - 3   Load switch settings
    35000 - 33
-    35100 - 125 Inverter running data
-    36000 - 27  Meter data
    37000 - 15
    37060 - 16
-    45248 - 7   Some operating params
-    36043 - 6   Meter sub-data
-    47745 - 18  UNKNOWN
-    36197 - 1   UNKNOWN
-    47001 - 2   Meter check...
-    47000 - 1   Operating mode
-    45350 - 9   Battery charge.discharge protection params
-    35365 - 1   No idea; near some meter energy stats
    47504 - 11
    35000 - 33
    35100 - 125
    36000 - 27
    37000 - 15
    37060 - 16
    45248 - 7
    36043 - 6
    47745 - 18
    47595 - 3
    36197 - 1
    47001 - 2
    47000 - 1
    45350 - 9
    35365 - 1
    47504 - 11
    35000 - 33
    35100 - 125
    36000 - 27
    37000 - 15
    37060 - 16
    +/


    int i = 0;
    while (true)
    {
        g_app.update();

        // Process program logic
        // ...

        sleep(msecs(1));
    }

    shutdownApplication();
}
