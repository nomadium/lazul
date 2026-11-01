/*
 * lazul EFI loader, installed as \EFI\BOOT\BOOTRISCV64.EFI on the EFI
 * system partition, where the firmware (e.g. U-Boot) looks for a boot
 * program.
 *
 * Its only job: read \kernel.elf from the partition it was loaded from,
 * place the ELF's loadable segments in the lowest free memory that holds
 * them, relocate the kernel there, leave UEFI boot services and jump to
 * the kernel's entry point with the same register contract as a direct
 * boot from OpenSBI:
 *   a0 = boot hart id (from RISCV_EFI_BOOT_PROTOCOL)
 *   a1 = device tree  (from the EFI configuration table)
 *
 * The kernel is an ordinary executable linked at a fixed address, built
 * with --emit-relocs so that it keeps its relocation records. Its code is
 * all PC-relative (-mcmodel=medany), so moving it only takes adding the
 * distance moved to every absolute address stored in its data: each
 * R_RISCV_64 relocation (see relocate()).
 *
 * The loader itself must stay position independent (the firmware loads it
 * anywhere and there are no relocations to apply): -mcmodel=medany makes
 * all code PC-relative, and there must be no jump tables and no pointers
 * in initialized data.
 */
#include <stdint.h>

#include "efi.h"

#define	KERNEL_PATH	u"\\kernel.elf"
#define	PAGE_SIZE	4096

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
#define	EM_RISCV	243
#define	SHT_RELA	4
#define	SHF_ALLOC	0x2		/* the section is loaded */
#define	SHN_UNDEF	0
#define	SHN_ABS		0xfff1		/* a number, not an address */

/* Relocation types (RISC-V ELF psABI) that hold an absolute address. */
#define	R_RISCV_32		1
#define	R_RISCV_64		2
#define	R_RISCV_HI20		26
#define	R_RISCV_LO12_I		27
#define	R_RISCV_LO12_S		28

static efi_system_table *st;
static efi_boot_services *bs;

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
 * Reserve the lowest free run of pages pages, and set *base to it. Low,
 * because the kernel's heap runs from the end of the kernel to the end of
 * its RAM: a kernel at the top of RAM would leave it none.
 */
static efi_status
allocate_low(uint64_t pages, uint64_t *base)
{
	const efi_memory_descriptor *d;
	uint64_t desc_size, i, key, size;
	void *map;
	efi_status s;

	s = get_memory_map(&map, &size, &key, &desc_size);
	if (s != EFI_SUCCESS)
		return s;
	*base = ~0ULL;
	for (i = 0; i + desc_size <= size; i += desc_size) {
		d = (const efi_memory_descriptor *)((uint8_t *)map + i);
		if (d->type == EFI_CONVENTIONAL_MEMORY &&
		    d->number_of_pages >= pages && d->physical_start < *base)
			*base = d->physical_start;
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
 * address stored in a loaded section, which is what each R_RISCV_64
 * relocation records. Relocations against symbols that are numbers
 * (SHN_ABS, e.g. sizes from the linker script) or undefined (weak, left 0)
 * are not addresses and stay as they are. Every other relocation is
 * PC-relative or a difference of two addresses, which moving everything
 * together leaves right. An absolute address in code would need its
 * instructions rewritten, so that is refused.
 */
static efi_status
relocate(const uint8_t *image, uint64_t size, uint64_t link_lo,
    uint64_t base)
{
	const struct elf64_ehdr *eh = (const struct elf64_ehdr *)image;
	const struct elf64_shdr *rel, *sh, *symtab;
	const struct elf64_rela *r;
	const struct elf64_sym *sym;
	uint64_t delta = base - link_lo, done = 0, i, j, nsyms, type;

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
			if (type != R_RISCV_64 && type != R_RISCV_32 &&
			    type != R_RISCV_HI20 && type != R_RISCV_LO12_I &&
			    type != R_RISCV_LO12_S)
				continue;	/* relative: still right */
			if ((r->info >> 32) >= nsyms)
				return fail("bad symbol in a relocation", 0);
			sym = (const struct elf64_sym *)(image +
			    symtab->offset) + (r->info >> 32);
			if (sym->shndx == SHN_ABS || sym->shndx == SHN_UNDEF)
				continue;	/* a number, not an address */
			if (type != R_RISCV_64)
				return fail("absolute address in kernel code; "
				    "build it with -mcmodel=medany", 0);
			*(uint64_t *)(r->offset + delta) += delta;
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
 * one allocation since segments may share a page: the lowest free pages
 * that hold it, wherever the kernel was linked to run, which works on any
 * board whatever its RAM addresses. The kernel is then relocated there.
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
	    eh->machine != EM_RISCV)
		return fail("kernel.elf is not a RISC-V ELF64 file", 0);

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

/*
 * Leave boot services. ExitBootServices needs the key of the current
 * memory map, and fails if the map changed since it was read (allocating
 * the buffer for it can change it), so this retries a few times. The
 * kernel reads the machine's memory from the device tree, so the map
 * itself is not passed on.
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
		if (s == EFI_SUCCESS)
			return s;
	}
	return s;
}

efi_status
efi_main(efi_handle image_handle, efi_system_table *system_table)
{
	efi_guid riscv_boot_guid = RISCV_EFI_BOOT_PROTOCOL_GUID;
	riscv_efi_boot_protocol *rbp;
	uint64_t entry = 0, hartid, size;
	uint8_t *kernel;
	void *dtb;
	efi_status s;

	st = system_table;
	bs = st->boot_services;
	print("lazul EFI loader\n");

	s = bs->locate_protocol(&riscv_boot_guid, 0, (void **)&rbp);
	if (s != EFI_SUCCESS)
		return fail("no RISCV_EFI_BOOT_PROTOCOL", s);
	if ((s = rbp->get_boot_hartid(rbp, &hartid)) != EFI_SUCCESS)
		return fail("cannot get the boot hart id", s);
	dtb = find_config_table((efi_guid)EFI_DTB_TABLE_GUID);
	if (dtb == 0)
		return fail("no device tree in the EFI configuration table", 0);

	if ((s = read_kernel(image_handle, &kernel, &size)) != EFI_SUCCESS)
		return s;
	if ((s = load_elf(kernel, size, &entry)) != EFI_SUCCESS)
		return s;

	print("  kernel.elf: ");
	print_hex(size);
	print(" bytes, entry ");
	print_hex(entry);
	print("\n  boot hart ");
	print_hex(hartid);
	print(", device tree at ");
	print_hex((uint64_t)dtb);
	print("\n  exiting boot services, jumping to the kernel\n");

	if ((s = exit_boot_services(image_handle)) != EFI_SUCCESS)
		return fail("ExitBootServices failed", s);

	/*
	 * No firmware from here on. Make the copied kernel visible to
	 * instruction fetch, and enter it the way OpenSBI would: interrupts
	 * off (sstatus.SIE and sie) and the MMU off (satp = 0).
	 */
	__asm__ volatile("fence.i");
	__asm__ volatile("csrc sstatus, %0" : : "r"(1UL << 1));
	__asm__ volatile("csrw sie, zero");
	__asm__ volatile("csrw satp, zero; sfence.vma");
	((void (*)(uint64_t, void *))entry)(hartid, dtb);
	for (;;)
		__asm__ volatile("wfi");
}
