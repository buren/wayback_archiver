require 'spec_helper'

RSpec.describe WaybackArchiver::RateLimiter do
  describe '#acquire' do
    it 'allows first request without sleeping' do
      limiter = described_class.new(rate_per_minute: 4)

      expect(limiter).not_to receive(:sleep)
      limiter.acquire
    end

    it 'sleeps when requests exceed the rate' do
      limiter = described_class.new(rate_per_minute: 4)
      allow(limiter).to receive(:sleep)

      4.times { limiter.acquire }

      expect(limiter).to receive(:sleep).with(a_value > 0)
      limiter.acquire
    end

    it 'does not sleep when enough time has passed' do
      limiter = described_class.new(rate_per_minute: 4)

      4.times { limiter.acquire }

      allow(Process).to receive(:clock_gettime)
        .with(Process::CLOCK_MONOTONIC)
        .and_return(Time.now.to_f + 61)

      expect(limiter).not_to receive(:sleep)
      limiter.acquire
    end

    it 'is thread-safe' do
      limiter = described_class.new(rate_per_minute: 100)
      allow(limiter).to receive(:sleep)

      threads = 10.times.map do
        Thread.new { 10.times { limiter.acquire } }
      end
      threads.each(&:join)
    end
  end

  describe '#acquire with enabled: false' do
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
