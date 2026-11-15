/*
 * amd64 primitives for Ruby, added by arch_hal_init() next to the
 * portable ones from src/hal.c:
 *
 *   Port.in8(port) -> Integer, Port.out8(port, v)  (8/16/32)
 *   CPU.rdmsr(msr) -> Integer, CPU.wrmsr(msr, v)
 *   CPU.cpuid(leaf, sub = 0) -> [eax, ebx, ecx, edx]
 *   CPU.tsc -> the time stamp counter
 *   CPU.take_pending -> the vectors recorded since the last call (irq.c):
 *       bit n is vector IRQ_VECTOR_BASE + n
 *   SMP.prepare(hartid, page, area) -> the startup IPI's vector that
 *       starts hartid on area (from Kern.alloc_hart_area), after copying
 *       the startup trampoline to page (below 1 MiB)
 *   SMP.ready?(hartid) -> whether that CPU has left the trampoline
 *   Kern::IRQ_VECTOR_BASE, Kern::IPI_VECTOR, Kern::SPURIOUS_VECTOR
 */
#include <stdint.h>
#include <string.h>

#include <mruby.h>
#include <mruby/array.h>

#include "kernel.h"
#include "amd64.h"

/* trampoline.S, start.S, arch.c */
extern char ap_trampoline[], ap_trampoline_end[];
extern char tr_gdt[], tr_gdtr[], tr_protected[], tr_long[];
extern char tr_jmp32[], tr_jmp64[], tr_cr3[], tr_stack[], tr_entry[];
extern char tr_hartid[];
extern char ap_entry[];
extern uint64_t kernel_pml4[];

/*
 * Define Port.in<bits> and Port.out<bits>. I/O ports are a second address
 * space of the PC, 64 Ki ports, reached only with the in and out
 * instructions; suffix is their size letter (b, w, l).
 */
#define	PORT_ACCESSORS(bits, suffix)					\
mrb_value								\
port_in##bits(mrb_state *mrb, mrb_value self)				\
{									\
	mrb_int port;							\
	uint##bits##_t v;						\
									\
	mrb_get_args(mrb, "i", &port);					\
	__asm__ volatile("in" suffix " %w1, %0"				\
	    : "=a"(v) : "Nd"((uint16_t)port));				\
	return mrb_int_value(mrb, v);					\
}									\
									\
mrb_value								\
port_out##bits(mrb_state *mrb, mrb_value self)				\
{									\
	mrb_int port, v;						\
									\
	mrb_get_args(mrb, "ii", &port, &v);				\
	__asm__ volatile("out" suffix " %0, %w1"			\
	    :: "a"((uint##bits##_t)v), "Nd"((uint16_t)port));		\
	return mrb_int_value(mrb, v);					\
}

PORT_ACCESSORS(8, "b")
PORT_ACCESSORS(16, "w")
PORT_ACCESSORS(32, "l")

/* CPU.rdmsr(msr): read a model specific register. */
mrb_value
cpu_rdmsr(mrb_state *mrb, mrb_value self)
{
	mrb_int msr;

	mrb_get_args(mrb, "i", &msr);
	return mrb_int_value(mrb, (mrb_int)rdmsr(msr));
}

/* CPU.wrmsr(msr, v): write a model specific register. */
mrb_value
cpu_wrmsr(mrb_state *mrb, mrb_value self)
{
	mrb_int msr, v;

	mrb_get_args(mrb, "ii", &msr, &v);
	wrmsr(msr, v);
	return mrb_nil_value();
}

/* CPU.cpuid(leaf, sub = 0): what the CPU reports for leaf and subleaf. */
mrb_value
cpu_cpuid(mrb_state *mrb, mrb_value self)
{
	mrb_int leaf, sub = 0;
	mrb_value r[4];
	uint32_t a, b, c, d;

	mrb_get_args(mrb, "i|i", &leaf, &sub);
	__asm__ volatile("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d)
	    : "a"(leaf), "c"(sub));
	r[0] = mrb_int_value(mrb, a);
	r[1] = mrb_int_value(mrb, b);
	r[2] = mrb_int_value(mrb, c);
	r[3] = mrb_int_value(mrb, d);
	return mrb_ary_new_from_values(mrb, 4, r);
}

/*
 * CPU.tsc: the time stamp counter, which counts at a constant rate on
 * every CPU QEMU emulates and every recent PC. How fast is not reported
 * everywhere, so Ruby measures it (arch.rb).
 */
mrb_value
cpu_tsc(mrb_state *mrb, mrb_value self)
{
	uint32_t hi, lo;

	__asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
	return mrb_int_value(mrb, (mrb_int)(((uint64_t)hi << 32) | lo));
}

/* CPU.take_pending: this CPU's recorded vectors, which it then clears. */
mrb_value
cpu_take_pending(mrb_state *mrb, mrb_value self)
{
	uint64_t bits;

	bits = __atomic_exchange_n(&irq_pending, 0, __ATOMIC_ACQ_REL);
	return mrb_int_value(mrb, (mrb_int)bits);
}

/*
 * SMP.prepare(hartid, page, area): copy the startup trampoline to page and
 * fill in its parameters for hartid (its stack, the page tables, the
 * kernel entry point), all as absolute addresses, since the trampoline
 * does not know where it was copied. Returns the page number, the startup
 * IPI's vector.
 */
mrb_value
smp_prepare(mrb_state *mrb, mrb_value self)
{
	mrb_int area, hartid, page;
	char *p;

	mrb_get_args(mrb, "iii", &hartid, &page, &area);
	if (page <= 0 || page >= 0x100000 || (page & 0xfff) != 0)
		mrb_raise(mrb, E_ARGUMENT_ERROR,
		    "trampoline must be a page below 1 MiB");

	p = (char *)page;
#define	AT(sym)	(p + ((sym) - ap_trampoline))
	memcpy(p, ap_trampoline, ap_trampoline_end - ap_trampoline);
	*(uint32_t *)(AT(tr_gdtr) + 2) = (uint32_t)(uintptr_t)AT(tr_gdt);
	*(uint32_t *)AT(tr_jmp32) = (uint32_t)(uintptr_t)AT(tr_protected);
	*(uint32_t *)AT(tr_jmp64) = (uint32_t)(uintptr_t)AT(tr_long);
	*(uint64_t *)AT(tr_cr3) = (uintptr_t)kernel_pml4;
	*(uint64_t *)AT(tr_stack) = area;
	*(uint64_t *)AT(tr_entry) = (uintptr_t)ap_entry;
	*(uint64_t *)AT(tr_hartid) = hartid;
#undef AT
	__atomic_store_n(&cpu_started, -1, __ATOMIC_SEQ_CST);
	return mrb_fixnum_value(page >> 12);
}

/* SMP.ready?(hartid): whether that CPU got as far as arch_cpu_init(). */
mrb_value
smp_ready_p(mrb_state *mrb, mrb_value self)
{
	mrb_int hartid;

	mrb_get_args(mrb, "i", &hartid);
	return mrb_bool_value(__atomic_load_n(&cpu_started,
	    __ATOMIC_ACQUIRE) == hartid);
}

/* Define the Port, CPU, SMP and Kern additions described above. */
void
arch_hal_init(mrb_state *mrb)
{
	struct RClass *cpu, *kern, *port, *smp;

	port = mrb_define_module(mrb, "Port");
#define	DEF_PORT(bits) do {						\
	mrb_define_module_function(mrb, port, "in" #bits,		\
	    port_in##bits, MRB_ARGS_REQ(1));				\
	mrb_define_module_function(mrb, port, "out" #bits,		\
	    port_out##bits, MRB_ARGS_REQ(2));				\
} while (0)
	DEF_PORT(8);
	DEF_PORT(16);
	DEF_PORT(32);
#undef DEF_PORT

	cpu = mrb_define_module(mrb, "CPU");
	mrb_define_module_function(mrb, cpu, "rdmsr", cpu_rdmsr,
	    MRB_ARGS_REQ(1));
	mrb_define_module_function(mrb, cpu, "wrmsr", cpu_wrmsr,
	    MRB_ARGS_REQ(2));
	mrb_define_module_function(mrb, cpu, "cpuid", cpu_cpuid,
	    MRB_ARGS_ARG(1, 1));
	mrb_define_module_function(mrb, cpu, "tsc", cpu_tsc, MRB_ARGS_NONE());
	mrb_define_module_function(mrb, cpu, "take_pending", cpu_take_pending,
	    MRB_ARGS_NONE());

	smp = mrb_define_module(mrb, "SMP");
	mrb_define_module_function(mrb, smp, "prepare", smp_prepare,
	    MRB_ARGS_REQ(3));
	mrb_define_module_function(mrb, smp, "ready?", smp_ready_p,
	    MRB_ARGS_REQ(1));

	kern = mrb_define_module(mrb, "Kern");
	mrb_define_const(mrb, kern, "IRQ_VECTOR_BASE",
	    mrb_fixnum_value(IRQ_VECTOR_BASE));
	mrb_define_const(mrb, kern, "IPI_VECTOR", mrb_fixnum_value(IPI_VECTOR));
	mrb_define_const(mrb, kern, "SPURIOUS_VECTOR",
	    mrb_fixnum_value(SPURIOUS_VECTOR));
}
