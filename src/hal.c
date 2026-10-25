/*
 * Hardware access exposed to Ruby. These are deliberately thin, mechanism
 * only: device drivers, interrupt routing, SMP bring-up etc. are written in
 * Ruby on top of them.
 *
 *   Memory[addr] -> byte, Memory[addr] = byte
 *   Memory.read32(addr) -> Integer, Memory.write32(addr, v)  (8/16/32/64)
 *   CPU.csr(:sip), CPU.csr_write/csr_set/csr_clear(:sie, bits)
 *   CPU.hartid, CPU.fence
 *   SBI.ecall(eid, fid, *args) -> [error, value]
 *   Kern::SECONDARY_ENTRY, Kern::MAX_HARTS, Kern::HEAP_START, Kern::HEAP_END
 */
#include <mruby.h>
#include <mruby/array.h>
#include <mruby/presym.h>

#include "kernel.h"
#include "riscv.h"
#include "sbi.h"

#define	CSR_LIST(X)							\
	X(sstatus); X(sie); X(sip); X(stvec); X(sscratch); X(sepc);	\
	X(scause); X(stval); X(satp)

enum csr_op { CSR_OP_READ, CSR_OP_WRITE, CSR_OP_SET, CSR_OP_CLEAR };

extern char __heap_start[], _secondary_start[];

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

/* Apply op to the CSR called name, then return its value. */
uint64_t
csr_access(mrb_state *mrb, mrb_sym name, enum csr_op op, uint64_t v)
{
#define	CSR_CASE(c) do {						\
	if (name == mrb_intern_lit(mrb, #c)) {				\
		switch (op) {						\
		case CSR_OP_WRITE:					\
			CSR_WRITE(c, v);				\
			break;						\
		case CSR_OP_SET:					\
			CSR_SET(c, v);					\
			break;						\
		case CSR_OP_CLEAR:					\
			CSR_CLEAR(c, v);				\
			break;						\
		default:						\
			break;						\
		}							\
		return CSR_READ(c);					\
	}								\
} while (0)
	CSR_LIST(CSR_CASE);
#undef CSR_CASE
	if (op == CSR_OP_READ && name == mrb_intern_lit(mrb, "time"))
		return CSR_READ(time);
	mrb_raisef(mrb, E_ARGUMENT_ERROR, "unsupported CSR: %n", name);
}

/* CPU.csr(name): read a CSR. */
mrb_value
cpu_csr(mrb_state *mrb, mrb_value self)
{
	mrb_sym name;

	mrb_get_args(mrb, "n", &name);
	return mrb_int_value(mrb,
	    (mrb_int)csr_access(mrb, name, CSR_OP_READ, 0));
}

/* Define CPU.csr_write, csr_set or csr_clear(name, value). */
#define	CSR_MODIFIER(fn, op)						\
mrb_value								\
fn(mrb_state *mrb, mrb_value self)					\
{									\
	mrb_int v;							\
	mrb_sym name;							\
									\
	mrb_get_args(mrb, "ni", &name, &v);				\
	return mrb_int_value(mrb,					\
	    (mrb_int)csr_access(mrb, name, (op), v));			\
}

CSR_MODIFIER(cpu_csr_write, CSR_OP_WRITE)
CSR_MODIFIER(cpu_csr_set, CSR_OP_SET)
CSR_MODIFIER(cpu_csr_clear, CSR_OP_CLEAR)

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

/* SBI.ecall(eid, fid, *args): make an SBI call, return [error, value]. */
mrb_value
sbi_ecall(mrb_state *mrb, mrb_value self)
{
	mrb_int a[6] = { 0 };
	struct sbiret r;
	mrb_int eid, fid;

	mrb_get_args(mrb, "ii|iiiiii", &eid, &fid, &a[0], &a[1], &a[2], &a[3],
	    &a[4], &a[5]);
	r = sbi_call(eid, fid, a[0], a[1], a[2], a[3], a[4], a[5]);

	return mrb_assoc_new(mrb, mrb_int_value(mrb, r.error),
	    mrb_int_value(mrb, r.value));
}

/* Define the Memory, CPU, SBI and Kern modules described above in mrb. */
void
hal_init(mrb_state *mrb)
{
	struct RClass *cpu, *kern, *mem, *sbi;

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

	cpu = mrb_define_module(mrb, "CPU");
	mrb_define_module_function(mrb, cpu, "csr", cpu_csr, MRB_ARGS_REQ(1));
	mrb_define_module_function(mrb, cpu, "csr_write", cpu_csr_write,
	    MRB_ARGS_REQ(2));
	mrb_define_module_function(mrb, cpu, "csr_set", cpu_csr_set,
	    MRB_ARGS_REQ(2));
	mrb_define_module_function(mrb, cpu, "csr_clear", cpu_csr_clear,
	    MRB_ARGS_REQ(2));
	mrb_define_module_function(mrb, cpu, "hartid", cpu_hartid,
	    MRB_ARGS_NONE());
	mrb_define_module_function(mrb, cpu, "fence", cpu_fence,
	    MRB_ARGS_NONE());

	sbi = mrb_define_module(mrb, "SBI");
	mrb_define_module_function(mrb, sbi, "ecall", sbi_ecall,
	    MRB_ARGS_ARG(2, 6));

	kern = mrb_define_module(mrb, "Kern");
	mrb_define_const(mrb, kern, "SECONDARY_ENTRY",
	    mrb_int_value(mrb, (mrb_int)_secondary_start));
	mrb_define_const(mrb, kern, "MAX_HARTS", mrb_fixnum_value(MAX_HARTS));
	mrb_define_const(mrb, kern, "HEAP_START",
	    mrb_int_value(mrb, (mrb_int)__heap_start));
	mrb_define_const(mrb, kern, "HEAP_END",
	    mrb_int_value(mrb, (mrb_int)heap_limit));
}
