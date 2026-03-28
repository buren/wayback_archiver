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

    # Set defalt concurrency to 1, so we don't have to deal with concurrency
    # issues in Webmock and rspec-mocks
    WaybackArchiver.concurrency = 1

    WaybackArchiver.max_limit = WaybackArchiver::DEFAULT_MAX_LIMIT

    WaybackArchiver.access_key = nil
    WaybackArchiver.secret_key = nil
  end
end
