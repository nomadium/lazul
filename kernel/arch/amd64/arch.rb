# amd64 side of the interface that the portable kernel code (Kern, Hart,
# Shell) uses for everything architecture specific; the riscv64 one is
# kernel/arch/riscv64/arch.rb.
#
# The kernel runs on a PC. There is no SBI here: the machine is described
# by the boot info and the ACPI tables (Platform), device interrupts go
# through the I/O APICs to a CPU's local APIC (apic.rb), which also sends
# IPIs and starts the other CPUs (INIT-SIPI-SIPI), the clock is the CPU's
# time stamp counter (TSC), timed against the ACPI PM timer, and poweroff
# and reboot go through the EFI runtime services when the kernel was
# booted through UEFI, or ACPI's power management registers.
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
  EFI_RESET_COLD = 0
  EFI_RESET_SHUTDOWN = 2
  SLP_EN = 1 << 13        # PM1 control: enter the sleep state SLP_TYP
  RESET_CONTROL = 0xcf9   # PCI reset control register (an I/O port)
  KBC_COMMAND = 0x64      # the keyboard controller's command port

  # Shell commands that only make sense here; Shell sends them to Arch.
  SHELL_COMMANDS = {
    "acpi" => "acpi [SIG] - ACPI tables: the list, or one table's bytes"
  }.freeze

  class << self
    # What the boot info and the ACPI tables say about the machine.
    attr_reader :platform

    # First thing at boot, before any device is used. The boot argument is
    # the boot info's address. Read it and the ACPI tables, and find out
    # how fast the TSC runs.
    def init(boot_info)
      @platform = Platform.new(boot_info)
      @lapic = LAPIC.new
      @timebase = tsc_frequency
    end

    # The firmware, for the boot banner. QEMU's direct kernel boot does not
    # say which one ran.
    def firmware = (@platform.efi_system_table == 0) ? "PVH boot" : "UEFI #{firmware_vendor}"

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
        "interrupts: #{ioapics}; local APIC #{@lapic.x2apic? ? "in x2APIC mode" : "at #{hex(@lapic.base)}"}"
      ]
    end

    # Hart ids (APIC ids) of the CPUs that can run the kernel.
    def harts = @platform.harts

    # The serial console: the one the firmware describes (ACPI SPCR), or
    # COM1.
    def console_uart
      u = @platform.uart
      regs = (u.space == :port) ? PortRegs.new(u.base) : MMIORegs.new(u.base)
      uart = UART.new(regs, u.irq)
      raise "no UART at #{hex(u.base)} (#{u.name})" unless uart.present?
      uart
    end

    # The interrupt controller: an object with register(irq, &handler) and
    # service(hartid, pending), which calls the handlers of the interrupts
    # pending on this CPU (pending is what Arch.pending reported).
    def interrupt_controller = IRQRouter.new(@platform, @lapic)

    # Enable what wakes this CPU from its idle wait: device interrupts
    # arrive through its local APIC. irqc routes them to the CPU that
    # registers them, the boot CPU.
    def enable_interrupts(_hartid, _irqc, _irq) = @lapic.enable

    # Wake CPU id with INIT-SIPI-SIPI, the sequence from Intel's
    # MultiProcessor Specification: INIT resets it, and it then waits for a
    # STARTUP IPI, which says at which page below 1 MiB to start; a second
    # one covers a CPU that missed the first. It runs the real-mode
    # trampoline that SMP.prepare set up there, enters long mode, comes up
    # in C (ap_entry) on the stack of the area it was given and calls
    # Kern.hart_started. Returns false if there is no such CPU or it does
    # not start.
    def start_hart(id)
      return false unless @platform.harts.include?(id)
      raise "no page below 1 MiB for starting CPUs" if @platform.trampoline == 0
      page_number = SMP.prepare(id, @platform.trampoline, Kern.alloc_hart_area)
      @lapic.send_init(id)
      delay_us(10_000)
      2.times do
        @lapic.send_startup(id, page_number)
        return true if wait_us(1_000) { SMP.ready?(id) }
      end
      return true if wait_us(100_000) { SMP.ready?(id) }
      puts "  hart #{id}: did not start"
      false
    end

    # The hart id is the APIC id.
    def send_ipi(id) = @lapic.send_ipi(id, Kern::IPI_VECTOR)

    # What woke this CPU: [ipi?, the other pending vectors as bits, or nil].
    def pending
      bits = CPU.take_pending
      ipi_bit = 1 << (Kern::IPI_VECTOR - Kern::IRQ_VECTOR_BASE)
      irqs = bits & ~ipi_bit
      [bits & ipi_bit != 0, (irqs == 0) ? nil : irqs]
    end

    # The clock: a tick count, and ticks per second.
    def time = CPU.tsc
    def timebase_hz = @timebase

    # EFI ResetSystem; failing that, ACPI S5, "soft off": the sleep type
    # for S5 and the enable bit, written to the PM1a control port.
    def shutdown
      EFI.reset_system(@platform.runtime_services, EFI_RESET_SHUTDOWN)
      fadt = @platform.fadt
      slp_typ = @platform.acpi.s5_sleep_type
      Port.out16(fadt[:pm1a_control], (slp_typ << 10) | SLP_EN) if fadt && slp_typ
      raise "poweroff failed"
    end

    # EFI ResetSystem; failing that, the ACPI reset register, then the
    # traditional PC ways: a full reset through the reset control register
    # (0xcf9), and a CPU reset through the keyboard controller.
    def reboot
      EFI.reset_system(@platform.runtime_services, EFI_RESET_COLD)
      fadt = @platform.fadt
      if fadt && fadt[:reset_reg]
        space, addr = fadt[:reset_reg]
        if space == 1
          Port.out8(addr, fadt[:reset_value])
        elsif space == 0
          Memory[addr] = fadt[:reset_value]
        end
      end
      Port.out8(RESET_CONTROL, 0x06)   # full reset (bit 3 clear), reset CPU
      Port.out8(KBC_COMMAND, 0xfe)     # pulse the CPU reset line
      raise "reboot failed"
    end

    def cmd_acpi(sig)
      if sig.empty?
        @platform.acpi.tables.each do |t|
          puts "  #{t.signature}  #{hex(t.addr)}  #{t.data.bytesize.to_s.rjust(6)} bytes  rev #{t.revision}  #{t.oem_id} #{t.oem_table_id}"
        end
        return
      end
      t = @platform.acpi[sig] or return puts("no such table: #{sig}")
      hexdump(t.addr, t.data)
    end

    private

    def hex(n) = "0x%x" % n

    def ranges(list) = list.map { |base, size| "#{hex(base)}-#{hex(base + size)}" }.join(", ")

    def ioapics
      @platform.madt.ioapics.map { |io| "I/O APIC at #{hex(io.address)}" }.join(", ")
    end

    # 16 bytes a line: address, bytes in hex, and the printable ones.
    def delay_us(us)
      t = CPU.tsc + us * @timebase / 1_000_000
      nil while CPU.tsc < t
    end

    # Poll until the block is true or us microseconds have passed.
    def wait_us(us)
      t = CPU.tsc + us * @timebase / 1_000_000
      until yield
        return false if CPU.tsc > t
      end
      true
    end

    # The firmware vendor string (UTF-16) from the EFI system table, which
    # lives in runtime memory and so is still there.
    def firmware_vendor
      ptr = Memory.read64(@platform.efi_system_table + 24)
      return "" if ptr == 0
      s = +""
      64.times do |i|
        c = Memory.read16(ptr + 2 * i)
        break if c == 0
        s << ((c < 0x80) ? c.chr : "?")
      end
      s
    end

    def hexdump(addr, data)
      (data.bytesize + 15).div(16).times do |i|
        bytes = data.byteslice(16 * i, 16).bytes
        text = bytes.map { |b| (b >= 0x20 && b < 0x7f) ? b.chr : "." }.join
        puts "  %08x  %-47s  %s" % [addr + 16 * i, bytes.map { |b| "%02x" % b }.join(" "), text]
      end
    end

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
