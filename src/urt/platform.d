module urt.platform;


// TODO: I'd like to wrangle some sort of 64bit version...


// Apply stuff is all separated... but a general Darwin would be nice
version (OSX)
    version = Darwin;
version (iOS)
    version = Darwin;
version (tvOS)
    version = Darwin;
version (watchOS)
    version = Darwin;
version (visionOS)
    version = Darwin;


version (Windows)
    enum string Platform = "Windows";
else version (linux)
    enum string Platform = "Linux";
else version (Darwin)
    enum string Platform = "Darwin";
else version (FreeBSD)
    enum string Platform = "FreeBSD";
else version (FreeStanding)
    enum string Platform = "Bare-metal";
else
    static assert(0, "Unsupported platform");
