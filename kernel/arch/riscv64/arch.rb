# riscv64 side of the interface that the portable kernel code (Kern, Hart,
# Shell) uses for everything architecture specific: the console UART and
# interrupt controller, interrupts, starting harts and IPIs, the clock and
# power. Another architecture provides the same methods in its own
# kernel/arch/<arch>/arch.rb.
#
# The kernel runs in S-mode under SBI firmware, on QEMU's virt machine.
module Arch
  SIP_SSIP = 1 << 1    # supervisor software interrupt (IPI)
  SIP_SEIP = 1 << 9    # supervisor external interrupt (PLIC)
  TIMEBASE_HZ = 10_000_000

  # QEMU virt machine. (To be discovered from the device tree eventually.)
  UART0_BASE = 0x1000_0000
  UART0_IRQ = 10
  PLIC_BASE = 0x0c00_0000

  # Shell commands that only make sense here; Shell sends them to Arch.
  SHELL_COMMANDS = {
    "dt" => "dt [PATH] - device tree: node list, or one node's properties"
  }

  class << self
    # The device tree the firmware passed in (an FDT).
    attr_reader :fdt

    # First thing at boot, before any device is used. The boot argument is
    # the device tree address.
    def init(dtb)
      @fdt = FDT.from_memory(dtb)
    end

    # The firmware, for the boot banner.
    def firmware = "SBI #{SBI.spec_version}"

    # What the boot argument passed to Kern.boot is, for the boot banner.
    def describe_boot_arg(dtb) = "device tree at 0x#{dtb.to_s(16)}"

    def console_uart = UART.new(UART0_BASE, UART0_IRQ)

    # The interrupt controller: an object with register(irq, &handler) and
    # service(hartid), which calls the handlers of pending interrupts.
    def interrupt_controller = PLIC.new(PLIC_BASE)

    # Route irq to this hart and enable what wakes it from its idle wait:
    # IPIs and device interrupts.
    def enable_interrupts(hartid, irqc, irq)
      irqc.threshold(hartid, 0)
      irqc.enable(irq, hartid)
      CPU.csr_set(:sie, SIP_SSIP | SIP_SEIP)
    end

    # Start hart id if the firmware has it stopped. It comes up in C at
    # _secondary_start and calls Kern.hart_started. Returns false if there
    # is no such hart.
    def start_hart(id)
      status = SBI.hart_status(id)
      return false unless status
      SBI.hart_start(id, Kern::SECONDARY_ENTRY) if status == SBI::HART_STOPPED
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
    def timebase_hz = TIMEBASE_HZ

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
