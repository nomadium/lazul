/*
 * lazul C core: everything that must happen before, around, or beneath
 * the mruby VM. Policy lives in Ruby (kernel/ directory); this file only
 *
 *   - sets up per-hart TLS (picolibc keeps errno etc. there),
 *   - owns the big kernel lock (BKL) serializing all access to the one VM,
 *   - runs each hart's idle loop: call Ruby, release the BKL, wfi, repeat,
 *   - catches CPU exceptions and panics.
 *
 * Ruby code always runs to completion with the BKL held and interrupts
 * globally disabled (sstatus.SIE = 0). Interrupts are never taken as traps:
 * wfi wakes up on any interrupt pending in sie, and Ruby then looks at sip
 * and services the device. This keeps the VM single-threaded and
 * non-reentrant, which is what mruby requires.
 */
#include <picotls.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <mruby.h>
#include <mruby/error.h>
#include <mruby/irep.h>
#include <mruby/string.h>

#include "kernel.h"
#include "riscv.h"
#include "sbi.h"

#define	TLS_AREA	256

/* Arguments of a call into Ruby, passed through mrb_protect_error(). */
struct kcall {
	mrb_int	argc;
	const	mrb_value *argv;
	const	char *name;
};

/* Ticket lock, so that no hart starves. */
struct ticket_lock {
	uint32_t	next;
	uint32_t	serving;
};

extern char __heap_end[], __heap_start[];
/* The kernel/ Ruby sources, compiled to bytecode by mrbc. */
extern const uint8_t kernel_rb[];

__thread int this_hartid = -1;
char *heap_limit = __heap_end;

static struct ticket_lock bkl;	/* big kernel lock */
static char *heap_brk = __heap_start;
static uint8_t hart_tls[MAX_HARTS][TLS_AREA] __attribute__((__aligned__(16)));
static mrb_state *mrb;

/*
 * Write the character c to the console through the firmware. This works
 * before Ruby and its UART driver are up, so early messages and panics
 * use it, through kputs() and kputhex().
 */
static void
kputc(char c)
{
	sbi_call(SBI_EXT_LEGACY_PUTCHAR, 0, c, 0, 0, 0, 0, 0);
}

/* Write the string s to the console through the firmware. */
void
kputs(const char *s)
{
	for (; *s != '\0'; s++)
		kputc(*s);
}

/*
 * Write v to the console as "0x" followed by 16 hex digits, most
 * significant first: each digit is the 4 bits that the shift brings down.
 */
void
kputhex(uint64_t v)
{
	int shift;

	kputs("0x");
	for (shift = 60; shift >= 0; shift -= 4)
		kputc("0123456789abcdef"[(v >> shift) & 0xf]);
}

/* Print msg and stop this hart for good; the other harts keep running. */
NORETURN void
panic(const char *msg)
{
	kputs("\npanic: ");
	kputs(msg);
	kputs("\n");
	for (;;)
		__asm__ volatile("wfi");
}

/* libc's abort() ends up here (e.g. from a failed assert in mruby). */
NORETURN void
_exit(int status)
{
	(void)status;
	panic("_exit called");
}

/* Supervisor trap vector. Only synchronous exceptions can land here. */
__attribute__((__interrupt__("supervisor"), __aligned__(4)))
void
trap_vector(void)
{
	kputs("\n*** exception on hart ");
	kputhex(this_hartid);
	kputs(" scause=");
	kputhex(CSR_READ(scause));
	kputs(" sepc=");
	kputhex(CSR_READ(sepc));
	kputs(" stval=");
	kputhex(CSR_READ(stval));
	panic("unexpected trap");
}

/* Take the big kernel lock, waiting for our turn. */
void
bkl_acquire(void)
{
	uint32_t ticket;

	ticket = __atomic_fetch_add(&bkl.next, 1, __ATOMIC_RELAXED);
	while (__atomic_load_n(&bkl.serving, __ATOMIC_ACQUIRE) != ticket)
		continue;
}

/* Release the big kernel lock to the next hart in line. */
void
bkl_release(void)
{
	__atomic_store_n(&bkl.serving, bkl.serving + 1, __ATOMIC_RELEASE);
}

/* Grow or shrink the heap by incr bytes for picolibc's malloc. */
void *
sbrk(ptrdiff_t incr)
{
	char *old;

	if (incr > heap_limit - heap_brk || incr < __heap_start - heap_brk)
		return (void *)-1;

	old = heap_brk;
	heap_brk += incr;

	return old;
}

/* Body of kern_call(), run under mrb_protect_error(). */
mrb_value
kcall_body(mrb_state *mrb, void *ud)
{
	struct kcall *c;
	struct RClass *kern;

	c = ud;
	kern = mrb_module_get(mrb, "Kern");
	return mrb_funcall_argv(mrb, mrb_obj_value(kern),
	    mrb_intern_cstr(mrb, c->name), c->argc, c->argv);
}

/* Body of report_exception(): inspect the exception, which may raise. */
mrb_value
inspect_body(mrb_state *mrb, void *ud)
{
	return mrb_inspect(mrb, *(mrb_value *)ud);
}

/* Print an exception that escaped from Ruby code. */
void
report_exception(mrb_value exc)
{
	mrb_value s;
	mrb_bool err;

	s = mrb_protect_error(mrb, inspect_body, &exc, &err);
	kputs("\nunhandled Ruby exception: ");
	kputs(err ? "(inspect failed)" : mrb_str_to_cstr(mrb, s));
	kputs("\n");
}

/* Call Kern.<name>(*argv). Must hold the BKL. */
void
kern_call(const char *name, mrb_int argc, const mrb_value *argv)
{
	struct kcall c;
	mrb_value r;
	int ai;
	mrb_bool err;

	ai = mrb_gc_arena_save(mrb);
	c.argc = argc;
	c.argv = argv;
	c.name = name;

	r = mrb_protect_error(mrb, kcall_body, &c, &err);
	if (err)
		report_exception(r);

	mrb->exc = NULL;
	mrb_gc_arena_restore(mrb, ai);
}

/* Give this hart its TLS and trap vector, with interrupts disabled. */
void
hart_setup(long hartid)
{
	if (hartid < 0 || hartid >= MAX_HARTS)
		panic("hart id out of range");

	if (_tls_size() > TLS_AREA)
		panic("TLS area too small");

	_init_tls(hart_tls[hartid]);
	_set_tls(hart_tls[hartid]);
	this_hartid = hartid;

	CSR_WRITE(stvec, (uintptr_t)trap_vector);
	/* Interrupts only ever wake wfi; they are never taken. */
	CSR_CLEAR(sstatus, SSTATUS_SIE);
	CSR_WRITE(sie, 0);
}

/* Idle loop of a hart: run Ruby, release the BKL, wfi, repeat. */
NORETURN void
hart_loop(long hartid)
{
	mrb_value id;

	id = mrb_fixnum_value(hartid);
	for (;;) {
		kern_call("tick", 1, &id);
		bkl_release();
		__asm__ volatile("wfi");
		bkl_acquire();
	}
}

/*
 * C entry point of the boot hart, called by _start in start.S with the
 * hart id and device tree address that the firmware passed. Set up the
 * hart and the mruby VM, load the kernel's Ruby code and call Kern.boot,
 * then become this hart's idle loop.
 */
NORETURN void
boot_main(long hartid, uintptr_t dtb)
{
	mrb_value args[2];

	hart_setup(hartid);
	kputs("lazul: booting on hart ");
	kputhex(hartid);
	kputs("\n");

	/* QEMU puts the device tree at the top of RAM; keep the heap below. */
	if (dtb > (uintptr_t)__heap_start && dtb < (uintptr_t)heap_limit)
		heap_limit = (char *)(dtb & ~0xfffUL);

	bkl_acquire();
	mrb = mrb_open();
	if (mrb == NULL)
		panic("mrb_open failed");

	hal_init(mrb);

	mrb_load_irep(mrb, kernel_rb);
	if (mrb->exc != NULL) {
		report_exception(mrb_obj_value(mrb->exc));
		panic("failed to load kernel Ruby code");
	}

	args[0] = mrb_fixnum_value(hartid);
	args[1] = mrb_int_value(mrb, dtb);
	kern_call("boot", 2, args);
	hart_loop(hartid);
}

/*
 * C entry point of every other hart, called by _secondary_start in start.S
 * once Ruby has started the hart through the SBI HSM extension. Set up
 * the hart, tell Kern.hart_started about it and become its idle loop.
 * opaque is the value Ruby passed to the HSM call; it is unused.
 */
NORETURN void
secondary_main(long hartid, uintptr_t opaque)
{
	mrb_value id;

	(void)opaque;
	hart_setup(hartid);
	bkl_acquire();
	id = mrb_fixnum_value(hartid);
	kern_call("hart_started", 1, &id);
	hart_loop(hartid);
}
