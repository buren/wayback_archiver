require 'spec_helper'
require 'wayback_archiver/error_codes'

RSpec.describe WaybackArchiver::ErrorCodes do
  describe 'REGISTRY' do
    it 'has 39 entries total' do
      expect(described_class::REGISTRY.size).to eq(39)
    end

    it 'has 17 transient entries' do
      count = described_class::REGISTRY.count { |_, v| v[:category] == :transient }
      expect(count).to eq(17)
    end

    it 'has 4 daily_limit entries' do
      count = described_class::REGISTRY.count { |_, v| v[:category] == :daily_limit }
      expect(count).to eq(4)
    end

    it 'has 18 permanent entries' do
      count = described_class::REGISTRY.count { |_, v| v[:category] == :permanent }
      expect(count).to eq(18)
    end

    it 'is frozen' do
      expect(described_class::REGISTRY).to be_frozen
    end

    it 'only uses valid categories' do
      categories = described_class::REGISTRY.values.map { |v| v[:category] }.uniq
      expect(categories).to all(satisfy { |c| described_class::CATEGORIES.include?(c) })
    end
  end

  describe '.category' do
    it 'returns :transient for a transient error' do
      expect(described_class.category('error:too-many-requests')).to eq(:transient)
    end

    it 'returns :transient for all original 6 retryable codes' do
      %w[
        error:too-many-requests error:user-session-limit error:service-unavailable
        error:cannot-fetch error:no-browsers-available error:celery
      ].each do |code|
        expect(described_class.category(code)).to eq(:transient), "Expected #{code} to be :transient"
      end
    end

    it 'returns :transient for newly added transient codes' do
      %w[
        error:proxy-error error:internal-server-error error:job-failed
        error:browsing-timeout error:gateway-timeout error:bad-gateway
      ].each do |code|
        expect(described_class.category(code)).to eq(:transient), "Expected #{code} to be :transient"
      end
    end

    it 'returns :daily_limit for a daily limit error' do
      expect(described_class.category('error:too-many-daily-captures')).to eq(:daily_limit)
    end

    it 'returns :permanent for a permanent error' do
      expect(described_class.category('error:blocked-url')).to eq(:permanent)
    end

    it 'returns :transient and warns for an unknown code' do
      expect(WaybackArchiver.logger).to receive(:warn).with(/Unknown SPN2 error code: error:new-thing/)
      expect(described_class.category('error:new-thing')).to eq(:transient)
    end

    it 'returns nil for nil input' do
      expect(described_class.category(nil)).to be_nil
    end
  end

  describe '.retryable?' do
    it 'returns true for transient errors' do
      expect(described_class.retryable?('error:celery')).to eq(true)
    end

    it 'returns false for daily_limit errors' do
      expect(described_class.retryable?('error:max-daily-bandwidth')).to eq(false)
    end

    it 'returns false for permanent errors' do
      expect(described_class.retryable?('error:invalid-url-syntax')).to eq(false)
    end

    it 'returns true for unknown codes' do
      allow(WaybackArchiver.logger).to receive(:warn)
      expect(described_class.retryable?('error:something-new')).to eq(true)
    end

    it 'returns false for nil' do
      expect(described_class.retryable?(nil)).to eq(false)
    end
  end

  describe '.message' do
    it 'returns human-readable message for a known code' do
      expect(described_class.message('error:blocked-url')).to eq('URL on block list (Mozilla web tracker lists)')
    end

    it 'returns the raw code for an unknown code' do
      allow(WaybackArchiver.logger).to receive(:warn)
      expect(described_class.message('error:mystery')).to eq('error:mystery')
    end

    it 'returns nil for nil input' do
      expect(described_class.message(nil)).to be_nil
    end
  end

  describe 'exhaustive REGISTRY validation' do
    described_class::REGISTRY.each do |code, entry|
      context code do
        it 'returns the correct category' do
          expect(described_class.category(code)).to eq(entry[:category])
        end

        it 'has a non-empty human-readable message' do
          expect(described_class.message(code)).to be_a(String)
          expect(described_class.message(code)).not_to be_empty
        end

        it "retryable? matches category == :transient" do
          expect(described_class.retryable?(code)).to eq(entry[:category] == :transient)
        end
      end
    end
  end
end
