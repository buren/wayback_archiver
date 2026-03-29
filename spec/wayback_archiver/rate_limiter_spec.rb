require 'spec_helper'

RSpec.describe WaybackArchiver::RateLimiter do
  before do
    allow_any_instance_of(described_class).to receive(:sleep)
  end

  describe '#acquire' do
    it 'allows first request immediately' do
      limiter = described_class.new(rate_per_minute: 4)

      expect_any_instance_of(described_class).not_to receive(:sleep)
      limiter.acquire
    end

    it 'sleeps when requests exceed the rate' do
      limiter = described_class.new(rate_per_minute: 4)

      # Simulate 4 requests already made in the last minute
      4.times { limiter.acquire }

      # 5th should sleep
      expect(limiter).to receive(:sleep).with(a_value > 0)
      limiter.acquire
    end

    it 'does not sleep when enough time has passed' do
      limiter = described_class.new(rate_per_minute: 4)

      # Fill the window
      4.times { limiter.acquire }

      # Advance time past the window
      allow(Process).to receive(:clock_gettime)
        .with(Process::CLOCK_MONOTONIC)
        .and_return(Time.now.to_f + 61)

      expect(limiter).not_to receive(:sleep)
      limiter.acquire
    end

    it 'is thread-safe' do
      limiter = described_class.new(rate_per_minute: 100)

      threads = 10.times.map do
        Thread.new { 10.times { limiter.acquire } }
      end
      threads.each(&:join)

      # No exceptions raised = pass
    end
  end

  describe 'enabled: false' do
    it 'skips rate limiting entirely' do
      limiter = described_class.new(rate_per_minute: 1, enabled: false)

      expect(limiter).not_to receive(:sleep)
      10.times { limiter.acquire }
    end
  end

  describe '.for_current_user' do
    it 'returns 12/min limiter when authenticated' do
      WaybackArchiver.access_key = 'key'
      WaybackArchiver.secret_key = 'secret'

      limiter = described_class.for_current_user
      expect(limiter.rate_per_minute).to eq(12)
    end

    it 'returns 4/min limiter when anonymous' do
      limiter = described_class.for_current_user
      expect(limiter.rate_per_minute).to eq(4)
    end
  end
end
