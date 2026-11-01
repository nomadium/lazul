/*
 * Definitions shared by the kernel's C files: per-hart state, the routines
 * that main.c and hal.c provide to each other, and the interface that each
 * architecture implements in src/arch/<arch>/.
 */
#ifndef LAZUL_KERNEL_H
#define LAZUL_KERNEL_H

#include <stddef.h>
#include <stdint.h>

#include <mruby.h>

#include "config.h"

/* Marks a function that never returns to its caller. */
#define	NORETURN	__attribute__((__noreturn__))

/* Id of the hart running this code, or -1 before its setup is done. */
extern __thread int this_hartid;

/*
 * Start of the kernel heap, and its end as far as the linker script knows,
 * both set by the linker script.
 */
extern char __heap_end[], __heap_start[];

/* End of the kernel heap; starts at __heap_end, arch_early_init() sets it. */
extern char *heap_limit;

/* main.c */
NORETURN void	boot_main(long, uintptr_t);
void	kputhex(uint64_t);
void	kputs(const char *);
NORETURN void	panic(const char *);
NORETURN void	secondary_main(long, uintptr_t);

/* hal.c */
void	hal_init(mrb_state *);

/* fdt.c */
uintptr_t	fdt_free_ram_end(uintptr_t, uintptr_t);

/*
 * Provided by each architecture, in src/arch/<arch>/, together with the
 * entry points (start.S), which set up a stack and call boot_main() or
 * secondary_main() with the hart id and an argument: for boot_main(), an
 * architecture-defined one; for secondary_main(), the hart's area (see
 * Kern.alloc_hart_area in hal.c), whose address is the top of the stack
 * the entry code has switched to.
 */

/*
 * Write one character to the console, polled, for code that runs before
 * Ruby's console driver is up and for panics.
 */
void	arch_putc(int);

/*
 * Boot hart only, first thing in boot_main(), before its CPU setup: act on
 * the boot argument (e.g. size the heap from what the firmware says about
 * memory) and set up what every hart's arch_cpu_init() relies on.
 */
void	arch_early_init(uintptr_t);

/*
 * Initialize this hart's TLS in the size bytes at area and point its
 * thread pointer there. Where the thread pointer goes within the area
 * depends on the architecture; panics if the area is too small for it.
 */
void	arch_set_tls(void *, size_t);

/*
 * Per-hart CPU setup, with interrupts disabled: trap handling, and
 * interrupt sources that only wake arch_idle() and are never taken.
 */
void	arch_cpu_init(long);

/* Wait until an interrupt is pending, without taking it. */
void	arch_idle(void);

/* Stop this hart for good: no interrupt wakes it up any more. */
NORETURN void	arch_halt(void);

/*
 * Wake every other hart (e.g. with an IPI), for panic(): each one then
 * finds that the kernel has stopped and halts.
 */
void	arch_stop_others(void);

/*
 * Define the architecture's own primitives for Ruby (registers, firmware
 * calls, ...), alongside the portable ones from hal.c.
 */
void	arch_hal_init(mrb_state *);

#endif
