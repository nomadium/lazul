# NS16550A UART driver.
class UART
  RBR = 0  # receive buffer (read)
  THR = 0  # transmit holding (write)
  IER = 1  # interrupt enable
  FCR = 2  # FIFO control
  LCR = 3  # line control
  MCR = 4  # modem control
  LSR = 5  # line status

  LSR_DATA_READY = 0x01
  LSR_THR_EMPTY = 0x20
  IER_RX_AVAILABLE = 0x01

  attr_reader :base, :irq

  def initialize(base, irq)
    @base = base
    @irq = irq
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

  # Next received byte, or nil if the receive FIFO is empty.
  def getc
    (read(LSR) & LSR_DATA_READY != 0) ? read(RBR) : nil
  end

  private

  def read(reg) = Memory[@base + reg]
  def write(reg, v) = Memory[@base + reg] = v
end
