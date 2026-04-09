/* RP2350 (ARM Cortex-M33) linker script
 *
 * Raspberry Pi RP2350B — dual Cortex-M33 @ 150MHz, 520KB SRAM, XIP QSPI flash.
 *
 * Memory layout:
 *   BOOT2:  0x10000000, 256B    (second-stage bootloader, copied to SRAM by ROM)
 *   FLASH:  0x10000100, ~4MB    (XIP execute-in-place, read-only)
 *   SRAM:   0x20000000, 520KB   (8 banks x 64KB + 8KB scratch)
 *
 * The RP2350 ROM loads the 256-byte boot2 block from the start of flash,
 * executes it from SRAM to configure the QSPI interface, then jumps to
 * the vector table at the start of .text.
 */

ENTRY(Reset_Handler)

/* Force-link newlib syscall stubs and D runtime symbols */
EXTERN(_write _read _close _lseek _fstat _isatty _sbrk _exit _kill _getpid)
EXTERN(_Dmodule_ref __errno_location stdout)

MEMORY
{
    /* Second-stage bootloader — first 256 bytes of flash */
    BOOT2 (rx)  : ORIGIN = 0x10000000, LENGTH = 256
    /* Application flash — XIP, code and read-only data */
    FLASH (rx)  : ORIGIN = 0x10000100, LENGTH = 4M - 256
    /* SRAM — all 8 banks contiguous (banks 0-7: 8 x 64KB = 512KB) + 8KB scratch */
    SRAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 520K
}

SECTIONS
{
    /* Boot2 — second-stage bootloader for QSPI flash init */
    .boot2 : ALIGN(4)
    {
        KEEP(*(.boot2))
    } > BOOT2

    /* Vector table must be first in FLASH (right after boot2) */
    .vector_table : ALIGN(4)
    {
        KEEP(*(.vector_table))
    } > FLASH

    .text : ALIGN(4)
    {
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

    /* ARM exception unwind tables */
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

    /* GOT in SRAM for fast access — LMA in FLASH, copied at startup */
    .got : ALIGN(4)
    {
        _got_load  = LOADADDR(.got);
        _got_start = .;
        *(.got .got.*)
        *(.got.plt)
        _got_end = .;
    } > SRAM AT > FLASH

    /* Initialized data — LMA in FLASH, copied to SRAM at startup */
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

    /* Thread-local initialized data — LMA in FLASH, copied to SRAM at startup */
    .tdata : ALIGN(4)
    {
        _tdata_start = .;
        *(.tdata .tdata.*)
        _tdata_end = .;
    } > SRAM AT > FLASH

    _tdata_load = LOADADDR(.tdata);

    /* Thread-local zero-initialized data */
    .tbss (NOLOAD) : ALIGN(4)
    {
        _tbss_start = .;
        *(.tbss .tbss.*)
        _tbss_end = .;
    } > SRAM

    /* Zero-initialized data */
    .bss (NOLOAD) : ALIGN(4)
    {
        __bss_start__ = .;
        _bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        _bss_end = .;
        __bss_end__ = .;
    } > SRAM

    /* Heap grows up from end of BSS */
    __heap_start = _bss_end;
    __heap_end   = ORIGIN(SRAM) + LENGTH(SRAM) - 4K;

    /* Stack at top of SRAM (4KB reserved) */
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
