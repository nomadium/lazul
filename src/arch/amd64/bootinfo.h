/*
 * The amd64 kernel's boot information: what it learns from whoever booted
 * it, the riscv64 kernel's device tree counterpart. However the kernel was
 * entered, boot_main() gets a struct boot_info, which C uses to size the
 * heap and Ruby reads (kernel/arch/amd64/platform.rb), so the layout is
 * fixed: 64-bit fields, in this order.
 *
 * For a direct boot from QEMU, boot.c fills one in from the PVH start
 * info that the firmware passes (struct hvm_start_info below).
 */
#ifndef LAZUL_BOOTINFO_H
#define LAZUL_BOOTINFO_H

#include <stdint.h>

#define	BOOT_INFO_MAGIC	0x4f464e49544f4f42ULL	/* "BOOTINFO" in memory */

/*
 * Memory types, numbered as in the PC BIOS's memory map (the E820 call),
 * which PVH uses too.
 */
#define	BOOT_MEM_FREE		1	/* RAM nothing uses */
#define	BOOT_MEM_RESERVED	2	/* not RAM, or not ours */
#define	BOOT_MEM_ACPI		3	/* ACPI tables, reusable once read */
#define	BOOT_MEM_NVS		4	/* firmware's, keep across sleep */
#define	BOOT_MEM_UNUSABLE	5	/* RAM with errors */

/* One range of the memory map. */
struct boot_memory {
	uint64_t	base;
	uint64_t	size;
	uint64_t	type;		/* BOOT_MEM_* */
};

struct boot_info {
	uint64_t	magic;
	uint64_t	acpi_rsdp;	/* the ACPI root pointer */
	uint64_t	memory_map;	/* a struct boot_memory array */
	uint64_t	memory_map_entries;
};

/*
 * The PVH boot protocol's start info (Xen's hvm_start_info, version 1),
 * passed in ebx: https://xenbits.xen.org/docs/unstable/misc/pvh.html
 */
#define	PVH_START_MAGIC	0x336ec578

struct hvm_start_info {
	uint32_t	magic;
	uint32_t	version;	/* the memory map needs 1 */
	uint32_t	flags;
	uint32_t	nr_modules;
	uint64_t	modlist_paddr;
	uint64_t	cmdline_paddr;
	uint64_t	rsdp_paddr;
	uint64_t	memmap_paddr;	/* struct hvm_memmap_entry array */
	uint32_t	memmap_entries;
	uint32_t	reserved;
};

struct hvm_memmap_entry {
	uint64_t	addr;
	uint64_t	size;
	uint32_t	type;		/* the E820 numbering */
	uint32_t	reserved;
};

#endif
