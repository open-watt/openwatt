/* BL618 (T-Head E907 RV32IMAFC) linker script
 *
 * Single-core Bouffalo BL616/BL618 — no M0/D0 split.
 * Code executes from flash via XIP or from OCRAM.
 *
 * Memory layout:
 *   FLASH XIP:  0xA0000000, 8MB   (execute-in-place, read-only)
 *   OCRAM:      0x62020000, 480KB (on-chip RAM, uncached)
 *   OCRAM$:     0x22020000, 480KB (same RAM, cached alias)
 *   DTCM:       0x20000000, 64KB  (tightly-coupled data memory)
 *
 * TODO: Verify memory map against actual BL618 hardware.
 *       The addresses below are from the BL616 reference manual
 *       and may need adjustment for the Sipeed M0P board.
 */

ENTRY(_start)

/* Force-link newlib syscall stubs and D runtime symbols */
EXTERN(_write _read _close _lseek _fstat _isatty _sbrk _exit _kill _getpid)
EXTERN(_Dmodule_ref __errno_location stdout)

MEMORY
{
    /* Flash XIP — code and read-only data */
    FLASH (rx)  : ORIGIN = 0xA0000000, LENGTH = 8M
    /* DTCM — fast tightly-coupled memory for stack and small data */
    DTCM  (rwx) : ORIGIN = 0x20000000, LENGTH = 64K
    /* OCRAM — main writable RAM (cached alias for performance) */
    RAM   (rwx) : ORIGIN = 0x22020000, LENGTH = 480K
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

    /* GOT and small data in DTCM for fast access.
     * LMA in FLASH, start.S copies to DTCM at boot. */
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

    /* Thread-local data/BSS in DTCM */
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

    /* Heap in OCRAM after BSS */
    __heap_start = _bss_end;
    __heap_end   = ORIGIN(RAM) + LENGTH(RAM);

    /* Stack in DTCM (fast access) */
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
