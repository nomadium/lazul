/*
 * Startup of the other CPUs. A CPU woken with INIT-SIPI-SIPI (arch.rb)
 * starts in 16-bit real mode, as an 8086 would, at the start of a page
 * below 1 MiB: the startup IPI carries the page number, and the CPU starts
 * there, at segment page number << 8, offset 0. SMP.prepare (hal.c)
 * copies this code to such a page and fills in the parameter block at its
 * end; the code takes the CPU through 32-bit protected mode into long
 * mode, as start.S does for the boot CPU, and jumps to ap_entry
 * (start.S).
 *
 * The code must work wherever it is copied: in real mode everything is
 * addressed relative to CS, and in 32 and 64-bit mode ebx/rbx holds the
 * page's address. OFF(sym) is sym's offset from the start of the code.
 */
#include "amd64.h"

	.text
	.globl	ap_trampoline, ap_trampoline_end
	.globl	tr_gdt, tr_gdtr, tr_protected, tr_long
	.globl	tr_jmp32, tr_jmp64, tr_cr3, tr_stack, tr_entry, tr_hartid

#define	OFF(sym)	((sym) - ap_trampoline)

	.code16
ap_trampoline:
	cli
	cld
	movw	%cs, %ax
	movw	%ax, %ds
	xorl	%ebx, %ebx
	movw	%ax, %bx
	shll	$4, %ebx		/* ebx = the page's linear address */
	lgdtl	OFF(tr_gdtr)
	movl	%cr0, %eax
	orl	$1, %eax		/* PE: protected mode */
	movl	%eax, %cr0
	ljmpl	*OFF(tr_jmp32)		/* to tr_protected, 32-bit code */

	.code32
tr_protected:
	movw	$0x10, %ax
	movw	%ax, %ds
	movw	%ax, %es
	movw	%ax, %ss
	movl	%cr0, %eax		/* SSE allowed, as in start.S */
	andl	$~CR0_EM, %eax
	orl	$CR0_MP, %eax
	movl	%eax, %cr0
	movl	%cr4, %eax
	orl	$(CR4_PAE | CR4_OSFXSR | CR4_OSXMMEXCPT), %eax
	movl	%eax, %cr4
	movl	OFF(tr_cr3)(%ebx), %eax	/* the kernel's page tables */
	movl	%eax, %cr3
	movl	$MSR_EFER, %ecx
	rdmsr
	orl	$EFER_LME, %eax		/* long mode enable */
	wrmsr
	movl	%cr0, %eax
	orl	$CR0_PG, %eax		/* paging: long mode is active from here */
	movl	%eax, %cr0
	ljmpl	*OFF(tr_jmp64)(%ebx)	/* to tr_long, 64-bit code */

	.code64
tr_long:
	movq	OFF(tr_stack)(%rbx), %rsp
	movq	OFF(tr_hartid)(%rbx), %rdi
	movq	OFF(tr_entry)(%rbx), %rax
	jmpq	*%rax

/* A GDT just for the mode switches. */
	.balign	8
tr_gdt:
	.quad	0
	.quad	0x00cf9a000000ffff	/* 0x08: 32-bit code */
	.quad	0x00cf92000000ffff	/* 0x10: data */
	.quad	0x00af9a000000ffff	/* 0x18: 64-bit code */
tr_gdt_end:

/* Parameter block, filled in by SMP.prepare with absolute addresses. */
	.balign	8
tr_gdtr:
	.word	tr_gdt_end - tr_gdt - 1
	.long	0			/* tr_gdt */
	.balign	8
tr_jmp32:
	.long	0			/* tr_protected */
	.word	0x08
	.balign	8
tr_jmp64:
	.long	0			/* tr_long */
	.word	0x18
	.balign	8
tr_cr3:
	.quad	0			/* kernel_pml4 */
tr_stack:
	.quad	0			/* this hart's area: the top of its stack */
tr_entry:
	.quad	0			/* ap_entry */
tr_hartid:
	.quad	0
ap_trampoline_end:

	.section .note.GNU-stack, "", @progbits
