/*
 * Interrupt and exception handling, the C half of vectors.S. Built with
 * -mgeneral-regs-only (see arch.mk): an interrupt can arrive while the
 * interrupted code has live SSE registers, and the entry stubs do not
 * save them.
 *
 * CPU exceptions (vectors 0-31: page faults, invalid instructions, ...)
 * are fatal: the kernel prints what the CPU reported and panics.
 *
 * Device interrupts are not handled here: the handler records the vector
 * in this CPU's pending word, tells the local APIC it is done (EOI) and
 * returns to the idle loop, which then calls Ruby (Kern.tick), where
 * CPU.take_pending reads the word.
 */
#include <stdint.h>

#include "kernel.h"
#include "amd64.h"

#define	LAPIC_EOI	0xb0	/* xAPIC end-of-interrupt register */

/* What vectors.S leaves on the stack: saved registers, then the CPU's. */
struct frame {
	uint64_t	r11, r10, r9, r8, rdi, rsi, rdx, rcx, rax;
	uint64_t	vector, error;
	uint64_t	rip, cs, rflags, rsp, ss;	/* pushed by the CPU */
};

/* This CPU's: bit n is set when vector IRQ_VECTOR_BASE + n arrived. */
__thread uint64_t irq_pending;

/*
 * Whether the local APICs are in x2APIC mode (registers are MSRs), and
 * otherwise where their registers are (the same address on every CPU).
 * Set by arch_early_init().
 */
int x2apic_mode;
uintptr_t lapic_mmio;

static const char *const exception_names[32] = {
	"divide error", "debug", "NMI", "breakpoint", "overflow",
	"bound range", "invalid opcode", "device not available",
	"double fault", "coprocessor overrun", "invalid TSS",
	"segment not present", "stack fault", "general protection",
	"page fault", "reserved", "x87 FP error", "alignment check",
	"machine check", "SIMD FP error", "virtualization",
	"control protection",
};

/*
 * Print what the CPU reported and panic. For a page fault, CR2 holds the
 * address that could not be accessed.
 */
static NORETURN void
exception(struct frame *f)
{
	const char *name;
	uint64_t cr2;

	__asm__ volatile("mov %%cr2, %0" : "=r"(cr2));
	name = exception_names[f->vector];
	kputs("\n*** exception on hart ");
	kputhex(this_hartid);
	kputs(": ");
	kputs(name != NULL ? name : "reserved");
	kputs("\n    vector=");
	kputhex(f->vector);
	kputs(" error=");
	kputhex(f->error);
	kputs(" rip=");
	kputhex(f->rip);
	kputs(" rsp=");
	kputhex(f->rsp);
	kputs(" cr2=");
	kputhex(cr2);
	panic("unexpected exception");
}

/*
 * Called by every entry stub in vectors.S. A spurious interrupt is what
 * the local APIC delivers when an interrupt went away before the CPU
 * took it; it takes no EOI.
 */
void
interrupt_dispatch(struct frame *f)
{
	uint64_t bit;

	if (f->vector < 32)
		exception(f);
	if (f->vector == SPURIOUS_VECTOR)
		return;

	bit = f->vector - IRQ_VECTOR_BASE;
	if (bit < 64)
		__atomic_fetch_or(&irq_pending, 1UL << bit, __ATOMIC_RELAXED);

	if (x2apic_mode)
		wrmsr(MSR_X2APIC_EOI, 0);
	else
		*(volatile uint32_t *)(lapic_mmio + LAPIC_EOI) = 0;
}
