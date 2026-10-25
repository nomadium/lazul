/*
 * kernel linker script: QEMU virt, S-mode payload loaded by OpenSBI.
 *
 * The compiler turns each .c and .S file into an object file (.o). Every
 * object holds named *sections* of code or data: .text for code, .rodata
 * for constants, .data for initialised variables, .bss for zeroed ones,
 * and a few more described below. The linker (ld, run by gcc in the
 * Makefile's kernel.elf rule) glues the sections of all the objects and
 * libraries together, picks an address for every byte, resolves the
 * references between them and writes build/riscv64/kernel.elf.
 *
 * This file tells the linker how to do that: which sections go where, in
 * which order, at which addresses, and which extra symbols to define. It
 * is passed with -T src/arch/riscv64/kernel.ld. Without -T, gcc would
 * use the default script of picolibc (our C library), picolibc.ld, which
 * is laid out for a microcontroller with flash and RAM; a kernel loaded
 * into RAM needs its own. picolibc.specs adds -Tpicolibc.ld only when no
 * -T is given.
 *
 * The result can be checked after every build:
 *   build/riscv64/kernel.map    written by -Wl,-Map: every input section,
 *                               where it went, and every symbol's address
 *   riscv64-unknown-elf-readelf -lSW build/riscv64/kernel.elf
 *                               the sections and segments described below
 *   riscv64-unknown-elf-nm -n build/riscv64/kernel.elf
 *                               all symbols, sorted by address
 *
 * Memory map of the kernel as linked (addresses for the default build):
 *
 *   0x80000000  +--------------------+
 *               | OpenSBI            |  firmware, M-mode; not ours
 *   0x80200000  +--------------------+  ORIGIN(ram)
 *               | .text              |  code; _start is the first byte
 *               | .rodata            |  constants, the Ruby bytecode
 *               +--------------------+  (first segment: read + execute)
 *               | .data              |  initialised variables
 *               |   .sdata           |  small ones, near gp
 *               | .tdata / .tbss     |  the TLS template
 *               | .bss               |  zeroed by _start
 *               |   hart_stacks      |  1 MiB, from start.S
 *               |   hart_tls, ...    |
 *               +--------------------+  (second segment: read + write)
 *               | (padding)          |  up to a 4 KiB boundary
 *   __heap_start+--------------------+  __kernel_end
 *               | heap               |  handed out by sbrk() in main.c
 *               |                    |  to malloc, i.e. to mruby
 *   __heap_end  +--------------------+  ORIGIN(ram) + LENGTH(ram)
 *               | (the DTB may sit   |  boot_main() lowers heap_limit
 *               |  here, or lower)   |  if it lies inside the heap
 *   0x88000000  +--------------------+  end of RAM with -m 128M
 *
 * Syntax notes for reading the rest:
 *   - "."  is the location counter: the address the linker will place the
 *     next byte at. Assigning to it moves it forward (never backwards
 *     inside a section).
 *   - A symbol defined here (e.g. __bss_start = .;) is only an address.
 *     It has no storage. C declares it as an array, "extern char
 *     __heap_start[];", and uses its address, never its value.
 *   - Input section patterns are shell globs over section names, written
 *     as "file(sections)"; "*" matches every input file.
 */

/* Machine type recorded in the ELF header. */
OUTPUT_ARCH(riscv)

/*
 * The ELF entry point (e_entry in the ELF header). QEMU reads it from
 * kernel.elf and passes it to OpenSBI as the address to jump to in
 * S-mode. It also roots the garbage collection done by --gc-sections
 * (see .text below): everything reachable from _start is kept.
 */
ENTRY(_start)

/*
 * The memory the kernel may occupy. The (rwx) attributes say that any
 * kind of section may go there; they matter only for "orphan" sections,
 * which this script does not name and the linker places on its own.
 *
 * ORIGIN: QEMU virt's RAM starts at 0x80000000. OpenSBI (-bios default)
 * takes the first 2 MiB and jumps to the next stage at 0x80200000, so
 * the kernel is linked to run there. The MMU is off, so these are
 * physical addresses and the code must sit exactly there: the address is
 * baked into every absolute reference in the binary.
 *
 * LENGTH: 128 MiB of RAM (MEM ?= 128M in the Makefile) minus those 2 MiB.
 * It sets __heap_end below, so it has to agree with the RAM that QEMU
 * gives the machine. With more RAM the rest goes unused; with less the
 * heap would run past the end of RAM. The linker also fails the link if
 * the sections themselves overflow this region.
 */
MEMORY { ram (rwx) : ORIGIN = 0x80200000, LENGTH = 126M }

/*
 * Program headers, or *segments*: what a loader looks at. A section is
 * the linker's unit; a segment is the loader's: "copy these file bytes to
 * that address, then zero-fill up to this size, with these permissions".
 * readelf -l shows both and which sections ended up in which segment.
 *
 * Without PHDRS the linker would make up the segments itself. Listing
 * them makes the result explicit:
 *   text  PT_LOAD  .text and .rodata. Read + execute.
 *   data  PT_LOAD  .data, .tdata, .bss. Read + write. Its memory size is
 *                  bigger than its file size: the .bss part takes no space
 *                  in the file, and the loader should zero it. start.S
 *                  zeroes it anyway, as not every loader does.
 *   tls   PT_TLS   .tdata and .tbss: not something to load (they already
 *                  sit inside "data") but a description of the TLS
 *                  template, for whoever sets up thread-local storage.
 *                  Once PHDRS is given, the linker emits only the listed
 *                  segments, so this one has to be listed.
 * The permissions come from the sections in each segment. Nothing
 * enforces them while the MMU is off, but they keep code and writable
 * data in separate, page-aligned (0x1000) segments.
 *
 * Each output section below names its segment(s) after a ":" and its
 * memory region after a ">".
 */
PHDRS {
  text PT_LOAD;
  data PT_LOAD;
  tls  PT_TLS;
}

SECTIONS
{
  /*
   * Code.
   *
   * .text.entry holds _start and _secondary_start (start.S puts them in a
   * section of their own for this). Listing it first puts _start at the
   * first address of the region, 0x80200000, where OpenSBI jumps. That
   * matters for loaders that ignore the ELF entry point and just jump to
   * the start of the image, e.g. after objcopy -O binary.
   *
   * KEEP: the Makefile links with --gc-sections, which drops every
   * section that nothing references. The compiler is told to put every
   * function in a section of its own (-ffunction-sections, giving names
   * like .text.boot_main), and every variable too (-fdata-sections), so
   * unused functions and data disappear one by one.
   * KEEP exempts the entry code from that pruning, whatever references it.
   *
   * Then the rest of the code: plain .text and every .text.<name>.
   */
  .text : {
    KEEP(*(.text.entry))
    *(.text .text.*)
  } >ram :text

  /*
   * Read-only data: string literals, const tables, and kernel_rb, the
   * kernel's Ruby code compiled to bytecode by mrbc. .srodata is the
   * "small" variant: constants of 8 bytes or less, which the compiler may
   * keep apart (see .sdata).
   *
   * ALIGN(16) aligns the start of the output section. 16 bytes is the
   * largest alignment any type needs on RV64 (long double, and the stack),
   * so it is the safe choice for any section start.
   */
  .rodata : ALIGN(16) { *(.rodata .rodata.* .srodata .srodata.*) } >ram :text

  /*
   * Initialised read-write data, e.g. "char *heap_limit = __heap_end;".
   * Its initial values are stored in the file and loaded with the image.
   *
   * __global_pointer$ and .sdata: RISC-V keeps one register, gp, pointing
   * into the data. Any address within gp - 2 KiB .. gp + 2 KiB is then
   * reachable with one instruction (a 12-bit signed offset from gp)
   * instead of the usual two (lui + addi, or auipc + addi). The linker
   * makes that rewrite itself, called "relaxation", wherever the target
   * turns out to be in range.
   *
   * To give that window the best chance, the compiler puts small
   * variables (8 bytes or less) in .sdata ("small data") and .sbss, and
   * the script sets gp 0x800 (2 KiB) past the start of .sdata: the whole
   * 4 KiB window then covers .sdata and whatever follows it. The name,
   * dollar sign included, is fixed by the RISC-V ABI; start.S loads gp
   * from it before any C code runs, and C code must never change gp.
   * Getting it wrong would not crash the link: relaxed instructions would
   * just read and write the wrong addresses at run time.
   *
   * In the current layout the window covers .sdata, the TLS template
   * (which picolibc's _init_tls reads through gp) and .sbss, which .bss
   * below places first for that reason.
   */
  .data : ALIGN(16) {
    *(.data .data.*)
    __global_pointer$ = . + 0x800;
    *(.sdata .sdata.*)
  } >ram :data

  /*
   * Thread-local storage (TLS): variables declared __thread in C, such as
   * this_hartid in main.c, of which every hart has its own copy.
   *
   * The compiler puts initialised ones in .tdata and zeroed ones in .tbss.
   * Together they form the *TLS template*: the image every hart's copy
   * starts from. At run time hart_setup() in main.c gives each hart a
   * block in hart_tls[], and arch_set_tls() (arch.c) has picolibc fill it:
   *   _init_tls(block)  copies .tdata to the start of the block and zeroes
   *                     the .tbss part after it
   *   _set_tls(block)   points the tp register at the block
   * The compiler accesses a __thread variable as tp + (its offset in the
   * template), so each hart sees its own copy. The template itself is
   * never used as a variable.
   *
   * ":data :tls" puts these sections in two segments at once: "data", so
   * the .tdata bytes are loaded with the rest of the image, and "tls",
   * which describes the template.
   *
   * The ". = ALIGN(16)" at the end of .tbss pads the template to a
   * multiple of 16 bytes, so that __tls_size below covers whole blocks.
   *
   * .tbss_space: .tbss is special to GNU ld. Being TLS and zero-filled, it
   * has an address and a size but does not advance the location counter,
   * so the next section would start at the same address and overlap it.
   * This empty section moves "." past .tbss to reserve that range. The
   * idea, and the name, come from picolibc.ld, where the template doubles
   * as the first thread's TLS block. lazul never uses the template in
   * place, so here it only keeps .bss from overlapping it (16 bytes).
   * NOLOAD marks it as taking no space in the file.
   */
  .tdata : ALIGN(16) { *(.tdata .tdata.*) } >ram :data :tls
  .tbss  : ALIGN(16) { *(.tbss .tbss.*) . = ALIGN(16); } >ram :data :tls
  .tbss_space (NOLOAD) : { . = ADDR(.tbss) + SIZEOF(.tbss); } >ram :data

  /*
   * Zero-initialised data: variables with no initial value or an initial
   * value of zero, e.g. hart_stacks (start.S), hart_tls, bkl and mrb
   * (main.c). None of it is stored in the file (NOLOAD; the section is of
   * type NOBITS). The memory has to be zeroed before C code runs: _start
   * clears every byte from __bss_start up to __bss_end.
   *
   * COMMON is the old-style home of uninitialised globals that several
   * files may define (gcc only emits it with -fcommon; GCC 10 and later
   * default to -fno-common). It is listed so nothing ends up as an orphan.
   *
   * .sbss gets a line of its own, ahead of the rest. Within one line the
   * linker places sections in the order it meets them, file by file, not
   * grouped by pattern. With a single line, hart_stacks (1 MiB, from
   * start.o, the first file of the link) would open .bss and push the
   * small variables out of gp's reach (see the gp note above). Separate
   * lines are filled one after the other, so .sbss comes right after the
   * TLS template, inside the gp window.
   *
   * Both ends are 16-byte aligned, which lets _start clear it 8 bytes at a
   * time with no leftover bytes to handle.
   */
  .bss (NOLOAD) : ALIGN(16) {
    __bss_start = .;
    *(.sbss .sbss.*)
    *(.bss .bss.* COMMON)
    . = ALIGN(16);
    __bss_end = .;
  } >ram :data

  /*
   * Everything from here to the end of the region is the heap. It starts
   * at the next 4 KiB page boundary after the kernel image. Nothing needs
   * the page alignment yet, but page tables, once there is an MMU setup,
   * map whole pages.
   *
   * These symbols are not in any section: they are plain addresses.
   *   __kernel_end   first byte after the kernel image
   *   __heap_start   first byte of the heap (same address); sbrk() starts
   *                  here, and Ruby sees it as Kern::HEAP_START
   *   __heap_end     end of RAM as described by MEMORY above; main.c
   *                  starts heap_limit here
   */
  . = ALIGN(4096);
  __kernel_end = .;
  __heap_start = .;
  __heap_end = ORIGIN(ram) + LENGTH(ram);

  /*
   * Input sections that are thrown away instead of linked in:
   *   .note, .note.*        notes such as the GNU build id and the ABI tag
   *   .comment              the compiler's version string
   *   .riscv.attributes     the ISA the objects were built for, used by
   *                         tools such as objdump
   * None of them is needed at run time.
   *
   * Sections not named anywhere in this script and not discarded are
   * "orphans": the linker places them itself, next to similar sections.
   * The debug sections (.debug_*, from -g) are orphans of that kind; they
   * have no address and are not loaded, they are only in the file for
   * gdb.
   */
  /DISCARD/ : { *(.note .note.* .comment .riscv.attributes) }
}

/*
 * Symbols that picolibc's TLS code needs. _init_tls() and _tls_size()
 * are written against picolibc.ld, which defines these; this script
 * replaces picolibc.ld, so it has to define them too, with the same
 * meanings. ADDR, SIZEOF and ALIGNOF give an output section's address,
 * size and alignment.
 *
 *   __tdata_source  where the .tdata template bytes are (copied by
 *                   _init_tls). In picolibc.ld this is a flash address
 *                   (LOADADDR); here the image is loaded straight into
 *                   RAM, so it is the section's own address.
 *   __tdata_size    how many bytes to copy
 *   __tbss_offset   where the zeroed part starts within a TLS block (after
 *                   .tdata plus alignment padding)
 *   __tbss_size     how many bytes to zero there
 *   __tls_size      size of one whole TLS block; _tls_size() returns it,
 *                   and hart_setup() panics if it outgrows TLS_AREA, the
 *                   size of each hart's block in hart_tls[]
 *   __tls_align     alignment a TLS block needs
 *
 * PROVIDE defines a symbol only if something references it and nothing
 * else defines it. So these cost nothing when unused (__tls_align, today)
 * and never clash with a definition elsewhere. The ones that are just
 * numbers (sizes, offsets) show up as absolute symbols ("A") in nm.
 */
PROVIDE(__tdata_source = ADDR(.tdata));
PROVIDE(__tdata_size = SIZEOF(.tdata));
PROVIDE(__tbss_offset = ADDR(.tbss) - ADDR(.tdata));
PROVIDE(__tbss_size = SIZEOF(.tbss));
PROVIDE(__tls_size = ADDR(.tbss) + SIZEOF(.tbss) - ADDR(.tdata));
PROVIDE(__tls_align = MAX(ALIGNOF(.tdata), ALIGNOF(.tbss)));
