/*
 * amd64 primitives for Ruby, added by arch_hal_init() next to the
 * portable ones from src/hal.c:
 *
 *   Port.in8(port) -> Integer, Port.out8(port, v)  (8/16/32)
 *   CPU.rdmsr(msr) -> Integer, CPU.wrmsr(msr, v)
 *   CPU.cpuid(leaf, sub = 0) -> [eax, ebx, ecx, edx]
 *   CPU.tsc -> the time stamp counter
 */
#include <stdint.h>

#include <mruby.h>
#include <mruby/array.h>

#include "kernel.h"
#include "amd64.h"

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

/* Define the Port and CPU additions described above. */
void
arch_hal_init(mrb_state *mrb)
{
	struct RClass *cpu, *port;

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
}
