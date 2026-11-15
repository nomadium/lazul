# amd64: long mode kernel on a PC; the machine is described by the ACPI
# tables (QEMU's q35 machine by default).
# Included by the Makefile; see there for what this file defines.
#
# Two ways to boot it, chosen with BOOT=:
#   direct  (default) QEMU loads kernel.elf, and its firmware (SeaBIOS)
#           enters it through the PVH boot protocol (see start.S).
#   uefi    like a PC: the UEFI firmware (OVMF) runs the EFI loader from a
#           FAT disk (QEMU's emulated view of the $(ESP) directory), which
#           loads kernel.elf.

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
# --emit-relocs keeps the relocation records in kernel.elf, so that the
# EFI loader can move the kernel to wherever the firmware has free memory
# (see loader.c).
ARCH_LDFLAGS := -no-pie -static -Wl,-z,noexecstack \
                -Wl,-z,max-page-size=4096 -Wl,--build-id=none \
                -Wl,--emit-relocs

ARCH_C_SRCS    := src/arch/amd64/arch.c src/arch/amd64/boot.c \
                  src/arch/amd64/irq.c src/arch/amd64/hal.c
ARCH_ASM_SRCS  := src/arch/amd64/start.S src/arch/amd64/vectors.S \
                  src/arch/amd64/trampoline.S
ARCH_RUBY_SRCS := kernel/arch/amd64/acpi.rb kernel/arch/amd64/platform.rb \
                  kernel/arch/amd64/apic.rb kernel/arch/amd64/arch.rb

# Interrupt context: see src/arch/amd64/irq.c.
CFLAGS_irq := -mgeneral-regs-only

# The EFI loader: a PE/COFF image, converted from a static ELF by objcopy.
# The firmware loads it anywhere and it has no relocations of its own, so
# all code is RIP-relative (-fpie) and nothing may need fixing up: no
# pointers in initialized data, no jump tables.
LOADER     := src/arch/amd64/loader
EFI_CFLAGS := -std=gnu11 -O2 -Wall -ffreestanding -fpie -mno-red-zone \
              -fno-stack-protector -U_FORTIFY_SOURCE -fcf-protection=none \
              -fno-jump-tables -fshort-wchar

$(BUILD)/loader.elf: $(LOADER)/loader.c $(LOADER)/efi.h $(LOADER)/loader.ld \
                     src/arch/amd64/bootinfo.h $(BUILD_FILES)
	@mkdir -p $(@D)
	$(CC) $(EFI_CFLAGS) -nostdlib -static -Wl,--build-id=none \
		-T $(LOADER)/loader.ld -o $@ $(LOADER)/loader.c

$(BUILD)/BOOTX64.EFI: $(BUILD)/loader.elf $(BUILD_FILES)
	$(OBJCOPY) --target=pei-x86-64 --subsystem=efi-app -S \
		-j .text -j .rodata -j .data -j .reloc $< $@

# The EFI system partition: the loader where the firmware looks for one,
# and the kernel where the loader looks for it. Copy this directory onto
# a PC's EFI system partition (e.g. a USB stick) to boot it there.
ESP := $(BUILD)/esp

$(ESP)/EFI/BOOT/BOOTX64.EFI: $(BUILD)/BOOTX64.EFI
	@mkdir -p $(@D)
	cp $< $@

# Without debug information, which the loader does not need and which
# --emit-relocs makes several times larger than the kernel.
$(ESP)/kernel.elf: $(BUILD)/kernel.elf $(BUILD_FILES)
	@mkdir -p $(@D)
	$(OBJCOPY) --strip-debug $< $@

BOOT_DEPS := $(ESP)/EFI/BOOT/BOOTX64.EFI $(ESP)/kernel.elf

BOOT ?= direct
QEMU ?= qemu-system-x86_64
MEM  ?= 512M

ifeq ($(BOOT),direct)
QEMU_FLAGS := -machine q35 -smp $(SMP) -m $(MEM) -nographic -nic none \
              -kernel $(BUILD)/kernel.elf
else ifeq ($(BOOT),uefi)
OVMF ?= /usr/share/ovmf/OVMF.fd
QEMU_FLAGS := -machine q35 -smp $(SMP) -m $(MEM) -nographic -nic none \
              -bios $(OVMF) \
              -drive file=fat:$(ESP),format=raw,if=none,id=esp,readonly=on \
              -device virtio-blk-pci,drive=esp
else
$(error unknown BOOT "$(BOOT)": use direct or uefi)
endif
