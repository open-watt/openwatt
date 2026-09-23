module driver.can;

version (linux)
{
    import driver.linux.can;
    alias CANDriverModule = LinuxSocketCANModule;
}
