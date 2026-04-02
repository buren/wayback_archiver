require 'spec_helper'
require 'wayback_archiver/check_result'

RSpec.describe WaybackArchiver::CheckResult do
  describe '#archived?' do
    it 'returns true when archived' do
      result = described_class.new('http://example.com', archived: true, timestamp: '20260326120000')
      expect(result.archived?).to eq(true)
    end

    it 'returns false when not archived' do
      result = described_class.new('http://example.com', archived: false)
      expect(result.archived?).to eq(false)
    end
  end

  describe '#wayback_url' do
    it 'returns wayback URL when timestamp is present' do
      result = described_class.new('http://example.com', archived: true, timestamp: '20260326120000')
      expect(result.wayback_url).to eq('https://web.archive.org/web/20260326120000/http://example.com')
    end

    it 'returns nil when timestamp is nil' do
      result = described_class.new('http://example.com', archived: false)
      expect(result.wayback_url).to be_nil
    end
  end

  describe '#url' do
    it 'returns the checked URL' do
      result = described_class.new('http://example.com', archived: false)
      expect(result.url).to eq('http://example.com')
    end
  end

  describe '#error' do
    it 'returns nil when no error' do
      result = described_class.new('http://example.com', archived: false)
      expect(result.error).to be_nil
    end

    it 'returns the error when CDX check failed' do
      error = StandardError.new('timeout')
      result = described_class.new('http://example.com', archived: false, error: error)
      expect(result.error).to eq(error)
    end
  end
end
