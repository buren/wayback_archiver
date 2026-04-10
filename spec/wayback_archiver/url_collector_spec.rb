require 'spec_helper'

RSpec.describe WaybackArchiver::URLCollector do
  describe '::sitemap' do
    it 'calls Sitemapper::urls' do
      expected = %w[http://example.com]
      allow(WaybackArchiver::Sitemapper).to receive(:urls).and_return(expected)
      expect(described_class.sitemap('http://example.com')).to eq(expected)
    end
  end

  describe '::feed' do
    it 'calls FeedParser::urls' do
      expected = %w[http://example.com/post/1]
      allow(WaybackArchiver::FeedParser).to receive(:urls).and_return(expected)
      expect(described_class.feed('http://example.com/feed.xml')).to eq(expected)
    end
  end

  describe '::crawl (resolve_start_url error handling)' do
    it 'falls back to original URL when resolve_start_url raises Request::Error' do
      # resolve_start_url calls Request.get; if it raises, the original URL is used
      allow(WaybackArchiver::Request).to receive(:get)
        .with('http://dead.example.com', hash_including(:follow_redirects))
        .and_raise(WaybackArchiver::Request::ServerError, 'connection refused')

      html_page = '<html><head><title>Test</title></head><body></body></html>'
      response_headers = { 'Content-Type' => 'text/html; charset=utf-8' }

      stub_request(:get, 'http://dead.example.com/robots.txt')
        .to_return(status: 200, body: '', headers: {})
      stub_request(:get, 'http://dead.example.com/')
        .to_return(status: 200, body: html_page, headers: response_headers)

      found = described_class.crawl('http://dead.example.com')

      expect(found).to include('http://dead.example.com')
    end
  end

  describe '::crawl' do
    let(:headers) do
      {
        'Accept' => '*/*',
        'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
        'User-Agent' => WaybackArchiver.config.user_agent
      }
    end

    it 'can crawl' do
      html_page = <<-HTML
      <!DOCTYPE html>
      <html>
        <head>
          <meta charset="utf-8">
          <title>Testing</title>
        </head>
        <body>
          <a href="http://example.com/found">An URL</a>
        </body>
      </html>
      HTML

      response_headers = { 'Content-Type' => 'text/html; charset=utf-8' }

      stub_request(:get, 'http://example.com/robots.txt')
        .with(headers: headers)
        .to_return(status: 200, body: '', headers: {})

      stub_request(:get, 'http://example.com/')
        .with(headers: headers)
        .to_return(status: 200, body: html_page, headers: response_headers)

      stub_request(:get, 'http://example.com/found')
        .with(headers: headers)
        .to_return(status: 200, body: '', headers: response_headers)

      expected_urls = %w[http://example.com http://example.com/found]
      expected_urls_dup = expected_urls.dup
      found_urls = described_class.crawl('http://example.com') do |url|
        expect(url).to eq(expected_urls.shift)
      end

      expect(found_urls).to eq(expected_urls_dup)
    end

    it 'follows redirects to resolve the start URL before crawling' do
      html_page = <<-HTML
      <!DOCTYPE html>
      <html>
        <head><title>Testing</title></head>
        <body>
          <a href="https://www.example.com/about">About</a>
        </body>
      </html>
      HTML

      response_headers = { 'Content-Type' => 'text/html; charset=utf-8' }

      # resolve_start_url follows the redirect via Request.get
      stub_request(:get, 'http://example.com')
        .with(headers: headers)
        .to_return(status: 301, headers: { 'Location' => 'https://www.example.com' })

      stub_request(:get, 'https://www.example.com')
        .with(headers: headers)
        .to_return(status: 200, body: html_page, headers: response_headers)

      # Spidr crawl requests (Spidr uses its own HTTP client)
      stub_request(:get, 'https://www.example.com/robots.txt')
        .to_return(status: 200, body: '', headers: {})

      stub_request(:get, 'https://www.example.com/')
        .to_return(status: 200, body: html_page, headers: response_headers)

      stub_request(:get, 'https://www.example.com/about')
        .to_return(status: 200, body: '', headers: response_headers)

      found_urls = described_class.crawl('http://example.com')

      expect(found_urls).to include('https://www.example.com')
      expect(found_urls).to include('https://www.example.com/about')
    end

    it 'passes exts and ignore_exts through to Spidr' do
      stub_request(:get, 'http://example.com')
        .to_return(status: 200, body: '', headers: {})

      expect(Spidr).to receive(:site).with(
        'http://example.com',
        hash_including(exts: %w[html], ignore_exts: %w[pdf])
      ).and_yield(double(every_page: nil))

      described_class.crawl('http://example.com', exts: %w[html], ignore_exts: %w[pdf])
    end
  end
end
