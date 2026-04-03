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

  describe '::crawl' do
    let(:headers) do
      {
        'Accept' => '*/*',
        'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
        'User-Agent' => WaybackArchiver.user_agent
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
  end
end
