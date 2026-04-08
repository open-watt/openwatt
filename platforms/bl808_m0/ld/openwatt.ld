/* BL808 M0 core (T-Head E907 RV32IMAFC) linker script
 *
 * The M0 core is the first to boot on BL808. It initializes clocks,
 * GPIO muxing, and peripherals before optionally starting the D0 core.
 *
 * Memory layout (MCU domain):
 *   FLASH XIP:  0x58000000, 2MB   (M0 firmware, execute-in-place)
 *   OCRAM:      0x22020000, 64KB  (on-chip RAM, cached alias)
 *   DTCM:       0x20000000, 64KB  (tightly-coupled data memory)
 *
 * TODO: Verify memory map on actual hardware. The M0's view of memory
 *       differs from D0's — M0 has its own PLIC, own UART IRQ domain,
 *       and cannot directly access the MM-domain PSRAM used by D0.
 */

ENTRY(_start)

EXTERN(_write _read _close _lseek _fstat _isatty _sbrk _exit _kill _getpid)
EXTERN(_Dmodule_ref __errno_location stdout)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x58000000, LENGTH = 2M
    DTCM  (rwx) : ORIGIN = 0x20000000, LENGTH = 64K
    RAM   (rwx) : ORIGIN = 0x22020000, LENGTH = 64K
}

SECTIONS
{
    .text : ALIGN(4)
    {
        KEEP(*(.text.entry))
        . = ALIGN(4);
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

    .got : ALIGN(4)
    {
        PROVIDE(__global_pointer$ = . + 0x800);
        *(.got .got.*)
        *(.got.plt)
        *(.sdata .sdata.*)
        *(.srodata .srodata.*)
    } > DTCM AT > FLASH

    _got_load  = LOADADDR(.got);
    _got_start = ADDR(.got);
    _got_end   = _got_start + SIZEOF(.got);

    .data : ALIGN(4)
    {
        *(.data .data.*)
    } > RAM AT > FLASH

    _data_load = LOADADDR(.data);
    _data_start = ADDR(.data);
    _data_end = _data_start + SIZEOF(.data);
    __ram_load_addr = _data_load;
    __ram_data_start__ = _data_start;
    __ram_data_end__ = _data_end;

    .bss (NOLOAD) : ALIGN(4)
    {
        __bss_start__ = .;
        _bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        _bss_end = .;
        __bss_end__ = .;
    } > RAM

    .tdata : ALIGN(4)
    {
        *(.tdata .tdata.*)
    } > DTCM AT > FLASH

    _tdata_load  = LOADADDR(.tdata);
    _tdata_start = ADDR(.tdata);
    _tdata_end   = _tdata_start + SIZEOF(.tdata);

    .tbss (NOLOAD) : ALIGN(4)
    {
        _tbss_start = .;
        *(.tbss .tbss.*)
        _tbss_end = .;
    } > DTCM

    __heap_start = _bss_end;
    __heap_end   = ORIGIN(RAM) + LENGTH(RAM);

    _stack_top = ORIGIN(DTCM) + LENGTH(DTCM);
    __StackTop = _stack_top;

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.gnu.hash)
        *(.gnu.linkonce.*)
    }
}
