# What the kernel needs to know about a PC, from the boot info
# (src/arch/amd64/bootinfo.h) and the ACPI tables. Pure interpretation of
# data read through a memory reader (Memory in the kernel, so that it could
# also run under CRuby); nothing here touches devices.
class Platform
  BOOT_INFO_MAGIC = 0x4f464e49544f4f42   # "BOOTINFO" in memory
  MEMORY_FREE = 1                        # BOOT_MEM_FREE
  COM1 = 0x3f8
  COM1_IRQ = 4

  UARTInfo = Struct.new(:space, :base, :irq, :name)   # space: :port or :mmio

  attr_reader :boot_info, :acpi, :madt, :fadt, :memory_map, :memory, :uart,
    :trampoline, :harts

  def initialize(boot_info, mem = Memory)
    @mem = mem
    @boot_info = boot_info
    magic, rsdp, map, entries, @trampoline = mem.read_bytes(boot_info, 40).unpack("Q<5")
    raise "bad boot info (magic 0x#{magic.to_s(16)})" unless magic == BOOT_INFO_MAGIC
    @memory_map = read_memory_map(map, entries)
    @memory = free_memory
    @acpi = ACPI.new(rsdp, mem)
    @madt = @acpi.madt or raise "no MADT in the ACPI tables"
    @fadt = @acpi.fadt
    @uart = find_uart
    # The CPUs the firmware enabled, by APIC id: the kernel's hart ids.
    @harts = @madt.cpus.select(&:enabled).map(&:apic_id).sort
  end

  # Who made the machine, as its ACPI tables say (e.g. "BOCHS BXPC" on
  # QEMU).
  def model
    t = @acpi["FACP"] || @acpi.tables.first
    [@acpi.oem_id, t&.oem_table_id].compact.join(" ")
  end

  # The ISA IRQ's global system interrupt number and polarity/trigger.
  def isa_irq(irq)
    o = @madt.overrides.find { |x| x.source == irq }
    o ? [o.gsi, o.active_low, o.level] : [irq, false, false]
  end

  private

  # [base, size, type] for each entry: 24 bytes, struct boot_memory.
  def read_memory_map(map, entries)
    data = @mem.read_bytes(map, 24 * entries)
    (0...entries).map { |i| data.byteslice(24 * i, 24).unpack("Q<3") }
  end

  # Free RAM as sorted [base, size] ranges, neighbours merged.
  def free_memory
    ranges = []
    @memory_map.sort.each do |base, size, type|
      next unless type == MEMORY_FREE
      last = ranges.last
      if last && last[0] + last[1] == base
        last[1] += size
      else
        ranges << [base, size]
      end
    end
    ranges
  end

  # SPCR if the firmware describes a 16550, else the traditional COM1.
  def find_uart
    if (spcr = @acpi.spcr)
      space, base, irq = spcr
      return UARTInfo.new((space == 1) ? :port : :mmio, base, irq, "SPCR")
    end
    UARTInfo.new(:port, COM1, COM1_IRQ, "COM1")
  end
end
