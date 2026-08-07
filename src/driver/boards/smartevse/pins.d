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

enum uint LCD_CLK = 26;
enum uint LCD_MOSI = 33;
enum uint LCD_A0 = 25;
enum uint LCD_RST = 5;
enum uint LCD_LED = 14;

enum uint BUTTON_LEFT = 0;
enum uint BUTTON_MIDDLE = LCD_A0;
enum uint BUTTON_RIGHT = LCD_MOSI;
}
else
    static assert(false, "SmartEVSE hardware version is not selected");
