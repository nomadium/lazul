/*
 * lazul EFI loader, installed as \EFI\BOOT\BOOTX64.EFI on the EFI system
 * partition, where the firmware (OVMF in QEMU, or a PC's) looks for a boot
 * program.
 *
 * Its only job: read \kernel.elf from the partition it was loaded from,
 * place the ELF's loadable segments in low free memory, relocate the
 * kernel there, leave UEFI boot services and jump to the kernel's entry
 * point, _start, with
 *   rdi = a struct boot_info (../bootinfo.h): the ACPI tables, the memory
 *         map, a page below 1 MiB for starting the other CPUs, and the EFI
 *         tables
 *
 * The kernel is an ordinary executable linked at a fixed address, built
 * with --emit-relocs so that it keeps its relocation records. On x86-64
 * an absolute address in code is a plain 32 or 64-bit field of the
 * instruction, not split over two instructions as on RISC-V, so moving the
 * kernel is the same addition everywhere: the distance moved, added to the
 * field each R_X86_64_64, R_X86_64_32 or R_X86_64_32S relocation records
 * (see relocate()). The 32-bit ones must still fit afterwards, so the
 * kernel stays below 2 GiB, as -mcmodel=small expects.
 *
 * The loader itself must stay position independent (the firmware loads it
 * anywhere and there are no relocations to apply): -fpie makes all code
 * RIP-relative, and there must be no jump tables and no pointers in
 * initialized data.
 */
#include <stdint.h>

#include "../bootinfo.h"
#include "efi.h"

#define	KERNEL_PATH	u"\\kernel.elf"
#define	PAGE_SIZE	4096
#define	KERNEL_MAX_END	(2ULL << 30)	/* -mcmodel=small: below 2 GiB */
#define	HEAP_PAGES	((64ULL << 20) / PAGE_SIZE)	/* room wanted after it */
#define	MAX_MEMORY	256	/* memory map entries passed to the kernel */

/*
 * The parts of ELF64 the loader reads: the file header, program headers
 * (what to load where), section headers, symbols and relocations (how to
 * move it).
 */
struct elf64_ehdr {
	uint8_t		ident[16];
	uint16_t	type, machine;
	uint32_t	version;
	uint64_t	entry, phoff, shoff;
	uint32_t	flags;
	uint16_t	ehsize, phentsize, phnum, shentsize, shnum, shstrndx;
};

struct elf64_phdr {
	uint32_t	type, flags;
	uint64_t	offset, vaddr, paddr, filesz, memsz, align;
};

struct elf64_shdr {
	uint32_t	name, type;
	uint64_t	flags, addr, offset, size;
	uint32_t	link, info;
	uint64_t	addralign, entsize;
};

struct elf64_sym {
	uint32_t	name;
	uint8_t		info, other;
	uint16_t	shndx;
	uint64_t	value, size;
};

struct elf64_rela {
	uint64_t	offset, info;
	int64_t		addend;
};

#define	PT_LOAD		1
#define	EM_X86_64	62
#define	SHT_RELA	4
#define	SHF_ALLOC	0x2		/* the section is loaded */
#define	SHN_UNDEF	0
#define	SHN_ABS		0xfff1		/* a number, not an address */

/* Relocation types (x86-64 psABI) that hold an absolute address. */
#define	R_X86_64_64		1
#define	R_X86_64_32		10	/* zero-extended to 64 bits */
#define	R_X86_64_32S		11	/* sign-extended */
#define	R_X86_64_16		12
#define	R_X86_64_8		14

/*
 * EDK2 relocates only images that have a base relocation directory; one
 * empty block is enough, as the code is all RIP-relative.
 */
__asm__(".section .reloc, \"a\"\n"
    ".long 0\n"			/* page RVA */
    ".long 10\n"		/* block size: this header and one entry */
    ".word 0\n"			/* IMAGE_REL_BASED_ABSOLUTE: no-op */
    ".previous");

static efi_system_table *st;
static efi_boot_services *bs;
static struct boot_info boot_info;
static struct boot_memory memory[MAX_MEMORY];

/* The compiler may emit calls to these; there is no C library here. */
void *
memcpy(void *dst, const void *src, unsigned long n)
{
	uint8_t *d = dst;
	const uint8_t *s = src;

	while (n-- > 0)
		*d++ = *s++;
	return dst;
}

void *
memset(void *dst, int c, unsigned long n)
{
	uint8_t *d = dst;

	while (n-- > 0)
		*d++ = c;
	return dst;
}

static int
guid_eq(const efi_guid *a, const efi_guid *b)
{
	const uint8_t *x = (const uint8_t *)a, *y = (const uint8_t *)b;
	unsigned i;

	for (i = 0; i < sizeof(efi_guid); i++)
		if (x[i] != y[i])
			return 0;
	return 1;
}

/* Print s on the firmware's console, which takes UTF-16 and CR LF. */
static void
print(const char *s)
{
	char16 buf[128];
	unsigned n = 0;

	for (; *s != '\0'; s++) {
		if (*s == '\n')
			buf[n++] = '\r';
		buf[n++] = *s;
		if (n >= 126 || s[1] == '\0') {
			buf[n] = 0;
			st->con_out->output_string(st->con_out, buf);
			n = 0;
		}
	}
}

/* Print v as "0x" followed by 16 hex digits. */
static void
print_hex(uint64_t v)
{
	char buf[19] = "0x";
	int shift;
	int i = 2;

	for (shift = 60; shift >= 0; shift -= 4)
		buf[i++] = "0123456789abcdef"[(v >> shift) & 0xf];
	buf[i] = '\0';
	print(buf);
}

/* Report why booting failed; returns an error status for efi_main(). */
static efi_status
fail(const char *msg, efi_status status)
{
	print("lazul loader: ");
	print(msg);
	print(" (status ");
	print_hex(status);
	print(")\n");
	return status != EFI_SUCCESS ? status : EFI_LOAD_ERROR;
}

/*
 * Read the current memory map into a buffer from the pool; free it with
 * free_pool(). Allocating the buffer can grow the map, hence the slack.
 */
static efi_status
get_memory_map(void **map, uint64_t *size, uint64_t *key,
    uint64_t *desc_size)
{
	uint32_t desc_version;
	efi_status s;

	*map = 0;
	*size = 0;
	s = bs->get_memory_map(size, *map, key, desc_size, &desc_version);
	if (s != EFI_BUFFER_TOO_SMALL)
		return s == EFI_SUCCESS ? EFI_LOAD_ERROR : s;
	*size += 4 * *desc_size;
	s = bs->allocate_pool(EFI_LOADER_DATA, *size, map);
	if (s != EFI_SUCCESS)
		return s;
	s = bs->get_memory_map(size, *map, key, desc_size, &desc_version);
	if (s != EFI_SUCCESS)
		bs->free_pool(*map);
	return s;
}

/*
 * Reserve the lowest free run of pages pages below KERNEL_MAX_END, and set
 * *base to it. Low, and with HEAP_PAGES more free pages after it if there
 * is such a place: the kernel's heap runs from the end of the kernel
 * through the free memory that follows it (boot.c).
 */
static efi_status
allocate_low(uint64_t pages, uint64_t *base)
{
	const efi_memory_descriptor *d;
	uint64_t desc_size, i, key, need, size;
	void *map;
	efi_status s;
	int pass;

	s = get_memory_map(&map, &size, &key, &desc_size);
	if (s != EFI_SUCCESS)
		return s;
	*base = ~0ULL;
	for (pass = 0; pass < 2 && *base == ~0ULL; pass++) {
		need = pass == 0 ? pages + HEAP_PAGES : pages;
		for (i = 0; i + desc_size <= size; i += desc_size) {
			d = (const efi_memory_descriptor *)((uint8_t *)map +
			    i);
			if (d->type == EFI_CONVENTIONAL_MEMORY &&
			    d->number_of_pages >= need &&
			    d->physical_start + pages * PAGE_SIZE <=
			    KERNEL_MAX_END && d->physical_start < *base)
				*base = d->physical_start;
		}
	}
	bs->free_pool(map);
	if (*base == ~0ULL)
		return EFI_BUFFER_TOO_SMALL;
	return bs->allocate_pages(ALLOCATE_ADDRESS, EFI_LOADER_CODE, pages,
	    base);
}

/*
 * Move the kernel, which load_elf() copied delta = base - link_lo bytes
 * away from where it was linked to run: add delta to every absolute
 * address stored in a loaded section, code or data, which is what each
 * R_X86_64_64, R_X86_64_32 and R_X86_64_32S relocation records.
 * Relocations against symbols that are numbers (SHN_ABS, e.g. sizes from
 * the linker script) or undefined (weak, left 0) are not addresses and
 * stay as they are. Every other relocation is RIP-relative, an offset
 * from the thread pointer or a difference of two addresses, which moving
 * everything together leaves right. 8 and 16-bit absolute addresses would
 * overflow, so they are refused.
 */
static efi_status
relocate(const uint8_t *image, uint64_t size, uint64_t link_lo,
    uint64_t base)
{
	const struct elf64_ehdr *eh = (const struct elf64_ehdr *)image;
	const struct elf64_shdr *rel, *sh, *symtab;
	const struct elf64_rela *r;
	const struct elf64_sym *sym;
	uint64_t delta = base - link_lo, done = 0, i, j, nsyms, type, v;
	uint8_t *p;

	if (eh->shoff == 0 || eh->shentsize != sizeof(*sh) ||
	    eh->shoff + eh->shnum * sizeof(*sh) > size)
		return fail("kernel.elf has no section headers", 0);
	sh = (const struct elf64_shdr *)(image + eh->shoff);

	for (i = 0; i < eh->shnum; i++) {
		rel = &sh[i];
		if (rel->type != SHT_RELA || rel->info >= eh->shnum ||
		    rel->link >= eh->shnum)
			continue;
		if ((sh[rel->info].flags & SHF_ALLOC) == 0)
			continue;	/* e.g. debug information */
		symtab = &sh[rel->link];
		if (rel->offset + rel->size > size ||
		    symtab->offset + symtab->size > size)
			return fail("truncated relocations", 0);
		nsyms = symtab->size / sizeof(*sym);
		r = (const struct elf64_rela *)(image + rel->offset);
		for (j = 0; j < rel->size / sizeof(*r); j++, r++) {
			type = r->info & 0xffffffff;
			if (type != R_X86_64_64 && type != R_X86_64_32 &&
			    type != R_X86_64_32S && type != R_X86_64_16 &&
			    type != R_X86_64_8)
				continue;	/* relative: still right */
			if ((r->info >> 32) >= nsyms)
				return fail("bad symbol in a relocation", 0);
			sym = (const struct elf64_sym *)(image +
			    symtab->offset) + (r->info >> 32);
			if (sym->shndx == SHN_ABS || sym->shndx == SHN_UNDEF)
				continue;	/* a number, not an address */
			p = (uint8_t *)(r->offset + delta);
			switch (type) {
			case R_X86_64_64:
				*(uint64_t *)p += delta;
				break;
			case R_X86_64_32:
				v = *(uint32_t *)p + delta;
				if (v > 0xffffffffULL)
					return fail("kernel above 4 GiB", 0);
				*(uint32_t *)p = v;
				break;
			case R_X86_64_32S:
				v = (uint64_t)(int64_t)*(int32_t *)p + delta;
				if ((int64_t)v != (int32_t)v)
					return fail("kernel above 2 GiB", 0);
				*(uint32_t *)p = v;
				break;
			default:
				return fail("8 or 16-bit absolute address "
				    "in the kernel", 0);
			}
			done++;
		}
	}
	print("  relocated ");
	print_hex(done);
	print(" addresses by ");
	print_hex(delta);
	print("\n");
	return EFI_SUCCESS;
}

/*
 * Place the ELF file at image in memory and set *entry. The whole span
 * that its PT_LOAD segments cover is reserved with the firmware first, in
 * one allocation since segments may share a page: low free pages (see
 * allocate_low()), wherever the kernel was linked to run, which works
 * whatever memory the firmware has taken. The kernel is then relocated
 * there.
 */
static efi_status
load_elf(const uint8_t *image, uint64_t size, uint64_t *entry)
{
	const struct elf64_ehdr *eh = (const struct elf64_ehdr *)image;
	const struct elf64_phdr *ph;
	uint64_t base, delta, hi = 0, lo = ~0ULL, pages;
	efi_status s;
	unsigned i;

	if (size < sizeof(*eh) || eh->ident[0] != 0x7f ||
	    eh->ident[1] != 'E' || eh->ident[2] != 'L' ||
	    eh->ident[3] != 'F' || eh->ident[4] != 2 ||
	    eh->machine != EM_X86_64)
		return fail("kernel.elf is not an x86-64 ELF64 file", 0);

	for (i = 0; i < eh->phnum; i++) {
		ph = (const struct elf64_phdr *)(image + eh->phoff +
		    i * eh->phentsize);
		if (ph->type != PT_LOAD || ph->memsz == 0)
			continue;
		if (ph->offset + ph->filesz > size)
			return fail("truncated segment", 0);
		if (ph->paddr < lo)
			lo = ph->paddr;
		if (ph->paddr + ph->memsz > hi)
			hi = ph->paddr + ph->memsz;
	}
	if (hi == 0)
		return fail("no loadable segments", 0);

	lo &= ~(uint64_t)(PAGE_SIZE - 1);
	pages = (hi - lo + PAGE_SIZE - 1) / PAGE_SIZE;
	if ((s = allocate_low(pages, &base)) != EFI_SUCCESS)
		return fail("no free memory for the kernel", s);
	delta = base - lo;

	for (i = 0; i < eh->phnum; i++) {
		ph = (const struct elf64_phdr *)(image + eh->phoff +
		    i * eh->phentsize);
		if (ph->type != PT_LOAD || ph->memsz == 0)
			continue;
		memcpy((void *)(ph->paddr + delta), image + ph->offset,
		    ph->filesz);
		memset((void *)(ph->paddr + delta + ph->filesz), 0,
		    ph->memsz - ph->filesz);
	}

	print("  kernel linked at ");
	print_hex(lo);
	print(", loaded at ");
	print_hex(base);
	print("\n");
	if (delta != 0) {
		s = relocate(image, size, lo, base);
		if (s != EFI_SUCCESS)
			return s;
	}
	*entry = eh->entry + delta;
	return EFI_SUCCESS;
}

/* Read \kernel.elf from the loader's own partition into *buf. */
static efi_status
read_kernel(efi_handle image_handle, uint8_t **buf, uint64_t *size)
{
	efi_guid loaded_image_guid = EFI_LOADED_IMAGE_PROTOCOL_GUID;
	efi_guid sfs_guid = EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID;
	efi_loaded_image *li;
	efi_simple_file_system *fs;
	efi_file *file, *root;
	efi_status s;
	uint64_t n;

	s = bs->handle_protocol(image_handle, &loaded_image_guid,
	    (void **)&li);
	if (s != EFI_SUCCESS)
		return fail("no loaded image protocol", s);
	s = bs->handle_protocol(li->device_handle, &sfs_guid, (void **)&fs);
	if (s != EFI_SUCCESS)
		return fail("boot device has no file system", s);
	if ((s = fs->open_volume(fs, &root)) != EFI_SUCCESS)
		return fail("cannot open boot volume", s);
	s = root->open(root, &file, KERNEL_PATH, EFI_FILE_MODE_READ, 0);
	if (s != EFI_SUCCESS)
		return fail("cannot open \\kernel.elf", s);

	file->set_position(file, EFI_FILE_POSITION_END);
	file->get_position(file, size);
	file->set_position(file, 0);
	s = bs->allocate_pool(EFI_LOADER_DATA, *size, (void **)buf);
	if (s != EFI_SUCCESS)
		return fail("out of memory", s);
	n = *size;
	if ((s = file->read(file, &n, *buf)) != EFI_SUCCESS || n != *size)
		return fail("cannot read \\kernel.elf", s);
	file->close(file);
	root->close(root);
	return EFI_SUCCESS;
}

/* The firmware's configuration table entry for guid, or 0. */
static void *
find_config_table(efi_guid guid)
{
	uint64_t i;

	for (i = 0; i < st->number_of_table_entries; i++)
		if (guid_eq(&st->configuration_table[i].guid, &guid))
			return st->configuration_table[i].table;
	return 0;
}

/* What the kernel makes of an EFI memory type (bootinfo.h). */
static uint64_t
boot_memory_type(uint32_t type)
{
	switch (type) {
	case EFI_CONVENTIONAL_MEMORY:
	case EFI_BOOT_SERVICES_CODE:	/* the firmware is done with these */
	case EFI_BOOT_SERVICES_DATA:
		return BOOT_MEM_FREE;
	case EFI_ACPI_RECLAIM_MEMORY:
		return BOOT_MEM_ACPI;
	case EFI_ACPI_MEMORY_NVS:
		return BOOT_MEM_NVS;
	case EFI_UNUSABLE_MEMORY:
		return BOOT_MEM_UNUSABLE;
	default:
		/*
		 * Among others, the loader's own memory (the kernel, this
		 * loader with the boot info it passes, the trampoline page)
		 * and the runtime services', which the kernel still calls.
		 */
		return BOOT_MEM_RESERVED;
	}
}

/*
 * Turn the final EFI memory map into the kernel's (memory[]), sorted by
 * address, with neighbours of the same type merged. It runs after
 * ExitBootServices, so it cannot report anything: entries beyond
 * MAX_MEMORY are dropped.
 */
static void
convert_memory_map(const void *map, uint64_t size, uint64_t desc_size)
{
	const efi_memory_descriptor *d;
	struct boot_memory m, *last;
	uint64_t i, j, n = 0;

	for (i = 0; i + desc_size <= size; i += desc_size) {
		d = (const efi_memory_descriptor *)((const uint8_t *)map + i);
		m.base = d->physical_start;
		m.size = d->number_of_pages * PAGE_SIZE;
		m.type = boot_memory_type(d->type);
		last = n > 0 ? &memory[n - 1] : 0;
		if (last != 0 && last->type == m.type &&
		    last->base + last->size == m.base) {
			last->size += m.size;
			continue;
		}
		if (n == MAX_MEMORY)
			break;
		/* Insertion sort: the firmware's order is not guaranteed. */
		for (j = n; j > 0 && memory[j - 1].base > m.base; j--)
			memory[j] = memory[j - 1];
		memory[j] = m;
		n++;
	}
	boot_info.memory_map = (uint64_t)memory;
	boot_info.memory_map_entries = n;
}

/*
 * Leave boot services. ExitBootServices needs the key of the current
 * memory map, and fails if the map changed since it was read (allocating
 * the buffer for it can change it), so this retries a few times. The
 * final map stays valid afterwards; the kernel gets it in boot_info.
 */
static efi_status
exit_boot_services(efi_handle image_handle)
{
	uint64_t desc_size = 48, key, size = 0;
	uint32_t desc_version;
	void *map = 0;
	efi_status s = EFI_SUCCESS;
	int attempt;

	for (attempt = 0; attempt < 4; attempt++) {
		s = bs->get_memory_map(&size, map, &key, &desc_size,
		    &desc_version);
		if (s == EFI_BUFFER_TOO_SMALL) {
			if (map != 0)
				bs->free_pool(map);
			size += 4 * desc_size;	/* room for the pool itself */
			s = bs->allocate_pool(EFI_LOADER_DATA, size, &map);
			if (s != EFI_SUCCESS)
				return s;
			continue;
		}
		if (s != EFI_SUCCESS)
			return s;
		s = bs->exit_boot_services(image_handle, key);
		if (s == EFI_SUCCESS) {
			convert_memory_map(map, size, desc_size);
			return s;
		}
	}
	return s;
}

EFIAPI efi_status
efi_main(efi_handle image_handle, efi_system_table *system_table)
{
	uint64_t entry = 0, size, trampoline;
	uint8_t *kernel;
	void *rsdp;
	efi_status s;

	st = system_table;
	bs = st->boot_services;
	print("lazul EFI loader\n");

	rsdp = find_config_table((efi_guid)EFI_ACPI_20_TABLE_GUID);
	if (rsdp == 0)
		rsdp = find_config_table((efi_guid)EFI_ACPI_10_TABLE_GUID);
	if (rsdp == 0)
		return fail("no ACPI tables in the EFI configuration table", 0);

	/* Other CPUs start in real mode, at a page below 1 MiB. */
	trampoline = 0x9f000;
	s = bs->allocate_pages(ALLOCATE_MAX_ADDRESS, EFI_LOADER_DATA, 1,
	    &trampoline);
	if (s != EFI_SUCCESS)
		return fail("no free page below 1 MiB for starting CPUs", s);

	if ((s = read_kernel(image_handle, &kernel, &size)) != EFI_SUCCESS)
		return s;
	if ((s = load_elf(kernel, size, &entry)) != EFI_SUCCESS)
		return s;
	bs->free_pool(kernel);	/* the file: the heap can have it */

	boot_info.magic = BOOT_INFO_MAGIC;
	boot_info.acpi_rsdp = (uint64_t)rsdp;
	boot_info.trampoline = trampoline;
	boot_info.efi_system_table = (uint64_t)st;
	boot_info.efi_runtime_services = (uint64_t)st->runtime_services;

	print("  kernel.elf: ");
	print_hex(size);
	print(" bytes, entry ");
	print_hex(entry);
	print("\n  ACPI tables at ");
	print_hex((uint64_t)rsdp);
	print(", trampoline page ");
	print_hex(trampoline);
	print("\n  exiting boot services, jumping to the kernel\n");

	if ((s = exit_boot_services(image_handle)) != EFI_SUCCESS)
		return fail("ExitBootServices failed", s);

	/*
	 * No firmware from here on, except the runtime services. Interrupts
	 * off; the kernel sets up its own GDT, IDT and page tables, the
	 * firmware's being in memory it now treats as free.
	 */
	__asm__ volatile("cli");
	((void (*)(struct boot_info *))entry)(&boot_info);
	for (;;)
		__asm__ volatile("hlt");
}
