/* BK7231N (ARM968E-S, ARMv5TE) linker script
 *
 * Beken BK7231N -- ARM968E-S @ 120MHz, no FPU, no MMU.
 * Wi-Fi 802.11b/g/n + BLE 5.0.
 *
 * Flash partition table (from BkDriverFlash.c):
 *   Bootloader:  0x000000, 68KB  (0x11000)
 *   Application: 0x011000, 1156KB (0x121000)
 *   OTA:         0x12A000, 664KB  (0xA6000)
 *   RF Firmware: 0x1D0000, 4KB
 *   NET Param:   0x1D1000, 4KB
 *
 * SRAM layout (OTA build, from SDK bk7231_ota.ld):
 *   TCM:   0x003F0000, 60KB - 512   (BLE/WiFi critical paths)
 *   ITCM:  0x003FEE00, 4608 bytes   (interrupt entry)
 *   RAM:   0x00400100, 192KB - 256   (application)
 *
 * The BLE 5.x stack claims 64KB from general SRAM as TCM regions.
 * Application gets 192KB minus the 256-byte reserved header.
 *
 * Non-OTA: set FLASH LENGTH to 1788K (up to RF firmware at 0x1D0000).
 */

ENTRY(Reset_Handler)

EXTERN(_write _read _close _lseek _fstat _isatty _sbrk _exit _kill _getpid)
EXTERN(_Dmodule_ref __errno_location stdout)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x00011000, LENGTH = 4M  /* TODO: restore to 1156K */
    SRAM  (rwx) : ORIGIN = 0x00400100, LENGTH = 192K - 0x100
}

SECTIONS
{
    .text : ALIGN(4)
    {
        KEEP(*(.vector_table))
        *(.text .text.*)
    } > FLASH

    .rodata : ALIGN(8)
    {
        *(.rodata .rodata.*)
    } > FLASH

    .eh_frame : ALIGN(8)
    {
        __eh_frame_start = .;
        KEEP(*(.eh_frame))
        KEEP(*(.eh_frame_hdr))
    } > FLASH

    .gcc_except_table : ALIGN(4)
    {
        *(.gcc_except_table .gcc_except_table.*)
    } > FLASH

    .init_array : ALIGN(4)
    {
        __init_array_start = .;
        KEEP(*(.init_array))
        __init_array_end = .;
    } > FLASH

    .ARM.exidx : ALIGN(4)
    {
        __exidx_start = .;
        *(.ARM.exidx* .gnu.linkonce.armexidx.*)
        __exidx_end = .;
    } > FLASH

    .ARM.extab : ALIGN(4)
    {
        *(.ARM.extab* .gnu.linkonce.armextab.*)
    } > FLASH

    .got : ALIGN(4)
    {
        _got_load  = LOADADDR(.got);
        _got_start = .;
        *(.got .got.*)
        *(.got.plt)
        _got_end = .;
    } > SRAM AT > FLASH

    .data : ALIGN(4)
    {
        _data_start = .;
        *(.data .data.*)
        _data_end = .;
    } > SRAM AT > FLASH

    _data_load = LOADADDR(.data);
    __ram_load_addr = _data_load;
    __ram_data_start__ = _data_start;
    __ram_data_end__ = _data_end;

    .tdata : ALIGN(4)
    {
        _tdata_start = .;
        *(.tdata .tdata.*)
        _tdata_end = .;
    } > SRAM AT > FLASH

    _tdata_load = LOADADDR(.tdata);

    .tbss (NOLOAD) : ALIGN(4)
    {
        _tbss_start = .;
        *(.tbss .tbss.*)
        _tbss_end = .;
    } > SRAM

    .bss (NOLOAD) : ALIGN(4)
    {
        __bss_start__ = .;
        _bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        _bss_end = .;
        __bss_end__ = .;
    } > SRAM

    __heap_start = _bss_end;
    __heap_end   = ORIGIN(SRAM) + LENGTH(SRAM) - 4K;

    _stack_top = ORIGIN(SRAM) + LENGTH(SRAM);
    __StackTop = _stack_top;

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.gnu.hash)
        *(.gnu.linkonce.*)
    }
}
