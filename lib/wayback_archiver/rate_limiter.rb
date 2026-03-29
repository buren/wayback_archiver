module WaybackArchiver
  # Thread-safe sliding window rate limiter.
  # Tracks timestamps of recent requests and sleeps when the rate limit is reached.
  class RateLimiter
    AUTHENTICATED_RATE = 12 # captures per minute
    ANONYMOUS_RATE     = 4  # captures per minute
    WINDOW             = 60.0 # seconds

    attr_reader :rate_per_minute

    # @param rate_per_minute [Integer] maximum requests per minute.
    # @param enabled [Boolean] set to false to disable rate limiting.
    def initialize(rate_per_minute:, enabled: true)
      @rate_per_minute = rate_per_minute
      @enabled = enabled
      @timestamps = []
      @mutex = Mutex.new
    end

    # Build a rate limiter based on current authentication status.
    # @return [RateLimiter]
    def self.for_current_user
      rate = WaybackArchiver.credentials? ? AUTHENTICATED_RATE : ANONYMOUS_RATE
      new(rate_per_minute: rate)
    end

    # Block until a request slot is available, then record the request.
    def acquire
      return unless @enabled

      @mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        prune_old_timestamps(now)

        if @timestamps.length >= @rate_per_minute
          wait_time = @timestamps.first + WINDOW - now
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
      cutoff = now - WINDOW
      @timestamps.reject! { |t| t < cutoff }
    end
  end
end
