# The system console: output, plus a line discipline for input (echo,
# backspace, line editing) that hands complete lines to a consumer.
module Console
  BS = 0x08
  DEL = 0x7f
  CR = 0x0d
  LF = 0x0a
  CTRL_C = 0x03
  CTRL_U = 0x15

  @line = ""

  class << self
    attr_accessor :device, :on_line, :prompt

    def write(str)
      return 0 unless @device
      str.each_byte do |b|
        @device.putc(CR) if b == LF
        @device.putc(b)
      end
      str.bytesize
    end

    # Drain the device's receive FIFO, echoing as we go.
    def receive
      while (c = @device.getc)
        input(c)
      end
    end

    def input(c)
      case c
      when CR, LF
        write("\n")
        line, @line = @line, ""
        @on_line&.call(line)
        show_prompt
      when BS, DEL
        unless @line.empty?
          @line = @line.byteslice(0, @line.bytesize - 1)
          write("\b \b")
        end
      when CTRL_U
        write("\b \b" * @line.size)
        @line = ""
      when CTRL_C
        write("^C\n")
        @line = ""
        show_prompt
      else
        if c >= 0x20 && c < 0x7f
          @line << c.chr
          write(c.chr)
        end
      end
    end

    def show_prompt
      write(@prompt) if @prompt
    end

    # Print a message that is not a reply to the line being typed (output
    # from another hart, say) without mangling the prompt and pending input.
    def notify(msg)
      write("\r\e[K")
      puts msg
      show_prompt
      write(@line)
    end
  end
end

module Kernel
  def print(*args)
    args.each { |a| Console.write(a.to_s) }
    nil
  end

  def puts(*args)
    return Console.write("\n") && nil if args.empty?
    args.each do |a|
      if a.is_a?(Array)
        a.flatten.each { |e| puts(e) }
      else
        s = a.nil? ? "" : a.to_s
        Console.write(s)
        Console.write("\n") unless s.end_with?("\n")
      end
    end
    nil
  end

  def p(*args)
    args.each { |a| Console.write(a.inspect + "\n") }
    (args.size <= 1) ? args.first : args
  end
end
