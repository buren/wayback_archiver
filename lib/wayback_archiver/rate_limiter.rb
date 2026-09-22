module WaybackArchiver
  # Thread-safe sliding window rate limiter.
  # Tracks timestamps of recent requests and sleeps when the rate limit is reached.
  # @api private
  class RateLimiter
    # Authenticated captures per minute. archive.org's docs are cited as 7/min
    # (upstream revision 2026-07-22); savepagenow cites 6/min attributed to
    # Internet Archive staff. Take the lower of the two: under the cap costs a
    # little throughput, over it earns errors. Was 12, which is long stale.
    RATE = 6

    attr_reader :max_requests, :window

    # @param max_requests [Integer] maximum requests per window.
    # @param window [Float] sliding window duration in seconds (default: 60.0).
    # @param enabled [Boolean] set to false to disable rate limiting.
    def initialize(max_requests:, window: 60.0, enabled: true)
      @max_requests = max_requests
      @window = window.to_f
      @enabled = enabled
      @timestamps = []
      @mutex = Mutex.new
    end

    # Build a rate limiter for the current user.
    # @return [RateLimiter]
    def self.for_current_user
      new(max_requests: RATE)
    end

    # Block until a request slot is available, then record the request.
    def acquire
      return unless @enabled

      @mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        prune_old_timestamps(now)

        if @timestamps.length >= @max_requests
          wait_time = @timestamps.first + @window - now
          if wait_time > 0
            sleep(wait_time)
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            prune_old_timestamps(now)
          end
        end

        @timestamps << now
      end
    end

    private

    def prune_old_timestamps(now)
      cutoff = now - @window
      @timestamps.reject! { |t| t < cutoff }
    end
  end
end
