require 'spec_helper'

RSpec.describe WaybackArchiver::FeedParser do
  let(:rss_xml) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0">
        <channel>
          <title>Example Blog</title>
          <link>http://example.com</link>
          <item>
            <title>First Post</title>
            <link>http://example.com/post/1</link>
          </item>
          <item>
            <title>Second Post</title>
            <link>http://example.com/post/2</link>
          </item>
        </channel>
      </rss>
    XML
  end

  let(:atom_xml) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <feed xmlns="http://www.w3.org/2005/Atom">
        <title>Example Blog</title>
        <link href="http://example.com"/>
        <link href="http://example.com/feed.atom" rel="self"/>
        <entry>
          <title>First Post</title>
          <link href="http://example.com/post/1"/>
        </entry>
        <entry>
          <title>Second Post</title>
          <link rel="alternate" href="http://example.com/post/2"/>
        </entry>
        <entry>
          <title>Edit Only</title>
          <link rel="edit" href="http://example.com/post/3/edit"/>
        </entry>
      </feed>
    XML
  end

  describe '.urls' do
    context 'with RSS feed' do
      it 'extracts item URLs' do
        urls = described_class.urls(xml: rss_xml)
        expect(urls).to eq(%w[http://example.com/post/1 http://example.com/post/2])
      end
    end

    context 'with Atom feed' do
      it 'extracts entry URLs with default or alternate rel' do
        urls = described_class.urls(xml: atom_xml)
        expect(urls).to eq(%w[http://example.com/post/1 http://example.com/post/2])
      end

      it 'skips entries with only non-alternate links' do
        urls = described_class.urls(xml: atom_xml)
        expect(urls).not_to include('http://example.com/post/3/edit')
      end
    end

    context 'with a URL' do
      it 'fetches the feed and extracts URLs' do
        stub_request(:get, 'http://example.com/feed.xml')
          .to_return(status: 200, body: rss_xml)

        urls = described_class.urls(url: 'http://example.com/feed.xml')
        expect(urls).to eq(%w[http://example.com/post/1 http://example.com/post/2])
      end
    end

    context 'with neither url nor xml' do
      it 'raises ArgumentError' do
        expect { described_class.urls }.to raise_error(ArgumentError, /must provide either/)
      end
    end

    context 'with unparseable XML' do
      it 'returns an empty array' do
        urls = described_class.urls(xml: 'not xml at all')
        expect(urls).to eq([])
      end
    end

    context 'with an empty feed' do
      it 'returns an empty array for RSS' do
        xml = <<~XML
          <?xml version="1.0"?>
          <rss version="2.0"><channel><title>Empty</title></channel></rss>
        XML
        expect(described_class.urls(xml: xml)).to eq([])
      end

      it 'returns an empty array for Atom' do
        xml = <<~XML
          <?xml version="1.0"?>
          <feed xmlns="http://www.w3.org/2005/Atom"><title>Empty</title></feed>
        XML
        expect(described_class.urls(xml: xml)).to eq([])
      end
    end

    context 'with an unrecognized feed type' do
      it 'returns an empty array' do
        allow(RSS::Parser).to receive(:parse).and_return(Object.new)
        expect(described_class.urls(xml: 'anything')).to eq([])
      end
    end

    context 'with items missing links' do
      it 'skips items without a link' do
        xml = <<~XML
          <?xml version="1.0"?>
          <rss version="2.0">
            <channel>
              <item><title>No link</title></item>
              <item><title>Has link</title><link>http://example.com/post/1</link></item>
            </channel>
          </rss>
        XML
        expect(described_class.urls(xml: xml)).to eq(%w[http://example.com/post/1])
      end
    end
  end

  describe '.autodiscover' do
    let(:base_url) { 'http://example.com' }

    before do
      # Stub all common feed paths to 404 by default
      described_class::COMMON_FEED_PATHS.each do |path|
        stub_request(:get, "#{base_url}/#{path}")
          .to_return(status: 404, body: 'Not Found')
      end
    end

    it 'returns URLs when a common feed path returns a valid feed' do
      stub_request(:get, "#{base_url}/feed.xml")
        .to_return(status: 200, body: rss_xml)

      urls = described_class.autodiscover(base_url)
      expect(urls).to eq(%w[http://example.com/post/1 http://example.com/post/2])
    end

    it 'returns URLs from an HTML link-discovered feed' do
      html = '<html><head><link rel="alternate" type="application/rss+xml" href="/my-feed.xml"></head></html>'
      stub_request(:get, "#{base_url}/my-feed.xml")
        .to_return(status: 200, body: rss_xml)

      urls = described_class.autodiscover(base_url, html: html)
      expect(urls).to eq(%w[http://example.com/post/1 http://example.com/post/2])
    end

    it 'tries HTML-discovered feeds before common paths' do
      other_rss = <<~XML
        <?xml version="1.0"?>
        <rss version="2.0"><channel>
          <item><title>Other</title><link>http://example.com/other</link></item>
        </channel></rss>
      XML

      html = '<link rel="alternate" type="application/rss+xml" href="/custom-feed">'
      stub_request(:get, "#{base_url}/custom-feed")
        .to_return(status: 200, body: rss_xml)
      stub_request(:get, "#{base_url}/feed")
        .to_return(status: 200, body: other_rss)

      urls = described_class.autodiscover(base_url, html: html)
      expect(urls).to eq(%w[http://example.com/post/1 http://example.com/post/2])
    end

    it 'returns empty array when no feeds found' do
      urls = described_class.autodiscover(base_url)
      expect(urls).to eq([])
    end

    it 'returns empty array on Request::Error' do
      allow(WaybackArchiver::Request).to receive(:get)
        .and_raise(WaybackArchiver::Request::ServerError, 'connection failed')

      urls = described_class.autodiscover(base_url)
      expect(urls).to eq([])
    end

    it 'resolves relative hrefs in HTML link tags' do
      html = '<link rel="alternate" type="application/atom+xml" href="/blog/feed.xml">'
      stub_request(:get, "#{base_url}/blog/feed.xml")
        .to_return(status: 200, body: atom_xml)

      urls = described_class.autodiscover(base_url, html: html)
      expect(urls).to eq(%w[http://example.com/post/1 http://example.com/post/2])
    end

    it 'deduplicates HTML and common path candidates' do
      html = '<link rel="alternate" type="application/rss+xml" href="/feed.xml">'
      stub_request(:get, "#{base_url}/feed.xml")
        .to_return(status: 200, body: rss_xml)

      described_class.autodiscover(base_url, html: html)

      # feed.xml appears in both HTML and common paths — should only be requested once
      expect(WebMock).to have_requested(:get, "#{base_url}/feed.xml").once
    end

    it 'skips feeds that return success but have no items' do
      empty_rss = <<~XML
        <?xml version="1.0"?>
        <rss version="2.0"><channel><title>Empty</title></channel></rss>
      XML
      stub_request(:get, "#{base_url}/feed")
        .to_return(status: 200, body: empty_rss)
      stub_request(:get, "#{base_url}/feed.xml")
        .to_return(status: 200, body: rss_xml)

      urls = described_class.autodiscover(base_url)
      expect(urls).to eq(%w[http://example.com/post/1 http://example.com/post/2])
    end

    it 'handles HTML with no feed links gracefully' do
      html = '<html><head><title>No feeds</title></head><body></body></html>'
      urls = described_class.autodiscover(base_url, html: html)
      expect(urls).to eq([])
    end

    it 'skips HTML link tags with invalid URIs' do
      html = '<link rel="alternate" type="application/rss+xml" href="ht tp://bad url">'
      urls = described_class.autodiscover(base_url, html: html)
      expect(urls).to eq([])
    end
  end
end
