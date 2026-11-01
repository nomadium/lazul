/*
 * lazul C core: everything that must happen before, around, or beneath
 * the mruby VM. Policy lives in Ruby (kernel/ directory); this file only
 *
 *   - sets up per-hart TLS (picolibc keeps errno etc. there),
 *   - owns the big kernel lock (BKL) serializing all access to the one VM,
 *   - runs each hart's idle loop: call Ruby, release the BKL, wait for an
 *     interrupt, repeat,
 *   - panics.
 *
 * It is the same on every architecture; the entry points, traps, CPU setup
 * and the early console are in src/arch/<arch>/ (see kernel.h).
 *
 * Ruby code always runs to completion with the BKL held and interrupts
 * disabled. Interrupts are never taken as traps: they only wake the idle
 * loop (arch_idle), and Ruby then finds out what is pending and services
 * the device. This keeps the VM single-threaded and non-reentrant, which
 * is what mruby requires.
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/error.h>
#include <mruby/irep.h>
#include <mruby/string.h>

#include "kernel.h"

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

/* The kernel/ Ruby sources, compiled to bytecode by mrbc. */
extern const uint8_t kernel_rb[];

__thread int this_hartid = -1;
char *heap_limit = __heap_end;

static struct ticket_lock bkl;	/* big kernel lock */
static int stopped;		/* set by panic(): every hart halts */
static char *heap_brk = __heap_start;
static uint8_t boot_tls[TLS_AREA] __attribute__((__aligned__(16)));
static mrb_state *mrb;

/*
 * Write the string s to the console with arch_putc(). This works before
 * Ruby and its UART driver are up, so early messages and panics use it.
 */
void
kputs(const char *s)
{
	for (; *s != '\0'; s++)
		arch_putc(*s);
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
		arch_putc("0123456789abcdef"[(v >> shift) & 0xf]);
}

/*
 * Print msg and stop the kernel: this hart and every other one halt for
 * good. The panicking hart usually holds the BKL, which it will never
 * release; without stopping them, the other harts would spin on it
 * forever as soon as an interrupt woke them. Instead they find stopped
 * set while waiting for the BKL (bkl_acquire()) and halt, and
 * arch_stop_others() wakes the ones that are asleep so that they do.
 * Only the first hart to panic prints; a second one just halts.
 */
NORETURN void
panic(const char *msg)
{
	if (__atomic_exchange_n(&stopped, 1, __ATOMIC_SEQ_CST) == 0) {
		kputs("\npanic: ");
		kputs(msg);
		kputs("\n");
		arch_stop_others();
	}
	arch_halt();
}

/* libc's abort() ends up here (e.g. from a failed assert in mruby). */
NORETURN void
_exit(int status)
{
	(void)status;
	panic("_exit called");
}

/*
 * Take the big kernel lock, waiting for our turn; or halt, if the kernel
 * has panicked meanwhile (see panic()).
 */
void
bkl_acquire(void)
{
	uint32_t ticket;

	ticket = __atomic_fetch_add(&bkl.next, 1, __ATOMIC_RELAXED);
	while (__atomic_load_n(&bkl.serving, __ATOMIC_ACQUIRE) != ticket)
		if (__atomic_load_n(&stopped, __ATOMIC_RELAXED))
			arch_halt();
	if (__atomic_load_n(&stopped, __ATOMIC_RELAXED))
		arch_halt();	/* the hart that panicked did not hold it */
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

/*
 * Body of report_exception(): the exception inspected, then its backtrace
 * one frame per line. Either may raise.
 */
mrb_value
inspect_body(mrb_state *mrb, void *ud)
{
	mrb_value bt, exc, s;
	mrb_int i;

	exc = *(mrb_value *)ud;
	s = mrb_inspect(mrb, exc);
	bt = mrb_funcall(mrb, exc, "backtrace", 0);
	if (mrb_array_p(bt)) {
		for (i = 0; i < RARRAY_LEN(bt); i++) {
			mrb_str_cat_lit(mrb, s, "\n    from ");
			mrb_str_cat_str(mrb, s,
			    mrb_obj_as_string(mrb, RARRAY_PTR(bt)[i]));
		}
	}
	return s;
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

/*
 * Call Kern.<name>(*argv). Must hold the BKL. An exception that escapes
 * is reported here; the return value says whether there was one (1), so
 * that the caller can decide whether the kernel can go on.
 */
int
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
	return err ? 1 : 0;
}

/*
 * Set up this hart's CPU and give it its TLS, in the TLS_AREA bytes at
 * tls, with interrupts disabled. The CPU comes first: on amd64, loading
 * the segment registers clears the thread pointer.
 */
void
hart_setup(long hartid, void *tls)
{
	arch_cpu_init(hartid);

	arch_set_tls(tls, TLS_AREA);
	this_hartid = hartid;
}

/* Idle loop of a hart: run Ruby, release the BKL, wait, repeat. */
NORETURN void
hart_loop(long hartid)
{
	mrb_value id;

	id = mrb_fixnum_value(hartid);
	for (;;) {
		/* An exception here only fails this one wake-up; go on. */
		kern_call("tick", 1, &id);
		bkl_release();
		arch_idle();
		bkl_acquire();
	}
}

/*
 * C entry point of the boot hart, called by the architecture's start.S
 * with the hart id and the boot argument from the firmware or the boot
 * loader (on riscv64, the device tree address). Set up the hart and the
 * mruby VM, load the kernel's Ruby code and call Kern.boot, then become
 * this hart's idle loop.
 */
NORETURN void
boot_main(long hartid, uintptr_t boot_arg)
{
	mrb_value args[2];

	arch_early_init(boot_arg);

	hart_setup(hartid, boot_tls);
	kputs("lazul: booting on hart ");
	kputhex(hartid);
	kputs("\n");

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
	args[1] = mrb_int_value(mrb, boot_arg);
	/*
	 * A kernel that did not finish booting cannot do anything useful,
	 * and the rest of it would run on half-initialized state.
	 */
	if (kern_call("boot", 2, args))
		panic("Kern.boot failed");
	hart_loop(hartid);
}

/*
 * C entry point of every other hart, called by the architecture's start.S
 * once Ruby has started the hart (on riscv64, through the SBI HSM
 * extension). area is the hart's area from Kern.alloc_hart_area: start.S
 * has made the stack below it the hart's stack, and the TLS area above it
 * becomes the hart's TLS. Set up the hart, tell Kern.hart_started about it
 * and become its idle loop.
 */
NORETURN void
secondary_main(long hartid, uintptr_t area)
{
	mrb_value id;

	hart_setup(hartid, (void *)area);
	bkl_acquire();
	id = mrb_fixnum_value(hartid);
	if (kern_call("hart_started", 1, &id))
		panic("Kern.hart_started failed");
	hart_loop(hartid);
}
