/*
 * Entry points of the kernel, and the per-hart stacks.
 *
 * Every hart enters the kernel here in S-mode, with the MMU off (all
 * addresses are physical), interrupts disabled (sstatus.SIE = 0) and no
 * stack. This file gives the hart a stack and jumps into C; nothing else.
 *
 *   _start            The boot hart, entered from OpenSBI. OpenSBI picks
 *                     the boot hart, so its id can be any number; one
 *                     with no stack slot hands the boot over to another
 *                     hart (see handover).
 *                     a0 = hart id, a1 = physical address of the device
 *                     tree blob (DTB).
 *   _secondary_start  Every other hart, started later by Ruby code through
 *                     the hart_start call of the SBI HSM (Hart State
 *                     Management) extension.
 *                     a0 = hart id, a1 = the opaque value that Ruby passed
 *                     to hart_start.
 *
 * Both paths leave a0 and a1 untouched, so they arrive as the first two
 * arguments of boot_main() and secondary_main() in main.c.
 */
#include "config.h"
#include "sbi.h"

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
	 * A boot hart whose id is MAX_HARTS or more has no stack slot; it
	 * hands the boot over to a hart that has one. It leaves before
	 * clearing .bss, which the new hart does anyway. A hart id that fits
	 * carries on at 3.
	 */
	li	t0, MAX_HARTS
	bltu	a0, t0, 3f		/* unsigned, so it catches every id */
	tail	handover		/* .text may be far: no branch here */
3:

	/*
	 * Zero .bss, which C expects to start out as all zeroes; with no
	 * program loader, nobody else does it. Only the boot hart runs this,
	 * before it starts any other hart, so nothing can be using .bss yet.
	 * The other harts must not repeat it: by the time they run, it would
	 * wipe out the state the boot hart has set up.
	 *
	 * The bounds come from kernel.ld, which aligns both to 16 bytes, so
	 * storing 8 bytes at a time cannot overrun. The stacks at the end of
	 * this file are in .bss too; clearing them is harmless, since no stack
	 * is in use yet.
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
	 * call puts the return address in ra and jumps. set_stack uses only
	 * t0 and sp, so a0 (hart id) and a1 (DTB) survive into C.
	 */
	call	set_stack
	/*
	 * tail jumps without saving a return address (a tail call):
	 * boot_main() never returns, and there is no caller to return to.
	 */
	tail	boot_main

/*
 * Every other hart: the same as _start without clearing .bss. gp is a
 * register, so each hart must load its own; the value is the same.
 */
	.text
	.globl	_secondary_start
_secondary_start:
	.option push
	.option norelax
	la	gp, __global_pointer$	/* see _start */
	.option pop
	call	set_stack		/* a0 = hart id, a1 = opaque */
	tail	secondary_main

/*
 * Point sp at the top of the stack of the hart whose id is in a0. With S
 * the size of one stack (1 << STACK_SHIFT bytes):
 *
 *	sp = hart_stacks + (a0 + 1) * S
 *
 * Stacks grow down, towards lower addresses, so a hart starts at the top
 * (highest address) of its own slot, which is where the next slot begins;
 * hence the + 1. Each hart computes its slot from its own id, so no
 * locking is needed. sp stays 16-byte aligned, as the RISC-V calling
 * convention requires, because hart_stacks is aligned and S is a multiple
 * of 16.
 *
 * A hart whose id is MAX_HARTS or more has no stack slot; set_stack sends
 * it to park instead of returning.
 *
 * set_stack is a leaf routine (it calls nothing and uses no stack), so ra
 * still holds the return address when it reaches ret. It clobbers t0.
 */
set_stack:
	li	t0, MAX_HARTS
	bgeu	a0, t0, park		/* no stack slot for this hart id */
	la	sp, hart_stacks		/* sp = start of all the stacks */
	addi	t0, a0, 1		/* t0 = hart id + 1 */
	slli	t0, t0, STACK_SHIFT	/* t0 *= S, as a left shift */
	add	sp, sp, t0		/* sp = top of this hart's stack */
	ret				/* return to the address in ra */

/*
 * Hand the boot over to another hart. _start comes here when OpenSBI
 * picked a boot hart whose id is MAX_HARTS or more. OpenSBI picks the
 * boot hart at random among all harts, so on a machine with more harts
 * than MAX_HARTS, or with sparse hart ids, this happens now and then.
 *
 * Through the SBI HSM extension, look for a hart with an id below
 * MAX_HARTS that is stopped (hart_get_status), start it at _start with the
 * DTB address as its opaque value (hart_start), and stop this one
 * (hart_stop). hart_start enters the new hart with a0 = its hart id and
 * a1 = the opaque value: exactly what _start expects from OpenSBI, so the
 * new hart boots as usual. This hart then rests in the firmware for good:
 * Ruby only starts harts whose id is below MAX_HARTS.
 *
 * Nothing here touches writable memory, so it cannot disturb the new hart,
 * which starts while this one is still on its way to hart_stop. ecall
 * only changes a0 and a1, so s0 and s1 survive the SBI calls; nothing has
 * to be preserved for anyone else, since there is no return from here.
 *
 * Firmware without HSM (SBI before v0.2) or with no stopped hart to hand
 * over to falls back to park.
 */
handover:
	mv	s0, a1			/* s0 = DTB, for the new hart */
	la	a0, handover_msg
	call	print
	li	a0, SBI_EXT_HSM		/* does the firmware have HSM? */
	li	a6, SBI_BASE_PROBE_EXTENSION
	li	a7, SBI_EXT_BASE
	ecall
	bnez	a0, park		/* error: no base extension either */
	beqz	a1, park		/* 0: no HSM */
	li	s1, 0			/* s1 = candidate hart id */
1:
	li	t0, MAX_HARTS
	bgeu	s1, t0, park		/* no candidate left */
	mv	a0, s1
	li	a6, SBI_HSM_HART_GET_STATUS
	li	a7, SBI_EXT_HSM
	ecall
	bnez	a0, 2f			/* error: no hart with this id */
	li	t0, SBI_HSM_STATE_STOPPED
	bne	a1, t0, 2f		/* running or busy: not a candidate */
	mv	a0, s1			/* hart_start(id, addr, opaque) */
	la	a1, _start
	mv	a2, s0
	li	a6, SBI_HSM_HART_START
	li	a7, SBI_EXT_HSM
	ecall
	beqz	a0, 3f			/* started: it owns the boot now */
2:
	addi	s1, s1, 1		/* try the next hart id */
	j	1b
3:
	li	a6, SBI_HSM_HART_STOP
	li	a7, SBI_EXT_HSM
	ecall				/* returns only if it failed */
	j	sleep			/* new hart is booting; stay quiet */

/*
 * Stop a hart that has no stack slot and could not hand the boot over,
 * before it touches any memory beyond hart_stacks. It says why on the
 * console, then waits for interrupts forever. The kernel then does not
 * boot at all; raise MAX_HARTS in config.h.
 *
 * Only the boot hart can end up here, from handover; set_stack also sends
 * secondary harts here as a safeguard, but Ruby starts no hart whose id is
 * MAX_HARTS or more.
 *
 * A more general fix would stop using hart ids as indexes: real machines
 * can have sparse or large hart ids, and harts whose id is MAX_HARTS or
 * more are never used today. Each hart would take the next free slot (an
 * atomic counter) and keep its slot number next to its hart id; the stacks
 * here, hart_tls in main.c and the loop over Kern::MAX_HARTS in
 * Hart.start_secondaries (kernel/hart.rb) all index by hart id today.
 */
park:
	la	a0, park_msg
	call	print
sleep:
	wfi				/* sleep; wake-ups are ignored */
	j	sleep

/*
 * Print the NUL-terminated string at a0 on the console through the
 * firmware, for code that cannot run C. The SBI legacy console call takes
 * the character in a0 and the extension in a7, and only changes a0, so t1
 * keeps the position in the string. A leaf routine: it clobbers a0, a7
 * and t1.
 */
print:
	mv	t1, a0			/* t1 = next character to print */
1:
	lbu	a0, 0(t1)		/* a0 = that character */
	beqz	a0, 2f			/* stop at the terminating NUL */
	li	a7, SBI_EXT_LEGACY_PUTCHAR
	ecall				/* print it */
	addi	t1, t1, 1
	j	1b
2:
	ret

	.section .rodata
handover_msg:
	.asciz	"\nboot hart id too large for MAX_HARTS; handing over\n"
park_msg:
	.asciz	"\nhart id too large for MAX_HARTS in config.h; hart parked\n"

/*
 * The stacks: MAX_HARTS slots of S bytes each, slot n for hart n.
 *
 *	hart_stacks	 +-----------------+
 *			 | hart 0's stack  |  (grows down)
 *	 + 1 * S	 +-----------------+  <- hart 0's initial sp
 *			 | hart 1's stack  |
 *	 + 2 * S	 +-----------------+  <- hart 1's initial sp
 *			 |       ...       |
 *	 + MAX_HARTS * S +-----------------+  <- last hart's initial sp
 *
 * .bss is NOLOAD in kernel.ld, so the stacks take up addresses in RAM but
 * no room in kernel.elf. .space reserves the bytes, and the loop in
 * _start zeroes them. .globl makes hart_stacks visible to C as well, for
 * debugging.
 */
	.bss
	.balign	16			/* sp must be 16-byte aligned */
	.globl	hart_stacks
hart_stacks:
	.space	MAX_HARTS << STACK_SHIFT
