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
./dmake         # build build/kernel.elf (fetches and builds mruby first)
./dmake run     # boot it in QEMU
```

`./dmake` runs `make` inside the container with your user id, so files in
the tree stay owned by you. It passes its arguments to `make`.

At the `>` prompt, type `help` for the built-in commands; anything else
is evaluated as Ruby. `poweroff` shuts the machine down, or press Ctrl-A X
to quit QEMU.

QEMU runs with 4 harts and 128 MiB of RAM by default; change that with
`./dmake run SMP=8 MEM=256M`.

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

- `src/`: C and assembly core (boot, traps, the mruby VM, hardware access)
- `kernel/`: the kernel's Ruby code
- `build_config/`: mruby build configuration
- `test/`: console test
