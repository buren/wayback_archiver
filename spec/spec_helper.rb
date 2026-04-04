require 'simplecov'
SimpleCov.start

Dir['./spec/support/**/*.rb'].each { |file| require file }

require 'wayback_archiver'
require 'webmock/rspec'

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.order = 'random'
  config.run_all_when_everything_filtered = false

  config.before(:each) do
    WaybackArchiver.logger = TestLogger.new
    WaybackArchiver.listener = WaybackArchiver::TestListener.new

    # Set defalt concurrency to 1, so we don't have to deal with concurrency
    # issues in Webmock and rspec-mocks
    WaybackArchiver.concurrency = 1

    WaybackArchiver.max_limit = WaybackArchiver::DEFAULT_MAX_LIMIT

    # Stub credential env vars so tests aren't affected by the host environment
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('WAYBACK_ACCESS_KEY').and_return(nil)
    allow(ENV).to receive(:[]).with('WAYBACK_SECRET_KEY').and_return(nil)
    allow(ENV).to receive(:[]).with('IA_S3_ACCESS_KEY').and_return(nil)
    allow(ENV).to receive(:[]).with('IA_S3_SECRET_KEY').and_return(nil)

    WaybackArchiver.access_key = nil
    WaybackArchiver.secret_key = nil
    # Disable rate limiting in tests to avoid real sleeps
    WaybackArchiver::WaybackMachine.instance_variable_set(
      :@rate_limiter,
      WaybackArchiver::RateLimiter.new(max_requests: 999, enabled: false)
    )
  end
end
