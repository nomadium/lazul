# Pick the architecture with ARCH= (default riscv64). Everything specific
# to it is in src/arch/$(ARCH)/arch.mk, which defines:
#
#   CROSS           prefix of the cross toolchain (e.g. riscv64-unknown-elf-)
#   ARCH_FLAGS      machine flags for compiling, assembling and linking
#   LIBC_SPECS      flags that select the C library (picolibc)
#   ARCH_C_SRCS     C sources in src/arch/$(ARCH)/
#   ARCH_ASM_SRCS   assembly sources in src/arch/$(ARCH)/
#   ARCH_RUBY_SRCS  Ruby sources in kernel/arch/$(ARCH)/, loaded first
#   QEMU, MEM, QEMU_FLAGS  how to run the kernel in QEMU
#
# The linker script is src/arch/$(ARCH)/kernel.ld and the mruby build
# configuration build_config/$(ARCH).rb.
ARCH ?= riscv64

ifeq ($(wildcard src/arch/$(ARCH)/arch.mk),)
$(error unsupported ARCH "$(ARCH)": no src/arch/$(ARCH)/arch.mk)
endif

MRUBY_VERSION := 4.0.0
MRUBY_REPO    := https://github.com/mruby/mruby.git
MRUBY_DIR     := mruby

BUILD_ROOT  := build
BUILD       := $(BUILD_ROOT)/$(ARCH)
MRUBY_BUILD := $(BUILD_ROOT)/mruby/$(ARCH)
MRBC        := $(BUILD_ROOT)/mruby/host/bin/mrbc
LIBMRUBY    := $(MRUBY_BUILD)/lib/libmruby.a

SMP ?= 4

include src/arch/$(ARCH)/arch.mk

CC     := $(CROSS)gcc
CFLAGS := $(ARCH_FLAGS) $(LIBC_SPECS) -std=gnu99 -O2 -g             \
           -Wall -Wundef -Wwrite-strings -ffreestanding             \
           -fno-common -ffunction-sections -fdata-sections -MMD -MP \
           -I src -I $(MRUBY_DIR)/include -I $(MRUBY_BUILD)/include \
           -DMRB_NO_STDIO -DMRB_INT64 -DMRB_UTF8_STRING
LDFLAGS := $(ARCH_FLAGS) $(LIBC_SPECS) -nostartfiles \
           -T src/arch/$(ARCH)/kernel.ld \
           -Wl,--gc-sections -Wl,-Map,$(BUILD)/kernel.map

# Kernel Ruby sources, in load order: architecture specific code first.
RUBY_SRCS := $(ARCH_RUBY_SRCS) kernel/uart.rb kernel/console.rb \
             kernel/hart.rb kernel/shell.rb kernel/kern.rb
C_SRCS  := src/main.c src/hal.c $(ARCH_C_SRCS)
OBJS    := $(ARCH_ASM_SRCS:src/%.S=$(BUILD)/%.o) \
           $(C_SRCS:src/%.c=$(BUILD)/%.o) $(BUILD)/kernel_rb.o
DEPS    := $(OBJS:.o=.d)

# Do not miss changes in header dependencies.
-include $(DEPS)

.DEFAULT_GOAL := $(BUILD)/kernel.elf


.PHONY: run debug gdb test lint lint-fix clean distclean image


$(BUILD)/kernel.elf: $(OBJS) $(LIBMRUBY) src/arch/$(ARCH)/kernel.ld
	$(CC) $(LDFLAGS) -o $@ $(OBJS) $(LIBMRUBY) -lm

$(BUILD)/kernel_rb.c: $(RUBY_SRCS) $(MRBC)
	@mkdir -p $(@D)
	$(MRBC) -g -Bkernel_rb -o $@ $(RUBY_SRCS)

$(BUILD)/%.o: src/%.c $(LIBMRUBY)
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/kernel_rb.o: $(BUILD)/kernel_rb.c
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/%.o: src/%.S
	@mkdir -p $(@D)
	$(CC) $(ARCH_FLAGS) -I src -g -MMD -MP -c -o $@ $<


$(MRUBY_DIR)/Rakefile:
	git clone --branch $(MRUBY_VERSION) $(MRUBY_REPO) $(MRUBY_DIR)

$(LIBMRUBY) $(MRBC) &: build_config/$(ARCH).rb $(MRUBY_DIR)/Rakefile
	cd $(MRUBY_DIR) && \
		rake -v MRUBY_CONFIG=$(abspath build_config/$(ARCH).rb) \
			BUILD_ROOT=$(abspath $(BUILD_ROOT)) -j$$(nproc) all
	@touch $(LIBMRUBY) $(MRBC)


# The kernel's own build products; mruby's, in $(BUILD_ROOT)/mruby, stay.
clean:
	rm -rf $(BUILD)

distclean:
	rm -rf $(BUILD_ROOT) $(MRUBY_DIR)


LINT_SRCS := test kernel
lint:
	standardrb $(LINT_SRCS)

lint-fix:
	standardrb --fix $(LINT_SRCS)


# Development container (run on the host; then use ./dmake instead of make).
IMAGE ?= lazul-dev
image:
	docker build -t $(IMAGE) .


GDB ?= gdb-multiarch

# make debug starts QEMU stopped, with its gdb stub on a Unix socket in the
# build tree; make gdb, from another terminal, attaches to it.  A socket
# file, not a TCP port, so that two ./dmake containers can reach each other
# through the bind-mounted tree.
GDB_SOCK := $(BUILD)/gdb.sock

run: $(BUILD)/kernel.elf
	$(QEMU) $(QEMU_FLAGS)

debug: $(BUILD)/kernel.elf
	$(QEMU) $(QEMU_FLAGS) -S -gdb unix:$(GDB_SOCK),server=on,wait=off

gdb: $(BUILD)/kernel.elf
	$(GDB) -q -ex 'target remote $(GDB_SOCK)' $(BUILD)/kernel.elf

test: $(BUILD)/kernel.elf
	SMP=$(SMP) QEMU_CMD="$(QEMU) $(QEMU_FLAGS)" test/console_test.rb
