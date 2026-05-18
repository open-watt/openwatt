module manager.features;

// Feature gating booleans. Default is "everything on" so fresh builds,
// IDE/IDE-launched builds (Visual Studio), and tools that don't go
// through features.mk get a full standalone build. To drop a feature,
// pass -version=NoSwitch / NoAll / NoIP / NoTLS / NoHTTP.
//
// The has_* enums let code compose features with static if -- D's
// version (...) clause is non-composable.

nothrow @nogc:

version (NoSwitch) enum has_switch = false; else enum has_switch = true;
version (NoAll)    enum has_all    = false; else enum has_all    = true;
version (NoIP)     enum has_ip     = false; else enum has_ip     = true;
version (NoTLS)    enum has_tls    = false; else enum has_tls    = true;
version (NoHTTP)   enum has_http   = false; else enum has_http   = true;

version (Headless) enum is_headless = true; else enum is_headless = false;
version (Tiny)     enum is_tiny     = true; else enum is_tiny     = false;
