// ST7565 128x64 monochrome GLCD, write-only SPI: no MISO, no CS, A0 selects command vs data.
// The panel retains its own frame, so scan-out sends only spans that differ from front.
module driver.boards.smartevse.display;

version (SmartEVSE):

import urt.driver.gpio;
import urt.driver.spi;
import urt.result : InternalResult, Result;
import urt.time : Duration, MonoTime, getTime, msecs, usecs;

import manager : EventPriority, g_app;

import driver.boards.smartevse.pins;
import driver.font.render;
import driver.font.small;

nothrow @nogc:


enum uint display_width = 128;
enum uint display_height = 64;
enum uint display_pages = display_height / 8;

// = void: a plain global lands in .data and pays flash for 2KB of buffer image.
__gshared SmartEVSEDisplay g_display = void;

struct SmartEVSEDisplay
{
nothrow @nogc:
    void pump(MonoTime)
    {
        advance(this);
    }

package:
    SpiBus bus;
    SpiOperation operation;
    ubyte port;
    ubyte[display_width * display_pages] back = void;
    ubyte[display_width * display_pages] front = void;
    ubyte[3] command = void;
    uint page;
    uint run_start;
    uint run_length;
    ScanPhase phase;
    bool dirty;
    bool backlight;
}

Result display_open(ref SmartEVSEDisplay display, ubyte port = 0)
{
    gpio_output_init(LCD_LED, true);
    gpio_output_init(LCD_A0, false);
    gpio_output_init(LCD_RST, true);

    SpiBusConfig config;
    config.frequency = 10_000_000;
    config.mode = SpiMode.mode3;
    config.sck_gpio = LCD_CLK;
    config.mosi_gpio = LCD_MOSI;
    display.bus.port = ubyte.max;
    display.backlight = true;
    display.port = port;
    Result result = spi_open(display.bus, port, config);
    if (!result)
        return result;

    // upstream waits here before reset: transients on the line can leave the panel garbled
    spin(200.msecs);
    gpio_output_set(LCD_RST, false);
    spin(10.usecs);
    gpio_output_set(LCD_RST, true);
    spin(10.usecs);

    static immutable ubyte[] init_sequence = [
        0xA2,           // bias 1/9
        0xA0,           // SEG direction normal
        0xC8,           // COM direction reversed
        0x24,           // regulation ratio
        0xF8, 0x01,     // booster 5x
        0x81, 0x24,     // electronic volume
        0xA6,           // not inverted
        0xA4,           // all-pixel-on off
        0x2F,           // power control: all on
    ];
    foreach (ubyte value; init_sequence)
    {
        result = send_blocking(display, false, (&value)[0 .. 1]);
        if (!result)
            goto failed;
    }

    // the booster needs to come up before the display is enabled; upstream gets this gap for
    // free by clearing the panel here, but our clear happens asynchronously after 0xAF
    spin(50.msecs);
    static immutable ubyte[1] display_on = [0xAF];
    result = send_blocking(display, false, display_on[]);
    if (!result)
        goto failed;

    // front differs everywhere, so the first scan-out clears whatever the panel retained
    display.back[] = 0;
    display.front[] = 0xFF;
    display.dirty = true;
    display.page = 0;
    display.phase = ScanPhase.idle;
    return Result.success;

failed:
    display_close(display);
    return result;
}

void display_close(ref SmartEVSEDisplay display)
{
    quiesce(display);
    gpio_output_set(LCD_LED, false);
}

// pixels is one byte per pixel, row-major, non-zero for a lit pixel.
void display_blit(ref SmartEVSEDisplay display, uint x, uint y, uint width, uint height, const(ubyte)[] pixels)
{
    if (x >= display_width || y >= display_height || width == 0 || height == 0)
        return;
    if (pixels.length < width * height)
        return;

    uint columns = width < display_width - x ? width : display_width - x;
    uint rows = height < display_height - y ? height : display_height - y;

    foreach (row; 0 .. rows)
    {
        uint target = y + row;
        uint offset = (target >> 3) * display_width + x;
        ubyte mask = 1 << (target & 7);
        const(ubyte)[] source = pixels[row * width .. row * width + columns];
        foreach (column, value; source)
        {
            if (value)
                display.back[offset + column] |= mask;
            else
                display.back[offset + column] &= ~mask;
        }
    }

    display.dirty = true;
}

void display_update(ref SmartEVSEDisplay display)
{
    advance(display);
}

// Upstream's encoding: a set bit means released, so an idle panel reads 0x7.
ubyte display_buttons(ref SmartEVSEDisplay display)
{
    if (display.phase != ScanPhase.idle || display.operation.is_pending)
        return 0x7;
    if (!spi_suspend(display.bus))
        return 0x7;

    gpio_input_init(BUTTON_RIGHT);
    gpio_input_init(BUTTON_MIDDLE);
    gpio_input_init(BUTTON_LEFT);

    ubyte state = (gpio_input_read(BUTTON_RIGHT) ? 4 : 0) |
                  (gpio_input_read(BUTTON_MIDDLE) ? 2 : 0) |
                  (gpio_input_read(BUTTON_LEFT) ? 1 : 0);

    gpio_output_init(LCD_A0, false);
    spi_resume(display.bus);
    return state;
}

void display_backlight(ref SmartEVSEDisplay display, bool on)
{
    display.backlight = on;
    gpio_output_set(LCD_LED, on);
}

bool display_backlight(ref const SmartEVSEDisplay display) pure
    => display.backlight;

// what the panel is showing, not what is queued: front trails back by at most one scan-out
const(ubyte)[] display_frame(ref const SmartEVSEDisplay display) pure
    => display.front[];

bool display_frame(ref SmartEVSEDisplay display, const(void)[] frame)
{
    if (frame.length != display.back.length)
        return false;
    display.back[] = cast(const(ubyte)[])frame;
    display.dirty = true;
    return true;
}

uint display_glyph(ref SmartEVSEDisplay display, uint x, uint y, wchar c)
{
    uint width = draw_glyph(display.back[], display_width, display_pages, x, y, c);
    display.dirty = true;
    return width;
}

size_t display_text(ref SmartEVSEDisplay display, uint x, uint y, const(char)[] text,
                    uint max_width = display_width)
{
    size_t resume = draw_text(display.back[], display_width, display_pages, x, y, text, max_width);
    display.dirty = true;
    return resume;
}


// --- bring-up test surface; remove once the panel is working -------------------

// Every glyph the font holds, so a glance at the panel says whether the tables,
// the run-length decode and the page arithmetic all survived the trip to hardware.
void display_font_test(ref SmartEVSEDisplay display)
{
    display.back[] = 0;

    uint x = 0, y = 0;
    void place(wchar c)
    {
        uint w = font_small_width_of(c);
        if (x + w > display_width)
        {
            x = 0;
            y += font_small_height;
        }
        if (y + font_small_height > display_height)
            return;
        x += display_glyph(display, x, y, c) + font_small_gap;
    }

    for (wchar c = font_small_first; c < 0x7F; ++c)
        place(c);
    foreach (wchar c; font_small_extra)
        place(c);

    x = 0;
    y = display_height - font_small_height * 2;
    display_text(display, x, y, "Charging 32.5±0.1A");
    display_text(display, x, y + font_small_height, "☀ 16A ⚡ 40°C ✓");
    display.dirty = true;
}


// Reads the LCD pins back as inputs; says whether anything external is driving them.
uint display_probe_pins(ref SmartEVSEDisplay display)
{
    if (!quiesce(display))
        return uint.max;
    static immutable ubyte[5] pins = [LCD_CLK, LCD_MOSI, LCD_A0, LCD_RST, LCD_LED];
    uint levels;
    foreach (i, pin; pins)
    {
        gpio_input_init(pin);
        if (gpio_input_read(pin))
            levels |= 1 << i;
    }
    return levels;
}

// Pushes an arbitrary byte sequence through the peripheral, as commands (A0=0) or data (A0=1).
bool display_transfer(ref SmartEVSEDisplay display, bool data, const(ubyte)[] bytes)
{
    if (bytes.length == 0 || !wait_idle(display))
        return false;
    display.phase = ScanPhase.idle;
    return send_blocking(display, data, bytes) == Result.success;
}

Result display_reinit(ref SmartEVSEDisplay display, ubyte port)
{
    if (!quiesce(display))
        return InternalResult.timeout;
    return display_open(display, port);
}

// Drives the panel with the pins as plain GPIOs, bypassing the SPI peripheral and DMA
// entirely. If the glass responds to this but not to the peripheral, the fault is the
// peripheral's routing rather than the wiring or the panel.
bool display_bitbang(ref SmartEVSEDisplay display)
{
    if (!quiesce(display))
        return false;

    gpio_output_init(LCD_CLK, true);        // mode 3: clock idles high
    gpio_output_init(LCD_MOSI, false);
    gpio_output_init(LCD_A0, false);
    gpio_output_init(LCD_RST, true);
    gpio_output_init(LCD_LED, true);

    spin(200.msecs);
    gpio_output_set(LCD_RST, false);
    spin(1.msecs);
    gpio_output_set(LCD_RST, true);
    spin(1.msecs);

    static immutable ubyte[12] init_sequence = [
        0xA2, 0xA0, 0xC8, 0x24, 0xF8, 0x01, 0x81, 0x24, 0xA6, 0xA4, 0x2F, 0xAF,
    ];
    foreach (value; init_sequence)
        bitbang_byte(value);

    foreach (page; 0 .. display_pages)
    {
        gpio_output_set(LCD_A0, false);
        bitbang_byte(cast(ubyte)(0xB0 | page));
        bitbang_byte(0x10);
        bitbang_byte(0x00);
        gpio_output_set(LCD_A0, true);
        foreach (column; 0 .. display_width)
            bitbang_byte((column & 1) ? 0xAA : 0x55);
    }
    gpio_output_set(LCD_A0, false);
    return true;
}

// Bit-bangs bytes into whatever state the panel is already in: no reset, no init, so it
// reports on what the SPI path left behind rather than starting over.
bool display_bitbang_bytes(ref SmartEVSEDisplay display, bool data, const(ubyte)[] bytes)
{
    if (bytes.length == 0 || !quiesce(display))
        return false;

    gpio_output_init(LCD_CLK, true);
    gpio_output_init(LCD_MOSI, false);
    gpio_output_init(LCD_A0, data);
    foreach (value; bytes)
        bitbang_byte(value);
    gpio_output_set(LCD_A0, false);
    return true;
}

private void bitbang_byte(ubyte value)
{
    foreach_reverse (bit; 0 .. 8)
    {
        gpio_output_set(LCD_CLK, false);
        gpio_output_set(LCD_MOSI, (value >> bit) & 1);
        spin(2.usecs);
        gpio_output_set(LCD_CLK, true);     // ST7565 samples on the rising edge
        spin(2.usecs);
    }
}

// The bring-up commands share the pump's operation, so they must never start while a
// transfer is in flight, and must never spin unbounded: this runs on the main loop, and
// a stuck wait takes the console and the watchdog feed down with it.
private bool wait_idle(ref SmartEVSEDisplay display)
{
    MonoTime deadline = getTime() + 50.msecs;
    while (display.operation.is_pending)
    {
        if (getTime() > deadline)
            return false;
    }
    return true;
}

private bool quiesce(ref SmartEVSEDisplay display)
{
    display.dirty = false;
    display.phase = ScanPhase.idle;
    if (!wait_idle(display))
        return false;
    spi_close(display.bus);
    return true;
}


private:

enum ScanPhase : ubyte
{
    idle,
    command,
    data,
}

void advance(ref SmartEVSEDisplay display)
{
    if (display.operation.is_pending || !display.bus.is_open)
        return;

    if (display.phase == ScanPhase.command)
    {
        uint base = display.page * display_width + display.run_start;
        display.phase = ScanPhase.data;
        if (!submit(display, true, display.front[base .. base + display.run_length]))
            invalidate(display);
        return;
    }

    if (display.phase == ScanPhase.data)
        ++display.page;
    display.phase = ScanPhase.idle;

    while (true)
    {
        // a blit landing behind the scan position must trigger another pass, not be dropped
        if (display.page == 0)
            display.dirty = false;
        if (next_run(display))
            break;
        display.page = 0;
        if (!display.dirty)
            return;
    }

    display.command[0] = 0xB0 | (display.page & 0x07);
    display.command[1] = 0x10 | ((display.run_start >> 4) & 0x0F);
    display.command[2] = display.run_start & 0x0F;
    if (submit(display, false, display.command[]))
        display.phase = ScanPhase.command;
    else
        invalidate(display);
}

// front no longer records what the panel holds, so resend everything
void invalidate(ref SmartEVSEDisplay display)
{
    foreach (i, value; display.back)
        display.front[i] = value ^ 0xFF;
    display.page = 0;
    display.phase = ScanPhase.idle;
    display.dirty = true;
}

// One span per page: a split costs another command plus completion round-trip, which
// outweighs shipping the gap's bytes at 10MHz.
bool next_run(ref SmartEVSEDisplay display)
{
    for (; display.page < display_pages; ++display.page)
    {
        uint base = display.page * display_width;
        uint first = 0;
        while (first < display_width && display.back[base + first] == display.front[base + first])
            ++first;
        if (first == display_width)
            continue;

        uint last = display_width - 1;
        while (display.back[base + last] == display.front[base + last])
            --last;

        display.front[base + first .. base + last + 1] = display.back[base + first .. base + last + 1];
        display.run_start = first;
        display.run_length = last - first + 1;
        return true;
    }
    return false;
}

bool submit(ref SmartEVSEDisplay display, bool data, const(ubyte)[] bytes)
{
    gpio_output_set(LCD_A0, data);
    display.operation.reset();
    display.operation.user_data = &display;
    display.operation.callback = &transfer_complete;

    SpiTransfer transfer;
    transfer.write_data = bytes;
    return spi_submit(display.bus, display.operation, transfer) == Result.success;
}

bool transfer_complete(ref SpiOperation operation, SpiCallbackContext)
{
    SmartEVSEDisplay* display = cast(SmartEVSEDisplay*)operation.user_data;
    return g_app.post_event_from_isr(&display.pump, EventPriority.control);
}

Result send_blocking(ref SmartEVSEDisplay display, bool data, const(ubyte)[] bytes)
{
    gpio_output_set(LCD_A0, data);
    display.operation.reset();
    display.operation.callback = null;

    SpiTransfer transfer;
    transfer.write_data = bytes;
    Result result = spi_submit(display.bus, display.operation, transfer);
    if (!result)
        return result;
    MonoTime deadline = getTime() + 50.msecs;
    while (!display.operation.is_done)
    {
        if (getTime() > deadline)
            return InternalResult.timeout;
    }
    return Result.success;
}

void spin(Duration duration)
{
    MonoTime deadline = getTime() + duration;
    while (getTime() < deadline)
    {}
}
