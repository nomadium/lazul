/*
 * Hardware access exposed to Ruby. These are deliberately thin, mechanism
 * only: device drivers, interrupt routing, SMP bring-up etc. are written in
 * Ruby on top of them.
 *
 *   Memory[addr] -> byte, Memory[addr] = byte
 *   Memory.read32(addr) -> Integer, Memory.write32(addr, v)  (8/16/32/64)
 *   Memory.read_bytes(addr, len) -> String (a copy, e.g. of a firmware table)
 *   CPU.hartid, CPU.fence
 *   Kern.alloc_hart_area -> Integer (a stack and TLS area for one more hart)
 *   Kern::HEAP_START, Kern::HEAP_END
 *
 * Architecture specific primitives (registers, firmware calls, ...) are
 * added by arch_hal_init() in src/arch/<arch>/hal.c.
 */
#include <stdlib.h>

#include <mruby.h>
#include <mruby/presym.h>
#include <mruby/string.h>

#include "kernel.h"

/* Define Memory.read<bits> and Memory.write<bits>. */
#define	MEM_ACCESSORS(bits)						\
mrb_value								\
mem_read##bits(mrb_state *mrb, mrb_value self)				\
{									\
	mrb_int addr;							\
									\
	mrb_get_args(mrb, "i", &addr);					\
	return mrb_int_value(mrb,					\
	    (mrb_int)*(volatile uint##bits##_t *)addr);			\
}									\
									\
mrb_value								\
mem_write##bits(mrb_state *mrb, mrb_value self)				\
{									\
	mrb_int addr, v;						\
									\
	mrb_get_args(mrb, "ii", &addr, &v);				\
	*(volatile uint##bits##_t *)addr = (uint##bits##_t)v;		\
	return mrb_int_value(mrb, v);					\
}

MEM_ACCESSORS(8)
MEM_ACCESSORS(16)
MEM_ACCESSORS(32)
MEM_ACCESSORS(64)

/* Memory.read_bytes(addr, len): copy len bytes at addr into a String. */
mrb_value
mem_read_bytes(mrb_state *mrb, mrb_value self)
{
	mrb_int addr, len;

	mrb_get_args(mrb, "ii", &addr, &len);
	if (len < 0)
		mrb_raise(mrb, E_ARGUMENT_ERROR, "negative length");
	return mrb_str_new(mrb, (const char *)addr, len);
}

/* CPU.hartid: id of the current hart. */
mrb_value
cpu_hartid(mrb_state *mrb, mrb_value self)
{
	return mrb_fixnum_value(this_hartid);
}

/* CPU.fence: full memory barrier. */
mrb_value
cpu_fence(mrb_state *mrb, mrb_value self)
{
	__atomic_thread_fence(__ATOMIC_SEQ_CST);
	return mrb_nil_value();
}

/*
 * Kern.alloc_hart_area: memory for one more hart, allocated once the
 * device tree has said which harts there are, before starting the hart.
 * It is a stack of 1 << STACK_SHIFT bytes with the hart's TLS_AREA bytes
 * of TLS right above it; the address returned is where the two meet, so
 * it is both the initial stack pointer and the TLS area. Never freed.
 */
mrb_value
kern_alloc_hart_area(mrb_state *mrb, mrb_value self)
{
	void *area;

	if (posix_memalign(&area, 16, (1UL << STACK_SHIFT) + TLS_AREA) != 0)
		mrb_raise(mrb, E_RUNTIME_ERROR, "no memory for a hart's stack");
	return mrb_int_value(mrb,
	    (mrb_int)((uint8_t *)area + (1UL << STACK_SHIFT)));
}

/* Define the Memory, CPU and Kern modules described above in mrb. */
void
hal_init(mrb_state *mrb)
{
	struct RClass *cpu, *kern, *mem;

	mem = mrb_define_module(mrb, "Memory");
	mrb_define_module_function(mrb, mem, "[]", mem_read8, MRB_ARGS_REQ(1));
	mrb_define_module_function(mrb, mem, "[]=", mem_write8,
	    MRB_ARGS_REQ(2));
#define	DEF_MEM(bits) do {						\
	mrb_define_module_function(mrb, mem, "read" #bits,		\
	    mem_read##bits, MRB_ARGS_REQ(1));				\
	mrb_define_module_function(mrb, mem, "write" #bits,		\
	    mem_write##bits, MRB_ARGS_REQ(2));				\
} while (0)
	DEF_MEM(8);
	DEF_MEM(16);
	DEF_MEM(32);
	DEF_MEM(64);
#undef DEF_MEM
	mrb_define_module_function(mrb, mem, "read_bytes", mem_read_bytes,
	    MRB_ARGS_REQ(2));

	cpu = mrb_define_module(mrb, "CPU");
	mrb_define_module_function(mrb, cpu, "hartid", cpu_hartid,
	    MRB_ARGS_NONE());
	mrb_define_module_function(mrb, cpu, "fence", cpu_fence,
	    MRB_ARGS_NONE());

	kern = mrb_define_module(mrb, "Kern");
	mrb_define_module_function(mrb, kern, "alloc_hart_area",
	    kern_alloc_hart_area, MRB_ARGS_NONE());
	mrb_define_const(mrb, kern, "HEAP_START",
	    mrb_int_value(mrb, (mrb_int)__heap_start));
	mrb_define_const(mrb, kern, "HEAP_END",
	    mrb_int_value(mrb, (mrb_int)heap_limit));

	arch_hal_init(mrb);
}
