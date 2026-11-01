# riscv64: S-mode kernel under OpenSBI; the machine is described by the
# device tree (QEMU's virt machine by default).
# Included by the Makefile; see there for what this file defines.
#
# Two ways to boot it, chosen with BOOT=:
#   direct  (default) QEMU loads kernel.elf and OpenSBI jumps to it.
#   uefi    like a board: OpenSBI, then U-Boot in S-mode, whose EFI boot
#           manager runs the EFI loader from a FAT disk (QEMU's emulated
#           view of the $(ESP) directory), which loads kernel.elf.

CROSS ?= riscv64-unknown-elf-
OBJCOPY := $(CROSS)objcopy

ARCH_FLAGS := -march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany
LIBC_SPECS := --specs=picolibc.specs

ARCH_C_SRCS    := src/arch/riscv64/arch.c src/arch/riscv64/hal.c
ARCH_ASM_SRCS  := src/arch/riscv64/start.S
ARCH_RUBY_SRCS := kernel/arch/riscv64/sbi.rb kernel/arch/riscv64/platform.rb \
                  kernel/arch/riscv64/plic.rb kernel/arch/riscv64/arch.rb

# The EFI loader: a PE/COFF image, converted from a static ELF by objcopy.
# The firmware loads it anywhere and it has no relocations of its own, so
# all code is PC-relative (-mcmodel=medany) and nothing may need fixing
# up: no pointers in initialized data, no jump tables.
LOADER     := src/arch/riscv64/loader
EFI_CFLAGS := $(ARCH_FLAGS) -std=gnu11 -O2 -Wall -ffreestanding -fno-pic \
              -fno-stack-protector -fno-jump-tables -fshort-wchar

$(BUILD)/loader.elf: $(LOADER)/loader.c $(LOADER)/efi.h $(LOADER)/loader.ld
	@mkdir -p $(@D)
	$(CC) $(EFI_CFLAGS) -nostdlib -static -Wl,--build-id=none \
		-T $(LOADER)/loader.ld -o $@ $(LOADER)/loader.c

$(BUILD)/BOOTRISCV64.EFI: $(BUILD)/loader.elf
	$(OBJCOPY) --target=pei-riscv64-little --subsystem=efi-app -S \
		-j .text -j .rodata -j .data $< $@

# The EFI system partition: the loader where the firmware looks for one,
# and the kernel where the loader looks for it. Copy this directory onto
# a board's EFI system partition to boot it there.
ESP := $(BUILD)/esp

$(ESP)/EFI/BOOT/BOOTRISCV64.EFI: $(BUILD)/BOOTRISCV64.EFI
	@mkdir -p $(@D)
	cp $< $@

$(ESP)/kernel.elf: $(BUILD)/kernel.elf
	@mkdir -p $(@D)
	cp $< $@

BOOT_DEPS := $(ESP)/EFI/BOOT/BOOTRISCV64.EFI $(ESP)/kernel.elf

BOOT ?= direct
QEMU ?= qemu-system-riscv64

ifeq ($(BOOT),direct)
MEM  ?= 128M
QEMU_FLAGS := -machine virt -smp $(SMP) -m $(MEM) -nographic -bios default \
              -kernel $(BUILD)/kernel.elf
else ifeq ($(BOOT),uefi)
# OpenSBI's fw_jump starts the next stage, U-Boot, at 0x80200000; U-Boot
# moves itself out of the way to the top of RAM, so the kernel can be
# loaded there afterwards. U-Boot's QEMU environment uses addresses up to
# 0x8c000000, so it needs at least 256 MiB.
MEM     ?= 256M
OPENSBI ?= /usr/lib/riscv64-linux-gnu/opensbi/generic/fw_jump.bin
UBOOT   ?= /usr/lib/u-boot/qemu-riscv64_smode/u-boot.bin
QEMU_FLAGS := -machine virt -smp $(SMP) -m $(MEM) -nographic \
              -bios $(OPENSBI) -kernel $(UBOOT) \
              -drive file=fat:$(ESP),format=raw,if=none,id=esp,readonly=on \
              -device virtio-blk-device,drive=esp
else
$(error unknown BOOT "$(BOOT)": use direct or uefi)
endif
