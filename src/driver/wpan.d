module driver.wpan;

import urt.driver.wpan : num_wpan;

// Platform-selected 802.15.4 radio backend. manager.plugin registers
// `driver.wpan` and the alias here resolves to the concrete *Module class.

static if (num_wpan > 0)
{
    import driver.baremetal.wpan;
    alias WpanModule = BuiltinWpanModule;
}
