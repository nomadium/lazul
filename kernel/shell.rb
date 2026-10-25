# Console shell. A few built-in commands; anything else is evaluated as Ruby.
module Shell
  COMMANDS = {
    "help"     => "show this help",
    "echo"     => "echo TEXT - print TEXT back",
    "harts"    => "list harts",
    "on"       => "on N EXPR - evaluate Ruby EXPR on hart N",
    "uptime"   => "seconds since boot",
    "poweroff" => "shut the machine down"
  }

  class << self
    attr_writer :binding

    def execute(line)
      cmd, rest = line.strip.split(" ", 2)
      return if cmd.nil?
      if COMMANDS.key?(cmd)
        send("cmd_#{cmd}", rest.to_s)
      else
        evaluate(line)
      end
    rescue Exception => e
      puts error_text(e)
    end

    # "Class: message", then where in the kernel it was raised.  Not for
    # errors raised by the typed line itself: its frame is just "(eval):1".
    def error_text(e)
      where = e.backtrace&.first
      where = nil if where&.start_with?("(eval)")
      text = "#{e.class}: #{e.message}"
      where ? "#{text}\n  from #{where}" : text
    end

    def evaluate(src)
      puts "=> #{@binding.eval(src).inspect}"
    end

    def cmd_help(_)
      COMMANDS.each { |c, d| puts "  %-9s %s" % [c, d] }
      puts "  anything else is evaluated as Ruby (try: Hart.all, Memory.read32(0x1000))"
    end

    def cmd_echo(text) = puts(text)

    def cmd_harts(_)
      Hart.all.each do |h|
        puts "  hart #{h.id}: #{h.state}#{" (this one)" if h == Hart.current}"
      end
    end

    def cmd_on(args)
      n, expr = args.split(" ", 2)
      hart = Hart[n.to_i] if n && !n.empty? && n.each_char.all? { |c| c.between?("0", "9") }
      return puts("no such hart: #{n}") unless hart && hart.state == :online
      return puts("usage: on N EXPR") unless expr
      hart.run do
        result = begin
          "=> #{eval(expr).inspect}"
        rescue Exception => e
          error_text(e)
        end
        Console.notify("[hart #{CPU.hartid}] #{result}")
      end
    end

    def cmd_uptime(_) = puts("%d.%03d s" % Kern.uptime_ms.divmod(1000))

    def cmd_poweroff(_)
      puts "powering off"
      Arch.shutdown
    end
  end
end

# REPL input is evaluated at top level, with local variables kept across lines.
Shell.binding = binding
