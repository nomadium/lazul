# Kernel entry points called from C (src/main.c). Each runs with the big
# kernel lock held and must return; nothing here may block.
module Kern
  SIP_SSIP = 1 << 1    # supervisor software interrupt (IPI)
  SIP_SEIP = 1 << 9    # supervisor external interrupt (PLIC)
  TIMEBASE_HZ = 10_000_000

  # QEMU virt machine. (To be discovered from the device tree eventually.)
  UART0_BASE = 0x1000_0000
  UART0_IRQ = 10
  PLIC_BASE = 0x0c00_0000

  class << self
    attr_reader :plic

    def boot(hartid, dtb)
      @boot_time = CPU.csr(:time)
      uart = UART.new(UART0_BASE, UART0_IRQ)
      uart.init
      Console.device = uart

      puts "lazul: Ruby is running on hart #{hartid} (SBI #{SBI.spec_version}, mruby #{MRUBY_VERSION})"
      puts "  device tree at 0x#{dtb.to_s(16)}, heap 0x#{HEAP_START.to_s(16)}-0x#{HEAP_END.to_s(16)}"

      @plic = PLIC.new(PLIC_BASE)
      @plic.register(uart.irq) { Console.receive }

      Hart.add(hartid, :online)
      Hart.start_secondaries
      setup_interrupts(hartid)
      Console.on_line = Shell.method(:execute)
      announce_if_ready
    end

    def hart_started(hartid)
      hart = Hart[hartid] || Hart.add(hartid, :starting)
      hart.state = :online
      setup_interrupts(hartid)
      Console.notify("hart #{hartid} online")
      announce_if_ready
    end

    # Called whenever a hart wakes up from wfi.
    def tick(hartid)
      pending = CPU.csr(:sip)
      if pending & SIP_SSIP != 0
        CPU.csr_clear(:sip, SIP_SSIP)
        Hart[hartid].run_queue
      end
      @plic.service(hartid) if pending & SIP_SEIP != 0
    end

    def uptime_ms = (CPU.csr(:time) - @boot_time) / (TIMEBASE_HZ / 1000)

    private

    def announce_if_ready
      return unless Hart.all.all? { |h| h.state == :online }
      puts "#{Hart.all.size} hart(s) online; type 'help'"
      Console.prompt = "> "
      Console.show_prompt
    end

    def setup_interrupts(hartid)
      @plic.threshold(hartid, 0)
      @plic.enable(UART0_IRQ, hartid)
      CPU.csr_set(:sie, SIP_SSIP | SIP_SEIP)
    end
  end
end
