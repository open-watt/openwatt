/* BL808 D0 core (T-Head C906 RV64GC) linker script
 *
 * M0 copies D0 firmware from Flash (0x580F0000) to PSRAM and starts D0
 * executing from PSRAM at 0x50100000.  This is NOT XIP — code runs from RAM.
 *
 * Memory layout:
 *   CODE PSRAM:  0x50100000, 2MB   (D0 firmware, copied by M0 from Flash)
 *   DATA PSRAM:  0x50300000, 61MB  (writable data, BSS, heap)
 *   SRAM:        0x3eff8000, 64KB  (stack, GOT, fast data)
 */

ENTRY(_start)

/* Force-link newlib syscall stubs and D runtime symbols
 * (otherwise --gc-sections strips them before newlib resolves) */
EXTERN(_write _read _close _lseek _fstat _isatty _sbrk _exit _kill _getpid)
EXTERN(_Dmodule_ref __errno_location stdout)
EXTERN(socket close poll _accept _recv _recvfrom _sendmsg)
EXTERN(_shutdown _bind _listen _connect setsockopt getsockname getpeername)
EXTERN(getaddrinfo freeaddrinfo)

MEMORY
{
    /* D0 firmware is loaded by M0 to PSRAM at this address */
    CODE  (rx)  : ORIGIN = 0x50100000, LENGTH = 2M
    /* Writable data starts after the 2MB firmware region */
    DATA  (rwx) : ORIGIN = 0x50300000, LENGTH = 61M
    SRAM  (rwx) : ORIGIN = 0x3eff8000, LENGTH = 64K
    /* HBN RAM: 4KB, survives hibernate if VBAT maintained */
    HBNRAM (rw) : ORIGIN = 0x20010000, LENGTH = 4K
}

SECTIONS
{
    .text : ALIGN(4)
    {
        KEEP(*(.text.entry))
        . = ALIGN(4);
        *(.text.psram_early)
        *(.text .text.*)
    } > CODE

    .rodata : ALIGN(8)
    {
        *(.rodata .rodata.*)
    } > CODE

    /* DWARF exception handling — required for D throw/catch (fibre abort, etc.).
     * eh_frame: stack frame descriptions for the unwinder.
     * gcc_except_table: LSDA (landing pads, catch clause type filters). */
    .eh_frame : ALIGN(8)
    {
        __eh_frame_start = .;
        KEEP(*(.eh_frame))
        KEEP(*(.eh_frame_hdr))
    } > CODE

    .gcc_except_table : ALIGN(4)
    {
        *(.gcc_except_table .gcc_except_table.*)
    } > CODE

    /* Init array — LDC module info registration functions.
     * Called from start.S before main(). */
    .init_array : ALIGN(8)
    {
        __init_array_start = .;
        KEEP(*(.init_array))
        __init_array_end = .;
    } > CODE

    /* GOT and small data in fast SRAM.
     * LMA is in CODE (PSRAM), start.S copies to SRAM at boot. */
    .got : ALIGN(8)
    {
        PROVIDE(__global_pointer$ = . + 0x800);
        *(.got .got.*)
        *(.got.plt)
        *(.sdata .sdata.*)
        *(.srodata .srodata.*)
    } > SRAM AT > CODE

    _got_load  = LOADADDR(.got);
    _got_start = ADDR(.got);
    _got_end   = _got_start + SIZEOF(.got);

    .data : ALIGN(8)
    {
        *(.data .data.*)
    } > DATA AT > CODE

    _data_load = LOADADDR(.data);
    _data_start = ADDR(.data);
    _data_end = _data_start + SIZEOF(.data);
    __ram_load_addr = _data_load;
    __ram_data_start__ = _data_start;
    __ram_data_end__ = _data_end;

    .bss (NOLOAD) : ALIGN(8)
    {
        __bss_start__ = .;
        _bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        _bss_end = .;
        __bss_end__ = .;
    } > DATA

    /* Thread-local data/BSS in SRAM */
    .tdata : ALIGN(8)
    {
        *(.tdata .tdata.*)
    } > SRAM AT > CODE

    _tdata_load  = LOADADDR(.tdata);
    _tdata_start = ADDR(.tdata);
    _tdata_end   = _tdata_start + SIZEOF(.tdata);

    .tbss (NOLOAD) : ALIGN(8)
    {
        _tbss_start = .;
        *(.tbss .tbss.*)
        _tbss_end = .;
    } > SRAM

    /* HBN RAM: persistent across hibernate, not initialized by startup */
    .hbn_ram (NOLOAD) : ALIGN(4)
    {
        *(.hbn_ram)
    } > HBNRAM

    /* Heap in DATA PSRAM after BSS */
    __heap_start = _bss_end;
    __heap_end   = ORIGIN(DATA) + LENGTH(DATA);

    /* Stack in fast on-chip SRAM */
    _stack_top = ORIGIN(SRAM) + LENGTH(SRAM);
    __StackTop = _stack_top;

    /* Vendor start_load.c expects these symbols for ITCM/DTCM/system RAM
     * copy loops. We don't use those sections, so define them as empty. */
    PROVIDE(__itcm_load_addr = 0);
    PROVIDE(__tcm_code_start__ = 0);
    PROVIDE(__tcm_code_end__ = 0);
    PROVIDE(__dtcm_load_addr = 0);
    PROVIDE(__tcm_data_start__ = 0);
    PROVIDE(__tcm_data_end__ = 0);
    PROVIDE(__system_ram_load_addr = 0);
    PROVIDE(__system_ram_data_start__ = 0);
    PROVIDE(__system_ram_data_end__ = 0);

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.gnu.hash)
        *(.gnu.linkonce.*)
    }
}
