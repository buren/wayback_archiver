module WaybackArchiver
  # Error that can be retried with backoff
  class RetryableError < StandardError; end

  # Retry with exponential backoff
  class Retry
    DEFAULT_MAX_RETRIES = 3
    DEFAULT_BASE_DELAY = 2   # seconds
    DEFAULT_MAX_DELAY  = 60  # seconds

    # Execute a block with exponential backoff on RetryableError.
    # @param max_retries [Integer] maximum number of retries.
    # @param base_delay [Numeric] initial delay in seconds.
    # @param max_delay [Numeric] maximum delay in seconds.
    # @yield the block to execute.
    # @return the block's return value.
    # @raise [RetryableError] if all retries are exhausted.
    def self.with_backoff(max_retries: DEFAULT_MAX_RETRIES, base_delay: DEFAULT_BASE_DELAY, max_delay: DEFAULT_MAX_DELAY, retry_on: [RetryableError])
      retries = 0
      begin
        yield
      rescue *retry_on => e
        retries += 1
        raise if retries > max_retries

        delay = [base_delay * (2**(retries - 1)), max_delay].min
        jitter = rand(0.0..(delay * 0.1))
        WaybackArchiver.logger.debug("Retryable error (#{e.message}), retry #{retries}/#{max_retries} in #{'%.1f' % (delay + jitter)}s")
        sleep(delay + jitter)
        retry
      end
    end
  end
end
