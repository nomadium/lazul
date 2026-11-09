/*
 * Entry point of the kernel, and the boot CPU's stack.
 *
 *   pvh_start  The boot CPU, entered from QEMU's direct kernel boot
 *              through the PVH boot protocol, which QEMU's firmware
 *              implements for ELF kernels: the CPU is in 32-bit protected
 *              mode with paging off, flat segments covering all of memory,
 *              interrupts disabled and no stack.
 *              ebx = physical address of the PVH start info (bootinfo.h).
 *
 * A PC starts every CPU in 16-bit real mode, as an 8086 would; the
 * firmware has already brought this one to 32-bit protected mode. The
 * kernel runs in 64-bit long mode, which takes four steps: page tables
 * (long mode always translates addresses), CR4.PAE (their 64-bit entry
 * format), EFER.LME (asking for long mode), and CR0.PG (turning paging
 * on, which activates long mode). The CPU then still runs 32-bit code,
 * until a far jump loads a 64-bit code segment.
 *
 * The page tables map the low 4 GiB to themselves (an identity map), so
 * the kernel keeps running at the physical addresses it was linked for.
 *
 * Hart ids are local APIC ids, the CPUs' own numbers (see arch.rb).
 */
#include "config.h"
#include "amd64.h"

/*
 * The PVH note: QEMU loads an ELF kernel that has one at the physical
 * addresses of its segments and starts it at the address in the note
 * (type 18, XEN_ELFNOTE_PHYS32_ENTRY: the protocol comes from Xen).
 */
	.section .note.Xen, "a"
	.balign	4
	.long	4			/* name size: "Xen" and its NUL */
	.long	8			/* descriptor size */
	.long	18			/* XEN_ELFNOTE_PHYS32_ENTRY */
	.asciz	"Xen"
	.quad	pvh_start		/* the descriptor: the entry point */

	.section .text.entry, "ax"
	.code32
	.globl	pvh_start
pvh_start:
	cli
	cld				/* string instructions count up */

	/*
	 * Clear .bss: C expects its zero-initialized variables to be zero.
	 * The kernel is below 4 GiB, so 32-bit addresses reach all of it.
	 * Then keep the start info address, which lives in .bss.
	 */
	movl	$__bss_start, %edi
	movl	$__bss_end, %ecx
	subl	%edi, %ecx
	xorl	%eax, %eax
	rep stosb
	movl	%ebx, pvh_start_info

	/*
	 * Allow SSE instructions, which the compiler uses in ordinary C code
	 * (copies, floating point): until CR4.OSFXSR says the OS saves the
	 * SSE registers, the CPU refuses them. CR0.EM off and MP on: no FPU
	 * emulation, the FPU is there. CR4.PAE, for long mode, goes in too.
	 */
	movl	%cr0, %eax
	andl	$~CR0_EM, %eax
	orl	$CR0_MP, %eax
	movl	%eax, %cr0
	movl	%cr4, %eax
	orl	$(CR4_PAE | CR4_OSFXSR | CR4_OSXMMEXCPT), %eax
	movl	%eax, %cr4

	/*
	 * The identity map of the low 4 GiB (arch.c's page tables, in .bss,
	 * all zeroes so far). Four levels of tables translate an address,
	 * 9 bits of it each: PML4, PDPT, PD, PT. With 2 MiB pages (PTE_PS)
	 * the PD entries map memory themselves, so no PT is needed:
	 *   kernel_pml4[0]     -> kernel_pdpt     (the first 512 GiB)
	 *   kernel_pdpt[0..3]  -> kernel_pd[0..3] (1 GiB each)
	 *   kernel_pd[i][j]    =  the 2 MiB page at (i << 30) + (j << 21)
	 * kernel_pd is 4 * 512 consecutive entries, so the loop fills them
	 * in order, each 2 MiB further. Entries are 8 bytes; the upper half
	 * stays zero, as every address is below 4 GiB.
	 */
	movl	$kernel_pd, %edi
	movl	$(PTE_P | PTE_W | PTE_PS), %eax
	movl	$(4 * 512), %ecx
1:	movl	%eax, (%edi)
	addl	$8, %edi
	addl	$(1 << 21), %eax
	loop	1b			/* ecx--, and again unless it is 0 */

	movl	$kernel_pdpt, %edi
	movl	$(kernel_pd + PTE_P + PTE_W), %eax
	movl	$4, %ecx
2:	movl	%eax, (%edi)
	addl	$8, %edi
	addl	$4096, %eax		/* the next PD */
	loop	2b

	movl	$(kernel_pdpt + PTE_P + PTE_W), kernel_pml4
	movl	$kernel_pml4, %eax
	movl	%eax, %cr3		/* the top table */

	/* Ask for long mode, then turn paging on, which enters it. */
	movl	$MSR_EFER, %ecx
	rdmsr
	orl	$EFER_LME, %eax
	wrmsr
	movl	%cr0, %eax
	orl	$CR0_PG, %eax
	movl	%eax, %cr0

	/*
	 * Still 32-bit code (compatibility mode): load a GDT with a 64-bit
	 * code segment and jump into it. The kernel loads its own GDT later
	 * (arch_cpu_init()), with the same selectors.
	 */
	lgdt	boot_gdtr
	ljmp	$SEL_CODE, $pvh_long

	.code64
pvh_long:
	movl	$SEL_DATA, %eax
	movw	%ax, %ds
	movw	%ax, %es
	movw	%ax, %ss
	leaq	boot_stack_top(%rip), %rsp

	/* The start info, turned into the kernel's boot info (boot.c). */
	movl	pvh_start_info(%rip), %edi
	call	pvh_boot_info
	movq	%rax, %rsi		/* boot_main's boot_arg */

	call	apic_id
	movl	%eax, %edi		/* boot_main's hart id */
	call	boot_main
1:	hlt				/* boot_main does not return */
	jmp	1b

/*
 * This CPU's local APIC id, in eax. CPUID reports it: leaf 0xb gives the
 * full 32-bit (x2APIC) id where the CPU has that leaf, leaf 1 gives the
 * original 8-bit one in bits 31-24 of ebx. cpuid overwrites eax, ebx, ecx
 * and edx; ebx must be preserved for the caller.
 */
apic_id:
	pushq	%rbx
	xorl	%eax, %eax		/* leaf 0: the highest leaf there is */
	cpuid
	cmpl	$0xb, %eax
	jb	1f
	movl	$0xb, %eax
	xorl	%ecx, %ecx
	cpuid
	testl	%ebx, %ebx		/* ebx = 0: the leaf is not really there */
	jz	1f
	movl	%edx, %eax
	popq	%rbx
	ret
1:	movl	$1, %eax
	cpuid
	movl	%ebx, %eax
	shrl	$24, %eax
	popq	%rbx
	ret

/* A GDT just for entering long mode: null, 64-bit code, data. */
	.section .rodata
	.balign	8
boot_gdt:
	.quad	0
	.quad	0x00af9a000000ffff	/* SEL_CODE: 64-bit code, ring 0 */
	.quad	0x00cf92000000ffff	/* SEL_DATA: data, ring 0 */
boot_gdt_end:
boot_gdtr:
	.word	boot_gdt_end - boot_gdt - 1
	.long	boot_gdt

/*
 * The boot CPU's stack, 1 << STACK_SHIFT bytes, and where pvh_start keeps
 * the start info address. Both in .bss, which takes no room in the file.
 */
	.bss
	.balign	16
	.globl	boot_stack, boot_stack_top
boot_stack:
	.space	1 << STACK_SHIFT
boot_stack_top:
	.balign	8
pvh_start_info:
	.quad	0

	.section .note.GNU-stack, "", @progbits
