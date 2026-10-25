/*
 * Calls into the Supervisor Binary Interface (SBI): the services that the
 * M-mode firmware (OpenSBI) provides to the kernel running in S-mode. See
 * the RISC-V SBI specification.
 *
 * start.S includes this file too; the C-only part is hidden from the
 * assembler.
 */
#ifndef LAZUL_SBI_H
#define LAZUL_SBI_H

/* Legacy (SBI v0.1) console output of one character, passed in a0. */
#define	SBI_EXT_LEGACY_PUTCHAR	0x01

/* Base extension: probe_extension returns nonzero if extension a0 exists. */
#define	SBI_EXT_BASE			0x10
#define	SBI_BASE_PROBE_EXTENSION	3

/* Hart State Management (HSM) extension: functions and hart states. */
#define	SBI_EXT_HSM		0x48534d	/* "HSM" */
#define	SBI_HSM_HART_START	0
#define	SBI_HSM_HART_STOP	1
#define	SBI_HSM_HART_GET_STATUS	2
#define	SBI_HSM_STATE_STOPPED	1

#ifndef __ASSEMBLER__

/*
 * Result of an SBI call. For the current extensions, error is 0 on
 * success or a negative SBI error code, and value is the result. Legacy
 * extensions return their result in error and leave value unspecified.
 */
struct sbiret {
	long	error;
	long	value;
};

/*
 * Call function fid of SBI extension eid with arguments a0 to a5. This
 * follows the SBI calling convention: eid goes in register a7, fid in a6
 * and the arguments in a0 to a5; the result comes back in a0 (error) and
 * a1 (value). Legacy extensions ignore fid.
 */
static inline struct sbiret
sbi_call(long eid, long fid, long a0, long a1, long a2, long a3, long a4,
    long a5)
{
	register long r0 __asm__("a0") = a0;
	register long r1 __asm__("a1") = a1;
	register long r2 __asm__("a2") = a2;
	register long r3 __asm__("a3") = a3;
	register long r4 __asm__("a4") = a4;
	register long r5 __asm__("a5") = a5;
	register long r6 __asm__("a6") = fid;
	register long r7 __asm__("a7") = eid;

	__asm__ volatile("ecall"
	    : "+r"(r0), "+r"(r1)
	    : "r"(r2), "r"(r3), "r"(r4), "r"(r5), "r"(r6), "r"(r7)
	    : "memory");
	return (struct sbiret){ r0, r1 };
}

#endif /* !__ASSEMBLER__ */

#endif
