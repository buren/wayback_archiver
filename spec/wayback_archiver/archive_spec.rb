require 'spec_helper'
require 'tmpdir'

RSpec.describe WaybackArchiver::Archive do
  describe '::post (sequential fallback)' do
    # Use a simple adapter to test the sequential (non-batch) path
    let(:simple_adapter) { ->(u) { WaybackArchiver::ArchiveResult.new(u) } }

    before do
      WaybackArchiver.config.adapter = simple_adapter
    end

    after do
      WaybackArchiver.config.adapter = WaybackArchiver::WaybackMachine
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

    it 'skips URLs in skip_urls' do
      allow(described_class).to receive(:post_url).and_return(WaybackArchiver::ArchiveResult.new(nil))

      skip = Set.new(['https://example.com'])
      described_class.post(%w[https://example.com https://example.com/path], skip_urls: skip)

      expect(described_class).to have_received(:post_url).once
      expect(described_class).to have_received(:post_url).with('https://example.com/path')
    end

    it 'does not skip anything when skip_urls is nil' do
      allow(described_class).to receive(:post_url).and_return(WaybackArchiver::ArchiveResult.new(nil))

      described_class.post(%w[https://example.com https://example.com/path], skip_urls: nil)

      expect(described_class).to have_received(:post_url).twice
    end

    describe 'extension filtering' do
      before do
        allow(described_class).to receive(:post_url).and_return(WaybackArchiver::ArchiveResult.new(nil))
      end

      it 'filters by include_ext' do
        urls = %w[http://a.com/doc.pdf http://a.com/page http://a.com/img.png]
        described_class.post(urls, include_ext: %w[pdf])

        expect(described_class).to have_received(:post_url).once
        expect(described_class).to have_received(:post_url).with('http://a.com/doc.pdf')
      end

      it 'filters by exclude_ext' do
        urls = %w[http://a.com/doc.pdf http://a.com/page http://a.com/img.png]
        described_class.post(urls, exclude_ext: %w[pdf png])

        expect(described_class).to have_received(:post_url).once
        expect(described_class).to have_received(:post_url).with('http://a.com/page')
      end

      it 'applies include_ext then exclude_ext' do
        urls = %w[http://a.com/a.pdf http://a.com/b.doc http://a.com/c.docx http://a.com/page]
        described_class.post(urls, include_ext: %w[pdf doc docx], exclude_ext: %w[docx])

        expect(described_class).to have_received(:post_url).twice
        expect(described_class).to have_received(:post_url).with('http://a.com/a.pdf')
        expect(described_class).to have_received(:post_url).with('http://a.com/b.doc')
      end

      it 'normalizes leading dots in extensions' do
        urls = %w[http://a.com/doc.pdf http://a.com/page]
        described_class.post(urls, include_ext: %w[.pdf])

        expect(described_class).to have_received(:post_url).once
        expect(described_class).to have_received(:post_url).with('http://a.com/doc.pdf')
      end

      it 'is case-insensitive' do
        urls = %w[http://a.com/doc.PDF http://a.com/page]
        described_class.post(urls, include_ext: %w[pdf])

        expect(described_class).to have_received(:post_url).once
        expect(described_class).to have_received(:post_url).with('http://a.com/doc.PDF')
      end

      it 'handles query strings and fragments' do
        urls = %w[http://a.com/doc.pdf?v=1 http://a.com/page#section]
        described_class.post(urls, include_ext: %w[pdf])

        expect(described_class).to have_received(:post_url).once
        expect(described_class).to have_received(:post_url).with('http://a.com/doc.pdf?v=1')
      end

      it 'does nothing when neither option is set' do
        urls = %w[http://a.com/doc.pdf http://a.com/page]
        described_class.post(urls)

        expect(described_class).to have_received(:post_url).twice
      end
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

    it 'skips URLs in skip_urls' do
      allow(WaybackArchiver::URLCollector).to receive(:crawl)
        .and_yield('http://a.com')
        .and_yield('http://b.com')
        .and_return(%w[http://a.com http://b.com])

      allow(described_class).to receive(:post_url).and_return(WaybackArchiver::ArchiveResult.new('http://b.com'))

      skip = Set.new(['http://a.com'])
      results = described_class.crawl('http://example.com', skip_urls: skip)

      expect(described_class).to have_received(:post_url).once
      expect(described_class).to have_received(:post_url).with('http://b.com')
    end

    it 'filters by include_ext' do
      allow(WaybackArchiver::URLCollector).to receive(:crawl)
        .and_yield('http://a.com/doc.pdf')
        .and_yield('http://a.com/page')
        .and_return(%w[http://a.com/doc.pdf http://a.com/page])

      allow(described_class).to receive(:post_url).and_return(WaybackArchiver::ArchiveResult.new(nil))

      described_class.crawl('http://a.com', include_ext: %w[pdf])

      expect(described_class).to have_received(:post_url).once
      expect(described_class).to have_received(:post_url).with('http://a.com/doc.pdf')
    end

    it 'filters by exclude_ext' do
      allow(WaybackArchiver::URLCollector).to receive(:crawl)
        .and_yield('http://a.com/doc.pdf')
        .and_yield('http://a.com/page')
        .and_return(%w[http://a.com/doc.pdf http://a.com/page])

      allow(described_class).to receive(:post_url).and_return(WaybackArchiver::ArchiveResult.new(nil))

      described_class.crawl('http://a.com', exclude_ext: %w[pdf])

      expect(described_class).to have_received(:post_url).once
      expect(described_class).to have_received(:post_url).with('http://a.com/page')
    end
  end

  describe '::post (batch mode)' do
    let(:adapter) { WaybackArchiver::WaybackMachine }
    let(:job1) { 'job-aaa' }
    let(:job2) { 'job-bbb' }

    before do
      allow(described_class).to receive(:sleep)
      allow(adapter).to receive(:check_user_status).and_return({ 'available' => 12, 'processing' => 0 })
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

      completed = yielded.reject(&:submitted?)
      expect(completed.length).to eq(2)
      expect(completed.map(&:uri)).to contain_exactly('http://a.com', 'http://b.com')
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

    it 'marks timed-out pending jobs as submitted' do
      allow(adapter).to receive(:submit)
        .with('http://slow.com').and_return({ 'url' => 'http://slow.com', 'job_id' => job1 })

      allow(adapter).to receive(:poll_statuses).and_return(
        job1 => { 'status' => 'pending', 'job_id' => job1 }
      )

      # available_slots uses clock_gettime (start + check), poll_until_done uses it too
      start = 100.0
      allow(Process).to receive(:clock_gettime).and_return(
        start,         # available_slots start_time
        start,         # available_slots elapsed check (within timeout)
        start,         # poll_until_done start_time
        start + 130    # poll_until_done elapsed check (exceeds timeout)
      )

      results = described_class.post(%w[http://slow.com])

      expect(results.length).to eq(1)
      expect(results.first.submitted?).to eq(true)
      expect(results.first.job_id).to eq(job1)
    end

    it 'downloads screenshots in batch mode when screenshot_dir is provided' do
      Dir.mktmpdir do |dir|
        WaybackArchiver.config.access_key = 'key'
        WaybackArchiver.config.secret_key = 'secret'
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

    it 'handles cached result from submit (no job_id, has timestamp)' do
      allow(adapter).to receive(:submit)
        .with('http://a.com').and_return({
          'url' => 'http://a.com', 'timestamp' => '20260401120000',
          'original_url' => 'http://a.com'
        })
      allow(adapter).to receive(:submit)
        .with('http://b.com').and_return({ 'url' => 'http://b.com', 'job_id' => job1 })

      allow(adapter).to receive(:poll_statuses).and_return(
        job1 => { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://b.com' }
      )

      results = described_class.post(%w[http://a.com http://b.com])

      expect(results.length).to eq(2)
      cached = results.find { |r| r.uri == 'http://a.com' }
      expect(cached.success?).to eq(true)
      expect(cached.cached?).to eq(true)
      expect(cached.timestamp).to eq('20260401120000')
      expect(cached.job_id).to be_nil
    end

    it 'handles submit response with missing job_id as error' do
      allow(adapter).to receive(:submit)
        .with('http://a.com').and_return({ 'message' => 'something unexpected' })

      results = described_class.post(%w[http://a.com])

      expect(results.length).to eq(1)
      expect(results.first.errored?).to eq(true)
      expect(results.first.error.message).to include('something unexpected')
    end

    it 'falls back to per-URL call for adapters without submit' do
      simple_adapter = ->(u) { WaybackArchiver::ArchiveResult.new(u) }
      WaybackArchiver.config.adapter = simple_adapter
      results = described_class.post(%w[http://a.com])
      WaybackArchiver.config.adapter = WaybackArchiver::WaybackMachine

      expect(results.length).to eq(1)
      expect(results.first.uri).to eq('http://a.com')
    end

    it 'returns empty array for empty URL list' do
      allow(adapter).to receive(:submit)
      allow(adapter).to receive(:poll_statuses)

      results = described_class.post([])

      expect(results).to eq([])
      expect(adapter).not_to have_received(:submit)
      expect(adapter).not_to have_received(:poll_statuses)
    end

    it 'polls between chunks and logs progress' do
      jobs = (1..14).map { |i| ["job-#{i}", "http://example.com/page-#{i}"] }
      jobs.each do |job_id, url|
        allow(adapter).to receive(:submit)
          .with(url).and_return({ 'url' => url, 'job_id' => job_id })
      end

      poll_count = 0
      allow(adapter).to receive(:poll_statuses) do |ids|
        poll_count += 1
        ids.each_with_object({}) do |jid, h|
          h[jid] = { 'status' => 'success', 'job_id' => jid, 'timestamp' => '20260326120000', 'original_url' => "http://example.com" }
        end
      end

      urls = jobs.map(&:last)
      results = described_class.post(urls)

      expect(results.length).to eq(14)
      expect(results).to all(be_success)
      # 2 chunks (12 + 2): inter-chunk poll after first chunk + final poll for second chunk
      expect(poll_count).to be >= 2
    end

    it 'includes counter in submit log messages' do
      allow(adapter).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })
      allow(adapter).to receive(:poll_statuses).and_return(
        job1 => { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' }
      )

      described_class.post(%w[http://a.com])

      expect(WaybackArchiver.logger.debug_log).to include('Submitting http://a.com (1/1)')
    end

    it 're-queues URLs that hit session limit' do
      call_count = 0
      allow(adapter).to receive(:submit).with('http://a.com') do
        call_count += 1
        if call_count <= 1
          { 'message' => 'You have already reached the limit of active Save Page Now sessions. Please wait for a minute and then try again.' }
        else
          { 'url' => 'http://a.com', 'job_id' => job1 }
        end
      end

      allow(adapter).to receive(:poll_statuses).and_return(
        job1 => { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' }
      )

      results = described_class.post(%w[http://a.com])

      expect(results.length).to eq(1)
      expect(results.first.success?).to eq(true)
      expect(call_count).to eq(2)
    end

    it 'handles poll_statuses raising Request::Error gracefully' do
      allow(adapter).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })

      call_count = 0
      allow(adapter).to receive(:poll_statuses) do |_ids|
        call_count += 1
        if call_count <= 1
          raise WaybackArchiver::Request::ServerError, 'network hiccup'
        else
          { job1 => { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' } }
        end
      end

      results = described_class.post(%w[http://a.com])

      expect(results.length).to eq(1)
      expect(results.first.success?).to eq(true)
    end

    it 'collects errored results from batch polling' do
      allow(adapter).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })

      allow(adapter).to receive(:poll_statuses).and_return(
        job1 => { 'status' => 'error', 'job_id' => job1, 'status_ext' => 'error:invalid-host-resolution', 'message' => "Couldn't resolve host" }
      )

      results = described_class.post(%w[http://a.com])

      expect(results.length).to eq(1)
      expect(results.first.errored?).to eq(true)
      expect(results.first.status_ext).to eq('error:invalid-host-resolution')
    end

    it 'handles poll_statuses returning an Array instead of a Hash' do
      allow(adapter).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })
      allow(adapter).to receive(:submit)
        .with('http://b.com').and_return({ 'url' => 'http://b.com', 'job_id' => job2 })

      allow(adapter).to receive(:poll_statuses).and_return([
        { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' },
        { 'status' => 'success', 'job_id' => job2, 'timestamp' => '20260326120001', 'original_url' => 'http://b.com' }
      ])

      results = described_class.post(%w[http://a.com http://b.com])

      successes = results.select(&:success?)
      expect(successes.length).to eq(2)
    end

    it 'does not crash when poll_statuses returns unknown job_ids' do
      allow(adapter).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })

      allow(adapter).to receive(:poll_statuses).and_return(
        job1 => { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' },
        'unknown-job' => { 'status' => 'success', 'job_id' => 'unknown-job', 'timestamp' => '20260326120000', 'original_url' => 'http://mystery.com' }
      )

      results = described_class.post(%w[http://a.com])

      known_result = results.find { |r| r.uri == 'http://a.com' }
      expect(known_result).to be_success
    end

    context 'dynamic chunk sizing via check_user_status' do
      it 'uses available count to size chunks' do
        allow(adapter).to receive(:check_user_status).and_return({ 'available' => 2, 'processing' => 10 })
        allow(adapter).to receive(:submit) do |url|
          { 'url' => url, 'job_id' => "job-#{url.hash.abs}" }
        end
        allow(adapter).to receive(:poll_statuses) do |ids|
          ids.each_with_object({}) do |jid, h|
            h[jid] = { 'status' => 'success', 'job_id' => jid, 'timestamp' => '20260326120000', 'original_url' => 'http://example.com' }
          end
        end

        results = described_class.post(%w[http://a.com http://b.com http://c.com http://d.com])

        expect(results.select(&:success?).length).to eq(4)
        # With available=2, should have called check_user_status multiple times (at least 2 chunks)
        expect(adapter).to have_received(:check_user_status).at_least(2).times
      end

      it 'waits and polls when available is 0' do
        call_count = 0
        allow(adapter).to receive(:check_user_status) do
          call_count += 1
          if call_count <= 1
            { 'available' => 0, 'processing' => 12 }
          else
            { 'available' => 4, 'processing' => 8 }
          end
        end
        allow(adapter).to receive(:submit)
          .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })
        allow(adapter).to receive(:poll_statuses).and_return(
          job1 => { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' }
        )

        results = described_class.post(%w[http://a.com])

        expect(results.select(&:success?).length).to eq(1)
        expect(call_count).to be >= 2
      end

      it 'aborts on cold-start ClientError from check_user_status' do
        allow(adapter).to receive(:check_user_status)
          .and_raise(WaybackArchiver::Request::ClientError, 'Errno::ECONNREFUSED, Connection refused')
        allow(adapter).to receive(:submit)

        results = described_class.post(%w[http://a.com])

        expect(results.length).to eq(1)
        expect(results.first.errored?).to eq(true)
        expect(adapter).not_to have_received(:submit)
      end

      it 'retries ECONNREFUSED mid-run in the wait loop then recovers' do
        call_count = 0
        allow(adapter).to receive(:check_user_status) do
          call_count += 1
          if call_count <= 1
            { 'available' => 2, 'processing' => 10 }
          elsif call_count <= 3
            raise WaybackArchiver::Request::ClientError, 'Errno::ECONNREFUSED, Connection refused'
          else
            { 'available' => 2, 'processing' => 10 }
          end
        end
        allow(adapter).to receive(:submit) do |url|
          { 'url' => url, 'job_id' => "job-#{url.hash.abs}" }
        end
        allow(adapter).to receive(:poll_statuses) do |ids|
          ids.each_with_object({}) do |jid, h|
            h[jid] = { 'status' => 'success', 'job_id' => jid, 'timestamp' => '20260326120000', 'original_url' => 'http://example.com' }
          end
        end

        results = described_class.post(%w[http://a.com http://b.com http://c.com http://d.com])

        expect(results.select(&:success?).length).to eq(4)
      end

      it 'logs progress while waiting for slots' do
        call_count = 0
        allow(adapter).to receive(:check_user_status) do
          call_count += 1
          if call_count <= 3
            { 'available' => 0, 'processing' => 7 }
          else
            { 'available' => 4, 'processing' => 3 }
          end
        end
        allow(adapter).to receive(:submit) do |url|
          { 'url' => url, 'job_id' => "job-#{url.hash.abs}" }
        end
        allow(adapter).to receive(:poll_statuses) do |ids|
          ids.each_with_object({}) do |jid, h|
            h[jid] = { 'status' => 'success', 'job_id' => jid, 'timestamp' => '20260326120000', 'original_url' => 'http://example.com' }
          end
        end

        results = described_class.post(%w[http://a.com])

        expect(results.select(&:success?).length).to eq(1)
        # Should have waited through multiple check_user_status calls
        expect(call_count).to be >= 3
        # Should have logged progress while waiting
        progress_lines = WaybackArchiver.logger.info_log.select { |l| l.include?('Polling...') }
        expect(progress_lines.length).to be >= 2
      end

      it 'limits session retries to 2' do
        allow(adapter).to receive(:check_user_status).and_return({ 'available' => 12, 'processing' => 0 })
        allow(adapter).to receive(:submit)
          .with('http://a.com').and_return({ 'message' => 'You have already reached the limit of active Save Page Now sessions. Please wait for a minute and then try again.' })
        allow(adapter).to receive(:poll_statuses).and_return({})

        results = described_class.post(%w[http://a.com])

        expect(results.length).to eq(1)
        expect(results.first.errored?).to eq(true)
        # Should have tried submit 3 times (1 + 2 retries)
        expect(adapter).to have_received(:submit).exactly(3).times
      end
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

      WaybackArchiver.config.adapter = simple_adapter
      result = described_class.post_url(url, capture_all: true)
      WaybackArchiver.config.adapter = WaybackArchiver::WaybackMachine

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
