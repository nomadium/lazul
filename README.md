# lazul

lazul is an experimental kernel written in C and [mruby](https://mruby.org):
a thin C core boots the machine and runs the mruby VM, and the rest of the
kernel (drivers, SMP bring-up, the console shell) is written in Ruby.

It currently runs on riscv64 (QEMU `virt` machine, S-mode under OpenSBI).
Support for real hardware and amd64 is planned.

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
is evaluated as Ruby. `poweroff` shuts the machine down, or press Ctrl-A X
to quit QEMU.

QEMU runs with 4 harts and 128 MiB of RAM by default; change that with
`./dmake run SMP=8 MEM=256M`.

The architecture is chosen with `ARCH=` (default and, for now, only
`riscv64`); each one builds into `build/<arch>/`.

## Debugging

```sh
./dmake debug   # terminal 1: QEMU starts with every hart stopped
./dmake gdb     # terminal 2: gdb attaches; "continue" boots the kernel
```

gdb sees each hart as a thread (`info threads`, `thread 2`). It debugs
the C and assembly code; Ruby code shows up as the mruby VM running it.

## Testing

```sh
./dmake test        # boot in QEMU and drive the console
./dmake lint        # check Ruby style (Standard)
```

## Layout

- `src/`: portable C core (the mruby VM, the kernel lock, hardware access)
- `src/arch/<arch>/`: entry points, traps, CPU setup and the linker script
- `kernel/`: the kernel's portable Ruby code
- `kernel/arch/<arch>/`: Ruby code for the architecture and its devices
- `build_config/<arch>.rb`: mruby build configuration
- `test/`: console test

## Adding an architecture

An architecture `<arch>` is a set of files, with no changes to the
portable code:

- `src/arch/<arch>/arch.mk`: toolchain, flags, sources and QEMU command
  line (the Makefile lists what it must define)
- `src/arch/<arch>/start.S` and `kernel.ld`: entry points and memory layout
- `src/arch/<arch>/*.c`: the `arch_*` functions declared in `src/kernel.h`
- `kernel/arch/<arch>/arch.rb`: the `Arch` module used by the Ruby code,
  following `kernel/arch/riscv64/arch.rb`
- `build_config/<arch>.rb`: how to cross-build mruby
- its toolchain and QEMU in the `Dockerfile`
