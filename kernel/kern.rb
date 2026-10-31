# Kernel entry points called from C (src/main.c). Each runs with the big
# kernel lock held and must return; nothing here may block. Everything
# architecture specific goes through Arch (kernel/arch/<arch>/arch.rb).
module Kern
  class << self
    attr_reader :irqc

    def boot(hartid, boot_arg)
      Arch.init(boot_arg)
      @boot_time = Arch.time
      @uart = Arch.console_uart
      @uart.init
      Console.device = @uart

      puts "lazul: Ruby is running on hart #{hartid} (#{Arch.firmware}, mruby #{MRUBY_VERSION})"
      Arch.describe.each { |line| puts "  #{line}" }

      if (@irqc = Arch.interrupt_controller)
        @irqc.register(@uart.irq) { Console.receive }
      else
        puts "  warning: no supported interrupt controller; console input disabled"
      end

      Hart.add(hartid, :online)
      Hart.start_secondaries(Arch.harts)
      setup_interrupts(hartid)
      Console.on_line = Shell.method(:execute)
      Console.on_eof = -> { Shell.cmd_poweroff("") }
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
      @irqc.service(hartid) if @irqc && irq
    end

    def uptime_ms = (Arch.time - @boot_time) * 1000 / Arch.timebase_hz

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
