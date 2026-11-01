#!/usr/bin/env ruby

# Boots the kernel in QEMU and drives the serial console like a user would.
# Usage: test/console_test.rb [smp] (default: $SMP or 4)
# "make test" passes the architecture in $ARCH and its QEMU command line in
# $QEMU_CMD; without them, the riscv64 kernel is run. BOOT=uefi says that
# command boots through U-Boot and the EFI loader (make test BOOT=uefi).

require "shellwords"
require "timeout"

SMP = Integer(ARGV[0] || ENV.fetch("SMP", 4))
ARCH = ENV.fetch("ARCH", "riscv64")
UEFI = ENV["BOOT"] == "uefi"
# Booting through U-Boot takes longer: it scans for devices first.
BOOT_TIMEOUT = UEFI ? 60 : 30
# The shell prompt; always written after a newline, so a "=> " that ends a
# partial read of a reply does not look like it.
PROMPT = "\r\n> "
KERNEL = File.expand_path("../build/riscv64/kernel.elf", __dir__)
QEMU = if ENV["QEMU_CMD"]
  Shellwords.split(ENV["QEMU_CMD"])
else
  %W[qemu-system-riscv64 -machine virt -smp #{SMP} -m 128M -nographic
    -bios default -kernel #{KERNEL}]
end

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

  # Everything the console prints within the next seconds.
  def output_for(seconds)
    start = @out.size
    Timeout.timeout(seconds) { loop { @out << @io.readpartial(4096) } }
  rescue Timeout::Error, EOFError
    @out[start..]
  end

  def write(str)
    @io.write(str)
  end
end

# CPU time QEMU (process pid) has used so far, in seconds (Linux only).
def cpu_seconds(pid)
  fields = File.read("/proc/#{pid}/stat").split(")").last.split
  (fields[11].to_i + fields[12].to_i) / 100.0
end

io = IO.popen(QEMU, "r+", err: [:child, :out])
t = ConsoleTest.new(io)

begin
  boot = t.expect(/#{SMP} hart\(s\) online; type 'help'#{PROMPT}\z/o, timeout: BOOT_TIMEOUT)
  if UEFI
    t.check("booted through the EFI loader", boot.include?("lazul EFI loader"))
    # The loader puts the kernel in the lowest free memory, not where it was
    # linked to run, so the whole test runs on a relocated kernel.
    linked, loaded = boot.match(/kernel linked at (0x\h+), loaded at (0x\h+)/)&.captures
    t.check("kernel relocated", linked && loaded != linked && boot.include?("relocated 0x"))
  end
  puts boot if ENV["VERBOSE"]
  # What the kernel found in the device tree.
  t.check("banner: harts", boot.include?("harts: #{(0...SMP).to_a.join(", ")}; timebase 10000000 Hz"))
  t.check("banner: console", boot.include?("console: /soc/serial@10000000 at 0x10000000, irq 10"))
  t.check("banner: plic", boot.include?("interrupts: PLIC at 0xc000000"))
  # The device tree sits at the top of RAM (put there by QEMU, or U-Boot's
  # copy), so the heap ends there.
  dtb = boot[/machine: .*, device tree at (0x\h+)/, 1]
  t.check("heap ends at the device tree", dtb && boot.include?("-#{dtb}\r\n"))
  boot_hart = boot[/Ruby is running on hart (\d+)/, 1].to_i  # OpenSBI picks it at random
  (0...SMP).each { |i| t.check("hart #{i} up", i == boot_hart || boot.include?("hart #{i} online")) }

  t.command("echo hello, mruby kernel", "hello, mruby kernel\r\n")
  t.command("a = 6 * 7", "=> 42")
  t.command("a + 1", "=> 43")
  t.command("self", "=> main")
  t.command("raise 'boom'", "RuntimeError: boom")
  t.command("0xd00dfeed", "=> 3490578157")   # wider than 32 bits
  t.command("harts", "hart #{SMP - 1}: online")
  t.command("Memory.read32(Kern::SECONDARY_ENTRY) != 0", "=> true")
  t.command("dt", "    cpu@#{SMP - 1}\r\n")
  t.command("dt /cpus", "timebase-frequency = <0x989680>;")
  t.command("dt /soc/serial", '"ns16550a"')

  # Line editing: backspace removes the typo before the line is submitted.
  t.command("echo typx\x7fo", "typo\r\n")

  # History: Up recalls the previous line; Ctrl-R searches older ones. The
  # editor redraws the line, prompt included, before running it.
  t.write("\e[A\r")
  t.expect(/\r\e\[K> echo typo\r\ntypo#{PROMPT}\z/o)
  t.check("up recalls the last line", true)
  t.write("\x12a = 6\r")
  t.expect(/reverse-i-search\)'a = 6': a = 6 \* 7.*=> 42#{PROMPT}\z/mo)
  t.check("ctrl-r finds an older line", true)

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
    # Output from another hart redraws the prompt after a line clear.
    t.expect(/\[hart #{SMP - 1}\] => #{(SMP - 1) * 100}\r\n\r\e\[K> \z/)
    t.check("on #{SMP - 1}", true)
  end

  # Allocate a lot so the GC runs while other harts hold references.
  t.command("GC.start; (1..100_000).map(&:to_s).last", '=> "100000"')

  # Reboot: the machine starts over, through the firmware, and comes back to
  # the prompt with every hart.
  t.write("reboot\r")
  t.expect(/rebooting\r\n/)
  again = t.expect(/#{SMP} hart\(s\) online; type 'help'#{PROMPT}\z/o, timeout: 2 * BOOT_TIMEOUT)
  t.check("reboot", again.include?("lazul: booting on hart"))
  t.check("reboot through the EFI loader", again.include?("lazul EFI loader")) if UEFI

  # Ctrl-D is ignored while the line has text, and powers off on an empty line.
  t.command("echo still here\x04", "still here\r\n")
  t.write("\x04")
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

# A panic stops the whole kernel. The hart that panics usually holds the
# kernel lock, which it will never release, so the other harts must halt
# rather than spin on it once something wakes them. Boot again, make a
# hart fault, and check that the machine goes quiet: keys get no answer,
# and QEMU's virtual CPUs sleep.
io = IO.popen(QEMU, "r+", err: [:child, :out])
pt = ConsoleTest.new(io)
begin
  pt.expect(/#{SMP} hart\(s\) online; type 'help'#{PROMPT}\z/o, timeout: BOOT_TIMEOUT)
  # Load from address 0, where QEMU's virt machine has nothing: an access
  # fault, which the kernel does not handle. On another hart if there is one.
  pt.write((SMP > 1) ? "on #{SMP - 1} Memory.read32(0)\r" : "Memory.read32(0)\r")
  pt.expect(/panic: .*\n/)
  pt.write("1 + 1\r")   # wakes every hart: the UART interrupt goes to all
  before = cpu_seconds(io.pid)
  quiet = pt.output_for(3)
  used = cpu_seconds(io.pid) - before
  pt.check("panic: no answer afterwards", !quiet.include?("=> 2"))
  pt.check("panic: harts halt (QEMU used %.2f CPU s in 3 s)" % used, used < 1)
rescue => e
  pt.check(e.message, false)
ensure
  begin
    Process.kill(:KILL, io.pid)
    Process.wait(io.pid)
  rescue
    nil
  end
end

# A kernel that cannot boot says why and panics. QEMU's sifive_u machine
# has a UART the kernel has no driver for (sifive,uart0), so Kern.boot
# raises there: the report must show the exception with its backtrace,
# files and lines included (mrbc -g), and end in a panic. The machine and
# its firmware are the same whatever BOOT is, so direct boots only.
ft = nil
unless UEFI
  io = IO.popen(%W[qemu-system-riscv64 -machine sifive_u -smp 2 -nographic
    -bios default -kernel #{KERNEL}], "r+", err: [:child, :out])
  ft = ConsoleTest.new(io)
  begin
    out = ft.expect(/panic: .*\n/, timeout: BOOT_TIMEOUT)
    ft.check("failed boot: exception reported",
      out.include?("unhandled Ruby exception: #<RuntimeError: no supported console UART"))
    ft.check("failed boot: backtrace with files and lines", out.match?(%r{\n +from kernel/\S+\.rb:\d+}))
    ft.check("failed boot: panic", out.include?("panic: Kern.boot failed"))
  rescue => e
    ft.check(e.message, false)
  ensure
    begin
      Process.kill(:KILL, io.pid)
      Process.wait(io.pid)
    rescue
      nil
    end
  end
end

failures = t.failures + pt.failures + (ft ? ft.failures : 0)
mode = "smp=#{SMP}#{", boot=uefi" if UEFI}"
puts failures.zero? ? "all tests passed (#{mode})" : "#{failures} failure(s) (#{mode})"
exit(failures.zero? ? 0 : 1)
