# Kernel entry points called from C (src/main.c). Each runs with the big
# kernel lock held and must return; nothing here may block. Everything
# architecture specific goes through Arch (kernel/arch/<arch>/arch.rb).
module Kern
  class << self
    attr_reader :irqc

    def boot(hartid, boot_arg)
      @boot_time = Arch.time
      @uart = Arch.console_uart
      @uart.init
      Console.device = @uart

      puts "lazul: Ruby is running on hart #{hartid} (#{Arch.firmware}, mruby #{MRUBY_VERSION})"
      puts "  #{Arch.describe_boot_arg(boot_arg)}, heap 0x#{HEAP_START.to_s(16)}-0x#{HEAP_END.to_s(16)}"

      @irqc = Arch.interrupt_controller
      @irqc.register(@uart.irq) { Console.receive }

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

    # Called whenever a hart wakes up from its idle wait.
    def tick(hartid)
      ipi, irq = Arch.pending
      Hart[hartid].run_queue if ipi
      @irqc.service(hartid) if irq
    end

    def uptime_ms = (Arch.time - @boot_time) / (Arch.timebase_hz / 1000)

    private

    def announce_if_ready
      return unless Hart.all.all? { |h| h.state == :online }
      puts "#{Hart.all.size} hart(s) online; type 'help'"
      Console.prompt = "> "
      Console.show_prompt
    end

    def setup_interrupts(hartid) = Arch.enable_interrupts(hartid, @irqc, @uart.irq)
  end
end
