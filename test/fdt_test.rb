#!/usr/bin/env ruby
# Host-side test of the device tree parser (kernel/fdt.rb) under CRuby,
# against device trees dumped from QEMU (qemu-system-riscv64 dumpdtb=).
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
load File.join(ROOT, "kernel/fdt.rb")

@failures = 0  # failed checks, counted by check()

def check(name, actual, expected)
  ok = actual == expected
  puts "#{ok ? "ok  " : "FAIL"} #{name}#{": expected #{expected.inspect}, got #{actual.inspect}" unless ok}"
  @failures += 1 unless ok
end

def raises(name, error)
  yield
  check name, "no exception", error
rescue error
  check name, true, true
end

# Have QEMU write the device tree of a machine to dir and parse it.
def dump_dtb(dir, name, machine, *args)
  path = File.join(dir, "#{name}.dtb")
  system("qemu-system-riscv64", "-machine", "#{machine},dumpdtb=#{path}", *args,
    "-nographic", out: File::NULL, err: File::NULL) or raise "qemu dumpdtb failed for #{name}"
  FDT.new(File.binread(path))
end

Dir.mktmpdir do |dir|
  # QEMU virt, 4 harts, 128 MiB: the machine the kernel boots on today.
  fdt = dump_dtb(dir, "virt4", "virt", "-smp", "4", "-m", "128M")
  check "root", fdt.root.path, "/"
  check "boot cpu id from the header", fdt.boot_cpuid, 0
  check "no memreserve entries", fdt.memreserve, []
  check "string property", fdt.root.string("model"), "riscv-virtio,qemu"
  check "u32 property", fdt.find("/cpus").u32("timebase-frequency"), 10_000_000
  check "missing property", fdt.find("/cpus").u32("nope"), nil

  # reg is decoded with the parent's #address-cells and #size-cells.
  check "reg, 2+2 cells", fdt.find("/memory@80000000").reg, [[0x8000_0000, 128 << 20]]
  check "reg, 1+0 cells", fdt.find("/cpus/cpu@2").reg, [[2, 0]]
  check "address cells", fdt.find("/cpus").address_cells, 1
  check "size cells", fdt.find("/cpus").size_cells, 0

  check "find by path", fdt.find("/cpus/cpu@2")&.path, "/cpus/cpu@2"
  check "find without unit address", fdt.find("/soc/serial")&.path, "/soc/serial@10000000"
  check "missing node", fdt.find("/nope"), nil
  check "node names", fdt.find("/soc/serial").base_name, "serial"
  check "unit address", fdt.find("/soc/serial").unit_address, "10000000"
  check "parent", fdt.find("/cpus/cpu@0").parent.path, "/cpus"

  plic = fdt.find("/soc/plic")
  check "string list", plic&.strings("compatible"), ["sifive,plic-1.0.0", "riscv,plic0"]
  check "compatible?", plic.compatible?("riscv,plic0"), true
  check "phandle lookup", fdt.phandle(plic.phandle), plic
  check "compatible search", fdt.compatible("ns16550a").map(&:path), ["/soc/serial@10000000"]
  check "cells", plic.cells("interrupts-extended").size, 4 * 4
  check "children", fdt.find("/cpus").children.count { |n| n.string("device_type") == "cpu" }, 4
  paths = []
  fdt.each_node { |n| paths << n.path }
  check "each_node walks the whole tree", [paths.first, paths.include?("/soc/serial@10000000")], ["/", true]

  # 2 GiB of memory needs both size cells.
  big = dump_dtb(dir, "virt8", "virt", "-smp", "8", "-m", "2G")
  check "reg, 64-bit size", big.find("/memory").reg, [[0x8000_0000, 2 << 30]]
  check "8 cpus", big.find("/cpus").children.count { |n| n.string("device_type") == "cpu" }, 8

  # Aliases: both machines have /aliases with serial0.
  check "alias lookup (virt)", fdt.find("serial0")&.path, "/soc/serial@10000000"
  su = dump_dtb(dir, "sifive_u", "sifive_u", "-smp", "5")
  check "alias lookup", su.find("serial0")&.path, "/soc/serial@10010000"
  check "alias with a subpath", su.find("serial0/nope"), nil
  check "unknown alias", su.find("nope0"), nil

  # Bad input is reported, not misparsed.
  blob = File.binread(File.join(dir, "virt4.dtb"))
  raises("bad magic", FDT::Error) { FDT.new("\0" * 64) }
  old = blob.dup
  old[20, 4] = [16].pack("N")
  raises("old version", FDT::Error) { FDT.new(old) }
end

puts @failures.zero? ? "all fdt tests passed" : "#{@failures} fdt failure(s)"
exit(@failures.zero? ? 0 : 1)
