require 'spec_helper'

RSpec.describe WaybackArchiver::Sitemapper do
  let(:headers) do
    {
      'Accept' => '*/*',
      'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
      'User-Agent' => WaybackArchiver.user_agent
    }
  end

  let(:robots_txt) { File.read('spec/data/robots.txt') }
  let(:sitemap_index_xml) { File.read('spec/data/sitemap_index.xml') }
  let(:sitemap_index_with_duplicate_url_xml) { File.read('spec/data/sitemap_index_with_duplicate_url.xml') }
  let(:sitemap_xml) { File.read('spec/data/sitemap.xml') }

  describe '::autodiscover' do
    context 'with found Sitemap location in robots.txt' do
      it 'fetches those Sitemap(s) and returns all present URLs' do
        # The robots gem doesn't play nice with the WebMock so we can't test this until
        # https://github.com/fizx/robots/pull/9 is merged.
        # Until then we're gonna use rspec-mocks
        # stub_request(:get, 'http://www.example.com/robots.txt').
        #   with(headers: headers).
        #   to_return(status: 200, body: robots_txt, headers: {})
        allow_any_instance_of(Robots).to receive(:other_values).and_return('Sitemap' => %w[http://www.example.com/sitemap.xml])

        stub_request(:get, 'http://www.example.com/sitemap.xml')
          .with(headers: headers)
          .to_return(status: 200, body: sitemap_xml, headers: {})

        expect(described_class.autodiscover('http://www.example.com')).to eq(%w[http://www.example.com/])
      end

      it 'returns empty list on request error' do
        allow_any_instance_of(Robots).to receive(:other_values).and_raise(WaybackArchiver::Request::Error)

        expect(described_class.autodiscover('http://www.example.com')).to be_empty
      end
    end

    context 'with found Sitemap location among common Sitemap locations' do
      it 'returns all present URLs if a Sitemap is found' do
        base_url = 'http://www.example.com'
        stub_request(:get, "#{base_url}/robots.txt")
          .with(headers: headers)
          .to_return(status: 200, body: robots_txt, headers: {})

        sitemap_path = WaybackArchiver::Sitemapper::COMMON_SITEMAP_LOCATIONS.first

        stub_request(:get, [base_url, sitemap_path].join('/'))
          .with(headers: headers)
          .to_return(status: 200, body: sitemap_xml, headers: {})

        expect(described_class.autodiscover('http://www.example.com')).to eq(%w[http://www.example.com/])
      end
    end

    context 'at the provided URL' do
      it 'returns all present URLs if a Sitemap is found' do
        base_url = 'http://www.example.com'
        stub_request(:get, "#{base_url}/robots.txt")
          .with(headers: headers)
          .to_return(status: 200, body: robots_txt, headers: {})

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

    it 'returns empty list on request error' do
      allow(WaybackArchiver::Request).to receive(:get).and_raise(WaybackArchiver::Request::Error)

      expect(described_class.urls(url: 'http://www.example.com')).to be_empty
    end
  end
end
