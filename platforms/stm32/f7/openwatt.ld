/* STM32F7 (ARM Cortex-M7) linker script
 *
 * Default memory map for STM32F746NG (Discovery board):
 *   FLASH:  1MB   at 0x08000000
 *   DTCM:   64KB  at 0x20000000 (tightly-coupled, fast, no DMA)
 *   RAM:    256KB at 0x20010000 (SRAM1 240KB + SRAM2 16KB contiguous)
 *
 * DTCM is used for stack and GOT (zero-wait-state single-cycle access).
 * Main RAM is used for .data, .bss, and heap.
 *
 * Adjust MEMORY sizes for your specific F7 variant.
 */

ENTRY(Reset_Handler)

EXTERN(_write _read _close _lseek _fstat _isatty _sbrk _exit _kill _getpid)
EXTERN(_Dmodule_ref __errno_location stdout)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 1M
    DTCM  (rwx) : ORIGIN = 0x20000000, LENGTH = 64K
    RAM   (rwx) : ORIGIN = 0x20010000, LENGTH = 256K
}

SECTIONS
{
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

    /* GOT in DTCM for fast access -- LMA in FLASH, copied at startup */
    .got : ALIGN(4)
    {
        _got_load  = LOADADDR(.got);
        _got_start = .;
        *(.got .got.*)
        *(.got.plt)
        _got_end = .;
    } > DTCM AT > FLASH

    /* Initialized data -- LMA in FLASH, copied to RAM at startup */
    .data : ALIGN(4)
    {
        _data_start = .;
        *(.data .data.*)
        _data_end = .;
    } > RAM AT > FLASH

    _data_load = LOADADDR(.data);
    __ram_load_addr = _data_load;
    __ram_data_start__ = _data_start;
    __ram_data_end__ = _data_end;

    /* Thread-local initialized data in DTCM -- LMA in FLASH */
    .tdata : ALIGN(4)
    {
        _tdata_start = .;
        *(.tdata .tdata.*)
        _tdata_end = .;
    } > DTCM AT > FLASH

    _tdata_load = LOADADDR(.tdata);

    /* Thread-local zero-initialized data */
    .tbss (NOLOAD) : ALIGN(4)
    {
        _tbss_start = .;
        *(.tbss .tbss.*)
        _tbss_end = .;
    } > DTCM

    /* Zero-initialized data */
    .bss (NOLOAD) : ALIGN(4)
    {
        __bss_start__ = .;
        _bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        _bss_end = .;
        __bss_end__ = .;
    } > RAM

    /* Heap grows up from end of BSS in RAM */
    __heap_start = _bss_end;
    __heap_end   = ORIGIN(RAM) + LENGTH(RAM);

    /* Stack at top of DTCM (fast access) */
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
