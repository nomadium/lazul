# x86 interrupt controllers, the PLIC's counterparts: the local APIC (one
# per CPU: its id, IPIs, accepting interrupts) and I/O APICs (route device
# interrupts to a CPU and vector). The interrupt handler in C
# (src/arch/amd64/irq.c) only records vectors and acknowledges them;
# everything else is here.

# The local APIC, in xAPIC mode (MMIO registers) or x2APIC mode (MSRs,
# where register r is MSR 0x800 + r / 16).
class LAPIC
  ID = 0x20
  TPR = 0x80   # task priority: interrupts below it are held back
  SVR = 0xf0   # spurious interrupt vector, and the enable bit (0x100)

  MSR_APIC_BASE = 0x1b
  X2APIC_ENABLED = 1 << 10

  attr_reader :base

  def initialize
    msr = CPU.rdmsr(MSR_APIC_BASE)
    @x2apic = msr & X2APIC_ENABLED != 0
    @base = msr & ~0xfff
  end

  def x2apic? = @x2apic

  def read(reg) = @x2apic ? CPU.rdmsr(0x800 + (reg >> 4)) : Memory.read32(@base + reg)

  def write(reg, v)
    @x2apic ? CPU.wrmsr(0x800 + (reg >> 4), v) : Memory.write32(@base + reg, v)
  end

  # The APIC id of the CPU running this.
  def id = @x2apic ? read(ID) : read(ID) >> 24

  # Enable this CPU's local APIC and accept all priorities.
  def enable
    write(TPR, 0)
    write(SVR, 0x100 | Kern::SPURIOUS_VECTOR)
  end
end

# An I/O APIC: a table of redirection entries, one per input (GSI), each
# saying which vector to deliver to which CPU. It has just two registers,
# a register select at its base and a data window at base + 0x10.
class IOAPIC
  attr_reader :address, :gsi_base, :size

  def initialize(address, gsi_base)
    @address = address
    @gsi_base = gsi_base
    @size = ((read(1) >> 16) & 0xff) + 1    # version register: inputs - 1
  end

  def handles?(gsi) = gsi >= @gsi_base && gsi < @gsi_base + @size

  # Deliver gsi as vector to the CPU with the given APIC id (fixed delivery,
  # physical destination), unmasked.
  def route(gsi, vector, apic_id, active_low: false, level: false)
    index = gsi - @gsi_base
    low = vector | (active_low ? 1 << 13 : 0) | (level ? 1 << 15 : 0)
    write(0x10 + 2 * index + 1, apic_id << 24)
    write(0x10 + 2 * index, low)
  end

  def mask(gsi) = write(0x10 + 2 * (gsi - @gsi_base), 1 << 16)

  private

  def read(reg)
    Memory.write32(@address, reg)
    Memory.read32(@address + 0x10)
  end

  def write(reg, v)
    Memory.write32(@address, reg)
    Memory.write32(@address + 0x10, v)
  end
end

# The interrupt controller interface Kern uses (register / service), for ISA
# IRQs routed through the I/O APICs to the CPU that registers them.
class IRQRouter
  attr_reader :ioapics

  def initialize(platform, lapic)
    @platform = platform
    @lapic = lapic
    @ioapics = platform.madt.ioapics.map { |io| IOAPIC.new(io.address, io.gsi_base) }
    @handlers = {}    # vector => block
  end

  def register(irq, &handler)
    gsi, active_low, level = @platform.isa_irq(irq)
    ioapic = @ioapics.find { |io| io.handles?(gsi) } or
      raise "no I/O APIC handles GSI #{gsi} (IRQ #{irq})"
    vector = Kern::IRQ_VECTOR_BASE + irq
    @handlers[vector] = handler
    ioapic.route(gsi, vector, @lapic.id, active_low: active_low, level: level)
  end

  # pending: bits from CPU.take_pending (bit n = vector IRQ_VECTOR_BASE + n).
  def service(_hartid, pending)
    @handlers.each do |vector, handler|
      handler.call if (pending >> (vector - Kern::IRQ_VECTOR_BASE)) & 1 == 1
    end
  end
end
