/*
 * EFI loader: linked as a static ELF at 0x1000 (room for the PE headers),
 * then converted to PE/COFF by objcopy (arch.mk). Sections are page
 * aligned, as PE expects. .reloc is the empty base relocation directory
 * that loader.c defines.
 */
ENTRY(efi_main)

SECTIONS
{
	. = 0x1000;
	.text : ALIGN(4096) {
		*(.text .text.*)
	}
	.rodata : ALIGN(4096) {
		*(.rodata .rodata.*)
	}
	.data : ALIGN(4096) {
		*(.data .data.*)
		*(.bss .bss.* COMMON)
	}
	.reloc : ALIGN(4096) {
		*(.reloc)
	}
	/DISCARD/ : {
		*(.note .note.* .comment .eh_frame* .dynamic .dynsym .dynstr)
		*(.interp .gnu.hash .hash)
	}
}
