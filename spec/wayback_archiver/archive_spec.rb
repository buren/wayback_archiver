require 'spec_helper'
require 'tmpdir'

RSpec.describe WaybackArchiver::Archive do
  describe '::post (sequential fallback)' do
    # Use a simple adapter to test the sequential (non-batch) path
    let(:simple_adapter) { ->(u) { WaybackArchiver::ArchiveResult.new(u) } }

    before do
      WaybackArchiver.adapter = simple_adapter
    end

    after do
      WaybackArchiver.adapter = WaybackArchiver::WaybackMachine
    end

    it 'calls ::post_url for each URL' do
      allow(described_class).to receive(:post_url).and_return(WaybackArchiver::ArchiveResult.new(nil))

      described_class.post(%w[https://example.com https://example.com/path])

      expect(described_class).to have_received(:post_url).twice
    end

    it 'calls ::post_url for each URL with support for an max limit' do
      allow(described_class).to receive(:post_url).and_return(WaybackArchiver::ArchiveResult.new(nil))

      described_class.post(%w[https://example.com https://example.com/path], limit: 1)

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

  describe '::post (batch mode)' do
    let(:adapter) { WaybackArchiver::WaybackMachine }
    let(:job1) { 'job-aaa' }
    let(:job2) { 'job-bbb' }

    before do
      allow(described_class).to receive(:sleep)
    end

    it 'submits all URLs then batch-polls' do
      allow(adapter).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })
      allow(adapter).to receive(:submit)
        .with('http://b.com').and_return({ 'url' => 'http://b.com', 'job_id' => job2 })

      allow(adapter).to receive(:poll_statuses).and_return(
        job1 => { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' },
        job2 => { 'status' => 'success', 'job_id' => job2, 'timestamp' => '20260326120001', 'original_url' => 'http://b.com' }
      )

      results = described_class.post(%w[http://a.com http://b.com])

      expect(results.length).to eq(2)
      expect(results.map(&:job_id)).to contain_exactly(job1, job2)
      expect(results).to all(be_success)
    end

    it 'yields results as they complete during batch polling' do
      allow(adapter).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })
      allow(adapter).to receive(:submit)
        .with('http://b.com').and_return({ 'url' => 'http://b.com', 'job_id' => job2 })

      call_count = 0
      allow(adapter).to receive(:poll_statuses) do |_ids|
        call_count += 1
        if call_count == 1
          {
            job1 => { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' },
            job2 => { 'status' => 'pending', 'job_id' => job2 }
          }
        else
          {
            job2 => { 'status' => 'success', 'job_id' => job2, 'timestamp' => '20260326120001', 'original_url' => 'http://b.com' }
          }
        end
      end

      yielded = []
      described_class.post(%w[http://a.com http://b.com]) { |r| yielded << r }

      expect(yielded.length).to eq(2)
      expect(yielded.map(&:uri)).to contain_exactly('http://a.com', 'http://b.com')
    end

    it 'handles submit failures as immediate error results' do
      allow(adapter).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })
      allow(adapter).to receive(:submit)
        .with('http://bad.com').and_return(WaybackArchiver::ArchiveResult.new('http://bad.com', error: StandardError.new('fail')))

      allow(adapter).to receive(:poll_statuses).and_return(
        job1 => { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' }
      )

      results = described_class.post(%w[http://a.com http://bad.com])

      expect(results.length).to eq(2)
      expect(results.find { |r| r.uri == 'http://bad.com' }.errored?).to eq(true)
      expect(results.find { |r| r.uri == 'http://a.com' }.success?).to eq(true)
    end

    it 'times out pending jobs' do
      allow(adapter).to receive(:submit)
        .with('http://slow.com').and_return({ 'url' => 'http://slow.com', 'job_id' => job1 })

      allow(adapter).to receive(:poll_statuses).and_return(
        job1 => { 'status' => 'pending', 'job_id' => job1 }
      )

      start = 100.0
      allow(Process).to receive(:clock_gettime).and_return(start, start + 130)

      results = described_class.post(%w[http://slow.com])

      expect(results.length).to eq(1)
      expect(results.first.errored?).to eq(true)
      expect(results.first.error).to be_a(WaybackArchiver::WaybackMachine::PollTimeoutError)
    end

    it 'downloads screenshots in batch mode when screenshot_dir is provided' do
      Dir.mktmpdir do |dir|
        WaybackArchiver.access_key = 'key'
        WaybackArchiver.secret_key = 'secret'

        screenshot_url = 'http://web.archive.org/screenshot/http://a.com'
        png_data = "\x89PNG\r\n\x1a\nfake"

        allow(adapter).to receive(:submit)
          .with('http://a.com', capture_screenshot: true, screenshot_dir: dir)
          .and_return({ 'url' => 'http://a.com', 'job_id' => job1 })

        allow(adapter).to receive(:poll_statuses).and_return(
          job1 => {
            'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000',
            'original_url' => 'http://a.com', 'screenshot' => screenshot_url
          }
        )

        stub_request(:get, screenshot_url)
          .to_return(status: 200, body: png_data)

        results = described_class.post(
          %w[http://a.com],
          capture_screenshot: true, screenshot_dir: dir
        )

        expect(results.first.screenshot_url).to eq(screenshot_url)
        expect(results.first.screenshot_path).to be_a(String)
        expect(File.exist?(results.first.screenshot_path)).to eq(true)
      end
    end

    it 'handles submit response with missing job_id as error' do
      allow(adapter).to receive(:submit)
        .with('http://a.com').and_return({ 'message' => 'something unexpected' })

      results = described_class.post(%w[http://a.com])

      expect(results.length).to eq(1)
      expect(results.first.errored?).to eq(true)
      expect(results.first.error.message).to include('Missing job_id')
    end

    it 'falls back to per-URL call for adapters without submit' do
      simple_adapter = ->(u) { WaybackArchiver::ArchiveResult.new(u) }
      WaybackArchiver.adapter = simple_adapter
      results = described_class.post(%w[http://a.com])
      WaybackArchiver.adapter = WaybackArchiver::WaybackMachine

      expect(results.length).to eq(1)
      expect(results.first.uri).to eq('http://a.com')
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
      WaybackArchiver.adapter = WaybackArchiver::WaybackMachine

      expect(result.uri).to eq(url)
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
