/*
 * amd64 side of the architecture interface in kernel.h: the kernel runs in
 * long mode on a PC, described by the ACPI tables and the boot info that
 * start.S passes (bootinfo.h).
 *
 * The boot CPU enters on temporary descriptor tables (GDT, IDT) that live
 * in memory the kernel does not own, so it replaces them with its own
 * before anything else (arch_early_init(), arch_cpu_init()).
 *
 * Interrupts stay disabled except inside arch_idle(), and the interrupt
 * handler (irq.c) does not call Ruby, so Ruby code still runs to
 * completion and is never re-entered.
 */
#include <picolibc.h>
#include <picotls.h>
#include <stddef.h>
#include <stdint.h>

#include "kernel.h"
#include "amd64.h"
#include "bootinfo.h"

#define	COM1		0x3f8	/* the first serial port's I/O base */
#define	PIC1_DATA	0x21	/* the 8259 interrupt controllers' masks */
#define	PIC2_DATA	0xa1
#define	COM_LSR		5	/* line status register */
#define	LSR_THR_EMPTY	0x20	/* transmit holding register empty */

/* A GDT or IDT pointer, as lgdt and lidt take it. */
struct descriptor_ptr {
	uint16_t	limit;
	uint64_t	base;
} __attribute__((__packed__));

/* An IDT entry: where the handler of one vector is. */
struct idt_gate {
	uint16_t	offset_lo;
	uint16_t	selector;
	uint8_t		ist;
	uint8_t		type;
	uint16_t	offset_mid;
	uint32_t	offset_hi;
	uint32_t	reserved;
};

/* Entry stubs, one per vector (vectors.S). */
extern const uint64_t isr_stubs[256];

/*
 * Page tables: an identity map of the low 4 GiB with 2 MiB pages, which
 * covers the RAM the kernel uses and the devices (see start.S for the
 * layout). start.S fills them in for a direct boot; setup_paging() does it
 * again, with the cache attributes devices need.
 */
uint64_t kernel_pml4[512] __attribute__((__aligned__(4096)));
uint64_t kernel_pdpt[512] __attribute__((__aligned__(4096)));
uint64_t kernel_pd[4][512] __attribute__((__aligned__(4096)));

/*
 * Segments hardly matter in long mode: no bases or limits, but the CPU
 * still takes the privilege level and the code size (64-bit or not) from
 * the code segment. Each entry is a packed descriptor.
 */
static const uint64_t gdt[] = {
	0,
	0x00af9a000000ffffUL,	/* SEL_CODE: 64-bit code, ring 0 */
	0x00cf92000000ffffUL,	/* SEL_DATA: data, ring 0 */
};

static struct idt_gate idt[256];

/* Write c to COM1, polled; a newline becomes CR LF for terminals. */
void
arch_putc(int c)
{
	if (c == '\n')
		arch_putc('\r');
	while ((inb(COM1 + COM_LSR) & LSR_THR_EMPTY) == 0)
		continue;
	outb(COM1, c);
}

/*
 * Map the low 4 GiB 1:1. From 0xfe000000 up are devices (the APICs, the
 * HPET), not memory, which must not be cached: reads and writes there have
 * to reach the device every time.
 */
static void
setup_paging(void)
{
	uint64_t addr, flags;
	int i, j;

	for (i = 0; i < 4; i++) {
		for (j = 0; j < 512; j++) {
			addr = ((uint64_t)i << 30) | ((uint64_t)j << 21);
			flags = PTE_P | PTE_W | PTE_PS;
			if (addr >= 0xfe000000)
				flags |= PTE_PCD | PTE_PWT;
			kernel_pd[i][j] = addr | flags;
		}
		kernel_pdpt[i] = (uint64_t)kernel_pd[i] | PTE_P | PTE_W;
	}
	kernel_pml4[0] = (uint64_t)kernel_pdpt | PTE_P | PTE_W;
}

/*
 * Point every vector at its stub, as an interrupt gate: the CPU clears IF
 * on entry, so handlers run with interrupts disabled.
 */
static void
setup_idt(void)
{
	uint64_t a;
	int v;

	for (v = 0; v < 256; v++) {
		a = isr_stubs[v];
		idt[v] = (struct idt_gate){
			.offset_lo = a,
			.selector = SEL_CODE,
			.type = 0x8e,	/* present, ring 0, interrupt gate */
			.offset_mid = a >> 16,
			.offset_hi = a >> 32,
		};
	}
}

/*
 * boot_arg is the boot info (bootinfo.h). Silence the legacy interrupt
 * controllers, build the page tables and the IDT that every CPU loads,
 * switch to the page tables (loading CR3 also drops whatever translations
 * the CPU had cached), and size the heap from the memory map.
 *
 * The legacy controllers are the two 8259 PICs of the original PC. The
 * BIOS leaves them delivering the timer and the keyboard on vectors 8-15,
 * which in protected and long mode are CPU exceptions (8 is a double
 * fault): the first interrupt would look like one. Masking every line
 * stops them for good; the APICs take over.
 */
void
arch_early_init(uintptr_t boot_arg)
{
	outb(PIC1_DATA, 0xff);
	outb(PIC2_DATA, 0xff);

	setup_paging();
	setup_idt();
	__asm__ volatile("mov %0, %%cr3" :: "r"(kernel_pml4) : "memory");

	heap_limit = (char *)(boot_free_ram_end(
	    (const struct boot_info *)boot_arg,
	    (uintptr_t)__heap_start) & ~0xfffUL);
}

/*
 * Load the kernel's GDT and IDT. CS can only be reloaded with a far jump
 * or return; the data segment registers are loaded directly. FS and GS get
 * the null selector, which clears their bases: the FS base is set
 * afterwards, by arch_set_tls().
 */
static void
load_descriptors(void)
{
	struct descriptor_ptr g = { sizeof(gdt) - 1, (uint64_t)gdt };
	struct descriptor_ptr i = { sizeof(idt) - 1, (uint64_t)idt };

	__asm__ volatile(
	    "lgdt	%0\n"
	    "pushq	%2\n"
	    "leaq	1f(%%rip), %%rax\n"
	    "pushq	%%rax\n"
	    "lretq\n"
	    "1:\n"
	    "movw	%3, %%ax\n"
	    "movw	%%ax, %%ds\n"
	    "movw	%%ax, %%es\n"
	    "movw	%%ax, %%ss\n"
	    "xorl	%%eax, %%eax\n"
	    "movw	%%ax, %%fs\n"
	    "movw	%%ax, %%gs\n"
	    "lidt	%1"
	    :: "m"(g), "m"(i), "i"(SEL_CODE), "i"(SEL_DATA)
	    : "rax", "memory");
}

/*
 * Load the kernel's descriptors and allow SSE (mruby's floating point
 * code uses it; start.S allowed it already for a direct boot).
 */
void
arch_cpu_init(long hartid)
{
	uint64_t cr0, cr4;

	(void)hartid;
	load_descriptors();

	__asm__ volatile("mov %%cr0, %0" : "=r"(cr0));
	cr0 = (cr0 & ~(uint64_t)CR0_EM) | CR0_MP;
	__asm__ volatile("mov %0, %%cr0" :: "r"(cr0));
	__asm__ volatile("mov %%cr4, %0" : "=r"(cr4));
	cr4 |= CR4_OSFXSR | CR4_OSXMMEXCPT;
	__asm__ volatile("mov %0, %%cr4" :: "r"(cr4));
}

/*
 * amd64 TLS is ELF "variant II": the thread pointer (the FS base) points
 * just past the TLS block, and the first word there points to itself (the
 * thread control block, TCB). So the block goes at the start of the area,
 * the thread pointer at its end, rounded up to the block's alignment, and
 * the TCB needs 8 more bytes.
 */
void
arch_set_tls(void *area, size_t size)
{
	uintptr_t align, tp;

	align = _tls_align() > 8 ? _tls_align() : 8;
	if (((uintptr_t)area & (align - 1)) != 0)
		panic("TLS area misaligned");
	tp = ((uintptr_t)area + _tls_size() + align - 1) & ~(align - 1);
	if (tp + 8 > (uintptr_t)area + size)
		panic("TLS area too small");

	_init_tls(area);
	*(uintptr_t *)tp = tp;
	wrmsr(MSR_FS_BASE, tp);
}

/*
 * Wait for an interrupt. Interrupts are only ever enabled here: sti takes
 * effect after the next instruction, so an interrupt that arrived while
 * the BKL was being released is taken during hlt rather than lost. The
 * handler (irq.c) records it and returns, and cli disables them again.
 */
void
arch_idle(void)
{
	__asm__ volatile("sti; hlt; cli" ::: "memory");
}

/*
 * Stop this CPU for good. With interrupts disabled only a non-maskable
 * interrupt ends hlt; the loop halts again.
 */
NORETURN void
arch_halt(void)
{
	for (;;)
		__asm__ volatile("cli; hlt");
}

/* Only the boot CPU runs so far. */
void
arch_stop_others(void)
{
}
