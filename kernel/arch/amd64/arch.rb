# amd64 side of the interface that the portable kernel code (Kern, Hart,
# Shell) uses for everything architecture specific; the riscv64 one is
# kernel/arch/riscv64/arch.rb.
#
# The kernel runs on a PC. There is no SBI here: the machine is described
# by the boot info and the ACPI tables (Platform), and the clock is the
# CPU's time stamp counter (TSC), timed against the ACPI PM timer.
#
# Hart ids are local APIC ids, the numbers the CPUs know themselves by.

# I/O port registers, with the same interface as MMIORegs (kernel/uart.rb).
class PortRegs
  attr_reader :base

  def initialize(base)
    @base = base
  end

  def read(reg) = Port.in8(@base + reg)
  def write(reg, v) = Port.out8(@base + reg, v)
end

module Arch
  PM_TIMER_HZ = 3_579_545

  # Shell commands that only make sense here; Shell sends them to Arch.
  SHELL_COMMANDS = {}.freeze

  class << self
    # What the boot info and the ACPI tables say about the machine.
    attr_reader :platform

    # First thing at boot, before any device is used. The boot argument is
    # the boot info's address. Read it and the ACPI tables, and find out
    # how fast the TSC runs.
    def init(boot_info)
      @platform = Platform.new(boot_info)
      @timebase = tsc_frequency
    end

    # The firmware, for the boot banner. QEMU's direct kernel boot does not
    # say which one ran.
    def firmware = "PVH boot"

    # The machine, for the boot banner: one line per item.
    def describe
      pf = @platform
      mib = pf.memory.sum { |_, size| size } >> 20
      u = pf.uart
      [
        "machine: #{pf.model}, boot info at #{hex(pf.boot_info)}",
        "ACPI: revision #{pf.acpi.revision}, root pointer at #{hex(pf.acpi.rsdp)}, #{pf.acpi.tables.size} tables",
        "free memory: #{ranges(pf.memory)} (#{mib} MiB)",
        "kernel heap: #{hex(Kern::HEAP_START)}-#{hex(Kern::HEAP_END)}",
        "harts: #{harts.join(", ")}; timebase #{@timebase} Hz (TSC)",
        "console: #{u.name} at #{(u.space == :port) ? "port" : "address"} #{hex(u.base)}, irq #{u.irq}",
        "interrupts: none supported"
      ]
    end

    # Only the boot CPU, so far.
    def harts = [CPU.hartid]

    # The serial console: the one the firmware describes (ACPI SPCR), or
    # COM1.
    def console_uart
      u = @platform.uart
      regs = (u.space == :port) ? PortRegs.new(u.base) : MMIORegs.new(u.base)
      uart = UART.new(regs, u.irq)
      raise "no UART at #{hex(u.base)} (#{u.name})" unless uart.present?
      uart
    end

    # No interrupt controller yet: Kern says that console input is off.
    def interrupt_controller = nil
    def enable_interrupts(_hartid, _irqc, _irq) = nil

    def start_hart(_id) = false

    # What woke this CPU: [ipi?, device interrupt pending?]. Nothing can,
    # yet.
    def pending = [false, nil]

    # The clock: a tick count, and ticks per second.
    def time = CPU.tsc
    def timebase_hz = @timebase

    def shutdown = raise(NotImplementedError, "no poweroff on amd64 yet")
    def reboot = raise(NotImplementedError, "no reboot on amd64 yet")

    private

    def hex(n) = "0x%x" % n

    def ranges(list) = list.map { |base, size| "#{hex(base)}-#{hex(base + size)}" }.join(", ")

    # TSC ticks per second: from CPUID leaf 0x15 when the CPU reports it,
    # else counted over 50 ms of the ACPI PM timer, else from CPUID leaf
    # 0x16 (the nominal frequency, in MHz).
    def tsc_frequency
      max_leaf = CPU.cpuid(0)[0]
      if max_leaf >= 0x15
        den, num, crystal, _ = CPU.cpuid(0x15)
        return crystal * num / den if den != 0 && num != 0 && crystal != 0
      end
      fadt = @platform.fadt
      if fadt && (port = fadt[:pm_timer]) != 0
        mask = fadt[:pm_timer_32bit] ? 0xffffffff : 0xffffff
        start = Port.in32(port) & mask
        t0 = CPU.tsc
        elapsed = 0
        elapsed = (Port.in32(port) - start) & mask while elapsed < PM_TIMER_HZ / 20
        return (CPU.tsc - t0) * PM_TIMER_HZ / elapsed
      end
      mhz = (max_leaf >= 0x16) ? CPU.cpuid(0x16)[0] : 0
      return mhz * 1_000_000 if mhz != 0
      raise "cannot find out the TSC frequency"
    end
  end
end
