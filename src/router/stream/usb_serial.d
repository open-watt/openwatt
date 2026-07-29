module router.stream.usb_serial;

version (ESP32_C3)
    version = USBSerialJTAG;
else version (ESP32_C5)
    version = USBSerialJTAG;
else version (ESP32_C6)
    version = USBSerialJTAG;
else version (ESP32_H2)
    version = USBSerialJTAG;
else version (ESP32_P4)
    version = USBSerialJTAG;
else version (ESP32_S3)
    version = USBSerialJTAG;
else version (ESP32_S2)
    version = USBCDC;

version (USBSerialJTAG)
    version = USBSerialAvailable;
else version (USBCDC)
    version = USBSerialAvailable;

version (USBSerialAvailable)
{
    import urt.meta;

    import manager;
    import manager.base;
    import manager.collection;
    import manager.plugin;

    import router.stream;
}

version (USBSerialJTAG)
{
    struct USBSerialJTAGConfig
    {
        uint tx_buffer_size;
        uint rx_buffer_size;
    }

    extern(C) nothrow @nogc
    {
        int usb_serial_jtag_driver_install(USBSerialJTAGConfig* config);
        int usb_serial_jtag_driver_uninstall();
        bool usb_serial_jtag_is_driver_installed();
        int usb_serial_jtag_read_bytes(void* buffer, uint length, uint ticks_to_wait);
        int usb_serial_jtag_write_bytes(const(void)* data, size_t length, uint ticks_to_wait);
        int usb_serial_jtag_wait_tx_done(uint ticks_to_wait);
        size_t usb_serial_jtag_get_read_bytes_available();
    }
}
else version (USBCDC)
{
    extern(C) nothrow @nogc
    {
        int esp_usb_console_init();
        bool esp_usb_console_is_installed();
        ptrdiff_t esp_usb_console_read_buf(char* buffer, size_t length);
        ptrdiff_t esp_usb_console_write_buf(const(char)* data, size_t length);
        ptrdiff_t esp_usb_console_flush();
        ptrdiff_t esp_usb_console_available_for_read();
    }
}

version (USBSerialAvailable):
nothrow @nogc:


class USBSerialStream : Stream
{
    alias Properties = AliasSeq!();
nothrow @nogc:

    enum type_name = "usb-serial";
    enum path = "/stream/usb-serial";

    this(CID id, ObjectFlags flags = ObjectFlags.none)
    {
        super(collection_type_info!USBSerialStream, id, flags);
    }

    override ptrdiff_t read(void[] buffer)
    {
        version (USBSerialJTAG)
            ptrdiff_t bytes = usb_serial_jtag_read_bytes(buffer.ptr, cast(uint)buffer.length, 0);
        else
            ptrdiff_t bytes = esp_usb_console_read_buf(cast(char*)buffer.ptr, buffer.length);
        if (bytes > 0)
            add_rx_bytes(bytes);
        return bytes;
    }

    override ptrdiff_t write(const(void[])[] data...)
    {
        ptrdiff_t total;
        foreach (d; data)
        {
            version (USBSerialJTAG)
                ptrdiff_t bytes = usb_serial_jtag_write_bytes(d.ptr, d.length, 0);
            else
                ptrdiff_t bytes = esp_usb_console_write_buf(cast(const(char)*)d.ptr, d.length);
            if (bytes < 0)
                return -1;
            add_tx_bytes(bytes);
            total += bytes;
            if (bytes < d.length)
                break;
        }
        return total;
    }

    override ptrdiff_t pending()
    {
        version (USBSerialJTAG)
            return cast(ptrdiff_t)usb_serial_jtag_get_read_bytes_available();
        else
            return esp_usb_console_available_for_read();
    }

    override ptrdiff_t flush()
    {
        version (USBSerialJTAG)
            return usb_serial_jtag_wait_tx_done(0) == 0 ? 0 : -1;
        else
            return esp_usb_console_flush();
    }

    override CompletionStatus startup()
    {
        version (USBSerialJTAG)
        {
            if (!usb_serial_jtag_is_driver_installed())
            {
                USBSerialJTAGConfig config = { 1024, 1024 };
                if (usb_serial_jtag_driver_install(&config) != 0)
                    return CompletionStatus.error;
                _driver_owned = true;
            }
        }
        else
        {
            if (!esp_usb_console_is_installed() &&
                esp_usb_console_init() != 0)
                return CompletionStatus.error;
        }
        return CompletionStatus.complete;
    }

    override CompletionStatus shutdown()
    {
        version (USBSerialJTAG)
        {
            if (_driver_owned)
            {
                usb_serial_jtag_driver_uninstall();
                _driver_owned = false;
            }
        }
        return CompletionStatus.complete;
    }

private:
    version (USBSerialJTAG)
        bool _driver_owned;
}


class USBSerialStreamModule : Module
{
    mixin DeclareModule!"stream.usb-serial";
nothrow @nogc:

    override void init()
    {
        g_app.console.register_collection!USBSerialStream();
    }
}
