# Line editing for the console: bytes from the terminal go in, screen output
# and completed lines come out. Supports backspace, Ctrl-U, Ctrl-D (end of
# input on an empty line) and history (Up/Down).
#
# Kept to the Ruby subset shared by mruby and CRuby so it can be tested on
# the host (test/console/line_editor_test.rb).
module Console
  class LineEditor
    BS     = 0x08
    DEL    = 0x7f
    CR     = 0x0d
    LF     = 0x0a
    ESC    = 0x1b
    CTRL_C = 0x03
    CTRL_D = 0x04
    CTRL_U = 0x15

    HISTORY_SIZE = 200

    attr_accessor :prompt
    attr_reader :line, :history

    # The block receives everything to be written to the terminal.
    def initialize(&output)
      @output   = output
      @line     = ""
      @history  = []
      @hist_pos = nil     # index into @history while browsing, nil otherwise
      @saved    = nil     # the line being typed before browsing started
      @esc      = nil     # escape sequence state: nil, :esc or :csi
    end

    # Feeds one input byte. Returns a completed line (String), :eof (Ctrl-D
    # on an empty line), :interrupt (Ctrl-C), or nil.
    def feed(c)
      return escape(c) if @esc

      case c
      when CR, LF
        write("\n")
        line, @line = @line, ""
        add_history(line)
        @hist_pos = nil
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
      when CTRL_D
        :eof if @line.empty?
      when CTRL_C
        write("^C\n")
        @line = ""
        @hist_pos = nil
        :interrupt
      when ESC
        @esc = :esc
        nil
      else
        if c >= 0x20 && c < 0x7f
          @line += c.chr      # not <<: @line may be a history entry
          write(c.chr)
        end
        nil
      end
    end

    # Redraws the current line (after a change mid-line).
    def refresh
      write("\r\e[K#{@prompt}#{@line}")
      nil
    end

    private

    def write(str)
      @output.call(str)
    end

    # Escape sequences: ESC [ <params> <final> or ESC O <final>. Bytes arrive
    # one at a time, possibly split across interrupts.
    def escape(c)
      if @esc == :esc
        if c == 0x5b || c == 0x4f   # '[' or 'O'
          @esc = :csi
          return nil
        end
        @esc = nil
        return feed(c)              # lone ESC: process the key normally
      end

      if c.between?(0x40, 0x7e)     # final byte
        @esc = nil
        case c
        when 0x41 then history_move(-1)   # Up
        when 0x42 then history_move(1)    # Down
        end
        nil
      elsif c.between?(0x20, 0x3f)   # parameter or intermediate byte
        nil
      else                           # not a valid sequence; drop it
        @esc = nil
        feed(c)
      end
    end

    def add_history(line)
      return if line.strip.empty? || line == @history.last
      @history << line
      @history.shift if @history.size > HISTORY_SIZE
    end

    def history_move(step)
      return if @history.empty?
      if @hist_pos.nil?
        return if step > 0
        @saved = @line
        @hist_pos = @history.size
      end
      pos = @hist_pos + step
      return if pos < 0
      if pos >= @history.size
        @hist_pos = nil
        @line = @saved
      else
        @hist_pos = pos
        @line = @history[pos]
      end
      refresh
    end
  end
end
