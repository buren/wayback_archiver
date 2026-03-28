require 'spec_helper'

RSpec.describe WaybackArchiver::Retry do
  before do
    allow(described_class).to receive(:sleep)
  end

  describe '.with_backoff' do
    it 'returns the block result on success' do
      result = described_class.with_backoff { 'ok' }
      expect(result).to eq('ok')
    end

    it 'retries on RetryableError and succeeds' do
      attempts = 0
      result = described_class.with_backoff(max_retries: 3) do
        attempts += 1
        raise WaybackArchiver::RetryableError, 'rate limited' if attempts < 2
        'ok'
      end

      expect(result).to eq('ok')
      expect(attempts).to eq(2)
    end

    it 'raises after exhausting max retries' do
      expect do
        described_class.with_backoff(max_retries: 2) do
          raise WaybackArchiver::RetryableError, 'always fails'
        end
      end.to raise_error(WaybackArchiver::RetryableError, 'always fails')
    end

    it 'does not retry non-RetryableError exceptions' do
      attempts = 0
      expect do
        described_class.with_backoff(max_retries: 3) do
          attempts += 1
          raise StandardError, 'not retryable'
        end
      end.to raise_error(StandardError, 'not retryable')

      expect(attempts).to eq(1)
    end

    it 'sleeps with exponential backoff between retries' do
      delays = []
      allow(described_class).to receive(:sleep) { |d| delays << d }

      expect do
        described_class.with_backoff(max_retries: 3, base_delay: 2, max_delay: 60) do
          raise WaybackArchiver::RetryableError, 'fail'
        end
      end.to raise_error(WaybackArchiver::RetryableError)

      # 3 retries = 3 sleeps: ~2s, ~4s, ~8s (with jitter)
      expect(delays.length).to eq(3)
      expect(delays[0]).to be_between(2, 2.3)
      expect(delays[1]).to be_between(4, 4.5)
      expect(delays[2]).to be_between(8, 8.9)
    end

    it 'caps delay at max_delay' do
      delays = []
      allow(described_class).to receive(:sleep) { |d| delays << d }

      expect do
        described_class.with_backoff(max_retries: 5, base_delay: 10, max_delay: 20) do
          raise WaybackArchiver::RetryableError, 'fail'
        end
      end.to raise_error(WaybackArchiver::RetryableError)

      # base_delay * 2^4 = 160, but capped at 20
      delays.each { |d| expect(d).to be <= 22 } # 20 + max jitter
    end
  end
end
