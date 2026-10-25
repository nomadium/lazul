MRUBY_VERSION := 4.0.0
MRUBY_REPO    := https://github.com/mruby/mruby.git
MRUBY_DIR     := mruby

BUILD       := build
MRUBY_BUILD := $(BUILD)/mruby/riscv64
MRBC        := $(BUILD)/mruby/host/bin/mrbc
LIBMRUBY    := $(MRUBY_BUILD)/lib/libmruby.a

CROSS  ?= riscv64-unknown-elf-
CC     := $(CROSS)gcc
ARCH   := -march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany
CFLAGS := $(ARCH) --specs=picolibc.specs -std=gnu99 -O2 -g          \
           -Wall -Wundef -Wwrite-strings -ffreestanding             \
           -fno-common -ffunction-sections -fdata-sections -MMD -MP \
           -I $(MRUBY_DIR)/include -I $(MRUBY_BUILD)/include        \
           -DMRB_NO_STDIO -DMRB_INT64 -DMRB_UTF8_STRING
LDFLAGS := $(ARCH) --specs=picolibc.specs -nostartfiles -T src/kernel.ld \
           -Wl,--gc-sections -Wl,-Map,$(BUILD)/kernel.map

# Kernel Ruby sources, in load order.
RUBY_SRCS := kernel/sbi.rb kernel/uart.rb kernel/plic.rb kernel/console.rb \
             kernel/hart.rb kernel/shell.rb kernel/kern.rb
C_SRCS  := src/main.c src/hal.c
OBJS    := $(BUILD)/start.o $(C_SRCS:src/%.c=$(BUILD)/%.o) $(BUILD)/kernel_rb.o
DEPS    := $(OBJS:.o=.d)

# Do not miss changes in header dependencies.
-include $(DEPS)

.DEFAULT_GOAL := $(BUILD)/kernel.elf


.PHONY: run debug gdb test lint lint-fix clean distclean image


$(BUILD)/kernel.elf: $(OBJS) $(LIBMRUBY) src/kernel.ld
	$(CC) $(LDFLAGS) -o $@ $(OBJS) $(LIBMRUBY) -lm

$(BUILD)/kernel_rb.c: $(RUBY_SRCS) $(MRBC)
	$(MRBC) -g -Bkernel_rb -o $@ $(RUBY_SRCS)

$(BUILD)/%.o: src/%.c $(LIBMRUBY)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/kernel_rb.o: $(BUILD)/kernel_rb.c
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/start.o: src/start.S
	@mkdir -p $(BUILD)
	$(CC) $(ARCH) -g -MMD -MP -c -o $@ $<


$(MRUBY_DIR)/Rakefile:
	git clone --branch $(MRUBY_VERSION) $(MRUBY_REPO) $(MRUBY_DIR)

$(LIBMRUBY) $(MRBC) &: build_config/riscv64.rb $(MRUBY_DIR)/Rakefile
	cd $(MRUBY_DIR) && \
		rake -v MRUBY_CONFIG=$(abspath build_config/riscv64.rb) \
			-j$$(nproc) all
	@touch $(LIBMRUBY) $(MRBC)


clean:
	rm -f $(BUILD)/*.o $(BUILD)/*.d $(BUILD)/kernel_rb.c $(BUILD)/kernel.*

distclean: clean
	rm -rf $(BUILD) $(MRUBY_DIR)


LINT_SRCS := test kernel
lint:
	standardrb $(LINT_SRCS)

lint-fix:
	standardrb --fix $(LINT_SRCS)


# Development container (run on the host; then use ./dmake instead of make).
IMAGE ?= lazul-dev
image:
	docker build -t $(IMAGE) .


QEMU ?= qemu-system-riscv64
GDB  ?= gdb-multiarch
SMP  ?= 4
MEM  ?= 128M

# make debug starts QEMU stopped, with its gdb stub on a Unix socket in the
# build tree; make gdb, from another terminal, attaches to it.  A socket
# file, not a TCP port, so that two ./dmake containers can reach each other
# through the bind-mounted tree.
GDB_SOCK := $(BUILD)/gdb.sock

QEMU_FLAGS := -machine virt -smp $(SMP) -m $(MEM) -nographic -bios default \
              -kernel $(BUILD)/kernel.elf

run: $(BUILD)/kernel.elf
	$(QEMU) $(QEMU_FLAGS)

debug: $(BUILD)/kernel.elf
	$(QEMU) $(QEMU_FLAGS) -S -gdb unix:$(GDB_SOCK),server=on,wait=off

gdb: $(BUILD)/kernel.elf
	$(GDB) -q -ex 'target remote $(GDB_SOCK)' $(BUILD)/kernel.elf

test: $(BUILD)/kernel.elf
	SMP=$(SMP) test/console_test.rb
