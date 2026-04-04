require 'spec_helper'

RSpec.describe WaybackArchiver::Configuration do
  subject(:config) { described_class.new }

  describe 'defaults' do
    it 'has default concurrency' do
      expect(config.concurrency).to eq(WaybackArchiver::DEFAULT_CONCURRENCY)
    end

    it 'has default max_limit' do
      expect(config.max_limit).to eq(WaybackArchiver::DEFAULT_MAX_LIMIT)
    end

    it 'has default respect_robots_txt' do
      expect(config.respect_robots_txt).to eq(WaybackArchiver::DEFAULT_RESPECT_ROBOTS_TXT)
    end

    it 'has NullLogger as default logger' do
      expect(config.logger).to be_a(WaybackArchiver::NullLogger)
    end

    it 'has NullListener wrapped in ListenerProxy as default listener' do
      expect(config.listener).to be_a(WaybackArchiver::ListenerProxy)
    end

    it 'has default user agent' do
      expect(config.user_agent).to eq(WaybackArchiver::USER_AGENT)
    end

  end

  describe '#concurrency' do
    it 'can be set' do
      config.concurrency = 8
      expect(config.concurrency).to eq(8)
    end
  end

  describe '#max_limit' do
    it 'can be set' do
      config.max_limit = 100
      expect(config.max_limit).to eq(100)
    end
  end

  describe '#respect_robots_txt' do
    it 'can be set' do
      config.respect_robots_txt = true
      expect(config.respect_robots_txt).to eq(true)
    end
  end

  describe '#logger' do
    it 'can be set' do
      logger = Logger.new($stdout)
      config.logger = logger
      expect(config.logger).to eq(logger)
    end
  end

  describe '#user_agent' do
    it 'can be set' do
      config.user_agent = 'CustomAgent/1.0'
      expect(config.user_agent).to eq('CustomAgent/1.0')
    end
  end

  describe '#access_key' do
    it 'can be set' do
      config.access_key = 'my-key'
      expect(config.access_key).to eq('my-key')
    end

    it 'falls back to WAYBACK_ACCESS_KEY env var' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('WAYBACK_ACCESS_KEY').and_return('env-key')
      expect(config.access_key).to eq('env-key')
    end

    it 'falls back to IA_S3_ACCESS_KEY env var' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('WAYBACK_ACCESS_KEY').and_return(nil)
      allow(ENV).to receive(:[]).with('IA_S3_ACCESS_KEY').and_return('ia-key')
      expect(config.access_key).to eq('ia-key')
    end

    it 'resets rate limiter when set' do
      expect(WaybackArchiver::WaybackMachine).to receive(:reset_rate_limiter!)
      config.access_key = 'new-key'
    end
  end

  describe '#secret_key' do
    it 'can be set' do
      config.secret_key = 'my-secret'
      expect(config.secret_key).to eq('my-secret')
    end

    it 'falls back to WAYBACK_SECRET_KEY env var' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('WAYBACK_SECRET_KEY').and_return('env-secret')
      expect(config.secret_key).to eq('env-secret')
    end

    it 'falls back to IA_S3_SECRET_KEY env var' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('WAYBACK_SECRET_KEY').and_return(nil)
      allow(ENV).to receive(:[]).with('IA_S3_SECRET_KEY').and_return('ia-secret')
      expect(config.secret_key).to eq('ia-secret')
    end

    it 'resets rate limiter when set' do
      expect(WaybackArchiver::WaybackMachine).to receive(:reset_rate_limiter!)
      config.secret_key = 'new-secret'
    end
  end

  describe '#credentials?' do
    it 'returns false when no keys are set' do
      expect(config.credentials?).to eq(false)
    end

    it 'returns false when only access_key is set' do
      config.access_key = 'key'
      expect(config.credentials?).to eq(false)
    end

    it 'returns true when both keys are set' do
      config.access_key = 'key'
      config.secret_key = 'secret'
      expect(config.credentials?).to eq(true)
    end
  end

  describe '#listener' do
    it 'wraps in ListenerProxy when set' do
      listener = WaybackArchiver::NullListener.new
      config.listener = listener
      expect(config.listener).to be_a(WaybackArchiver::ListenerProxy)
    end
  end

end

RSpec.describe WaybackArchiver do
  describe '.config' do
    it 'returns a Configuration instance' do
      expect(described_class.config).to be_a(WaybackArchiver::Configuration)
    end

    it 'returns the same instance on repeated calls' do
      expect(described_class.config).to equal(described_class.config)
    end
  end

  describe '.configure' do
    it 'yields the config object' do
      described_class.configure do |c|
        expect(c).to equal(described_class.config)
      end
    end

    it 'returns the config' do
      result = described_class.configure { |c| }
      expect(result).to equal(described_class.config)
    end
  end

  describe '.logger' do
    it 'delegates to config.logger' do
      expect(described_class.logger).to equal(described_class.config.logger)
    end
  end

  describe '.listener' do
    it 'delegates to config.listener' do
      expect(described_class.listener).to equal(described_class.config.listener)
    end
  end
end
