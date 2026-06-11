require 'spec_helper'

RSpec.describe WaybackArchiver::RateLimiter do
  describe '#acquire' do
    it 'allows first request without sleeping' do
      limiter = described_class.new(max_requests: 4)

      expect(limiter).not_to receive(:sleep)
      limiter.acquire
    end

    it 'sleeps when requests exceed the rate' do
      limiter = described_class.new(max_requests: 4)
      allow(limiter).to receive(:sleep)

      4.times { limiter.acquire }

      expect(limiter).to receive(:sleep).with(a_value > 0)
      limiter.acquire
    end

    it 'does not sleep when enough time has passed' do
      limiter = described_class.new(max_requests: 4)

      4.times { limiter.acquire }

      allow(Process).to receive(:clock_gettime)
        .with(Process::CLOCK_MONOTONIC)
        .and_return(Time.now.to_f + 61)

      expect(limiter).not_to receive(:sleep)
      limiter.acquire
    end

    it 'sleeps exactly until the oldest timestamp leaves the window' do
      limiter = described_class.new(max_requests: 4, window: 60.0)
      clock = 100.0
      allow(Process).to receive(:clock_gettime)
        .with(Process::CLOCK_MONOTONIC) { clock }
      slept = nil
      allow(limiter).to receive(:sleep) { |duration| slept = duration }

      4.times { limiter.acquire } # all at t=100
      clock = 130.0
      limiter.acquire

      # Oldest request at t=100 leaves the 60s window at t=160; at t=130
      # that is 30s away.
      expect(slept).to eq(30.0)
    end

    it 'is thread-safe: no acquire is lost under concurrency' do
      limiter = described_class.new(max_requests: 1000, window: 600.0)
      allow(limiter).to receive(:sleep)

      threads = 10.times.map do
        Thread.new { 10.times { limiter.acquire } }
      end
      threads.each(&:join)

      # Unsynchronized Array#<< under contention loses updates; every one of
      # the 100 acquires must be recorded.
      timestamps = limiter.instance_variable_get(:@timestamps)
      expect(timestamps.length).to eq(100)
      expect(limiter).not_to have_received(:sleep)
    end
  end

  describe '#acquire with enabled: false' do
    it 'skips rate limiting entirely' do
      limiter = described_class.new(max_requests: 1, enabled: false)

      expect(limiter).not_to receive(:sleep)
      10.times { limiter.acquire }
    end
  end

  describe 'custom window' do
    it 'uses the provided window duration' do
      limiter = described_class.new(max_requests: 2, window: 1.0)
      expect(limiter.window).to eq(1.0)

      allow(limiter).to receive(:sleep)
      2.times { limiter.acquire }

      expect(limiter).to receive(:sleep).with(a_value > 0)
      limiter.acquire
    end

    it 'allows requests after custom window expires' do
      limiter = described_class.new(max_requests: 2, window: 1.0)

      2.times { limiter.acquire }

      allow(Process).to receive(:clock_gettime)
        .with(Process::CLOCK_MONOTONIC)
        .and_return(Time.now.to_f + 1.1)

      expect(limiter).not_to receive(:sleep)
      limiter.acquire
    end
  end

  describe '.for_current_user' do
    it 'returns 12/min limiter' do
      limiter = described_class.for_current_user
      expect(limiter.max_requests).to eq(12)
    end
  end
end
