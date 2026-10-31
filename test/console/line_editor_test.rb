#!/usr/bin/env ruby
# Host-side test of the console line editor (kernel/console/line_editor.rb) under
# CRuby: feed key sequences, check the resulting lines and screen output.

ROOT = File.expand_path("../..", __dir__)
load File.join(ROOT, "kernel/console/line_editor.rb")

@failures = 0  # failed checks, counted by check()

def check(name, actual, expected)
  ok = actual == expected
  puts "#{ok ? "ok  " : "FAIL"} #{name}#{": expected #{expected.inspect}, got #{actual.inspect}" unless ok}"
  @failures += 1 unless ok
end

# A fresh editor plus the screen output it produced; `type` returns the
# results the editor reported (lines, :interrupt). Lines given to new() are
# typed first, to fill the history.
class Session
  attr_reader :editor, :out

  def initialize(*lines)
    @out = +""
    @editor = Console::LineEditor.new { |s| @out << s }
    @editor.prompt = "> "
    lines.each { |l| type(l + "\r") }
    @out.clear
  end

  def type(keys)
    keys.each_byte.map { |b| @editor.feed(b) }.compact
  end

  def line = @editor.line
end

s = Session.new
check "line returned on enter", s.type("echo hi\r"), ["echo hi"]
check "enter echoes a newline", s.out, "echo hi\n"
check "line cleared after enter", s.line, ""
check "lf also ends a line", Session.new.type("a\n"), ["a"]
check "empty line", Session.new.type("\r"), [""]

s = Session.new
s.type("tyx\x7fpo")
check "backspace (DEL)", s.line, "typo"
check "backspace erases on screen", s.out, "tyx\b \bpo"
check "backspace (BS)", Session.new.tap { |x| x.type("ab\x08") }.line, "a"
s = Session.new
s.type("\x7f")
check "backspace on empty line does nothing", s.out, ""

s = Session.new
s.type("abc\x15")
check "ctrl-u clears", s.line, ""
check "ctrl-u erases on screen", s.out, "abc" + "\b \b" * 3

s = Session.new
check "ctrl-c", s.type("abc\x03"), [:interrupt]
check "ctrl-c echoes ^C", s.out, "abc^C\n"
check "line cleared after ctrl-c", s.line, ""

s = Session.new
check "control and non-ASCII bytes ignored", s.type("a\e\tb\xc3\xa9c\r"), ["abc"]

s = Session.new
lines = s.type("one\rtwo\r")
check "several lines", lines, %w[one two]
lines.first << "!"
check "returned line is not reused", s.type("x\r"), ["x"]

# History.
UP = "\e[A"
DOWN = "\e[B"

s = Session.new("one", "two", "three")
check "history recorded", s.editor.history, %w[one two three]
s.type(UP)
check "up recalls newest", s.line, "three"
s.type(UP + UP)
check "up again goes older", s.line, "one"
s.type(UP)
check "up stops at oldest", s.line, "one"
s.type(DOWN)
check "down goes newer", s.line, "two"
check "redraw clears the row", s.out.end_with?("\r\e[K> two"), true

s = Session.new("one", "two")
s.type("draft")
s.type(UP + DOWN)
check "down past newest restores draft", s.line, "draft"
check "down with no browsing does nothing", Session.new("x").tap { |x| x.type(DOWN) }.line, ""
check "up with no history does nothing", Session.new.tap { |x| x.type("a" + UP) }.out, "a"

s = Session.new("one")
check "recalled line runs", s.type(UP + "\r"), ["one"]
check "duplicates not stored", s.editor.history, %w[one]
check "blank lines not stored", Session.new("", "  ").editor.history, []

s = Session.new("abc")
s.type(UP + "d\r")
check "editing a recalled line leaves history alone", s.editor.history, %w[abc abcd]

s = Session.new("one", "two")
s.type(UP + UP + "\x03" + UP)
check "ctrl-c stops browsing", s.line, "two"

s = Session.new("one")
s.type("\e")
s.type("[")
s.type("A")
check "escape sequence split across reads", s.line, "one"
check "unknown sequences are swallowed", Session.new.tap { |x| x.type("a\e[Cb\e[1;5Dc") }.line, "abc"
check "SS3 arrows (ESC O A)", Session.new("one").tap { |x| x.type("\eOA") }.line, "one"
check "lone ESC drops only itself", Session.new.tap { |x| x.type("a\exb") }.line, "axb"
check "bad sequence keeps the key", Session.new.type("a\e[\r"), ["a"]

s = Session.new
(Console::LineEditor::HISTORY_SIZE + 5).times { |i| s.type("cmd #{i}\r") }
check "history is capped", s.editor.history.size, Console::LineEditor::HISTORY_SIZE
check "oldest entries dropped", s.editor.history.first, "cmd 5"

puts @failures.zero? ? "all line editor tests passed" : "#{@failures} failure(s)"
exit(@failures.zero? ? 0 : 1)
