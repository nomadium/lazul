# lazul

lazul is an experimental kernel written in C and [mruby](https://mruby.org):
a thin C core boots the machine and runs the mruby VM, and the rest of the
kernel (drivers, SMP bring-up, the console shell) is written in Ruby.

It runs in QEMU on two architectures:

- riscv64: the `virt` machine, in S-mode under OpenSBI, described by
  the device tree
- amd64: the `q35` machine, a PC, described by the ACPI tables

Each boots either directly from QEMU or through UEFI firmware and
lazul's EFI loader. Support for real hardware is planned.

## Requirements

Docker. The toolchain, QEMU and everything else needed to build and run
lazul live in a development image built from the `Dockerfile`.

## Building and running

```sh
make image      # build the development image (once)
./dmake         # build build/riscv64/kernel.elf (fetches and builds mruby first)
./dmake run     # boot it in QEMU
```

`./dmake` runs `make` inside the container with your user id, so files in
the tree stay owned by you. It passes its arguments to `make`.

At the `>` prompt, type `help` for the built-in commands; anything else
is evaluated as Ruby. `reboot` restarts the machine, and `poweroff` (or
Ctrl-D on an empty line) shuts it down; or press Ctrl-A X to quit QEMU.

QEMU runs with 4 harts and 128 MiB of RAM by default (512 MiB on amd64);
change that with `./dmake run SMP=8 MEM=256M`.

The architecture is chosen with `ARCH=`, `riscv64` (the default) or
`amd64`, e.g. `./dmake run ARCH=amd64`; each one builds into
`build/<arch>/`. On amd64 a hart is a CPU, and its id is the CPU's local
APIC id.

### Booting through UEFI

```sh
./dmake run BOOT=uefi   # firmware, the EFI loader, then the kernel
./dmake test BOOT=uefi  # the console test, booted that way
```

On riscv64, by default QEMU loads `kernel.elf` and OpenSBI jumps straight
to it. `BOOT=uefi` boots the way a board does: OpenSBI starts U-Boot in S-mode,
whose EFI boot manager finds `\EFI\BOOT\BOOTRISCV64.EFI` on a FAT disk
(QEMU's emulated view of `build/riscv64/esp/`). That is lazul's EFI loader
(`src/arch/riscv64/loader/`): it reads `\kernel.elf` from the same disk,
places it in the lowest free memory, wherever the board's RAM is, exits
boot services and jumps to the kernel with the boot hart id and the device
tree, as OpenSBI would. To boot a board with U-Boot, copy
`build/riscv64/esp/` onto its EFI system partition. QEMU gets 256 MiB of
RAM this way, as U-Boot needs it.

On amd64, by default QEMU loads `kernel.elf` itself, and its firmware
(SeaBIOS) enters it through the PVH boot protocol, in 32-bit mode;
`start.S` takes it to 64-bit long mode. `BOOT=uefi` boots it like a PC:
QEMU runs OVMF, the UEFI firmware, which finds `\EFI\BOOT\BOOTX64.EFI`
on a FAT disk (`build/amd64/esp/`), lazul's EFI loader for amd64. It
passes the kernel the ACPI tables and the memory map. To boot a PC with
it, copy `build/amd64/esp/` onto the EFI system partition of a USB stick.

The kernel is still linked at a fixed address (0x80200000 on riscv64,
1 MiB on amd64), with `--emit-relocs` so that `kernel.elf` keeps its
relocation records; the loader moves it by adding the distance to every
absolute address in it, and prints both addresses. To debug a kernel
that was moved, load its symbols at that distance in gdb: `symbol-file
-o <loaded - linked> build/<arch>/kernel.elf`.

## Debugging

```sh
./dmake debug   # terminal 1: QEMU starts with every hart stopped
./dmake gdb     # terminal 2: gdb attaches; "continue" boots the kernel
```

gdb sees each hart as a thread (`info threads`, `thread 2`). It debugs
the C and assembly code; Ruby code shows up as the mruby VM running it.

## Testing

```sh
./dmake test        # run unit tests, then boot in QEMU and drive the console
./dmake lint        # check Ruby style (Standard)
```

`test` takes `ARCH=`, `SMP=` and `BOOT=` too; CI runs it on both
architectures with 1, 4 and 8 harts, and booted through UEFI.

## Layout

- `src/`: portable C core (the mruby VM, the kernel lock, hardware access)
- `src/arch/<arch>/`: entry points, traps, CPU setup and the linker script
- `src/arch/<arch>/loader/`: the EFI loader
- `kernel/`: the kernel's portable Ruby code
- `kernel/arch/<arch>/`: Ruby code for the architecture and its devices
- `build_config/<arch>.rb`: mruby build configuration
- `build_config/picolibc-amd64.txt`: how the `Dockerfile` builds picolibc
  for amd64, which Debian does not package
- `test/`: console test, and host-side tests of the line editor and the
  device tree parser

## Adding an architecture

An architecture `<arch>` is a set of files, with no changes to the
portable code:

- `src/arch/<arch>/arch.mk`: toolchain, flags, sources and QEMU command
  line, and anything else QEMU needs to boot it, such as the EFI system
  partition (the Makefile lists what it defines)
- `src/arch/<arch>/start.S` and `kernel.ld`: entry points and memory layout
- `src/arch/<arch>/*.c`: the `arch_*` functions declared in `src/kernel.h`
- `kernel/arch/<arch>/arch.rb`: the `Arch` module used by the Ruby code,
  following `kernel/arch/riscv64/arch.rb` or `kernel/arch/amd64/arch.rb`
- `build_config/<arch>.rb`: how to cross-build mruby
- its toolchain, C library and QEMU in the `Dockerfile`, and its entry in
  the CI matrix (`.github/workflows/ci.yml`)
