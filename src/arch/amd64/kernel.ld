/*
 * kernel linker script, amd64. See src/arch/riscv64/kernel.ld for what
 * each directive means; only what differs is explained here.
 *
 * Memory map of the kernel as linked:
 *
 *   0x00000000  +--------------------+
 *               | the PC's first MiB |  real-mode interrupt table, BIOS
 *               |                    |  data, VGA memory (0xa0000), option
 *               |                    |  ROMs and the BIOS (0xf0000): not
 *               |                    |  for the kernel
 *   0x00100000  +--------------------+  ORIGIN(ram), 1 MiB
 *               | .text              |  code; pvh_start comes first
 *               | .rodata            |  constants, the Ruby bytecode
 *               +--------------------+  (first segment: read + execute)
 *               | .data              |  initialised variables
 *               | .tdata / .tbss     |  the TLS template
 *               | .bss               |  zeroed at entry: the boot stack,
 *               |                    |  the page tables (arch.c)
 *               +--------------------+  (second segment: read + write)
 *   __heap_start+--------------------+  __kernel_end
 *               | heap               |  up to heap_limit: the end of the
 *               |                    |  free RAM the kernel sits in, from
 *               |                    |  the boot info's memory map
 *               +--------------------+
 *
 * The kernel runs at the address it was linked for: the paging set up at
 * entry maps every address to itself (an identity map). QEMU's direct
 * kernel boot loads each segment at its physical address, so 1 MiB, the
 * traditional lowest address for a PC kernel, must be free RAM, as it is
 * on every PC.
 */
OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)

/*
 * The ELF entry point. QEMU's direct boot does not use it: it enters
 * the kernel in 32-bit mode at the address in the PVH note (start.S).
 */
ENTRY(pvh_start)

/*
 * LENGTH: room for the kernel image, a generous cap as in riscv64's
 * kernel.ld: the image is around 1 MiB.
 */
MEMORY { ram (rwx) : ORIGIN = 0x100000, LENGTH = 30M }

/*
 * As in riscv64's script, plus a PT_NOTE segment: ELF notes are small
 * tagged records that tools and loaders look for. QEMU finds the kernel's
 * 32-bit entry point in one (see .note.Xen below).
 */
PHDRS {
  text PT_LOAD;
  data PT_LOAD;
  tls  PT_TLS;
  note PT_NOTE;
}

SECTIONS
{
  /* Entry code first, then the rest of the code. */
  .text : {
    KEEP(*(.text.entry))
    *(.text .text.*)
  } >ram :text

  /*
   * The PVH note (start.S): in the text segment, so that it is part of
   * the image, and in the note segment, where QEMU looks for it. Notes are
   * 4-byte aligned; QEMU relies on the segment's alignment being exactly
   * that to find the note's contents.
   */
  .note.Xen : ALIGN(4) { KEEP(*(.note.Xen)) } >ram :text :note

  /*
   * etext and edata bracket the read-only data. The compiler targets
   * Linux (it defines __linux__), so mruby is built with
   * MRB_USE_ETEXT_RO_DATA_P and uses them to tell string literals, which
   * it does not need to copy, from other strings.
   */
  .rodata : ALIGN(16) {
    etext = .;
    *(.rodata .rodata.*)
    edata = .;
  } >ram :text

  .data : ALIGN(4096) { *(.data .data.*) } >ram :data

  /* The TLS template, copied into each hart's TLS area (arch.c). */
  .tdata : ALIGN(16) { *(.tdata .tdata.*) } >ram :data :tls
  .tbss  : ALIGN(16) { *(.tbss .tbss.*) . = ALIGN(16); } >ram :data :tls
  .tbss_space (NOLOAD) : { . = ADDR(.tbss) + SIZEOF(.tbss); } >ram :data

  .bss (NOLOAD) : ALIGN(16) {
    __bss_start = .;
    *(.bss .bss.* COMMON)
    . = ALIGN(16);
    __bss_end = .;
  } >ram :data

  /* The heap, from the next page to heap_limit (set at boot). */
  . = ALIGN(4096);
  __kernel_end = .;
  __heap_start = .;
  __heap_end = .;

  /*
   * Also thrown away here: .eh_frame, the unwinding tables that the
   * compiler emits for C++ exceptions and debuggers. The kernel unwinds
   * nothing, and gdb uses the debug information instead.
   */
  /DISCARD/ : { *(.note .note.* .comment .eh_frame .eh_frame_hdr) }
}

/* For picolibc's TLS code, as in src/arch/riscv64/kernel.ld. */
PROVIDE(__tdata_source = ADDR(.tdata));
PROVIDE(__tdata_size = SIZEOF(.tdata));
PROVIDE(__tbss_offset = ADDR(.tbss) - ADDR(.tdata));
PROVIDE(__tbss_size = SIZEOF(.tbss));
PROVIDE(__tls_size = ADDR(.tbss) + SIZEOF(.tbss) - ADDR(.tdata));
PROVIDE(__tls_align = MAX(ALIGNOF(.tdata), ALIGNOF(.tbss)));
