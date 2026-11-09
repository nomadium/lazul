/*
 * amd64 (x86-64 in long mode) definitions: control register and page
 * table bits, segment selectors, model specific registers (MSRs), and
 * the instructions C cannot express. The constants are also used by the
 * assembly files, so the C parts are kept apart.
 */
#ifndef LAZUL_AMD64_H
#define LAZUL_AMD64_H

/* Control register bits. */
#define	CR0_MP		(1 << 1)	/* monitor coprocessor (for SSE) */
#define	CR0_EM		(1 << 2)	/* emulate the FPU: must be off */
#define	CR0_PG		0x80000000	/* paging */
#define	CR4_PAE		(1 << 5)	/* physical address extension */
#define	CR4_OSFXSR	(1 << 9)	/* the OS saves SSE state */
#define	CR4_OSXMMEXCPT	(1 << 10)	/* the OS handles SSE exceptions */

/* Page table entry bits. */
#define	PTE_P		(1 << 0)	/* present */
#define	PTE_W		(1 << 1)	/* writable */
#define	PTE_PWT		(1 << 3)	/* write-through */
#define	PTE_PCD		(1 << 4)	/* cache disabled */
#define	PTE_PS		(1 << 7)	/* large page (2 MiB in a PD) */

/* The kernel's segments (arch.c): null, then code and data, ring 0. */
#define	SEL_CODE	0x08
#define	SEL_DATA	0x10

/* Model specific registers. */
#define	MSR_EFER	0xc0000080	/* extended features */
#define	EFER_LME	(1 << 8)	/* long mode enable */
#define	MSR_FS_BASE	0xc0000100	/* the FS base: the thread pointer */

#ifndef __ASSEMBLER__

#include <stdint.h>

/* Read the model specific register msr. */
static inline uint64_t
rdmsr(uint32_t msr)
{
	uint32_t hi, lo;

	__asm__ volatile("rdmsr" : "=a"(lo), "=d"(hi) : "c"(msr));
	return ((uint64_t)hi << 32) | lo;
}

/* Write v to the model specific register msr. */
static inline void
wrmsr(uint32_t msr, uint64_t v)
{
	__asm__ volatile("wrmsr" :: "c"(msr), "a"((uint32_t)v),
	    "d"((uint32_t)(v >> 32)) : "memory");
}

/* Read a byte from the I/O port port. */
static inline uint8_t
inb(uint16_t port)
{
	uint8_t v;

	__asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(port));
	return v;
}

/* Write the byte v to the I/O port port. */
static inline void
outb(uint16_t port, uint8_t v)
{
	__asm__ volatile("outb %0, %1" :: "a"(v), "Nd"(port));
}

struct boot_info;

/* boot.c */
uintptr_t	boot_free_ram_end(const struct boot_info *, uintptr_t);
struct boot_info	*pvh_boot_info(uint32_t);

#endif /* __ASSEMBLER__ */

#endif
