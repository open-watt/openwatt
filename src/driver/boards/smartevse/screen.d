// Board-internal status UI: renders hardware ground truth from evse.d state, so every page
// works whether or not the manager has claimed the hardware or loaded any configuration.
module driver.boards.smartevse.screen;

version (SmartEVSE):

import urt.inet : IPAddr;
import urt.string.format : tconcat;
import urt.system : get_cpu_load, get_sysinfo;
import urt.time : DateTime, MonoTime, getAppTime, getDateTime, getTime, msecs, seconds, wall_time_set;

import manager : g_app;

import router.iface.mac : MACAddress;

import driver.boards.smartevse.display;
import driver.boards.smartevse.evse;
import driver.font.render : text_width;
import driver.font.small : font_small_height;

nothrow @nogc:


enum ScreenLinkState : ubyte
{
    none,
    down,
    up,
}

struct ScreenNetworkInfo
{
    char[32] sta_ssid = '\0';
    char[32] ap_ssid = '\0';
    MACAddress sta_mac;
    MACAddress ap_mac;
    IPAddr sta_ip;
    IPAddr ap_ip;
    byte sta_rssi;
    ubyte channel;
    ubyte ap_clients;
    ubyte sta_ssid_len;
    ubyte ap_ssid_len;
    ScreenLinkState sta_state;
    ScreenLinkState ap_state;
}

__gshared SmartEVSEScreen g_screen;

struct SmartEVSEScreen
{
nothrow @nogc:
    void sample_tick(MonoTime now)
    {
        g_app.schedule(now + button_poll, &sample_tick);

        ubyte pressed = (~display_buttons(g_display)) & 0x7;
        ubyte went_down = pressed & ~buttons;
        buttons = pressed;
        if (went_down)
        {
            last_input = now;
            if (!display_backlight(g_display))
                display_backlight(g_display, true);     // waking the panel consumes the press
            else if (went_down & SmartEVSEButton.left)
                page = cast(ubyte)((page + screen_pages - 1) % screen_pages);
            else if (went_down & SmartEVSEButton.right)
                page = cast(ubyte)((page + 1) % screen_pages);
            else if (went_down & SmartEVSEButton.middle)
                page = 0;
            render_pending = true;
        }

        if (page != 0 && now - last_input > page_timeout)
        {
            page = 0;
            render_pending = true;
        }
        if (display_backlight(g_display) && now - last_input > backlight_timeout)
            display_backlight(g_display, false);

        if (render_pending || now - last_render >= refresh_period)
            render(now);
    }

package:
    ScreenNetworkInfo network;
    MonoTime last_input;
    MonoTime last_render;
    ubyte page;
    ubyte buttons;
    bool claimed;
    bool render_pending;
    bool active;
}


void screen_init()
{
    MonoTime now = getTime();
    g_screen.active = true;
    g_screen.page = 0;
    g_screen.buttons = 0;
    g_screen.last_input = now;
    g_screen.render_pending = true;
    g_app.schedule(now + button_poll, &g_screen.sample_tick);
}

void screen_close()
{
    if (!g_screen.active)
        return;
    g_screen.active = false;
    g_app.cancel(&g_screen.sample_tick);
}

// pressed-bit mask (SmartEVSEButton) from the most recent sample
ubyte screen_buttons()
    => g_screen.buttons;

void screen_set_claimed(bool claimed)
{
    if (g_screen.claimed == claimed)
        return;
    g_screen.claimed = claimed;
    g_screen.render_pending = true;
}

// EVSE state worth lighting the panel for changed (plug in/out, fault)
void screen_wake()
{
    g_screen.last_input = getTime();
    if (g_screen.active && !display_backlight(g_display))
        display_backlight(g_display, true);
    g_screen.render_pending = true;
}

void screen_notify()
{
    g_screen.render_pending = true;
}

void screen_set_network(ref const ScreenNetworkInfo info)
{
    if (g_screen.network == info)
        return;
    g_screen.network = info;
    if (g_screen.page == 1)
        g_screen.render_pending = true;
}


private:

enum screen_pages = 3;
enum button_poll = msecs(50);
enum refresh_period = seconds(1);
enum page_timeout = seconds(30);
enum backlight_timeout = seconds(300);

void render(MonoTime now)
{
    g_screen.last_render = now;
    g_screen.render_pending = false;
    if (!g_screen.active)
        return;

    g_display.back[] = 0;
    switch (g_screen.page)
    {
        case 1:  draw_network();     break;
        case 2:  draw_diagnostics(); break;
        default: draw_status();      break;
    }
    draw_footer();
    g_display.dirty = true;
}

void line(uint row, const(char)[] text)
{
    display_text(g_display, 0, row * font_small_height, text);
}

void header(const(char)[] title)
{
    line(0, title);
    const(char)[] marker = tconcat(g_screen.page + 1, '/', screen_pages);
    display_text(g_display, display_width - text_width(marker), 0, marker);
}

void draw_footer()
{
    char[8] clock = "--:--:--";
    if (wall_time_set())
    {
        DateTime now = getDateTime();
        clock[0] = char('0' + now.hour / 10);
        clock[1] = char('0' + now.hour % 10);
        clock[3] = char('0' + now.minute / 10);
        clock[4] = char('0' + now.minute % 10);
        clock[6] = char('0' + now.second / 10);
        clock[7] = char('0' + now.second % 10);
    }
    line(7, clock[]);

    const(char)[] uptime = tconcat(seconds(getAppTime().as!"seconds"));
    display_text(g_display, display_width - text_width(uptime), 7 * font_small_height, uptime);
}

const(char)[] deci_amps(uint deci)
    => tconcat(deci / 10, '.', deci % 10, 'A');

int temperature_c()
    => (cast(int)TemperatureVoltageMV - 500) / 10;

void draw_status()
{
    if (!g_screen.claimed)
    {
        header("SmartEVSE");
        line(2, "EVSE offline");
        if (g_screen.network.ap_state == ScreenLinkState.up)
        {
            line(4, tconcat("AP: ", g_screen.network.ap_ssid[0 .. g_screen.network.ap_ssid_len]));
            line(5, tconcat("http://", g_screen.network.ap_ip));
        }
        return;
    }

    const(char)[] title;
    switch (State)
    {
        case STATE_A:        title = AccessStatus ? "Ready" : "Stopped";   break;
        case STATE_B:        title = "Connected";                          break;
        case STATE_B1:       title = AccessStatus ? "Waiting" : "Stopped"; break;
        case STATE_C:        title = "Charging";                           break;
        case STATE_C1:       title = "Stopping";                           break;
        case STATE_ACTSTART: title = "Activating";                         break;
        case STATE_ERROR:    title = "FAULT";                              break;
        default:             title = "SmartEVSE";                          break;
    }
    header(title);

    line(2, tconcat("Set ", deci_amps(ChargeCurrent), "  Cable ", MaxCapacity, 'A'));
    if (State == STATE_C)
        line(3, tconcat("Offering ", deci_amps(GetCurrent())));
    line(4, tconcat("Temp ", temperature_c(), 'C'));

    if (RCMFault)
        line(6, "RCM FAULT LATCHED");
    else if (TemperatureFault)
        line(6, "OVER TEMPERATURE");
    else if (ChargeDelay)
        line(6, tconcat("retry in ", ChargeDelay, 's'));
}

void draw_network()
{
    header("Network");

    const ScreenNetworkInfo* n = &g_screen.network;
    if (n.sta_state == ScreenLinkState.none)
        line(1, "WiFi: not configured");
    else if (n.sta_state == ScreenLinkState.down)
        line(1, tconcat("WiFi ... ", n.sta_ssid[0 .. n.sta_ssid_len]));
    else
    {
        line(1, tconcat("WiFi ", n.sta_ssid[0 .. n.sta_ssid_len]));
        line(2, tconcat(' ', n.sta_ip));
        line(3, tconcat(' ', n.sta_rssi, "dBm  ch", n.channel));
    }

    if (n.ap_state != ScreenLinkState.none)
    {
        line(4, tconcat("AP ", n.ap_ssid[0 .. n.ap_ssid_len],
                        n.ap_state == ScreenLinkState.up ? "" : " (down)"));
        if (n.ap_state == ScreenLinkState.up)
            line(5, tconcat(' ', n.ap_ip, "  ", n.ap_clients, " sta"));
    }

    MACAddress mac = n.sta_state != ScreenLinkState.none ? n.sta_mac : n.ap_mac;
    if (mac != MACAddress())
        line(6, tconcat(mac));
}

void draw_diagnostics()
{
    header("Diagnostics");
    line(1, tconcat("CP ", PilotMinMV, '-', PilotMaxMV, "mV"));
    line(2, tconcat("PP ", PPVoltageMV, "mV  cable ", MaxCapacity, 'A'));
    line(3, tconcat("Temp ", TemperatureVoltageMV, "mV  ", temperature_c(), 'C'));
    line(4, tconcat("PWM ", CurrentPWM, "/1024"));
    if (ChargeDelay)
        line(5, tconcat("C1 ", Contactor1 ? "on" : "off", " C2 ", Contactor2 ? "on" : "off",
                        " Dly ", ChargeDelay, 's'));
    else
        line(5, tconcat("C1 ", Contactor1 ? "on" : "off", "  C2 ", Contactor2 ? "on" : "off"));

    auto info = get_sysinfo();
    line(6, tconcat("RAM ", info.pools[0].used >> 10, '/', info.pools[0].total >> 10,
                    "K CPU ", get_cpu_load(), '%'));
}
