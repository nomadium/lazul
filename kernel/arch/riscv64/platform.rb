# What the kernel needs to know about the machine, read from the device tree
# instead of hard-coded QEMU constants. Pure interpretation of an FDT: no
# hardware access, so it also runs in CRuby on the host (test/fdt_test.rb).
class Platform
  UART_COMPATIBLE = %w[ns16550a ns16550 ns8250 snps,dw-apb-uart].freeze
  PLIC_COMPATIBLE = %w[riscv,plic0 sifive,plic-1.0.0].freeze
  IRQ_S_EXT = 9      # supervisor external interrupt, in interrupts-extended

  UARTInfo = Struct.new(:node, :base, :irq, :reg_shift, :reg_io_width)
  PLICInfo = Struct.new(:node, :base, :ndev, :contexts)   # contexts: hartid => S-mode context

  attr_reader :fdt, :model, :memory, :reserved, :harts, :timebase, :uart, :plic

  def initialize(fdt)
    @fdt = fdt
    @model = fdt.root.string("model") || fdt.root.string("compatible") || "unknown"
    @memory = find_memory
    @reserved = find_reserved
    @timebase = fdt.find("/cpus")&.int("timebase-frequency")
    @harts = find_harts
    @uart = find_uart
    @plic = find_plic
  end

  private

  def find_memory
    regions = []
    @fdt.each_node do |n|
      next unless n.string("device_type") == "memory" && n.enabled?
      regions.concat(n.reg)
    end
    regions.sort
  end

  # /memreserve/ entries plus /reserved-memory children (e.g. OpenSBI's own
  # region, which it adds when it boots).
  def find_reserved
    regions = @fdt.memreserve.dup
    rm = @fdt.find("/reserved-memory")
    rm&.children&.each { |n| regions.concat(n.reg) }
    regions.sort
  end

  # Hart ids of enabled CPUs that can run S-mode (have an MMU). This skips
  # e.g. the S-mode-less monitor core that SiFive-style SoCs have as hart 0.
  def find_harts
    cpus = @fdt.find("/cpus")
    return [] unless cpus
    cpus.children.select { |n| cpu_usable?(n) }.map { |n| n.reg[0][0] }.sort
  end

  def cpu_usable?(n)
    n.string("device_type") == "cpu" && n.enabled? &&
      n.prop?("mmu-type") && n.string("mmu-type") != "riscv,none"
  end

  # The console UART: /chosen stdout-path (a path or an alias, optionally
  # followed by ":options"), else the first supported UART.
  def find_uart
    node = nil
    stdout = @fdt.find("/chosen")&.string("stdout-path")
    if stdout
      node = @fdt.find(stdout.split(":", 2)[0])
      node = nil unless node && UART_COMPATIBLE.any? { |c| node.compatible?(c) }
    end
    node ||= @fdt.compatible(*UART_COMPATIBLE).first
    return nil unless node
    UARTInfo.new(node, node.reg[0][0], node.cells("interrupts")&.first,
      node.u32("reg-shift") || 0, node.u32("reg-io-width") || 1)
  end

  # PLIC contexts come from interrupts-extended: entry i is
  # <cpu-intc-phandle irq>, and it describes context i. The cpu-intc node's
  # parent is the cpu, whose reg is the hart id. irq 9 = S-mode external.
  def find_plic
    node = @fdt.compatible(*PLIC_COMPATIBLE).first
    return nil unless node
    contexts = {}
    FDT.chunks(node.cells("interrupts-extended") || [], 2).each_with_index do |(phandle, irq), ctx|
      cpu = @fdt.phandle(phandle)&.parent
      next unless cpu && irq == IRQ_S_EXT
      contexts[cpu.reg[0][0]] = ctx
    end
    PLICInfo.new(node, node.reg[0][0], node.u32("riscv,ndev"), contexts)
  end
end
