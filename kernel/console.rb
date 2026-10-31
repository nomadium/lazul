# The system console: output, plus input through a LineEditor (echo, line
# editing, history) that hands complete lines to a consumer.
module Console
  CR = 0x0d
  LF = 0x0a

  @editor = LineEditor.new { |str| Console.write(str) }

  class << self
    attr_accessor :device, :on_line

    def prompt = @editor.prompt

    def prompt=(str)
      @editor.prompt = str
    end

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

    # Feed one byte to the line editor and run the line it completes, if
    # any.
    def input(c)
      case (result = @editor.feed(c))
      when String
        @on_line&.call(result)
        show_prompt
      when :interrupt
        show_prompt
      end
    end

    def show_prompt
      write(prompt) if prompt
    end

    # Print a message that is not a reply to the line being typed (output
    # from another hart, say) without mangling the prompt and pending input.
    def notify(msg)
      write("\r\e[K")
      puts msg
      show_prompt
      write(@editor.line)
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
