/*
 * RISC-V privileged architecture: control and status registers (CSRs) as
 * seen from S-mode.
 */
#ifndef LAZUL_RISCV_H
#define LAZUL_RISCV_H

#include <stdint.h>

/* sstatus.SIE: supervisor interrupts are globally enabled. */
#define	SSTATUS_SIE	(1UL << 1)

/*
 * Access the control and status register csr of the current hart. csr is
 * the register's name as an identifier (e.g. sstatus), not a string, since
 * it becomes part of the instruction. CSR_READ() evaluates to the value
 * of the register, CSR_WRITE() replaces it with v, and CSR_SET() and
 * CSR_CLEAR() set or clear the bits that are set in v.
 */
#define	CSR_READ(csr) ({						\
	uint64_t __v;							\
									\
	__asm__ volatile("csrr %0, " #csr : "=r"(__v));			\
	__v;								\
})

#define	CSR_WRITE(csr, v)						\
	__asm__ volatile("csrw " #csr ", %0" :: "rK"(v))

#define	CSR_SET(csr, v)							\
	__asm__ volatile("csrs " #csr ", %0" :: "rK"(v))

#define	CSR_CLEAR(csr, v)						\
	__asm__ volatile("csrc " #csr ", %0" :: "rK"(v))

#endif
