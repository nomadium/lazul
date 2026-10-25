# riscv64: S-mode kernel under OpenSBI, on QEMU's virt machine.
# Included by the Makefile; see there for what this file defines.

CROSS ?= riscv64-unknown-elf-

ARCH_FLAGS := -march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany
LIBC_SPECS := --specs=picolibc.specs

ARCH_C_SRCS    := src/arch/riscv64/arch.c src/arch/riscv64/hal.c
ARCH_ASM_SRCS  := src/arch/riscv64/start.S
ARCH_RUBY_SRCS := kernel/arch/riscv64/sbi.rb kernel/arch/riscv64/plic.rb \
                  kernel/arch/riscv64/arch.rb

QEMU ?= qemu-system-riscv64
MEM  ?= 128M

QEMU_FLAGS := -machine virt -smp $(SMP) -m $(MEM) -nographic -bios default \
              -kernel $(BUILD)/kernel.elf
