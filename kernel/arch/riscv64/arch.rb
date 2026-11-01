# riscv64 side of the interface that the portable kernel code (Kern, Hart,
# Shell) uses for everything architecture specific: the console UART and
# interrupt controller, interrupts, starting harts and IPIs, the clock and
# power. Another architecture provides the same methods in its own
# kernel/arch/<arch>/arch.rb.
#
# The kernel runs in S-mode under SBI firmware. What the machine has (RAM,
# harts, timebase, console UART, PLIC) comes from the device tree the
# firmware passes in, through Platform.
module Arch
  SIP_SSIP = 1 << 1    # supervisor software interrupt (IPI)
  SIP_SEIP = 1 << 9    # supervisor external interrupt (PLIC)

  # Shell commands that only make sense here; Shell sends them to Arch.
  SHELL_COMMANDS = {
    "dt" => "dt [PATH] - device tree: node list, or one node's properties"
  }

  class << self
    # The device tree the firmware passed in (an FDT), and what it says
    # about the machine (a Platform).
    attr_reader :fdt, :platform

    # First thing at boot, before any device is used. The boot argument is
    # the device tree address.
    def init(dtb)
      @dtb = dtb
      @fdt = FDT.from_memory(dtb)
      @platform = Platform.new(@fdt)
      raise "no timebase-frequency in the device tree" unless @platform.timebase
    end

    # The firmware, for the boot banner.
    def firmware = "SBI #{SBI.spec_version}"

    # The machine, for the boot banner: one line per item.
    def describe
      pf = @platform
      mib = pf.memory.sum { |_, size| size } >> 20
      [
        "machine: #{pf.model}, device tree at #{hex(@dtb)}",
        "memory: #{ranges(pf.memory)} (#{mib} MiB)",
        "reserved: #{pf.reserved.empty? ? "none" : ranges(pf.reserved)}",
        "kernel heap: #{hex(Kern::HEAP_START)}-#{hex(Kern::HEAP_END)}",
        "harts: #{pf.harts.join(", ")}; timebase #{pf.timebase} Hz",
        "console: #{pf.uart.node.path} at #{hex(pf.uart.base)}, irq #{pf.uart.irq}",
        "interrupts: #{pf.plic ? "PLIC at #{hex(pf.plic.base)}" : "none supported"}"
      ]
    end

    # Hart ids that can run the kernel.
    def harts = @platform.harts

    def console_uart
      u = @platform.uart or raise "no supported console UART in the device tree"
      UART.new(u.base, u.irq, reg_shift: u.reg_shift, io_width: u.reg_io_width)
    end

    # The interrupt controller, or nil if there is none we support: an
    # object with register(irq, &handler) and service(hartid), which calls
    # the handlers of pending interrupts.
    def interrupt_controller
      PLIC.new(@platform.plic.base, @platform.plic.contexts) if @platform.plic
    end

    # Route irq to this hart (if there is an interrupt controller) and enable
    # what wakes it from its idle wait: IPIs and device interrupts.
    def enable_interrupts(hartid, irqc, irq)
      sie = SIP_SSIP
      if irqc
        irqc.threshold(hartid, 0)
        irqc.enable(irq, hartid)
        sie |= SIP_SEIP
      end
      CPU.csr_set(:sie, sie)
    end

    # Start hart id if the firmware has it stopped. It comes up in C at
    # _secondary_start, on the stack of the area passed as the opaque
    # value, and calls Kern.hart_started. Returns false if there is no such
    # hart.
    def start_hart(id)
      status = SBI.hart_status(id)
      return false unless status
      if status == SBI::HART_STOPPED
        SBI.hart_start(id, Kern::SECONDARY_ENTRY, Kern.alloc_hart_area)
      end
      true
    end

    def send_ipi(id) = SBI.send_ipi([id])

    # What woke this hart: [ipi?, device interrupt pending?]. Acknowledges
    # the IPI.
    def pending
      sip = CPU.csr(:sip)
      ipi = sip & SIP_SSIP != 0
      CPU.csr_clear(:sip, SIP_SSIP) if ipi
      [ipi, sip & SIP_SEIP != 0]
    end

    # The clock: a tick count, and ticks per second.
    def time = CPU.csr(:time)
    def timebase_hz = @platform.timebase

    def shutdown = SBI.shutdown
    def reboot = SBI.reboot

    def cmd_dt(path)
      if path.empty?
        @fdt.each_node do |n|
          depth = (n.path == "/") ? 0 : n.path.count("/")
          puts "#{"  " * depth}#{n.parent ? n.name : "/"}"
        end
        return
      end
      node = @fdt.find(path)
      return puts("no such node: #{path}") unless node
      puts "#{node.path} {"
      node.props.each do |name, value|
        puts value.empty? ? "  #{name};" : "  #{name} = #{format_prop(value)};"
      end
      node.children.each { |c| puts "  #{c.name} { ... };" }
      puts "};"
    end

    private

    def hex(n) = "0x%x" % n

    def ranges(list) = list.map { |base, size| "#{hex(base)}-#{hex(base + size)}" }.join(", ")

    # Show a property value the way dtc would guess: strings, cells or bytes.
    def format_prop(v)
      text = v.getbyte(v.bytesize - 1) == 0 && v.getbyte(0) != 0 && !v.include?("\0\0") &&
        v.each_byte.all? { |b| b == 0 || (b >= 0x20 && b < 0x7f) }
      if text
        v.byteslice(0, v.bytesize - 1).split("\0").map(&:inspect).join(", ")
      elsif v.bytesize % 4 == 0
        "<" + v.unpack("N*").map { |c| "0x%x" % c }.join(" ") + ">"
      else
        "[" + v.unpack("C*").map { |b| "%02x" % b }.join(" ") + "]"
      end
    end
  end
end
