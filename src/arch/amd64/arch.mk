# amd64: long mode kernel on a PC; the machine is described by the ACPI
# tables (QEMU's q35 machine by default).
# Included by the Makefile; see there for what this file defines.
#
# QEMU loads kernel.elf itself: its firmware (SeaBIOS) enters the kernel
# through the PVH boot protocol (see start.S).

# The host compiler, with picolibc built for the kernel (see Dockerfile).
CROSS ?= x86_64-linux-gnu-
OBJCOPY := $(CROSS)objcopy

PICOLIBC := /opt/picolibc-amd64

# -mno-red-zone: interrupts arrive on the current stack, so code must not
# keep data below the stack pointer. -mcmodel=small -fno-pic: linked at a
# fixed address below 2 GiB, where 32-bit addresses reach every symbol.
# And none of the distribution's defaults that expect a Linux libc or CPU
# features the kernel does not set up (stack protector, fortify, CET).
ARCH_FLAGS := -mcmodel=small -mno-red-zone -fno-pic -fno-pie \
              -fno-stack-protector -U_FORTIFY_SOURCE -fcf-protection=none
LIBC_SPECS := --specs=$(PICOLIBC)/lib/picolibc.specs
ARCH_LDFLAGS := -no-pie -static -Wl,-z,noexecstack \
                -Wl,-z,max-page-size=4096 -Wl,--build-id=none

ARCH_C_SRCS    := src/arch/amd64/arch.c src/arch/amd64/boot.c \
                  src/arch/amd64/irq.c src/arch/amd64/hal.c
ARCH_ASM_SRCS  := src/arch/amd64/start.S src/arch/amd64/vectors.S
ARCH_RUBY_SRCS := kernel/arch/amd64/acpi.rb kernel/arch/amd64/platform.rb \
                  kernel/arch/amd64/arch.rb

# Interrupt context: see src/arch/amd64/irq.c.
CFLAGS_irq := -mgeneral-regs-only

QEMU ?= qemu-system-x86_64
MEM  ?= 512M

QEMU_FLAGS := -machine q35 -smp $(SMP) -m $(MEM) -nographic -nic none \
              -kernel $(BUILD)/kernel.elf
