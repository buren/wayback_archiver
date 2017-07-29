require 'spec_helper'

RSpec.describe WaybackArchiver::URLCollector do
  describe '::sitemap' do
    it 'calls Sitemapper::urls' do
      expected = %w[http://example.com]
      allow(WaybackArchiver::Sitemapper).to receive(:urls).and_return(expected)
      expect(described_class.sitemap('http://example.com')).to eq(expected)
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
  end
end
