# A monotonic clock the specs move by hand.
#
# Stub `sleep` to advance it and `Process.clock_gettime(CLOCK_MONOTONIC)` to
# read it, and time-dependent behaviour — retry backoff, rate limiting, poll
# deadlines — can be asserted in seconds without the suite waiting for them.
#
# Locked because the code under test submits from several threads at once.
class SimulatedClock
  def initialize(now = 0.0)
    @now = now
    @lock = Mutex.new
  end

  def now
    @lock.synchronize { @now }
  end

  def advance(seconds)
    @lock.synchronize { @now += seconds.to_f }
  end
end
