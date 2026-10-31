# Flattened device tree (DTB) parser.
#
# Works on a String holding the blob, so the same code runs in the kernel
# (FDT.from_memory reads the blob the firmware handed us) and in CRuby on
# the host (test/fdt_test.rb). Keep it to the Ruby subset both support.
#
#   fdt = FDT.new(blob)
#   fdt.find("/cpus").u32("timebase-frequency")
#   fdt.compatible("ns16550a").first.reg     # => [[0x10000000, 0x100]]
#
# Format: https://devicetree-specification.readthedocs.io (chapter 5)
class FDT
  MAGIC      = 0xd00dfeed
  BEGIN_NODE = 1
  END_NODE   = 2
  PROP       = 3
  NOP        = 4
  FDT_END    = 9

  class Error < StandardError; end

  class Node
    attr_reader :name, :parent, :children, :props

    def initialize(fdt, name, parent)
      @fdt      = fdt
      @name     = name
      @parent   = parent
      @children = []
      @props    = {}
    end

    def path
      return "/" unless @parent
      @parent.parent ? "#{@parent.path}/#{@name}" : "/#{@name}"
    end

    # "serial@10000000" -> "serial", "10000000"
    def base_name = @name.split("@", 2)[0]
    def unit_address = @name.split("@", 2)[1]

    def [](prop) = @props[prop]
    def prop?(prop) = @props.key?(prop)

    # Property values. Device tree data is big-endian 32-bit cells.
    def cells(prop)
      v = @props[prop]
      v&.unpack("N*")
    end

    def u32(prop)
      v = @props[prop]
      (v && v.bytesize >= 4) ? v.unpack1("N") : nil
    end

    # A number made of however many cells the property has (1 or 2 usually).
    def int(prop)
      c = cells(prop)
      c ? FDT.combine(c) : nil
    end

    def string(prop) = strings(prop)&.first

    def strings(prop)
      v = @props[prop]
      return nil unless v
      v = v.byteslice(0, v.bytesize - 1) if v.getbyte(v.bytesize - 1) == 0
      v.split("\0")
    end

    def compatible?(c) = (strings("compatible") || []).include?(c)

    def enabled?
      s = string("status")
      s.nil? || s == "okay" || s == "ok"
    end

    def phandle = u32("phandle")

    # Cell counts that apply to this node's children (spec defaults: 2 and 1).
    def address_cells = u32("#address-cells") || 2
    def size_cells = u32("#size-cells") || 1

    # "reg" as [[address, size], ...], decoded with the parent's cell counts.
    def reg
      c = cells("reg")
      return [] unless c
      ac = @parent ? @parent.address_cells : 2
      sc = @parent ? @parent.size_cells : 1
      FDT.chunks(c, ac + sc).map do |entry|
        [FDT.combine(entry[0, ac]), FDT.combine(entry[ac, sc])]
      end
    end

    def child(name)
      @children.find { |c| c.name == name } || @children.find { |c| c.base_name == name }
    end

    def each(&block)
      block.call(self)
      @children.each { |c| c.each(&block) }
    end

    def inspect = "#<FDT::Node #{path}>"
  end

  attr_reader :root, :memreserve, :boot_cpuid, :size

  # Read a blob that the firmware left in memory (kernel only).
  def self.from_memory(addr)
    magic, size = Memory.read_bytes(addr, 8).unpack("NN")
    raise Error, "no device tree at 0x#{addr.to_s(16)}" unless magic == MAGIC
    new(Memory.read_bytes(addr, size))
  end

  def self.combine(cells) = cells.inject(0) { |v, c| (v << 32) | c }

  def self.chunks(ary, n)
    return [] if n <= 0
    out = []
    i = 0
    while i + n <= ary.size
      out << ary[i, n]
      i += n
    end
    out
  end

  def initialize(blob)
    @blob = blob
    magic, @size, off_struct, off_strings, off_rsvmap, version, _last_comp, @boot_cpuid =
      blob.unpack("N8")
    raise Error, "bad magic 0x#{magic.to_s(16)}" unless magic == MAGIC
    raise Error, "unsupported version #{version}" if version < 17
    @strings_off = off_strings
    @memreserve = parse_memreserve(off_rsvmap)
    @root = parse_struct(off_struct)
    @phandles = {}
    @root.each { |n| @phandles[n.phandle] = n if n.phandle }
  end

  # Look up a node by path ("/cpus/cpu@0"); a leading alias also works
  # ("serial0" -> /aliases/serial0). Unit addresses may be omitted.
  def find(path)
    unless path.start_with?("/")
      first, rest = path.split("/", 2)
      target = @root.child("aliases")&.string(first)
      return nil unless target
      path = rest ? "#{target}/#{rest}" : target
    end
    node = @root
    path.split("/").each do |part|
      next if part.empty?
      node = node.child(part)
      return nil unless node
    end
    node
  end

  def phandle(n) = @phandles[n]

  def each_node(&block) = @root.each(&block)

  # Enabled nodes compatible with any of the given strings.
  def compatible(*names)
    found = []
    each_node { |n| found << n if n.enabled? && names.any? { |c| n.compatible?(c) } }
    found
  end

  private

  def u32_at(off) = @blob.byteslice(off, 4).unpack1("N")

  def cstring_at(off)
    stop = @blob.byteindex("\0", off)
    raise Error, "unterminated string at #{off}" unless stop
    @blob.byteslice(off, stop - off)
  end

  def align4(n) = (n + 3) & ~3

  def parse_memreserve(off)
    list = []
    loop do
      addr, size = @blob.byteslice(off, 16).unpack("Q>Q>")
      break if addr == 0 && size == 0
      list << [addr, size]
      off += 16
    end
    list
  end

  def parse_struct(off)
    root = nil
    node = nil
    loop do
      token = u32_at(off)
      off += 4
      case token
      when BEGIN_NODE
        name = cstring_at(off)
        off = align4(off + name.bytesize + 1)
        child = Node.new(self, name, node)
        if node
          node.children << child
        else
          root = child
        end
        node = child
      when END_NODE
        node = node.parent
      when PROP
        len = u32_at(off)
        name = cstring_at(@strings_off + u32_at(off + 4))
        node.props[name] = @blob.byteslice(off + 8, len)
        off = align4(off + 8 + len)
      when NOP
        next
      when FDT_END
        break
      else
        raise Error, "bad token #{token} at offset #{off - 4}"
      end
    end
    root
  end
end
