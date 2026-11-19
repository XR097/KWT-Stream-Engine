OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY
{
    ITCM (rx)  : ORIGIN = 0x80000000, LENGTH = 64K
    DTCM (rw)  : ORIGIN = 0x90000000, LENGTH = 64K
}
SECTIONS
{
    .text : { KEEP(*(.text.start)) *(.text .text.*) } > ITCM
    .rodata : ALIGN(4) { *(.rodata .rodata.* .srodata .srodata.*) } > ITCM
    .data : ALIGN(4) {
        __data_start = .;
        *(.data .data.* .sdata .sdata.*)
        . = ALIGN(4);
        __data_end = .;
    } > DTCM AT> ITCM
    __data_load = LOADADDR(.data);
    .bss (NOLOAD) : ALIGN(4) {
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > DTCM
    __stack_top = ORIGIN(DTCM) + LENGTH(DTCM) - 16;
    /DISCARD/ : { *(.comment .note .note.* .eh_frame .eh_frame.* .riscv.attributes) }
}
ASSERT(_start == 0x80000000, "entry must be at the ITCM base")
