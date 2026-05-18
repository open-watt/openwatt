module manager.features;

// Single conversion site from Makefile `-version=Feature_*` flags into
// `enum has_*` booleans, so the rest of the codebase can compose them
// with `static if (has_switch || has_x)` -- D's `version (...)` does not
// support boolean composition.
//
// Driven by features.mk; orthogonal to Tiny (size) and Embedded (OS).

nothrow @nogc:

version (Feature_Switch) enum has_switch  = true; else enum has_switch  = false;
version (Feature_All)    enum has_all     = true; else enum has_all     = false;
version (Feature_IP)     enum has_ip      = true; else enum has_ip      = false;
version (Feature_TLS)    enum has_tls     = true; else enum has_tls     = false;
version (Feature_HTTP)   enum has_http    = true; else enum has_http    = false;

version (Headless)       enum is_headless = true; else enum is_headless = false;
version (Tiny)           enum is_tiny     = true; else enum is_tiny     = false;
