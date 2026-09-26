module driver.ethernet;

// Platform-selected ethernet driver backend(s). manager.plugin registers
// `driver.ethernet` and the version ladder here resolves to the right
// concrete *Module class. Add entries below as new backends land
// (driver/posix/ethernet.d, driver/baremetal/ethernet.d, ...).
// SFPPort is the platform's /interface/sfp class: a port on its MAC where it drives one.

import router.iface.sfp : SFPInterface;

version (Windows)
{
    import driver.windows.ethernet;
    alias EthernetModule = WindowsPcapEthernetModule;
    alias SFPPort = SFPInterface;
}
else version (linux)
{
    import driver.linux.ethernet;
    alias EthernetModule = LinuxRawEthernetModule;
    alias SFPPort = SFPInterface;
}
else
{
    import urt.driver.ethernet : num_ethernet;
    static if (num_ethernet > 0)
    {
        import driver.baremetal.ethernet;
        import driver.baremetal.sfp : BuiltinSFP;
        alias EthernetModule = BuiltinEthernetModule;
        alias SFPPort = BuiltinSFP;
    }
    else
        alias SFPPort = SFPInterface;
}
