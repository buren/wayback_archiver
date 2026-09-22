require 'spec_helper'

RSpec.describe WaybackArchiver::Response do
  describe '#success?' do
    it 'returns true for 200' do
      response = described_class.new('200', 'OK', 'body', 'http://example.com')
      expect(response.success?).to eq(true)
    end

    it 'returns true for other 2xx codes' do
      response = described_class.new('201', 'Created', '', 'http://example.com')
      expect(response.success?).to eq(true)
    end

    it 'returns false for 4xx' do
      response = described_class.new('404', 'Not Found', '', 'http://example.com')
      expect(response.success?).to eq(false)
    end

    it 'returns false for 5xx' do
      response = described_class.new('500', 'Internal Server Error', '', 'http://example.com')
      expect(response.success?).to eq(false)
    end

    it 'returns false for 3xx' do
      response = described_class.new('301', 'Moved', '', 'http://example.com')
      expect(response.success?).to eq(false)
    end

    it 'returns false for nil code' do
      response = described_class.new(nil, nil, nil, nil)
      expect(response.success?).to eq(false)
    end
  end

  describe 'struct fields' do
    it 'exposes code, message, body, uri, and error' do
      error = StandardError.new('boom')
      response = described_class.new('500', 'Error', 'body', 'http://example.com', error)

      expect(response.code).to eq('500')
      expect(response.message).to eq('Error')
      expect(response.body).to eq('body')
      expect(response.uri).to eq('http://example.com')
      expect(response.error).to eq(error)
    end
  end
end
