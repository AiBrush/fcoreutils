/* Minimal linker script for farch release build */
OUTPUT_FORMAT("elf64-x86-64")
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

PHDRS
{
    load  PT_LOAD FLAGS(7);         /* PF_R | PF_W | PF_X */
    stack PT_GNU_STACK FLAGS(6);    /* PF_R | PF_W (non-executable stack) */
}

SECTIONS
{
    . = 0x400000 + SIZEOF_HEADERS;

    .text   : { *(.text*) } :load
    .rodata : { *(.rodata*) } :load
    .bss    : { *(.bss*) *(COMMON) } :load

    .stack  : { *(.note.GNU-stack) } :stack

    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}
