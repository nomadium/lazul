# ACPI tables: the PC's counterpart of the device tree. The firmware leaves
# them in memory, found from the root pointer (RSDP) that the boot info
# passes on. Only the static tables are read, not the AML byte code that
# describes most devices (which would need an interpreter):
#
#   FACP  the FADT, "fixed" hardware: the PM timer, power management ports
#   SPCR  the serial console, when the firmware describes one
#
# Every table starts with the same 36-byte header: a 4-character
# signature, the length of the table, a revision, a checksum and who made
# it (OEM ids). Tables are read through a memory reader (anything with
# read_bytes(addr, len)), Memory in the kernel, so the parsing can run in
# CRuby too.
#
# Specification: https://uefi.org/specifications (ACPI, chapter 5).
class ACPI
  Table = Struct.new(:signature, :addr, :data) do
    def revision = data.getbyte(8)
    def oem_id = data.byteslice(10, 6).delete("\0").strip
    def oem_table_id = data.byteslice(16, 8).delete("\0").strip
    def u8(off) = data.getbyte(off)
    def u16(off) = data.byteslice(off, 2).unpack1("v")
    def u32(off) = data.byteslice(off, 4).unpack1("V")
    def u64(off) = data.byteslice(off, 8).unpack1("Q<")

    # Generic Address Structure: [space (0 memory, 1 I/O port), address].
    def gas(off) = [u8(off), u64(off + 4)]
  end

  attr_reader :rsdp, :revision, :oem_id, :tables

  # The RSDP: "RSD PTR ", a checksum, the OEM id, the revision, then the
  # address of the root table: the RSDT (32-bit pointers to the other
  # tables) or, from revision 2 on, the XSDT (64-bit ones).
  def initialize(rsdp, mem = Memory)
    @mem = mem
    @rsdp = rsdp
    raise "no ACPI root pointer" if rsdp == 0
    header = mem.read_bytes(rsdp, 36)
    raise "no ACPI RSDP at 0x#{rsdp.to_s(16)}" unless header.byteslice(0, 8) == "RSD PTR "
    @oem_id = header.byteslice(9, 6).delete("\0").strip
    @revision = header.getbyte(15)
    @tables = []
    xsdt = (@revision >= 2) ? header.byteslice(24, 8).unpack1("Q<") : 0
    if xsdt != 0
      read_root(xsdt, 8)
    else
      read_root(header.byteslice(16, 4).unpack1("V"), 4)
    end
  end

  def [](signature) = @tables.find { |t| t.signature == signature }

  # FADT: the PM timer (a 3.579545 MHz counter, 24 or 32 bits wide) and
  # the DSDT, the table with the machine's AML.
  def fadt
    t = self["FACP"] or return nil
    flags = t.u32(112)
    {
      pm_timer: t.u32(76),
      pm_timer_32bit: flags & (1 << 8) != 0,
      dsdt: t.u32(40)
    }
  end

  # SPCR: the firmware's serial console, as [space, address, irq] (space
  # 0 = MMIO, 1 = I/O port), or nil. Only 16550-compatible interfaces.
  def spcr
    t = self["SPCR"] or return nil
    return nil unless [0, 1, 0x12].include?(t.u8(36))  # 16550, 16450, 16550-compatible
    space, addr = t.gas(40)
    [space, addr, t.u8(53)]
  end

  private

  # The root table's header, then its pointers to the other tables.
  def read_root(addr, entry_size)
    len = @mem.read_bytes(addr + 4, 4).unpack1("V")
    root = @mem.read_bytes(addr, len)
    off = 36
    while off + entry_size <= len
      ptr = root.byteslice(off, entry_size).unpack1((entry_size == 8) ? "Q<" : "V")
      hdr = @mem.read_bytes(ptr, 8)
      tlen = hdr.byteslice(4, 4).unpack1("V")
      @tables << Table.new(hdr.byteslice(0, 4), ptr, @mem.read_bytes(ptr, tlen))
      off += entry_size
    end
  end
end
