/*
 * Interrupt and exception entry stubs, one per vector, and the table of
 * their addresses that arch.c puts in the IDT.
 *
 * The CPU pushes an error code for some exceptions only. Each stub pushes
 * a dummy one for the other vectors, then the vector number, so that all
 * of them reach interrupt_dispatch() (irq.c) with the same frame (struct
 * frame). Only the registers that C code may change are saved: the C code
 * saves the rest itself, and it is built to never touch SSE registers.
 */
	.altmacro

/* The stub of vector v. */
.macro	stub v
	.balign	16
isr_\v:
	/* Exceptions 8, 10-14, 17, 21, 29 and 30 push an error code. */
	.if (\v == 8) || ((\v >= 10) && (\v <= 14)) || (\v == 17) || (\v == 21) || (\v == 29) || (\v == 30)
	.else
	pushq	$0
	.endif
	pushq	$\v
	jmp	isr_common
.endm

/* The address of vector v's stub, for isr_stubs. */
.macro	stub_addr v
	.quad	isr_\v
.endm

	.text
	.set	i, 0
	.rept	256
	stub	%i
	.set	i, i + 1
	.endr

isr_common:
	pushq	%rax
	pushq	%rcx
	pushq	%rdx
	pushq	%rsi
	pushq	%rdi
	pushq	%r8
	pushq	%r9
	pushq	%r10
	pushq	%r11
	movq	%rsp, %rdi		/* struct frame; 16-byte aligned here */
	cld
	call	interrupt_dispatch
	popq	%r11
	popq	%r10
	popq	%r9
	popq	%r8
	popq	%rdi
	popq	%rsi
	popq	%rdx
	popq	%rcx
	popq	%rax
	addq	$16, %rsp		/* the vector and the error code */
	iretq

	.section .rodata
	.balign	8
	.globl	isr_stubs
isr_stubs:
	.set	i, 0
	.rept	256
	stub_addr %i
	.set	i, i + 1
	.endr

	.section .note.GNU-stack, "", @progbits
