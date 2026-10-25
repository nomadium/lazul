/*
 * Definitions shared by the kernel's C files: per-hart state and the
 * routines that main.c and hal.c provide to each other.
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

/* End of the kernel heap; boot_main() lowers it to stay below the DTB. */
extern char *heap_limit;

/* main.c */
NORETURN void	boot_main(long, uintptr_t);
void	kputs(const char *);
NORETURN void	panic(const char *);
NORETURN void	secondary_main(long, uintptr_t);

/* hal.c */
void	hal_init(mrb_state *);

#endif
