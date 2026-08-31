module manager.features;

// Feature gating booleans. Default is "everything on" so fresh builds,
// IDE/IDE-launched builds (Visual Studio), and tools that don't go
// through features.mk get a full standalone build. To drop a feature,
// pass -version=NoSwitch / NoAll / NoIP / NoTLS / NoHTTP / NoIPv6 /
// NoGateway.
//
// The has_* enums let code compose features with static if -- D's
// version (...) clause is non-composable.

nothrow @nogc:

version (NoSwitch) enum has_switch = false; else enum has_switch = true;
version (NoAll)    enum has_all    = false; else enum has_all    = true;
version (NoIP)     enum has_ip     = false; else enum has_ip     = true;
version (NoTLS)    enum has_tls    = false; else enum has_tls    = true;
version (NoHTTP)   enum has_http   = false; else enum has_http   = true;
version (NoECSecret) enum has_ec_secret = false; else enum has_ec_secret = true;
version (NoHTTPClient) enum has_http_client = false; else enum has_http_client = true;
version (NoHTTPFileServer) enum has_http_file_server = false; else enum has_http_file_server = true;
version (NoModbus) enum has_modbus = false; else enum has_modbus = true;
version (NoIPv6)   enum has_ipv6   = false; else enum has_ipv6 = has_ip;
version (NoGateway) enum has_gateway = false; else enum has_gateway = true;
version (HasAPI)   enum has_api    = true; else version (NoAll) enum has_api = false; else enum has_api = true;
version (HasOTA)   enum has_ota    = true; else version (NoAll) enum has_ota = false; else enum has_ota = true;

version (Headless) enum is_headless = true; else enum is_headless = false;
version (Tiny)     enum is_tiny     = true; else enum is_tiny     = false;
