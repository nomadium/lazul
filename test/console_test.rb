#!/usr/bin/env ruby

# Boots the kernel in QEMU and drives the serial console like a user would.
# Usage: test/console_test.rb [smp] (default: $SMP or 4)

require "timeout"

SMP = Integer(ARGV[0] || ENV.fetch("SMP", 4))
# The shell prompt; always written after a newline, so a "=> " that ends a
# partial read of a reply does not look like it.
PROMPT = "\r\n> "
KERNEL = File.expand_path("../build/kernel.elf", __dir__)
QEMU = %W[qemu-system-riscv64 -machine virt -smp #{SMP} -m 128M -nographic
  -bios default -kernel #{KERNEL}]

# Drives the kernel's serial console and counts failed checks.
class ConsoleTest
  attr_reader :failures

  def initialize(io)
    @io = io
    @out = +""
    @failures = 0
  end

  # Read console output until it matches pattern; returns the new output.
  def expect(pattern, timeout: 10)
    start = @out.size
    Timeout.timeout(timeout) do
      @out << @io.readpartial(4096) until @out[start..] =~ pattern
    end
    @out[start..]
  rescue Timeout::Error, EOFError
    raise "timed out waiting for #{pattern.inspect}; output so far:\n#{@out[start..]}"
  end

  def check(name, ok)
    puts "#{ok ? "ok  " : "FAIL"} #{name}"
    @failures += 1 unless ok
  end

  # Type a line and check that the reply includes expected.
  def command(line, expected)
    @io.write(line + "\r")
    out = expect(/#{PROMPT}\z/o)
    check(line, out.include?(expected))
    out
  end

  def write(str)
    @io.write(str)
  end
end

io = IO.popen(QEMU, "r+", err: [:child, :out])
t = ConsoleTest.new(io)

begin
  boot = t.expect(/#{SMP} hart\(s\) online; type 'help'#{PROMPT}\z/o, timeout: 30)
  puts boot if ENV["VERBOSE"]
  boot_hart = boot[/Ruby is running on hart (\d+)/, 1].to_i  # OpenSBI picks it at random
  (0...SMP).each { |i| t.check("hart #{i} up", i == boot_hart || boot.include?("hart #{i} online")) }

  t.command("echo hello, mruby kernel", "hello, mruby kernel\r\n")
  t.command("a = 6 * 7", "=> 42")
  t.command("a + 1", "=> 43")
  t.command("self", "=> main")
  t.command("raise 'boom'", "RuntimeError: boom")
  t.command("harts", "hart #{SMP - 1}: online")
  t.command("Memory.read32(Kern::SECONDARY_ENTRY) != 0", "=> true")

  # Line editing: backspace removes the typo before the line is submitted.
  t.command("echo typx\x7fo", "typo\r\n")

  # Run work on every hart via IPIs, then make sure all of it happened.
  t.write("$seen = []; Hart.online.each { |h| h.run { $seen << CPU.hartid } }; nil\r")
  t.expect(/#{PROMPT}\z/o)
  sleep 0.5
  t.command("$seen.sort", "=> #{(0...SMP).to_a.inspect}")

  # Stress the big kernel lock: lots of queued jobs on all harts, with GCs.
  t.write("$c = 0; Hart.online.each { |h| 200.times { h.run { $c += 1; GC.start if $c % 50 == 0 } } }; nil\r")
  t.expect(/#{PROMPT}\z/o)
  sleep 2
  t.command("$c", "=> #{200 * SMP}")

  if SMP > 1
    t.write("on #{SMP - 1} CPU.hartid * 100\r")
    t.expect(/\[hart #{SMP - 1}\] => #{(SMP - 1) * 100}#{PROMPT}\z/)
    t.check("on #{SMP - 1}", true)
  end

  # Allocate a lot so the GC runs while other harts hold references.
  t.command("GC.start; (1..100_000).map(&:to_s).last", '=> "100000"')

  t.write("poweroff\r")
  t.expect(/powering off/)
  Timeout.timeout(10) { Process.wait(io.pid) }
  t.check("qemu exited", true)
rescue => e
  t.check(e.message, false)
  begin
    Process.kill(:KILL, io.pid)
  rescue
    nil
  end
end

puts t.failures.zero? ? "all tests passed (smp=#{SMP})" : "#{t.failures} failure(s) (smp=#{SMP})"
exit(t.failures.zero? ? 0 : 1)
