/*
 * riscv64 primitives for Ruby, added by arch_hal_init() next to the
 * portable ones from src/hal.c:
 *
 *   CPU.csr(:sip), CPU.csr_write/csr_set/csr_clear(:sie, bits)
 *   SBI.ecall(eid, fid, *args) -> [error, value]
 *   Kern::SECONDARY_ENTRY (where SBI hart_start starts the other harts)
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

extern char _secondary_start[];

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

/* Define the CPU, SBI and Kern additions described above in mrb. */
void
arch_hal_init(mrb_state *mrb)
{
	struct RClass *cpu, *kern, *sbi;

	cpu = mrb_define_module(mrb, "CPU");
	mrb_define_module_function(mrb, cpu, "csr", cpu_csr, MRB_ARGS_REQ(1));
	mrb_define_module_function(mrb, cpu, "csr_write", cpu_csr_write,
	    MRB_ARGS_REQ(2));
	mrb_define_module_function(mrb, cpu, "csr_set", cpu_csr_set,
	    MRB_ARGS_REQ(2));
	mrb_define_module_function(mrb, cpu, "csr_clear", cpu_csr_clear,
	    MRB_ARGS_REQ(2));

	sbi = mrb_define_module(mrb, "SBI");
	mrb_define_module_function(mrb, sbi, "ecall", sbi_ecall,
	    MRB_ARGS_ARG(2, 6));

	kern = mrb_define_module(mrb, "Kern");
	mrb_define_const(mrb, kern, "SECONDARY_ENTRY",
	    mrb_int_value(mrb, (mrb_int)_secondary_start));
}
