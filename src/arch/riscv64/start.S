/*
 * Entry points of the kernel, and the per-hart stacks.
 *
 * Every hart enters the kernel here in S-mode, with the MMU off (all
 * addresses are physical), interrupts disabled (sstatus.SIE = 0) and no
 * stack. This file gives the hart a stack and jumps into C; nothing else.
 *
 *   _start            The boot hart, entered from OpenSBI. OpenSBI picks
 *                     the boot hart, so its id can be any number; it
 *                     runs on boot_stack, at the end of this file.
 *                     a0 = hart id, a1 = physical address of the device
 *                     tree blob (DTB).
 *   _secondary_start  Every other hart, started later by Ruby code through
 *                     the hart_start call of the SBI HSM (Hart State
 *                     Management) extension.
 *                     a0 = hart id, a1 = the opaque value that Ruby passed
 *                     to hart_start: the hart's area from
 *                     Kern.alloc_hart_area (src/hal.c), whose address is
 *                     the top of its stack.
 *
 * Stacks are not indexed by hart id, so hart ids can be large or sparse,
 * and there is no limit on the number of harts: the boot hart has one
 * stack of its own, and Ruby allocates one for every other hart, after
 * reading the device tree, before starting it.
 *
 * Both paths leave a0 and a1 untouched, so they arrive as the first two
 * arguments of boot_main() and secondary_main() in main.c.
 */
#include "config.h"

/*
 * The boot hart.
 *
 * .text.entry is a section of its own so that the linker script can place
 * it first: kernel.ld starts .text with KEEP(*(.text.entry)), which puts
 * _start at the address OpenSBI jumps to (0x80200000 on QEMU virt).
 * ENTRY(_start) in kernel.ld also makes it the ELF entry point. .globl
 * makes the symbol visible to the linker.
 */
	.section .text.entry
	.globl	_start
_start:
	/*
	 * Load the global pointer. The linker turns accesses to small globals
	 * that lie within 2 KiB of gp into a single gp-relative instruction
	 * ("linker relaxation"). kernel.ld sets __global_pointer$ 0x800 bytes
	 * past the start of .sdata, so gp reaches the first 4 KiB of it.
	 *
	 * This one instruction must not be relaxed: the linker could rewrite
	 * it relative to gp itself, which is not loaded yet. push and pop
	 * limit the norelax option to these lines.
	 */
	.option push
	.option norelax
	la	gp, __global_pointer$
	.option pop

	/*
	 * Zero .bss, which C expects to start out as all zeroes; with no
	 * program loader, nobody else does it. Only the boot hart runs this,
	 * before it starts any other hart, so nothing can be using .bss yet.
	 * The other harts must not repeat it: by the time they run, it would
	 * wipe out the state the boot hart has set up.
	 *
	 * The bounds come from kernel.ld, which aligns both to 16 bytes, so
	 * storing 8 bytes at a time cannot overrun. The boot stack at the end of
	 * this file is in .bss too; clearing it is harmless, since no stack is
	 * in use yet.
	 *
	 * "1:" and "2:" are local labels: "1b" means the nearest label 1
	 * backwards, "2f" the nearest label 2 forwards.
	 */
	la	t0, __bss_start		/* t0 = next address to clear */
	la	t1, __bss_end		/* t1 = end of .bss */
1:
	bgeu	t0, t1, 2f		/* done once t0 >= t1 (unsigned) */
	sd	zero, 0(t0)		/* store 8 zero bytes at t0 */
	addi	t0, t0, 8		/* advance to the next 8 bytes */
	j	1b			/* and loop */
2:
	/*
	 * Stacks grow down, towards lower addresses, so sp starts at the top
	 * (highest address) of boot_stack. a0 (hart id) and a1 (DTB) are
	 * untouched and go on into C.
	 */
	la	sp, boot_stack_top
	/*
	 * tail jumps without saving a return address (a tail call):
	 * boot_main() never returns, and there is no caller to return to.
	 */
	tail	boot_main

/*
 * Every other hart: like _start without clearing .bss, on the stack Ruby
 * allocated for it, whose top arrives in a1. gp is a register, so each
 * hart must load its own; the value is the same.
 */
	.text
	.globl	_secondary_start
_secondary_start:
	.option push
	.option norelax
	la	gp, __global_pointer$	/* see _start */
	.option pop
	mv	sp, a1			/* a0 = hart id, a1 = its area */
	tail	secondary_main

/*
 * The boot hart's stack, S = 1 << STACK_SHIFT bytes:
 *
 *	boot_stack	 +-----------------+
 *			 | boot hart's     |  (grows down)
 *			 | stack           |
 *	boot_stack_top	 +-----------------+  <- the boot hart's initial sp
 *
 * .bss is NOLOAD in kernel.ld, so the stack takes up addresses in RAM but
 * no room in kernel.elf. .space reserves the bytes, and the loop in
 * _start zeroes them. sp must stay 16-byte aligned, as the RISC-V calling
 * convention requires: the stack starts aligned, and S is a multiple of
 * 16. .globl makes the symbols visible to C as well, for debugging.
 */
	.bss
	.balign	16			/* sp must be 16-byte aligned */
	.globl	boot_stack, boot_stack_top
boot_stack:
	.space	1 << STACK_SHIFT
boot_stack_top:
