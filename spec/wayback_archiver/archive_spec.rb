require 'spec_helper'

RSpec.describe WaybackArchiver::Archive do
  let(:headers) do
    {
      'Accept' => '*/*',
      'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
      'User-Agent' => WaybackArchiver.user_agent
    }
  end

  describe '::post' do
    it 'calls ::post_url for each URL' do
      allow(described_class).to receive(:post_url).and_return(WaybackArchiver::ArchiveResult.new(nil))

      result = described_class.post(%w[https://example.com https://example.com/path])

      expect(described_class).to have_received(:post_url).twice
    end

    it 'calls ::post_url for each URL with support for an max limit' do
      allow(described_class).to receive(:post_url).and_return(WaybackArchiver::ArchiveResult.new(nil))

      result = described_class.post(%w[https://example.com https://example.com/path], limit: 1)

      expect(described_class).to have_received(:post_url).once
    end
  end

  describe '::crawl' do
    it 'calls URLCollector::crawl and ::post_url' do
      url = 'https://example.com'

      allow(WaybackArchiver::URLCollector).to receive(:crawl)
        .and_yield(url)
        .and_return([url])

      allow(described_class).to receive(:post_url).and_return(WaybackArchiver::ArchiveResult.new(url))

      expect(described_class.crawl(url)[0].uri).to eq(url)
    end
  end

  describe '::post_url' do
    it 'posts URL to the Wayback Machine' do
      url = 'https://example.com'
      expected_request_url = "https://web.archive.org/save/#{url}"

      stub_request(:get, expected_request_url)
        .with(headers: headers)
        .to_return(status: 301, body: 'buren', headers: {})

      result = described_class.post_url(url)

      expect(result.uri).to eq(url)
      expect(result.code).to eq('301')
      expect(WaybackArchiver.logger.debug_log.first).to include(expected_request_url)
      expect(WaybackArchiver.logger.info_log.last).to include(url)
    end

    it 'rescues and logs Request::ServerError' do
      allow(WaybackArchiver::Request).to receive(:get)
        .and_raise(WaybackArchiver::Request::MaxRedirectError, 'too many redirects')

      url = 'https://example.com'
      expected_request_url = "https://web.archive.org/save/#{url}"

      stub_request(:get, expected_request_url)
        .with(headers: headers)
        .to_return(status: 301, body: 'buren', headers: {})

      result = described_class.post_url(url)

      expect(result.uri).to eq(url)
      expect(result.response_error).to be_nil
      expect(result.request_url).to be_nil
      expect(result.error).to be_a(WaybackArchiver::Request::MaxRedirectError)

      last_error_log = WaybackArchiver.logger.error_log.last
      expect(last_error_log).to include(url)
      expect(last_error_log).to include('MaxRedirectError')
      expect(last_error_log).to include('too many redirects')
    end
  end
end
