module driver.ethernet;

// Platform-selected ethernet driver backend(s). manager.plugin registers
// `driver.ethernet` and the version ladder here resolves to the right
// concrete *Module class. Add entries below as new backends land
// (driver/posix/ethernet.d, driver/baremetal/ethernet.d, ...).

version (Windows)
{
    import driver.windows.ethernet;
    alias EthernetModule = WindowsPcapEthernetModule;
}
else version (linux)
{
    import driver.linux.ethernet;
    alias EthernetModule = LinuxRawEthernetModule;
}
else
{
    import urt.driver.ethernet : num_ethernet;
    static if (num_ethernet > 0)
    {
        import driver.baremetal.ethernet;
        alias EthernetModule = BuiltinEthernetModule;
    }
}
