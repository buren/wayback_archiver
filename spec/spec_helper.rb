require 'simplecov'
SimpleCov.start do
  # Without this the specs count themselves and inflate the figure.
  add_filter '/spec/'
  # examples_spec.rb loads the example scripts into this process, which would
  # otherwise fold them into the library's coverage figure.
  add_filter '/examples/'
end

Dir['./spec/support/**/*.rb'].each { |file| require file }

require 'wayback_archiver'
require 'webmock/rspec'

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.order = 'random'
  config.run_all_when_everything_filtered = false

  config.before(:each) do
    WaybackArchiver.config.logger = TestLogger.new
    WaybackArchiver.config.listener = WaybackArchiver::TestListener.new

    # Set defalt concurrency to 1, so we don't have to deal with concurrency
    # issues in Webmock and rspec-mocks
    WaybackArchiver.config.concurrency = 1

    WaybackArchiver.config.max_limit = WaybackArchiver::DEFAULT_MAX_LIMIT

    # Stub credential env vars so tests aren't affected by the host environment
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('WAYBACK_ACCESS_KEY').and_return(nil)
    allow(ENV).to receive(:[]).with('WAYBACK_SECRET_KEY').and_return(nil)
    allow(ENV).to receive(:[]).with('IA_S3_ACCESS_KEY').and_return(nil)
    allow(ENV).to receive(:[]).with('IA_S3_SECRET_KEY').and_return(nil)

    WaybackArchiver.config.access_key = nil
    WaybackArchiver.config.secret_key = nil
    # Disable rate limiting in tests to avoid real sleeps
    WaybackArchiver::WaybackMachine.instance_variable_set(
      :@rate_limiter,
      WaybackArchiver::RateLimiter.new(max_requests: 999, enabled: false)
    )
    # Per-URL retry backoff is wall-clock time. Specs that stub BatchSubmitter's
    # sleep to a no-op would otherwise busy-wait out the real 62s of a URL's
    # five retries. batch_retry_spec.rb restores the real delay (against a
    # simulated clock) to cover the backoff itself.
    stub_const('WaybackArchiver::BatchSubmitter::RETRY_BASE_DELAY', 0)
  end
end
