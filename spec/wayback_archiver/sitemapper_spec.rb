require 'spec_helper'

RSpec.describe WaybackArchiver::Sitemapper do
  let(:headers) do
    {
      'Accept' => '*/*',
      'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
      'User-Agent' => WaybackArchiver.config.user_agent
    }
  end

  let(:robots_txt) { File.read('spec/data/robots.txt') }
  let(:sitemap_index_xml) { File.read('spec/data/sitemap_index.xml') }
  let(:sitemap_index_with_duplicate_url_xml) { File.read('spec/data/sitemap_index_with_duplicate_url.xml') }
  let(:sitemap_xml) { File.read('spec/data/sitemap.xml') }

  describe '::autodiscover' do
    context 'with a URL missing the scheme' do
      it 'normalizes the URL before querying robots.txt' do
        stub_request(:get, 'http://www.example.com/robots.txt')
          .to_return(status: 200, body: robots_txt, headers: { 'Content-Type' => 'text/plain' })

        stub_request(:get, 'http://www.example.com/sitemap.xml')
          .with(headers: headers)
          .to_return(status: 200, body: sitemap_xml, headers: {})

        expect(described_class.autodiscover('www.example.com')).to eq(%w[http://www.example.com/])
      end
    end

    context 'with found Sitemap location in robots.txt' do
      it 'fetches those Sitemap(s) and returns all present URLs' do
        stub_request(:get, 'http://www.example.com/robots.txt')
          .to_return(status: 200, body: robots_txt, headers: { 'Content-Type' => 'text/plain' })

        stub_request(:get, 'http://www.example.com/sitemap.xml')
          .with(headers: headers)
          .to_return(status: 200, body: sitemap_xml, headers: {})

        expect(described_class.autodiscover('http://www.example.com')).to eq(%w[http://www.example.com/])
      end

      it 'returns empty list on request error' do
        stub_request(:get, 'http://www.example.com/robots.txt')
          .to_return(status: 200, body: robots_txt, headers: { 'Content-Type' => 'text/plain' })

        stub_request(:get, 'http://www.example.com/sitemap.xml')
          .to_raise(WaybackArchiver::Request::Error)

        expect(described_class.autodiscover('http://www.example.com')).to be_empty
      end
    end

    context 'with found Sitemap location among common Sitemap locations' do
      it 'returns all present URLs if a Sitemap is found' do
        base_url = 'http://www.example.com'
        stub_request(:get, "#{base_url}/robots.txt")
          .to_return(status: 200, body: "User-agent: *\nAllow: /\n", headers: { 'Content-Type' => 'text/plain' })

        sitemap_path = WaybackArchiver::Sitemapper::COMMON_SITEMAP_LOCATIONS.first

        stub_request(:get, [base_url, sitemap_path].join('/'))
          .with(headers: headers)
          .to_return(status: 200, body: sitemap_xml, headers: {})

        expect(described_class.autodiscover('http://www.example.com')).to eq(%w[http://www.example.com/])
      end
    end

    context 'when a network error occurs during common location probing' do
      it 'rescues Request::Error and returns empty array' do
        base_url = 'http://www.example.com'
        stub_request(:get, "#{base_url}/robots.txt")
          .to_return(status: 200, body: "User-agent: *\nAllow: /\n", headers: { 'Content-Type' => 'text/plain' })

        # First common location raises a network error
        allow(WaybackArchiver::Request).to receive(:get)
          .with(/sitemap/, anything)
          .and_raise(WaybackArchiver::Request::ServerError, 'connection reset')

        expect(described_class.autodiscover(base_url)).to eq([])
      end
    end

    context 'at the provided URL' do
      it 'returns all present URLs if a Sitemap is found' do
        base_url = 'http://www.example.com'
        stub_request(:get, "#{base_url}/robots.txt")
          .to_return(status: 200, body: "User-agent: *\nAllow: /\n", headers: { 'Content-Type' => 'text/plain' })

        WaybackArchiver::Sitemapper::COMMON_SITEMAP_LOCATIONS.each do |sitemap_path|
          stub_request(:get, [base_url, sitemap_path].join('/'))
            .with(headers: headers)
            .to_return(status: 404, body: '', headers: {})
        end

        stub_request(:get, base_url)
          .with(headers: headers)
          .to_return(status: 200, body: sitemap_xml, headers: {})

        expect(described_class.autodiscover(base_url)).to eq(%w[http://www.example.com/])
      end
    end
  end

  describe '::urls' do
    it 'can start with xml argument' do
      expect(described_class.urls(xml: sitemap_xml)).to eq(%w[http://www.example.com/])
    end

    it 'returns empty array if url already has been visited' do
      start_url = 'http://www.example.com/sitemap_index.xml'

      stub_request(:get, start_url)
        .with(headers: headers)
        .to_return(status: 200, body: sitemap_index_with_duplicate_url_xml, headers: {})

      %w[http://www.example.com/sitemap1.xml.gz].each do |url|
        stub_request(:get, url)
          .with(headers: headers)
          .to_return(status: 200, body: sitemap_xml, headers: {})
      end

      result = described_class.urls(url: start_url)
      expect(WaybackArchiver.logger.debug_log).to include("Already visited http://www.example.com/sitemap1.xml.gz skipping..")
      expect(result).to eq(%w[http://www.example.com/])
    end

    context 'with url argument and returned sitemap index' do
      it 'follows the index and returns all URLs sitemap(s)' do
        start_url = 'http://www.example.com/sitemap_index.xml'

        stub_request(:get, start_url)
          .with(headers: headers)
          .to_return(status: 200, body: sitemap_index_xml, headers: {})

        %w[http://www.example.com/sitemap1.xml.gz http://www.example.com/sitemap2.xml.gz].each do |url|
          stub_request(:get, url)
            .with(headers: headers)
            .to_return(status: 200, body: sitemap_xml, headers: {})
        end

        result = described_class.urls(url: start_url)
        expect(result).to eq(%w[http://www.example.com/ http://www.example.com/])
      end
    end

    context 'with url argument and returned sitemap' do
      it 'returns all URLs in sitemap' do
        stub_request(:get, 'http://www.example.com/sitemap.xml')
          .with(headers: headers)
          .to_return(status: 200, body: sitemap_xml, headers: {})

        result = described_class.urls(url: 'http://www.example.com/sitemap.xml')
        expect(result).to eq(%w[http://www.example.com/])
      end
    end

    # A network error must propagate: returning [] made 'site unreachable'
    # indistinguishable from 'empty sitemap' for library callers. The auto
    # cascade still falls back to crawl — autodiscover keeps its rescue.
    it 'raises on request error' do
      allow(WaybackArchiver::Request).to receive(:get).and_raise(WaybackArchiver::Request::Error)

      expect { described_class.urls(url: 'http://www.example.com') }
        .to raise_error(WaybackArchiver::Request::Error)
    end
  end

  describe 'unreachable sitemaps' do
    # Regression: a 404 body was parsed as empty XML and reported as
    # "0 URLs found", so a typo in --sitemap looked like a successful run.
    it 'raises when the sitemap URL returns an HTTP error' do
      stub_request(:get, 'http://example.com/sitemap.xml').to_return(status: 404, body: 'not found')

      expect { described_class.urls(url: 'http://example.com/sitemap.xml') }
        .to raise_error(WaybackArchiver::Request::ResponseError)
    end

    it 'skips an unreachable child of a sitemap index instead of failing the lot' do
      index = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <sitemap><loc>http://example.com/good.xml</loc></sitemap>
          <sitemap><loc>http://example.com/dead.xml</loc></sitemap>
        </sitemapindex>
      XML
      good = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>http://example.com/page</loc></url>
        </urlset>
      XML
      stub_request(:get, 'http://example.com/sitemap_index.xml').to_return(status: 200, body: index)
      stub_request(:get, 'http://example.com/good.xml').to_return(status: 200, body: good)
      stub_request(:get, 'http://example.com/dead.xml').to_return(status: 500, body: 'oops')

      expect(described_class.urls(url: 'http://example.com/sitemap_index.xml'))
        .to eq(%w[http://example.com/page])
    end

    it 'falls back to crawling when autodiscovery hits an unreachable sitemap' do
      stub_request(:get, 'http://example.com/robots.txt').to_return(status: 404, body: '')
      stub_request(:get, %r{http://example\.com/sitemap}).to_return(status: 404, body: '')
      stub_request(:get, 'http://example.com').to_return(status: 404, body: '')

      expect(described_class.autodiscover('http://example.com')).to eq([])
    end
  end

  describe 'sitemap validation' do
    let(:urlset) do
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>http://example.com/page</loc></url>
        </urlset>
      XML
    end
    let(:html) { "<!DOCTYPE html>\n<html><body>homepage</body></html>" }

    # Regression: a 200 that isn't a sitemap parsed as an empty document and
    # reported "0 URL(s) discovered" with exit 0, so a mistyped --sitemap
    # target looked like a successful run that archived nothing.
    it 'raises when the fetched document is not a sitemap' do
      stub_request(:get, 'http://example.com/').to_return(status: 200, body: html)

      expect { described_class.urls(url: 'http://example.com/') }
        .to raise_error(WaybackArchiver::Sitemapper::InvalidSitemapError, /not a sitemap/i)
    end

    it 'keeps probing common locations past a 200 that is not a sitemap' do
      stub_request(:get, 'http://example.com/robots.txt').to_return(status: 404, body: '')
      stub_request(:get, %r{http://example\.com/sitemap[_-]index\.xml(\.gz)?$})
        .to_return(status: 200, body: html) # SPA catch-all returns the homepage
      stub_request(:get, 'http://example.com/sitemap.xml.gz').to_return(status: 404, body: '')
      stub_request(:get, 'http://example.com/sitemap.xml').to_return(status: 200, body: urlset)

      expect(described_class.autodiscover('http://example.com'))
        .to eq(%w[http://example.com/page])
    end

    it 'falls back to crawling when no candidate is a real sitemap' do
      stub_request(:get, 'http://example.com/robots.txt').to_return(status: 404, body: '')
      stub_request(:get, %r{http://example\.com/sitemap}).to_return(status: 200, body: html)
      stub_request(:get, 'http://example.com').to_return(status: 200, body: html)

      expect(described_class.autodiscover('http://example.com')).to eq([])
    end

    it 'skips an index child that is not a sitemap' do
      index = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <sitemap><loc>http://example.com/good.xml</loc></sitemap>
          <sitemap><loc>http://example.com/bogus.xml</loc></sitemap>
        </sitemapindex>
      XML
      stub_request(:get, 'http://example.com/index.xml').to_return(status: 200, body: index)
      stub_request(:get, 'http://example.com/good.xml').to_return(status: 200, body: urlset)
      stub_request(:get, 'http://example.com/bogus.xml').to_return(status: 200, body: html)

      expect(described_class.urls(url: 'http://example.com/index.xml'))
        .to eq(%w[http://example.com/page])
    end
  end
end
