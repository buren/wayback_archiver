require 'spec_helper'
require 'wayback_archiver/cdx'

RSpec.describe WaybackArchiver::CDX do
  let(:cdx_url) { 'https://web.archive.org/cdx/search/cdx' }

  before do
    described_class.instance_variable_set(
      :@rate_limiter,
      WaybackArchiver::RateLimiter.new(max_requests: 999, enabled: false)
    )
  end

  def cdx_json_response(timestamp: '20260326120000', url: 'http://example.com')
    [
      %w[urlkey timestamp original mimetype statuscode digest length],
      ["com,example)/", timestamp, url, "text/html", "200", "ABC123", "1234"]
    ].to_json
  end

  describe '.check' do
    it 'returns archived CheckResult when CDX has a match' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .to_return(status: 200, body: cdx_json_response)

      result = described_class.check('http://example.com')

      expect(result).to be_a(WaybackArchiver::CheckResult)
      expect(result.archived?).to eq(true)
      expect(result.timestamp).to eq('20260326120000')
      expect(result.url).to eq('http://example.com')
    end

    it 'returns not-archived CheckResult when CDX returns empty' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .to_return(status: 200, body: '[]')

      result = described_class.check('http://nonexistent.com')

      expect(result.archived?).to eq(false)
      expect(result.timestamp).to be_nil
    end

    it 'returns not-archived CheckResult on empty body' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .to_return(status: 200, body: '')

      result = described_class.check('http://nonexistent.com')

      expect(result.archived?).to eq(false)
    end

    it 'returns not-archived CheckResult on CDX error' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .to_raise(Timeout::Error)

      result = described_class.check('http://example.com')

      expect(result.archived?).to eq(false)
      expect(result.error).to be_a(WaybackArchiver::Request::ServerError)
    end

    it 'includes from parameter when specified' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}.*from=20260301/)
        .to_return(status: 200, body: cdx_json_response)

      result = described_class.check('http://example.com', from: '20260301000000')

      expect(result.archived?).to eq(true)
    end

    it 'does not include from parameter when nil' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .with { |req| !req.uri.query.include?('from=') }
        .to_return(status: 200, body: cdx_json_response)

      described_class.check('http://example.com')
    end

    it 'escapes URL in query parameter' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .with { |req| req.uri.to_s.include?('url=http') }
        .to_return(status: 200, body: '[]')

      result = described_class.check('http://example.com/path?q=1')
      expect(result).to be_a(WaybackArchiver::CheckResult)
    end
  end

  describe '.check_urls' do
    it 'checks multiple URLs and returns results' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .to_return(status: 200, body: cdx_json_response)

      results = described_class.check_urls(
        ['http://a.com', 'http://b.com'],
        concurrency: 1
      )

      expect(results.length).to eq(2)
      expect(results).to all(be_a(WaybackArchiver::CheckResult))
    end

    it 'yields each result as it completes' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .to_return(status: 200, body: cdx_json_response)

      yielded = []
      described_class.check_urls(['http://a.com', 'http://b.com'], concurrency: 1) do |result|
        yielded << result
      end

      expect(yielded.length).to eq(2)
    end

    it 'passes from parameter to each check' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}.*from=20260301/)
        .to_return(status: 200, body: cdx_json_response)

      results = described_class.check_urls(
        ['http://example.com'],
        concurrency: 1,
        from: '20260301000000'
      )

      expect(results.first.archived?).to eq(true)
    end
  end
end
