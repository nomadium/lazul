/*
 * EFI loader: linked as a static ELF at 0x1000 (room for the PE headers),
 * then converted to PE/COFF by objcopy (arch.mk). Sections are page
 * aligned, as PE expects.
 */
OUTPUT_ARCH(riscv)
ENTRY(efi_main)

SECTIONS
{
	. = 0x1000;
	.text : ALIGN(4096) {
		*(.text .text.*)
	}
	.rodata : ALIGN(4096) {
		*(.rodata .rodata.* .srodata .srodata.*)
	}
	.data : ALIGN(4096) {
		*(.data .data.* .sdata .sdata.*)
		*(.sbss .sbss.* .bss .bss.* COMMON)
	}
	/DISCARD/ : {
		*(.note .note.* .comment .riscv.attributes .eh_frame*)
	}
}
