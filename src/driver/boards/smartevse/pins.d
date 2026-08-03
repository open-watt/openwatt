// SmartEVSE board pin map, split from evse.d so hardware.d can bind reflex
// links at compile time (NMI task masks are immediates baked into the
// synthesized handler; runtime config cannot reach them).
module driver.boards.smartevse.pins;

version (SmartEVSE):

nothrow @nogc:

version (SmartEVSE_v30)
{
enum uint PP_IN = 34;
enum uint CP_IN = 39;
enum uint TEMP = 36;
enum uint SSR1 = 32;
enum uint SSR2 = 27;
enum uint RCMFAULT = 13;
enum uint CP_OUT = 19;
enum uint CPOFF = 15;
}
else
    static assert(false, "SmartEVSE hardware version is not selected");
