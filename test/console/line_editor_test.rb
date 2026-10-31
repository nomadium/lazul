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
# results the editor reported (lines, :interrupt).
class Session
  attr_reader :editor, :out

  def initialize
    @out = +""
    @editor = Console::LineEditor.new { |s| @out << s }
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

puts @failures.zero? ? "all line editor tests passed" : "#{@failures} failure(s)"
exit(@failures.zero? ? 0 : 1)
