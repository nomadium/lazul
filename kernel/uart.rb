# NS16550A UART driver. Registers are 1 << reg_shift bytes apart and are
# accessed io_width bytes at a time (1 or 4), as the device tree says.
class UART
  RBR = 0  # receive buffer (read)
  THR = 0  # transmit holding (write)
  IER = 1  # interrupt enable
  FCR = 2  # FIFO control
  LCR = 3  # line control
  MCR = 4  # modem control
  LSR = 5  # line status

  LSR_DATA_READY = 0x01
  LSR_THR_EMPTY = 0x20   # room for another byte
  LSR_TX_EMPTY = 0x40    # everything sent, the shift register too
  IER_RX_AVAILABLE = 0x01

  attr_reader :base, :irq

  def initialize(base, irq, reg_shift: 0, io_width: 1)
    @base = base
    @irq = irq
    @reg_shift = reg_shift
    @io_width = io_width
  end

  def init
    write(IER, 0)
    write(LCR, 0x03)                # 8N1
    write(FCR, 0x07)                # enable and clear FIFOs
    write(MCR, 0x0b)                # DTR, RTS, OUT2 (IRQ line enable)
    write(IER, IER_RX_AVAILABLE)
  end

  def putc(byte)
    nil until read(LSR) & LSR_THR_EMPTY != 0
    write(THR, byte)
  end

  # Wait until every byte written has left the UART, e.g. before the
  # machine is reset or powered off.
  def flush
    nil until read(LSR) & LSR_TX_EMPTY != 0
  end

  # Next received byte, or nil if the receive FIFO is empty.
  def getc
    (read(LSR) & LSR_DATA_READY != 0) ? read(RBR) : nil
  end

  private

  def read(reg)
    addr = @base + (reg << @reg_shift)
    (@io_width == 4) ? Memory.read32(addr) & 0xff : Memory[addr]
  end

  def write(reg, v)
    addr = @base + (reg << @reg_shift)
    (@io_width == 4) ? Memory.write32(addr, v) : Memory[addr] = v
  end
end
