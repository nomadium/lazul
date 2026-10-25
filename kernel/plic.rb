# RISC-V Platform-Level Interrupt Controller.
class PLIC
  def initialize(base)
    @base = base
    @handlers = {}
  end

  # On QEMU virt, context 2*hart is M-mode and 2*hart+1 is S-mode.
  def context(hartid) = 2 * hartid + 1

  def register(irq, priority: 1, &handler)
    @handlers[irq] = handler
    Memory.write32(@base + 4 * irq, priority)
  end

  # Route irq to the given hart's S-mode context.
  def enable(irq, hartid)
    addr = @base + 0x2000 + 0x80 * context(hartid) + 4 * (irq / 32)
    Memory.write32(addr, Memory.read32(addr) | (1 << (irq % 32)))
  end

  def threshold(hartid, value)
    Memory.write32(@base + 0x200000 + 0x1000 * context(hartid), value)
  end

  def claim(hartid) = Memory.read32(@base + 0x200004 + 0x1000 * context(hartid))
  def complete(hartid, irq) = Memory.write32(@base + 0x200004 + 0x1000 * context(hartid), irq)

  # Service every interrupt pending for this hart. Several harts may be
  # woken for the same interrupt; only one wins the claim, the rest get 0.
  def service(hartid)
    while (irq = claim(hartid)) != 0
      begin
        @handlers[irq]&.call(irq)
      ensure
        complete(hartid, irq)
      end
    end
  end
end
