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

  describe '::crawl with respect_robots_txt' do
    after { WaybackArchiver.config.respect_robots_txt = WaybackArchiver::DEFAULT_RESPECT_ROBOTS_TXT }

    # Regression: deleting the vendored lib/robots.rb in v2 left Spidr's
    # robots: true option without the Robots constant it requires, so enabling
    # respect_robots_txt raised ArgumentError at crawl start.
    it 'crawls politely, skipping robots.txt-disallowed paths' do
      WaybackArchiver.config.respect_robots_txt = true

      robots_txt = "User-agent: *\nDisallow: /private\n"
      html_page = <<-HTML
      <!DOCTYPE html>
      <html>
        <head><title>Testing</title></head>
        <body>
          <a href="http://example.com/public">Public</a>
          <a href="http://example.com/private">Private</a>
        </body>
      </html>
      HTML
      response_headers = { 'Content-Type' => 'text/html; charset=utf-8' }

      # The robots gem only honors robots.txt when status is exactly ["200", "OK"]
      # and content type is text/plain; anything else falls back to allow-all.
      stub_request(:get, 'http://example.com/robots.txt')
        .to_return(status: [200, 'OK'], body: robots_txt, headers: { 'Content-Type' => 'text/plain' })
      stub_request(:get, 'http://example.com/')
        .to_return(status: 200, body: html_page, headers: response_headers)
      stub_request(:get, 'http://example.com/public')
        .to_return(status: 200, body: '', headers: response_headers)
      # Deliberately no stub for /private — fetching it would raise via WebMock

      found = described_class.crawl('http://example.com')

      expect(found).to include('http://example.com/public')
      expect(found).not_to include('http://example.com/private')
      expect(a_request(:get, 'http://example.com/private')).not_to have_been_made
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

    it 'skips non-archivable assets like images, CSS, and JS' do
      html_page = <<-HTML
      <!DOCTYPE html>
      <html>
        <head>
          <title>Testing</title>
          <link rel="stylesheet" href="http://example.com/style.css">
          <script src="http://example.com/app.js"></script>
        </head>
        <body>
          <a href="http://example.com/about">About</a>
          <a href="http://example.com/doc.pdf">PDF</a>
          <img src="http://example.com/logo.png">
        </body>
      </html>
      HTML

      response_headers = { 'Content-Type' => 'text/html; charset=utf-8' }

      stub_request(:get, 'http://example.com/robots.txt')
        .to_return(status: 200, body: '', headers: {})
      stub_request(:get, 'http://example.com/')
        .to_return(status: 200, body: html_page, headers: response_headers)
      stub_request(:get, 'http://example.com/about')
        .to_return(status: 200, body: '', headers: response_headers)
      stub_request(:get, 'http://example.com/doc.pdf')
        .to_return(status: 200, body: '%PDF-1.4', headers: { 'Content-Type' => 'application/pdf' })
      stub_request(:get, 'http://example.com/style.css')
        .to_return(status: 200, body: 'body{}', headers: { 'Content-Type' => 'text/css' })
      stub_request(:get, 'http://example.com/app.js')
        .to_return(status: 200, body: 'var x=1', headers: { 'Content-Type' => 'application/javascript' })
      stub_request(:get, 'http://example.com/logo.png')
        .to_return(status: 200, body: "\x89PNG", headers: { 'Content-Type' => 'image/png' })

      found_urls = described_class.crawl('http://example.com')

      expect(found_urls).to include('http://example.com')
      expect(found_urls).to include('http://example.com/about')
      expect(found_urls).to include('http://example.com/doc.pdf')
      expect(found_urls).not_to include('http://example.com/style.css')
      expect(found_urls).not_to include('http://example.com/app.js')
      expect(found_urls).not_to include('http://example.com/logo.png')
    end

    it 'skips pages with non-success HTTP status codes' do
      html_page = <<-HTML
      <!DOCTYPE html>
      <html>
        <head><title>Testing</title></head>
        <body>
          <a href="http://example.com/found">OK page</a>
          <a href="http://example.com/missing">Missing page</a>
          <a href="http://example.com/error">Error page</a>
        </body>
      </html>
      HTML

      response_headers = { 'Content-Type' => 'text/html; charset=utf-8' }

      stub_request(:get, 'http://example.com/robots.txt')
        .to_return(status: 200, body: '', headers: {})
      stub_request(:get, 'http://example.com/')
        .to_return(status: 200, body: html_page, headers: response_headers)
      stub_request(:get, 'http://example.com/found')
        .to_return(status: 200, body: '', headers: response_headers)
      stub_request(:get, 'http://example.com/missing')
        .to_return(status: 404, body: 'Not Found', headers: response_headers)
      stub_request(:get, 'http://example.com/error')
        .to_return(status: 500, body: 'Server Error', headers: response_headers)

      found_urls = described_class.crawl('http://example.com')

      expect(found_urls).to include('http://example.com')
      expect(found_urls).to include('http://example.com/found')
      expect(found_urls).not_to include('http://example.com/missing')
      expect(found_urls).not_to include('http://example.com/error')
    end

    describe 'duplicate content detection' do
      let(:response_headers) { { 'Content-Type' => 'text/html; charset=utf-8' } }

      before do
        stub_request(:get, 'http://example.com/robots.txt')
          .to_return(status: 200, body: '', headers: {})
      end

      it 'skips pages with same path and same body content' do
        same_body = '<html><body>Same content</body></html>'
        root_page = <<-HTML
        <html><body>
          <a href="http://example.com/page">Page</a>
          <a href="http://example.com/page?p=1">Page 1</a>
          <a href="http://example.com/page?p=2">Page 2</a>
        </body></html>
        HTML

        stub_request(:get, 'http://example.com/')
          .to_return(status: 200, body: root_page, headers: response_headers)
        stub_request(:get, 'http://example.com/page')
          .to_return(status: 200, body: same_body, headers: response_headers)
        stub_request(:get, 'http://example.com/page?p=1')
          .to_return(status: 200, body: same_body, headers: response_headers)
        stub_request(:get, 'http://example.com/page?p=2')
          .to_return(status: 200, body: same_body, headers: response_headers)

        found_urls = described_class.crawl('http://example.com')

        expect(found_urls).to include('http://example.com')
        expect(found_urls).to include('http://example.com/page')
        expect(found_urls).not_to include('http://example.com/page?p=1')
        expect(found_urls).not_to include('http://example.com/page?p=2')
      end

      it 'keeps pages with same path but different body content' do
        root_page = <<-HTML
        <html><body>
          <a href="http://example.com/page">Page</a>
          <a href="http://example.com/page?p=2">Page 2</a>
        </body></html>
        HTML

        stub_request(:get, 'http://example.com/')
          .to_return(status: 200, body: root_page, headers: response_headers)
        stub_request(:get, 'http://example.com/page')
          .to_return(status: 200, body: '<html><body>Page one content</body></html>', headers: response_headers)
        stub_request(:get, 'http://example.com/page?p=2')
          .to_return(status: 200, body: '<html><body>Page two content</body></html>', headers: response_headers)

        found_urls = described_class.crawl('http://example.com')

        expect(found_urls).to include('http://example.com/page')
        expect(found_urls).to include('http://example.com/page?p=2')
      end

      it 'keeps pages with different paths but same body content' do
        same_body = '<html><body>Same content</body></html>'
        root_page = <<-HTML
        <html><body>
          <a href="http://example.com/about">About</a>
          <a href="http://example.com/contact">Contact</a>
        </body></html>
        HTML

        stub_request(:get, 'http://example.com/')
          .to_return(status: 200, body: root_page, headers: response_headers)
        stub_request(:get, 'http://example.com/about')
          .to_return(status: 200, body: same_body, headers: response_headers)
        stub_request(:get, 'http://example.com/contact')
          .to_return(status: 200, body: same_body, headers: response_headers)

        found_urls = described_class.crawl('http://example.com')

        expect(found_urls).to include('http://example.com/about')
        expect(found_urls).to include('http://example.com/contact')
      end

      it 'fires on_duplicate_skipped listener event for skipped URLs' do
        same_body = '<html><body>Same content</body></html>'
        root_page = <<-HTML
        <html><body>
          <a href="http://example.com/page">Page</a>
          <a href="http://example.com/page?p=1">Page 1</a>
        </body></html>
        HTML

        stub_request(:get, 'http://example.com/')
          .to_return(status: 200, body: root_page, headers: response_headers)
        stub_request(:get, 'http://example.com/page')
          .to_return(status: 200, body: same_body, headers: response_headers)
        stub_request(:get, 'http://example.com/page?p=1')
          .to_return(status: 200, body: same_body, headers: response_headers)

        listener = instance_double(WaybackArchiver::NullListener)
        allow(listener).to receive(:on_duplicate_skipped)
        allow(WaybackArchiver).to receive(:listener).and_return(listener)

        described_class.crawl('http://example.com')

        expect(listener).to have_received(:on_duplicate_skipped).with(url: 'http://example.com/page?p=1')
      end

      it 'does not deduplicate when skip_duplicates is false' do
        same_body = '<html><body>Same content</body></html>'
        root_page = <<-HTML
        <html><body>
          <a href="http://example.com/page">Page</a>
          <a href="http://example.com/page?p=1">Page 1</a>
        </body></html>
        HTML

        stub_request(:get, 'http://example.com/')
          .to_return(status: 200, body: root_page, headers: response_headers)
        stub_request(:get, 'http://example.com/page')
          .to_return(status: 200, body: same_body, headers: response_headers)
        stub_request(:get, 'http://example.com/page?p=1')
          .to_return(status: 200, body: same_body, headers: response_headers)

        found_urls = described_class.crawl('http://example.com', skip_duplicates: false)

        expect(found_urls).to include('http://example.com/page')
        expect(found_urls).to include('http://example.com/page?p=1')
      end
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
