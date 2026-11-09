/*
 * The boot info (bootinfo.h), in C: what the heap must be sized from
 * before mruby starts, and the conversion from what QEMU's direct boot
 * passes. Ruby reads the rest of it (kernel/arch/amd64/platform.rb).
 */
#include <stdint.h>
#include <string.h>

#include "kernel.h"
#include "amd64.h"
#include "bootinfo.h"

#define	MAX_MEMORY	128	/* memory map entries kept from PVH */
#define	IDENTITY_MAP_END	(4ULL << 30)	/* what arch.c maps */

static struct boot_info pvh_info;
static struct boot_memory pvh_memory[MAX_MEMORY];

/*
 * Where the ACPI root pointer (RSDP) is, if the firmware did not say: on
 * a 16-byte boundary in the BIOS's read-only area, 0xe0000-0xfffff, which
 * is where QEMU's firmware puts it. It starts with "RSD PTR " and its
 * first 20 bytes add up to 0 (mod 256).
 */
static uint64_t
find_rsdp(void)
{
	const uint8_t *p;
	uint8_t sum;
	int i;

	for (p = (const uint8_t *)0xe0000; p < (const uint8_t *)0x100000;
	    p += 16) {
		if (memcmp(p, "RSD PTR ", 8) != 0)
			continue;
		for (sum = 0, i = 0; i < 20; i++)
			sum += p[i];
		if (sum == 0)
			return (uintptr_t)p;
	}
	return 0;
}

/*
 * Turn the PVH start info at addr into the kernel's boot info. Called
 * from start.S on a direct boot, before boot_main(). The memory map is
 * copied, sorted by address, into the kernel's own memory (.bss), so that
 * nothing the heap may grow over is needed afterwards.
 */
struct boot_info *
pvh_boot_info(uint32_t addr)
{
	const struct hvm_start_info *si;
	const struct hvm_memmap_entry *e;
	struct boot_memory m;
	uint32_t i, j, n;

	si = (const struct hvm_start_info *)(uintptr_t)addr;
	if (si->magic != PVH_START_MAGIC)
		panic("no PVH start info");
	if (si->version < 1 || si->memmap_entries == 0)
		panic("PVH start info without a memory map");
	n = si->memmap_entries;
	if (n > MAX_MEMORY)
		panic("PVH memory map too large");

	e = (const struct hvm_memmap_entry *)(uintptr_t)si->memmap_paddr;
	for (i = 0; i < n; i++) {
		m.base = e[i].addr;
		m.size = e[i].size;
		m.type = e[i].type;
		/* Insertion sort: the firmware's order is not guaranteed. */
		for (j = i; j > 0 && pvh_memory[j - 1].base > m.base; j--)
			pvh_memory[j] = pvh_memory[j - 1];
		pvh_memory[j] = m;
	}

	pvh_info.magic = BOOT_INFO_MAGIC;
	pvh_info.acpi_rsdp = si->rsdp_paddr != 0 ? si->rsdp_paddr :
	    find_rsdp();
	pvh_info.memory_map = (uintptr_t)pvh_memory;
	pvh_info.memory_map_entries = n;
	return &pvh_info;
}

/*
 * End of the free RAM that starts at start: the end of the free range
 * holding start, extended through free ranges that follow it directly,
 * and at most the end of the identity map. Panics if the boot info is
 * unusable, or says start is not free RAM.
 */
uintptr_t
boot_free_ram_end(const struct boot_info *info, uintptr_t start)
{
	const struct boot_memory *map;
	uint64_t end, i, grew;

	if (info == NULL || info->magic != BOOT_INFO_MAGIC)
		panic("no boot info at the boot argument");
	map = (const struct boot_memory *)(uintptr_t)info->memory_map;

	end = 0;
	for (i = 0; i < info->memory_map_entries; i++)
		if (map[i].type == BOOT_MEM_FREE && map[i].base <= start &&
		    start < map[i].base + map[i].size)
			end = map[i].base + map[i].size;
	if (end == 0)
		panic("boot info: the heap start is not free RAM");

	do {
		grew = 0;
		for (i = 0; i < info->memory_map_entries; i++)
			if (map[i].type == BOOT_MEM_FREE &&
			    map[i].base == end) {
				end += map[i].size;
				grew = 1;
			}
	} while (grew);

	return end < IDENTITY_MAP_END ? end : IDENTITY_MAP_END;
}
