module WaybackArchiver
  # Holds all configurable settings for WaybackArchiver.
  #
  # Access via {WaybackArchiver.config} or use the block form:
  #
  #   WaybackArchiver.configure do |config|
  #     config.access_key = 'your-access-key'
  #     config.concurrency = 8
  #   end
  class Configuration
    attr_accessor :concurrency, :max_limit, :respect_robots_txt
    attr_writer :logger, :user_agent

    def initialize
      @concurrency = DEFAULT_CONCURRENCY
      @max_limit = DEFAULT_MAX_LIMIT
      @respect_robots_txt = DEFAULT_RESPECT_ROBOTS_TXT
    end

    # Sets the Internet Archive S3 access key and resets the rate limiter.
    def access_key=(key)
      @access_key = key
      WaybackMachine.reset_rate_limiter!
    end

    # Returns the configured access key, falling back to environment variables.
    def access_key
      @access_key || ENV['WAYBACK_ACCESS_KEY'] || ENV['IA_S3_ACCESS_KEY']
    end

    # Sets the Internet Archive S3 secret key and resets the rate limiter.
    def secret_key=(key)
      @secret_key = key
      WaybackMachine.reset_rate_limiter!
    end

    # Returns the configured secret key, falling back to environment variables.
    def secret_key
      @secret_key || ENV['WAYBACK_SECRET_KEY'] || ENV['IA_S3_SECRET_KEY']
    end

    # Returns whether both access_key and secret_key are configured.
    def credentials?
      !access_key.nil? && !secret_key.nil?
    end

    # Returns the current logger, defaulting to NullLogger.
    def logger
      @logger ||= NullLogger.new
    end

    # Sets the event listener, wrapping it in a ListenerProxy.
    def listener=(listener)
      @listener = ListenerProxy.new(listener)
    end

    # Returns the current event listener.
    def listener
      @listener ||= ListenerProxy.new(NullListener.new)
    end

    # Returns the configured user agent.
    def user_agent
      @user_agent ||= USER_AGENT
    end

    # Sets the adapter (must respond to #call).
    def adapter=(adapter)
      unless adapter.respond_to?(:call)
        raise(ArgumentError, 'adapter must implement #call')
      end

      @adapter = adapter
    end

    # Returns the configured adapter, defaulting to WaybackMachine.
    def adapter
      @adapter ||= WaybackMachine
    end
  end
end
