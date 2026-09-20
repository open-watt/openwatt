module driver.can;

// Platform-selected CAN driver backend(s). manager.plugin registers `driver.can`
// and the version ladder here resolves to the right concrete *Module class.
//
// Espressif's on-chip TWAI controller needs no discovery module: it is a fixed
// peripheral addressed as `adapter=twaiN` straight through urt.driver.can.

version (linux)
{
    import driver.linux.can;
    alias CANDriverModule = LinuxSocketCANModule;
}
