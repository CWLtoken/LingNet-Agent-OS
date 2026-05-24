/* LingNet Agent OS V2.2 - Linker Script
 * Defines .lingnet_l0 section for ROM-hardened Core Skills
 * Enforces: W^X on L0 text, contiguous layout for mprotect
 */

SECTIONS
{
    /* L0 Core Skills: Read-Execute only, no write permission possible */
    .lingnet_l0 : ALIGN(4096)
    {
        __lingnet_l0_start = .;
        KEEP(*(.text.lingnet_l0))
        KEEP(*(.text.lingnet_l0.*))
        . = ALIGN(4096);
        __lingnet_l0_end = .;
        __lingnet_l0_size = __lingnet_l0_end - __lingnet_l0_start;
    }

    /* L1 Built-in Skills: Read-Execute, but can be hot-replaced */
    .lingnet_l1 : ALIGN(4096)
    {
        __lingnet_l1_start = .;
        KEEP(*(.text.lingnet_l1))
        KEEP(*(.text.lingnet_l1.*))
        . = ALIGN(4096);
        __lingnet_l1_end = .;
    }

    /* GQAP Arena metadata section (read-only after boot) */
    .lingnet_arena_meta : ALIGN(64)
    {
        __lingnet_arena_meta_start = .;
        KEEP(*(.data.lingnet_arena))
        . = ALIGN(64);
        __lingnet_arena_meta_end = .;
    }
}

/* Insert after standard text section */
INSERT AFTER .text;
