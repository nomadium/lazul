# Harts (hardware threads). Every hart runs the same Ruby VM, one at a time,
# under the big kernel lock. A hart can be handed work with Hart#run: the
# block is queued and the hart is woken with an IPI.
class Hart
  attr_reader :id
  attr_accessor :state

  @harts = {}

  class << self
    def [](id) = @harts[id]
    def all = @harts.values.sort_by(&:id)
    def online = all.select { |h| h.state == :online }
    def current = @harts[CPU.hartid]
    def add(id, state) = @harts[id] = Hart.new(id, state)

    # Find every hart SBI knows about and start the stopped ones.
    # They come up in C at _secondary_start and call Kern.hart_started.
    def start_secondaries
      Kern::MAX_HARTS.times do |id|
        next if @harts[id]
        status = SBI.hart_status(id)
        next unless status
        add(id, :starting)
        SBI.hart_start(id, Kern::SECONDARY_ENTRY) if status == SBI::HART_STOPPED
      end
    end
  end

  def initialize(id, state)
    @id = id
    @state = state
    @queue = []
  end

  def run(&block)
    @queue << block
    SBI.send_ipi([@id])
    self
  end

  def run_queue
    while (job = @queue.shift)
      begin
        job.call
      rescue Exception => e
        Console.notify("hart #{@id}: #{Shell.error_text(e)}")
      end
    end
  end

  def inspect = "#<Hart #{@id} #{@state}>"
end
