/*
 * riscv64 side of the architecture interface in kernel.h: the kernel runs
 * in S-mode under SBI firmware (OpenSBI), on a machine described by the
 * device tree the firmware passes in.
 *
 * Interrupts stay globally disabled (sstatus.SIE = 0) and are never taken
 * as traps: wfi wakes up on any interrupt pending in sie, and Ruby then
 * looks at sip and services the device. Only synchronous exceptions reach
 * the trap vector, and they panic.
 */
#include <picotls.h>
#include <stddef.h>
#include <stdint.h>

#include "kernel.h"
#include "riscv.h"
#include "sbi.h"

/* Write c to the console through the firmware. */
void
arch_putc(int c)
{
	sbi_call(SBI_EXT_LEGACY_PUTCHAR, 0, c, 0, 0, 0, 0, 0);
}

/*
 * boot_arg is the device tree address. The heap runs from the end of the
 * kernel to the end of its RAM region, or to the first reserved range
 * before that (e.g. the device tree itself, which QEMU puts at the top of
 * RAM), whatever the device tree says the machine has.
 */
void
arch_early_init(uintptr_t boot_arg)
{
	heap_limit = (char *)(fdt_free_ram_end(boot_arg,
	    (uintptr_t)__heap_start) & ~0xfffUL);
}

/*
 * picolibc keeps the thread pointer in tp and knows how to set it up: the
 * TLS block starts at tp, so it starts at the area.
 */
void
arch_set_tls(void *area, size_t size)
{
	if (_tls_size() > size)
		panic("TLS area too small");

	_init_tls(area);
	_set_tls(area);
}

/* Supervisor trap vector. Only synchronous exceptions can land here. */
__attribute__((__interrupt__("supervisor"), __aligned__(4)))
void
trap_vector(void)
{
	kputs("\n*** exception on hart ");
	kputhex(this_hartid);
	kputs(" scause=");
	kputhex(CSR_READ(scause));
	kputs(" sepc=");
	kputhex(CSR_READ(sepc));
	kputs(" stval=");
	kputhex(CSR_READ(stval));
	panic("unexpected trap");
}

/* Install the trap vector and mask every interrupt source. */
void
arch_cpu_init(long hartid)
{
	(void)hartid;
	CSR_WRITE(stvec, (uintptr_t)trap_vector);
	/* Interrupts only ever wake wfi; they are never taken. */
	CSR_CLEAR(sstatus, SSTATUS_SIE);
	CSR_WRITE(sie, 0);
}

/* wfi wakes up for anything enabled in sie, even with sstatus.SIE = 0. */
void
arch_idle(void)
{
	__asm__ volatile("wfi");
}

/*
 * Sleep forever. Masking every interrupt source first matters: wfi
 * returns as soon as an enabled interrupt is pending, and one that
 * nobody services any more (an IPI, the UART's) stays pending for good,
 * which would turn this loop into a busy one. The loop stays because wfi
 * may still return for other reasons (the firmware's own interrupts).
 */
NORETURN void
arch_halt(void)
{
	CSR_WRITE(sie, 0);
	for (;;)
		__asm__ volatile("wfi");
}

/* An IPI to every hart there is (this one included, which does no harm). */
void
arch_stop_others(void)
{
	sbi_call(SBI_EXT_IPI, SBI_IPI_SEND_IPI, 0, SBI_HART_MASK_ALL, 0, 0,
	    0, 0);
}
