/* STM32F4 (ARM Cortex-M4) linker script
 *
 * Default memory map for STM32F407VG (Discovery board):
 *   FLASH:  1MB  at 0x08000000
 *   RAM:    128KB at 0x20000000 (SRAM1 112KB + SRAM2 16KB contiguous)
 *
 * STM32F4 also has 64KB CCM RAM at 0x10000000 (no DMA access).
 * Not used here -- add a DTCM region if you need it for stack/GOT.
 *
 * Adjust MEMORY sizes for your specific F4 variant.
 */

ENTRY(Reset_Handler)

EXTERN(_write _read _close _lseek _fstat _isatty _sbrk _exit _kill _getpid)
EXTERN(_Dmodule_ref __errno_location stdout)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 1M
    RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 128K
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

    /* GOT in RAM for fast access -- LMA in FLASH, copied at startup */
    .got : ALIGN(4)
    {
        _got_load  = LOADADDR(.got);
        _got_start = .;
        *(.got .got.*)
        *(.got.plt)
        _got_end = .;
    } > RAM AT > FLASH

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

    /* Thread-local initialized data -- LMA in FLASH, copied to RAM at startup */
    .tdata : ALIGN(4)
    {
        _tdata_start = .;
        *(.tdata .tdata.*)
        _tdata_end = .;
    } > RAM AT > FLASH

    _tdata_load = LOADADDR(.tdata);

    /* Thread-local zero-initialized data */
    .tbss (NOLOAD) : ALIGN(4)
    {
        _tbss_start = .;
        *(.tbss .tbss.*)
        _tbss_end = .;
    } > RAM

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

    /* Heap grows up from end of BSS */
    __heap_start = _bss_end;
    __heap_end   = ORIGIN(RAM) + LENGTH(RAM) - 4K;

    /* Stack at top of RAM (4KB reserved) */
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
    __StackTop = _stack_top;

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.gnu.hash)
        *(.gnu.linkonce.*)
    }
}
