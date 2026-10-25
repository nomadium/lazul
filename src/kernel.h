/*
 * Definitions shared by the kernel's C files: per-hart state, the routines
 * that main.c and hal.c provide to each other, and the interface that each
 * architecture implements in src/arch/<arch>/.
 */
#ifndef LAZUL_KERNEL_H
#define LAZUL_KERNEL_H

#include <stdint.h>

#include <mruby.h>

#include "config.h"

/* Marks a function that never returns to its caller. */
#define	NORETURN	__attribute__((__noreturn__))

/* Id of the hart running this code, or -1 before its setup is done. */
extern __thread int this_hartid;

/* Start and end of the kernel heap, set by the linker script. */
extern char __heap_end[], __heap_start[];

/* End of the kernel heap; arch_early_init() may lower it. */
extern char *heap_limit;

/* main.c */
NORETURN void	boot_main(long, uintptr_t);
void	kputhex(uint64_t);
void	kputs(const char *);
NORETURN void	panic(const char *);
NORETURN void	secondary_main(long, uintptr_t);

/* hal.c */
void	hal_init(mrb_state *);

/*
 * Provided by each architecture, in src/arch/<arch>/, together with the
 * entry points (start.S), which set up a stack and call boot_main() or
 * secondary_main() with the hart id and an architecture-defined argument.
 */

/*
 * Write one character to the console, polled, for code that runs before
 * Ruby's console driver is up and for panics.
 */
void	arch_putc(int);

/*
 * Boot hart only, before mruby starts: act on the boot argument (e.g. keep
 * the heap clear of what the firmware passed in memory).
 */
void	arch_early_init(uintptr_t);

/* Point this hart's thread pointer at its TLS area and initialize it. */
void	arch_set_tls(void *);

/*
 * Per-hart CPU setup, with interrupts disabled: trap handling, and
 * interrupt sources that only wake arch_idle() and are never taken.
 */
void	arch_cpu_init(long);

/* Wait until an interrupt is pending, without taking it. */
void	arch_idle(void);

/* Stop this hart for good. */
NORETURN void	arch_halt(void);

/*
 * Define the architecture's own primitives for Ruby (registers, firmware
 * calls, ...), alongside the portable ones from hal.c.
 */
void	arch_hal_init(mrb_state *);

#endif
