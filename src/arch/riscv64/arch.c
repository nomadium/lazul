/*
 * riscv64 side of the architecture interface in kernel.h: the kernel runs
 * in S-mode under SBI firmware (OpenSBI), on QEMU's virt machine.
 *
 * Interrupts stay globally disabled (sstatus.SIE = 0) and are never taken
 * as traps: wfi wakes up on any interrupt pending in sie, and Ruby then
 * looks at sip and services the device. Only synchronous exceptions reach
 * the trap vector, and they panic.
 */
#include <picotls.h>
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
 * boot_arg is the device tree address. QEMU puts the device tree at the
 * top of RAM; keep the heap below it.
 */
void
arch_early_init(uintptr_t boot_arg)
{
	if (boot_arg > (uintptr_t)__heap_start &&
	    boot_arg < (uintptr_t)heap_limit)
		heap_limit = (char *)(boot_arg & ~0xfffUL);
}

/* picolibc keeps the thread pointer in tp and knows how to set it up. */
void
arch_set_tls(void *area)
{
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

/* Sleep forever; wake-ups are ignored. */
NORETURN void
arch_halt(void)
{
	for (;;)
		__asm__ volatile("wfi");
}
