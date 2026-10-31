# Line editing for the console: bytes from the terminal go in, screen output
# and completed lines come out. Supports backspace and Ctrl-U.
#
# Kept to the Ruby subset shared by mruby and CRuby so it can be tested on
# the host (test/console/line_editor_test.rb).
module Console
  class LineEditor
    BS     = 0x08
    DEL    = 0x7f
    CR     = 0x0d
    LF     = 0x0a
    CTRL_C = 0x03
    CTRL_U = 0x15

    attr_reader :line

    # The block receives everything to be written to the terminal.
    def initialize(&output)
      @output = output
      @line = ""
    end

    # Feeds one input byte. Returns a completed line (String), :interrupt
    # (Ctrl-C), or nil.
    def feed(c)
      case c
      when CR, LF
        write("\n")
        line, @line = @line, ""
        line
      when BS, DEL
        unless @line.empty?
          @line = @line.byteslice(0, @line.bytesize - 1)
          write("\b \b")
        end
        nil
      when CTRL_U
        write("\b \b" * @line.size)
        @line = ""
        nil
      when CTRL_C
        write("^C\n")
        @line = ""
        :interrupt
      else
        if c >= 0x20 && c < 0x7f
          @line << c.chr
          write(c.chr)
        end
        nil
      end
    end

    private

    def write(str)
      @output.call(str)
    end
  end
end
