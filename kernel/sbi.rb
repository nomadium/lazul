# Supervisor Binary Interface calls, built on the single SBI.ecall primitive.
module SBI
  EXT_BASE = 0x10
  EXT_IPI = 0x735049    # "sPI"
  EXT_HSM = 0x48534D    # "HSM"
  EXT_SRST = 0x53525354  # "SRST"

  HART_STARTED = 0
  HART_STOPPED = 1

  class Error < StandardError; end

  def self.call(eid, fid, *args)
    err, value = ecall(eid, fid, *args)
    raise Error, "SBI call #{eid.to_s(16)}/#{fid} failed: #{err}" if err != 0
    value
  end

  def self.spec_version
    v = call(EXT_BASE, 0)
    "#{v >> 24}.#{v & 0xffffff}"
  end

  def self.impl_id = call(EXT_BASE, 1)

  def self.hart_start(hartid, addr, opaque = 0) = call(EXT_HSM, 0, hartid, addr, opaque)

  # Status of a hart, or nil if no such hart exists.
  def self.hart_status(hartid)
    err, value = ecall(EXT_HSM, 2, hartid)
    (err == 0) ? value : nil
  end

  def self.send_ipi(hartids)
    mask = hartids.inject(0) { |m, id| m | (1 << id) }
    call(EXT_IPI, 0, mask, 0)
  end

  def self.shutdown = call(EXT_SRST, 0, 0, 0)
end
