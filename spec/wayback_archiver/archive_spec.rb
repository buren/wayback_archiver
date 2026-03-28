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

    it 'returns ALL results including errored ones' do
      success = WaybackArchiver::ArchiveResult.new('http://ok.com')
      failure = WaybackArchiver::ArchiveResult.new('http://fail.com', error: StandardError.new('boom'))

      call_count = 0
      allow(described_class).to receive(:post_url) do
        call_count += 1
        call_count == 1 ? success : failure
      end

      results = described_class.post(%w[http://ok.com http://fail.com])

      expect(results.length).to eq(2)
      expect(results.map(&:uri)).to contain_exactly('http://ok.com', 'http://fail.com')
    end

    it 'passes **options through to post_url' do
      allow(described_class).to receive(:post_url).and_return(WaybackArchiver::ArchiveResult.new(nil))

      described_class.post(%w[https://example.com], capture_all: true, js_behavior_timeout: 10)

      expect(described_class).to have_received(:post_url).with('https://example.com', capture_all: true, js_behavior_timeout: 10)
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
    it 'delegates to the configured adapter' do
      url = 'https://example.com'
      expected_result = WaybackArchiver::ArchiveResult.new(url, job_id: 'test-123', timestamp: '20260326120000')

      allow(WaybackArchiver::WaybackMachine).to receive(:call).and_return(expected_result)

      result = described_class.post_url(url)

      expect(result).to eq(expected_result)
      expect(WaybackArchiver::WaybackMachine).to have_received(:call).with(url)
    end

    it 'passes kwargs to adapter when adapter accepts them' do
      url = 'https://example.com'
      expected_result = WaybackArchiver::ArchiveResult.new(url)

      allow(WaybackArchiver::WaybackMachine).to receive(:call).and_return(expected_result)

      described_class.post_url(url, capture_all: true)

      expect(WaybackArchiver::WaybackMachine).to have_received(:call).with(url, capture_all: true)
    end

    it 'calls adapter without kwargs when adapter does not accept them' do
      url = 'https://example.com'
      simple_adapter = ->(u) { WaybackArchiver::ArchiveResult.new(u) }

      WaybackArchiver.adapter = simple_adapter

      result = described_class.post_url(url, capture_all: true)

      expect(result.uri).to eq(url)
    ensure
      WaybackArchiver.adapter = WaybackArchiver::WaybackMachine
    end

    it 'returns ArchiveResult with error when adapter fails' do
      url = 'https://example.com'
      error_result = WaybackArchiver::ArchiveResult.new(url, error: StandardError.new('boom'))

      allow(WaybackArchiver::WaybackMachine).to receive(:call).and_return(error_result)

      result = described_class.post_url(url)

      expect(result.uri).to eq(url)
      expect(result.errored?).to eq(true)
    end
  end
end
