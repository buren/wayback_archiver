require 'spec_helper'
require 'tmpdir'

RSpec.describe WaybackArchiver::Archive do
  describe '::post' do
    before do
      allow_any_instance_of(WaybackArchiver::BatchSubmitter).to receive(:sleep)
      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status).and_return({ 'available' => 12, 'processing' => 0 })
    end

    it 'submits each URL via WaybackMachine' do
      allow(WaybackArchiver::WaybackMachine).to receive(:submit) do |url|
        { 'url' => url, 'job_id' => "job-#{url.hash.abs}" }
      end
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses) do |ids|
        ids.each_with_object({}) do |jid, h|
          h[jid] = { 'status' => 'success', 'job_id' => jid, 'timestamp' => '20260326120000', 'original_url' => 'http://example.com' }
        end
      end

      results = described_class.post(%w[https://example.com https://example.com/path])

      expect(WaybackArchiver::WaybackMachine).to have_received(:submit).twice
      expect(results.length).to eq(2)
    end

    it 'respects max limit' do
      allow(WaybackArchiver::WaybackMachine).to receive(:submit) do |url|
        { 'url' => url, 'job_id' => "job-#{url.hash.abs}" }
      end
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses) do |ids|
        ids.each_with_object({}) do |jid, h|
          h[jid] = { 'status' => 'success', 'job_id' => jid, 'timestamp' => '20260326120000', 'original_url' => 'http://example.com' }
        end
      end

      described_class.post(%w[https://example.com https://example.com/path], limit: 1)

      expect(WaybackArchiver::WaybackMachine).to have_received(:submit).once
    end

    it 'returns ALL results including errored ones' do
      allow(WaybackArchiver::WaybackMachine).to receive(:submit).with('http://ok.com') do
        { 'url' => 'http://ok.com', 'job_id' => 'job-ok' }
      end
      allow(WaybackArchiver::WaybackMachine).to receive(:submit).with('http://fail.com') do
        WaybackArchiver::ArchiveResult.new('http://fail.com', error: StandardError.new('boom'))
      end
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
        'job-ok' => { 'status' => 'success', 'job_id' => 'job-ok', 'timestamp' => '20260326120000', 'original_url' => 'http://ok.com' }
      )

      results = described_class.post(%w[http://ok.com http://fail.com])

      expect(results.length).to eq(2)
      expect(results.map(&:uri)).to contain_exactly('http://ok.com', 'http://fail.com')
    end

    it 'passes **options through to WaybackMachine.submit' do
      allow(WaybackArchiver::WaybackMachine).to receive(:submit) do |url, **_opts|
        { 'url' => url, 'job_id' => 'job-1' }
      end
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
        'job-1' => { 'status' => 'success', 'job_id' => 'job-1', 'timestamp' => '20260326120000', 'original_url' => 'https://example.com' }
      )

      described_class.post(%w[https://example.com], capture_all: true, js_behavior_timeout: 10)

      expect(WaybackArchiver::WaybackMachine).to have_received(:submit).with('https://example.com', capture_all: true, js_behavior_timeout: 10)
    end

    it 'skips URLs in skip_urls' do
      allow(WaybackArchiver::WaybackMachine).to receive(:submit) do |url, **_opts|
        { 'url' => url, 'job_id' => "job-#{url.hash.abs}" }
      end
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses) do |ids|
        ids.each_with_object({}) do |jid, h|
          h[jid] = { 'status' => 'success', 'job_id' => jid, 'timestamp' => '20260326120000', 'original_url' => 'http://example.com' }
        end
      end

      skip = Set.new(['https://example.com'])
      described_class.post(%w[https://example.com https://example.com/path], skip_urls: skip)

      expect(WaybackArchiver::WaybackMachine).to have_received(:submit).once
      expect(WaybackArchiver::WaybackMachine).to have_received(:submit).with('https://example.com/path')
    end

    it 'does not skip anything when skip_urls is nil' do
      allow(WaybackArchiver::WaybackMachine).to receive(:submit) do |url, **_opts|
        { 'url' => url, 'job_id' => "job-#{url.hash.abs}" }
      end
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses) do |ids|
        ids.each_with_object({}) do |jid, h|
          h[jid] = { 'status' => 'success', 'job_id' => jid, 'timestamp' => '20260326120000', 'original_url' => 'http://example.com' }
        end
      end

      described_class.post(%w[https://example.com https://example.com/path], skip_urls: nil)

      expect(WaybackArchiver::WaybackMachine).to have_received(:submit).twice
    end

    describe 'skip_patterns filtering' do
      before do
        allow(WaybackArchiver::WaybackMachine).to receive(:submit) do |url, **_opts|
          { 'url' => url, 'job_id' => "job-#{url.hash.abs}" }
        end
        allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses) do |ids|
          ids.each_with_object({}) do |jid, h|
            h[jid] = { 'status' => 'success', 'job_id' => jid, 'timestamp' => '20260326120000', 'original_url' => 'http://example.com' }
          end
        end
      end

      it 'excludes URLs matching a pattern' do
        urls = %w[https://example.com https://example.com/page?hs_amp=true]
        described_class.post(urls, skip_patterns: [/hs_amp=true/])

        expect(WaybackArchiver::WaybackMachine).to have_received(:submit).once
        expect(WaybackArchiver::WaybackMachine).to have_received(:submit).with('https://example.com')
      end

      it 'excludes URLs matching any of multiple patterns' do
        urls = %w[https://example.com https://example.com/page?hs_amp=true https://example.com/tag/ruby]
        described_class.post(urls, skip_patterns: [/hs_amp=true/, %r{/tag/}])

        expect(WaybackArchiver::WaybackMachine).to have_received(:submit).once
        expect(WaybackArchiver::WaybackMachine).to have_received(:submit).with('https://example.com')
      end

      it 'does not skip anything when skip_patterns is nil' do
        urls = %w[https://example.com https://example.com/page?hs_amp=true]
        described_class.post(urls, skip_patterns: nil)

        expect(WaybackArchiver::WaybackMachine).to have_received(:submit).twice
      end
    end

    describe 'extension filtering' do
      before do
        allow(WaybackArchiver::WaybackMachine).to receive(:submit) do |url, **_opts|
          { 'url' => url, 'job_id' => "job-#{url.hash.abs}" }
        end
        allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses) do |ids|
          ids.each_with_object({}) do |jid, h|
            h[jid] = { 'status' => 'success', 'job_id' => jid, 'timestamp' => '20260326120000', 'original_url' => 'http://example.com' }
          end
        end
      end

      it 'filters by include_ext' do
        urls = %w[http://a.com/doc.pdf http://a.com/page http://a.com/img.png]
        described_class.post(urls, include_ext: %w[pdf])

        expect(WaybackArchiver::WaybackMachine).to have_received(:submit).once
        expect(WaybackArchiver::WaybackMachine).to have_received(:submit).with('http://a.com/doc.pdf')
      end

      it 'filters by exclude_ext' do
        urls = %w[http://a.com/doc.pdf http://a.com/page http://a.com/img.png]
        described_class.post(urls, exclude_ext: %w[pdf png])

        expect(WaybackArchiver::WaybackMachine).to have_received(:submit).once
        expect(WaybackArchiver::WaybackMachine).to have_received(:submit).with('http://a.com/page')
      end

      it 'applies include_ext then exclude_ext' do
        urls = %w[http://a.com/a.pdf http://a.com/b.doc http://a.com/c.docx http://a.com/page]
        described_class.post(urls, include_ext: %w[pdf doc docx], exclude_ext: %w[docx])

        expect(WaybackArchiver::WaybackMachine).to have_received(:submit).twice
        expect(WaybackArchiver::WaybackMachine).to have_received(:submit).with('http://a.com/a.pdf')
        expect(WaybackArchiver::WaybackMachine).to have_received(:submit).with('http://a.com/b.doc')
      end

      it 'normalizes leading dots in extensions' do
        urls = %w[http://a.com/doc.pdf http://a.com/page]
        described_class.post(urls, include_ext: %w[.pdf])

        expect(WaybackArchiver::WaybackMachine).to have_received(:submit).once
        expect(WaybackArchiver::WaybackMachine).to have_received(:submit).with('http://a.com/doc.pdf')
      end

      it 'is case-insensitive' do
        urls = %w[http://a.com/doc.PDF http://a.com/page]
        described_class.post(urls, include_ext: %w[pdf])

        expect(WaybackArchiver::WaybackMachine).to have_received(:submit).once
        expect(WaybackArchiver::WaybackMachine).to have_received(:submit).with('http://a.com/doc.PDF')
      end

      it 'handles query strings and fragments' do
        urls = %w[http://a.com/doc.pdf?v=1 http://a.com/page#section]
        described_class.post(urls, include_ext: %w[pdf])

        expect(WaybackArchiver::WaybackMachine).to have_received(:submit).once
        expect(WaybackArchiver::WaybackMachine).to have_received(:submit).with('http://a.com/doc.pdf?v=1')
      end

      it 'does nothing when neither option is set' do
        urls = %w[http://a.com/doc.pdf http://a.com/page]
        described_class.post(urls)

        expect(WaybackArchiver::WaybackMachine).to have_received(:submit).twice
      end
    end

    it 'submits all URLs then batch-polls' do
      job1 = 'job-aaa'
      job2 = 'job-bbb'

      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://b.com').and_return({ 'url' => 'http://b.com', 'job_id' => job2 })

      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
        job1 => { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' },
        job2 => { 'status' => 'success', 'job_id' => job2, 'timestamp' => '20260326120001', 'original_url' => 'http://b.com' }
      )

      results = described_class.post(%w[http://a.com http://b.com])

      expect(results.length).to eq(2)
      expect(results.map(&:job_id)).to contain_exactly(job1, job2)
      expect(results).to all(be_success)
    end

    it 'yields results as they complete during batch polling' do
      job1 = 'job-aaa'
      job2 = 'job-bbb'

      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://b.com').and_return({ 'url' => 'http://b.com', 'job_id' => job2 })

      call_count = 0
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses) do |_ids|
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
      job1 = 'job-aaa'

      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://bad.com').and_return(WaybackArchiver::ArchiveResult.new('http://bad.com', error: StandardError.new('fail')))

      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
        job1 => { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' }
      )

      results = described_class.post(%w[http://a.com http://bad.com])

      expect(results.length).to eq(2)
      expect(results.find { |r| r.uri == 'http://bad.com' }.errored?).to eq(true)
      expect(results.find { |r| r.uri == 'http://a.com' }.success?).to eq(true)
    end

    it 'marks timed-out pending jobs as submitted' do
      job1 = 'job-aaa'

      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://slow.com').and_return({ 'url' => 'http://slow.com', 'job_id' => job1 })

      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
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
      job1 = 'job-aaa'

      Dir.mktmpdir do |dir|
        WaybackArchiver.config.access_key = 'key'
        WaybackArchiver.config.secret_key = 'secret'
        screenshot_url = 'http://web.archive.org/screenshot/http://a.com'
        png_data = "\x89PNG\r\n\x1a\nfake"

        allow(WaybackArchiver::WaybackMachine).to receive(:submit)
          .with('http://a.com', capture_screenshot: true, screenshot_dir: dir)
          .and_return({ 'url' => 'http://a.com', 'job_id' => job1 })

        allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
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
      job1 = 'job-aaa'

      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://a.com').and_return({
          'url' => 'http://a.com', 'timestamp' => '20260401120000',
          'original_url' => 'http://a.com'
        })
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://b.com').and_return({ 'url' => 'http://b.com', 'job_id' => job1 })

      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
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
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://a.com').and_return({ 'message' => 'something unexpected' })

      results = described_class.post(%w[http://a.com])

      expect(results.length).to eq(1)
      expect(results.first.errored?).to eq(true)
      expect(results.first.error.message).to include('something unexpected')
    end

    it 'returns empty array for empty URL list' do
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses)

      results = described_class.post([])

      expect(results).to eq([])
      expect(WaybackArchiver::WaybackMachine).not_to have_received(:submit)
      expect(WaybackArchiver::WaybackMachine).not_to have_received(:poll_statuses)
    end

    # Regression: success/error counters were incremented at four scattered
    # call sites; cached results and submit-time permanent failures were
    # recorded without being counted, so progress events and the final
    # summary undercounted — and the cold-start abort heuristic
    # (counts[:success] == 0) could spuriously abort runs that archived
    # everything from cache.
    it 'counts cached results as captured in progress totals' do
      tl = WaybackArchiver::TestListener.new
      WaybackArchiver.config.listener = tl
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .and_return({ 'url' => 'http://example.com', 'timestamp' => '20260326120000' })

      described_class.post(%w[http://example.com])

      expect(tl.progress_events.last[:captured]).to eq(1)
    end

    it 'counts submit-time permanent failures in progress totals' do
      tl = WaybackArchiver::TestListener.new
      WaybackArchiver.config.listener = tl
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .and_return({ 'status' => 'error', 'status_ext' => 'error:blocked-url', 'message' => 'blocked' })

      described_class.post(%w[http://example.com])

      expect(tl.progress_events.last[:failed]).to eq(1)
    end

    it 'emits a final on_progress with pending: 0 once poll_until_done drains the last jobs' do
      progress_events = []
      listener = {
        on_batch_start: ->(**) {},
        on_progress: ->(captured:, failed:, pending:) { progress_events << pending },
        on_submitted: ->(**) {},
        on_completed: ->(**) {}
      }
      WaybackArchiver.config.listener = WaybackArchiver::ListenerProxy.new(listener)

      allow(WaybackArchiver::WaybackMachine).to receive(:submit) do |url|
        { 'url' => url, 'job_id' => "job-#{url.hash.abs}" }
      end

      # Force the work to land in poll_until_done: the inter-chunk poll sees
      # all jobs still pending, only the next poll (run by poll_until_done)
      # resolves them.
      poll_call = 0
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses) do |ids|
        poll_call += 1
        if poll_call == 1
          ids.each_with_object({}) { |jid, h| h[jid] = { 'status' => 'pending', 'job_id' => jid } }
        else
          ids.each_with_object({}) do |jid, h|
            h[jid] = { 'status' => 'success', 'job_id' => jid, 'timestamp' => '20260326120000', 'original_url' => 'http://example.com' }
          end
        end
      end

      # Avoid the 3s POLL_INTERVAL sleep inside poll_until_done
      stub_const('WaybackArchiver::WaybackMachine::POLL_INTERVAL', 0)

      described_class.post(%w[http://a.com http://b.com])

      # The last reported pending count must be 0 so the renderer's footer
      # doesn't display a stale non-zero pending value at end-of-run.
      expect(progress_events.last).to eq(0),
        "expected final on_progress pending to be 0, got #{progress_events.inspect}"
    end

    it 'polls between chunks and logs progress' do
      jobs = (1..14).map { |i| ["job-#{i}", "http://example.com/page-#{i}"] }
      jobs.each do |job_id, url|
        allow(WaybackArchiver::WaybackMachine).to receive(:submit)
          .with(url).and_return({ 'url' => url, 'job_id' => job_id })
      end

      poll_count = 0
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses) do |ids|
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
      job1 = 'job-aaa'

      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
        job1 => { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' }
      )

      described_class.post(%w[http://a.com])

      expect(WaybackArchiver.logger.debug_log).to include('Submitting http://a.com (1/1)')
    end

    it 're-queues URLs that hit session limit' do
      job1 = 'job-aaa'
      call_count = 0
      allow(WaybackArchiver::WaybackMachine).to receive(:submit).with('http://a.com') do
        call_count += 1
        if call_count <= 1
          { 'message' => 'You have already reached the limit of active Save Page Now sessions. Please wait for a minute and then try again.' }
        else
          { 'url' => 'http://a.com', 'job_id' => job1 }
        end
      end

      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
        job1 => { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' }
      )

      results = described_class.post(%w[http://a.com])

      expect(results.length).to eq(1)
      expect(results.first.success?).to eq(true)
      expect(call_count).to eq(2)
    end

    it 're-queues URLs that hit connection errors' do
      job1 = 'job-aaa'
      call_count = 0
      allow(WaybackArchiver::WaybackMachine).to receive(:submit).with('http://a.com') do
        call_count += 1
        if call_count <= 1
          raise WaybackArchiver::Request::ClientError, 'Errno::ECONNREFUSED, Connection refused'
        else
          { 'url' => 'http://a.com', 'job_id' => job1 }
        end
      end

      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
        job1 => { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' }
      )

      results = described_class.post(%w[http://a.com])

      expect(results.length).to eq(1)
      expect(results.first.success?).to eq(true)
      expect(call_count).to eq(2)
    end

    it 'handles poll_statuses raising Request::Error gracefully' do
      job1 = 'job-aaa'

      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })

      call_count = 0
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses) do |_ids|
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
      job1 = 'job-aaa'

      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })

      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
        job1 => { 'status' => 'error', 'job_id' => job1, 'status_ext' => 'error:invalid-host-resolution', 'message' => "Couldn't resolve host" }
      )

      results = described_class.post(%w[http://a.com])

      expect(results.length).to eq(1)
      expect(results.first.errored?).to eq(true)
      expect(results.first.status_ext).to eq('error:invalid-host-resolution')
    end

    it 'handles poll_statuses returning an Array instead of a Hash' do
      job1 = 'job-aaa'
      job2 = 'job-bbb'

      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://b.com').and_return({ 'url' => 'http://b.com', 'job_id' => job2 })

      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return([
        { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' },
        { 'status' => 'success', 'job_id' => job2, 'timestamp' => '20260326120001', 'original_url' => 'http://b.com' }
      ])

      results = described_class.post(%w[http://a.com http://b.com])

      successes = results.select(&:success?)
      expect(successes.length).to eq(2)
    end

    it 'does not crash when poll_statuses returns unknown job_ids' do
      job1 = 'job-aaa'

      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })

      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
        job1 => { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' },
        'unknown-job' => { 'status' => 'success', 'job_id' => 'unknown-job', 'timestamp' => '20260326120000', 'original_url' => 'http://mystery.com' }
      )

      results = described_class.post(%w[http://a.com])

      known_result = results.find { |r| r.uri == 'http://a.com' }
      expect(known_result).to be_success
    end

    context 'dynamic chunk sizing via check_user_status' do
      it 'uses available count to size chunks' do
        allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status).and_return({ 'available' => 2, 'processing' => 10 })
        allow(WaybackArchiver::WaybackMachine).to receive(:submit) do |url|
          { 'url' => url, 'job_id' => "job-#{url.hash.abs}" }
        end
        allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses) do |ids|
          ids.each_with_object({}) do |jid, h|
            h[jid] = { 'status' => 'success', 'job_id' => jid, 'timestamp' => '20260326120000', 'original_url' => 'http://example.com' }
          end
        end

        results = described_class.post(%w[http://a.com http://b.com http://c.com http://d.com])

        expect(results.select(&:success?).length).to eq(4)
        # With available=2, should have called check_user_status multiple times (at least 2 chunks)
        expect(WaybackArchiver::WaybackMachine).to have_received(:check_user_status).at_least(2).times
      end

      it 'waits and polls when available is 0' do
        job1 = 'job-aaa'
        call_count = 0
        allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status) do
          call_count += 1
          if call_count <= 1
            { 'available' => 0, 'processing' => 12 }
          else
            { 'available' => 4, 'processing' => 8 }
          end
        end
        allow(WaybackArchiver::WaybackMachine).to receive(:submit)
          .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })
        allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
          job1 => { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' }
        )

        results = described_class.post(%w[http://a.com])

        expect(results.select(&:success?).length).to eq(1)
        expect(call_count).to be >= 2
      end

      it 'aborts on cold-start ClientError from check_user_status' do
        allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status)
          .and_raise(WaybackArchiver::Request::ClientError, 'Errno::ECONNREFUSED, Connection refused')
        allow(WaybackArchiver::WaybackMachine).to receive(:submit)

        results = described_class.post(%w[http://a.com])

        expect(results.length).to eq(1)
        expect(results.first.errored?).to eq(true)
        expect(WaybackArchiver::WaybackMachine).not_to have_received(:submit)
      end

      it 'retries ECONNREFUSED mid-run in the wait loop then recovers' do
        call_count = 0
        allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status) do
          call_count += 1
          if call_count <= 1
            { 'available' => 2, 'processing' => 10 }
          elsif call_count <= 3
            raise WaybackArchiver::Request::ClientError, 'Errno::ECONNREFUSED, Connection refused'
          else
            { 'available' => 2, 'processing' => 10 }
          end
        end
        allow(WaybackArchiver::WaybackMachine).to receive(:submit) do |url|
          { 'url' => url, 'job_id' => "job-#{url.hash.abs}" }
        end
        allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses) do |ids|
          ids.each_with_object({}) do |jid, h|
            h[jid] = { 'status' => 'success', 'job_id' => jid, 'timestamp' => '20260326120000', 'original_url' => 'http://example.com' }
          end
        end

        results = described_class.post(%w[http://a.com http://b.com http://c.com http://d.com])

        expect(results.select(&:success?).length).to eq(4)
      end

      it 'logs progress while waiting for slots' do
        call_count = 0
        allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status) do
          call_count += 1
          if call_count <= 3
            { 'available' => 0, 'processing' => 7 }
          else
            { 'available' => 4, 'processing' => 3 }
          end
        end
        allow(WaybackArchiver::WaybackMachine).to receive(:submit) do |url|
          { 'url' => url, 'job_id' => "job-#{url.hash.abs}" }
        end
        allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses) do |ids|
          ids.each_with_object({}) do |jid, h|
            h[jid] = { 'status' => 'success', 'job_id' => jid, 'timestamp' => '20260326120000', 'original_url' => 'http://example.com' }
          end
        end

        results = described_class.post(%w[http://a.com])

        expect(results.select(&:success?).length).to eq(1)
        # Should have waited through multiple check_user_status calls
        expect(call_count).to be >= 3
        # Should have logged progress while waiting (debug level)
        progress_lines = WaybackArchiver.logger.debug_log.select { |l| l.include?('Polling...') }
        expect(progress_lines.length).to be >= 2
      end

      it 'limits retries to MAX_RETRIES' do
        allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status).and_return({ 'available' => 12, 'processing' => 0 })
        allow(WaybackArchiver::WaybackMachine).to receive(:submit)
          .with('http://a.com').and_return({ 'message' => 'You have already reached the limit of active Save Page Now sessions. Please wait for a minute and then try again.' })
        allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return({})

        results = described_class.post(%w[http://a.com])

        expect(results.length).to eq(1)
        expect(results.first.errored?).to eq(true)
        # Should have tried submit 6 times (1 + 5 retries)
        expect(WaybackArchiver::WaybackMachine).to have_received(:submit).exactly(6).times
      end

      it 'logs retries at debug level and only logs error on final failure' do
        allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status).and_return({ 'available' => 12, 'processing' => 0 })
        allow(WaybackArchiver::WaybackMachine).to receive(:submit)
          .with('http://a.com').and_raise(WaybackArchiver::Request::ClientError, 'Connection refused')
        allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return({})

        described_class.post(%w[http://a.com])

        # Intermediate retries should be debug, not warn
        warn_connection_lines = WaybackArchiver.logger.warn_log.select { |l| l.include?('Connection error') || l.include?('Re-queuing') }
        expect(warn_connection_lines).to be_empty

        # Debug should mention retries will happen
        debug_retry_lines = WaybackArchiver.logger.debug_log.select { |l| l.include?('will retry') }
        expect(debug_retry_lines).not_to be_empty

        # Final failure should be error level
        error_lines = WaybackArchiver.logger.error_log.select { |l| l.include?('Retry limit exceeded') }
        expect(error_lines.length).to eq(1)
      end
    end
  end

  describe '::crawl' do
    before do
      allow_any_instance_of(WaybackArchiver::BatchSubmitter).to receive(:sleep)
      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status).and_return({ 'available' => 12, 'processing' => 0 })
    end

    it 'submits discovered URLs to SPN2' do
      allow(WaybackArchiver::URLCollector).to receive(:crawl).and_yield('https://example.com').and_return(['https://example.com'])
      allow(WaybackArchiver::WaybackMachine).to receive(:submit) do |url|
        { 'url' => url, 'job_id' => 'job-1' }
      end
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
        'job-1' => { 'status' => 'success', 'job_id' => 'job-1', 'timestamp' => '20260326120000', 'original_url' => 'https://example.com' }
      )

      results = described_class.crawl('https://example.com')

      expect(results.length).to eq(1)
      expect(results[0].uri).to eq('https://example.com')
      expect(WaybackArchiver::WaybackMachine).to have_received(:submit).with('https://example.com')
    end

    it 'filters out skip_urls before submitting' do
      allow(WaybackArchiver::URLCollector).to receive(:crawl)
        .and_yield('http://a.com').and_yield('http://b.com')
        .and_return(%w[http://a.com http://b.com])
      allow(WaybackArchiver::WaybackMachine).to receive(:submit) do |url|
        { 'url' => url, 'job_id' => "job-#{url.hash.abs}" }
      end
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses) do |ids|
        ids.each_with_object({}) do |jid, h|
          h[jid] = { 'status' => 'success', 'job_id' => jid, 'timestamp' => '20260326120000', 'original_url' => 'http://b.com' }
        end
      end

      skip = Set.new(['http://a.com'])
      results = described_class.crawl('http://example.com', skip_urls: skip)

      expect(WaybackArchiver::WaybackMachine).to have_received(:submit).once
      expect(WaybackArchiver::WaybackMachine).to have_received(:submit).with('http://b.com')
    end

    it 'filters out URLs matching skip_patterns before submitting' do
      allow(WaybackArchiver::URLCollector).to receive(:crawl)
        .and_yield('http://example.com/page').and_yield('http://example.com/page?hs_amp=true')
        .and_return(%w[http://example.com/page http://example.com/page?hs_amp=true])
      allow(WaybackArchiver::WaybackMachine).to receive(:submit) do |url|
        { 'url' => url, 'job_id' => "job-#{url.hash.abs}" }
      end
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses) do |ids|
        ids.each_with_object({}) do |jid, h|
          h[jid] = { 'status' => 'success', 'job_id' => jid, 'timestamp' => '20260326120000', 'original_url' => 'http://example.com/page' }
        end
      end

      results = described_class.crawl('http://example.com', skip_patterns: [/hs_amp=true/])

      expect(WaybackArchiver::WaybackMachine).to have_received(:submit).once
      expect(WaybackArchiver::WaybackMachine).to have_received(:submit).with('http://example.com/page')
    end

    it 'applies extension filtering inline' do
      allow(WaybackArchiver::URLCollector).to receive(:crawl)
        .and_yield('http://example.com/doc.pdf').and_yield('http://example.com/page.html')
        .and_return(%w[http://example.com/doc.pdf http://example.com/page.html])
      allow(WaybackArchiver::WaybackMachine).to receive(:submit) do |url|
        { 'url' => url, 'job_id' => "job-#{url.hash.abs}" }
      end
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses) do |ids|
        ids.each_with_object({}) do |jid, h|
          h[jid] = { 'status' => 'success', 'job_id' => jid, 'timestamp' => '20260326120000', 'original_url' => 'http://example.com/doc.pdf' }
        end
      end

      results = described_class.crawl('http://example.com', include_ext: %w[pdf])

      expect(WaybackArchiver::WaybackMachine).to have_received(:submit).once
      expect(WaybackArchiver::WaybackMachine).to have_received(:submit).with('http://example.com/doc.pdf')
    end

    it 'fires on_url_discovered and on_crawl_complete events' do
      discovered_events = []
      crawl_complete_event = nil

      listener = {
        on_url_discovered: ->(url:, count:) { discovered_events << { url: url, count: count } },
        on_crawl_complete: ->(url_count:) { crawl_complete_event = url_count },
        on_batch_start: ->(**) {},
        on_progress: ->(**) {}
      }
      WaybackArchiver.config.listener = WaybackArchiver::ListenerProxy.new(listener)

      allow(WaybackArchiver::URLCollector).to receive(:crawl)
        .and_yield('http://a.com').and_yield('http://b.com')
        .and_return(%w[http://a.com http://b.com])
      allow(WaybackArchiver::WaybackMachine).to receive(:submit) do |url|
        { 'url' => url, 'job_id' => "job-#{url.hash.abs}" }
      end
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses) do |ids|
        ids.each_with_object({}) do |jid, h|
          h[jid] = { 'status' => 'success', 'job_id' => jid, 'timestamp' => '20260326120000', 'original_url' => 'http://example.com' }
        end
      end

      described_class.crawl('http://example.com')

      expect(discovered_events.length).to eq(2)
      expect(discovered_events[0]).to eq({ url: 'http://a.com', count: 1 })
      expect(discovered_events[1]).to eq({ url: 'http://b.com', count: 2 })
      expect(crawl_complete_event).to eq(2)
    end

    it 'surfaces crawler thread errors after draining the queue' do
      allow(WaybackArchiver::URLCollector).to receive(:crawl) do |*, &blk|
        blk.call('http://a.com')
        raise 'crawler exploded'
      end
      allow(WaybackArchiver::WaybackMachine).to receive(:submit) do |url|
        { 'url' => url, 'job_id' => 'job-1' }
      end
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
        'job-1' => { 'status' => 'success', 'job_id' => 'job-1', 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' }
      )

      expect { described_class.crawl('http://example.com') }.to raise_error('crawler exploded')
    end

    it 're-queues transient errors without deadlocking the SizedQueue' do
      call_count = 0
      allow(WaybackArchiver::URLCollector).to receive(:crawl)
        .and_yield('http://a.com')
        .and_return(%w[http://a.com])
      allow(WaybackArchiver::WaybackMachine).to receive(:submit).with('http://a.com') do
        call_count += 1
        if call_count <= 1
          raise WaybackArchiver::Request::ClientError, 'Connection refused'
        else
          { 'url' => 'http://a.com', 'job_id' => 'job-1' }
        end
      end
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
        'job-1' => { 'status' => 'success', 'job_id' => 'job-1', 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' }
      )

      results = described_class.crawl('http://example.com')

      expect(results.length).to eq(1)
      expect(results.first.success?).to eq(true)
      expect(call_count).to eq(2)
    end

    it 'passes extension filters through to URLCollector.crawl' do
      allow(WaybackArchiver::URLCollector).to receive(:crawl).and_return([])
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return({})

      described_class.crawl('http://example.com', include_ext: %w[html], exclude_ext: %w[pdf])

      expect(WaybackArchiver::URLCollector).to have_received(:crawl).with(
        'http://example.com',
        hash_including(exts: %w[html], ignore_exts: %w[pdf])
      )
    end

    it 'passes capture_all through to URLCollector.crawl so error pages are discovered' do
      allow(WaybackArchiver::URLCollector).to receive(:crawl).and_return([])
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return({})

      described_class.crawl('http://example.com', capture_all: true)

      expect(WaybackArchiver::URLCollector).to have_received(:crawl).with(
        'http://example.com',
        hash_including(capture_all: true)
      )
    end
  end

  describe 'limit vs filter ordering' do
    # Regression: limit sliced the URL list BEFORE the skip filters ran, so
    # session-skipped URLs consumed the budget — a resumed run with --limit
    # silently under-archived even though eligible URLs remained.
    it 'applies skip filters before the limit so skipped URLs do not consume the budget' do
      submitted = nil
      fake_submitter = instance_double(WaybackArchiver::BatchSubmitter, call: [])
      allow(WaybackArchiver::BatchSubmitter).to receive(:new) do |queue, **|
        submitted = queue
        fake_submitter
      end

      urls = %w[http://example.com/old1 http://example.com/old2
                http://example.com/new1 http://example.com/new2]
      described_class.post(urls, limit: 2,
                           skip_urls: Set['http://example.com/old1', 'http://example.com/old2'])

      expect(submitted).to eq(%w[http://example.com/new1 http://example.com/new2])
    end
  end

  describe 'worker exception safety' do
    # Regression: the pool.post block only rescued Request::Error. Any other
    # StandardError raised in a worker (e.g. a listener writing to a closed
    # pipe) was swallowed by concurrent-ruby — the URL silently vanished from
    # the results and the totals went quietly wrong.
    it 'records an error result when a worker raises an unexpected exception' do
      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status)
        .and_return({ 'available' => 12, 'processing' => 0 })
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return({})
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .and_raise(Errno::EPIPE, 'Broken pipe')

      results = described_class.post(%w[http://example.com])

      expect(results.length).to eq(1)
      expect(results.first.uri).to eq('http://example.com')
      expect(results.first.errored?).to eq(true)
    end
  end

  describe 'unknown option validation' do
    before do
      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status)
        .and_return({ 'available' => 12, 'processing' => 0 })
    end

    # A typo'd option used to be silently dropped by build_post_body —
    # capture_screenshots: true archived without screenshots and told no one.
    it 'raises ArgumentError for unknown options in post' do
      expect { described_class.post(%w[http://example.com], capture_screenshots: true) }
        .to raise_error(ArgumentError, /capture_screenshots/)
    end

    it 'raises ArgumentError for unknown options in crawl' do
      expect { described_class.crawl('http://example.com', capture_screenshots: true) }
        .to raise_error(ArgumentError, /capture_screenshots/)
    end

    it 'raises ArgumentError for unknown options in post_url' do
      allow(WaybackArchiver::WaybackMachine).to receive(:call)

      expect { described_class.post_url('http://example.com', screenshots: true) }
        .to raise_error(ArgumentError, /screenshots/)
      expect(WaybackArchiver::WaybackMachine).not_to have_received(:call)
    end

    it 'accepts every documented SPN2 option plus local side-channel options' do
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .and_return({ 'url' => 'http://example.com', 'timestamp' => '20260326120000' })
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return({})

      all_options = (WaybackArchiver::WaybackMachine::BOOLEAN_OPTIONS +
                     WaybackArchiver::WaybackMachine::VALUE_OPTIONS).to_h { |k| [k, '1'] }
      all_options[:screenshot_dir] = 'shots/'
      all_options[:skip_duplicates] = true

      expect { described_class.post(%w[http://example.com], **all_options) }
        .not_to raise_error
    end
  end

  describe 'BatchSubmitter abort' do
    before do
      allow_any_instance_of(WaybackArchiver::BatchSubmitter).to receive(:sleep)
    end

    it 'records still-queued streaming URLs as errors instead of dropping them' do
      queue = SizedQueue.new(100)
      queue.push('http://a.com')
      queue.push('http://b.com')
      crawler = Thread.new {} # already finished — queue is fully populated
      crawler.join

      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status)
        .and_raise(WaybackArchiver::Request::ClientError, 'Errno::ECONNREFUSED, Connection refused')

      results = WaybackArchiver::BatchSubmitter.new(
        queue, concurrency: 1, source_thread: crawler
      ).call

      expect(results.map(&:uri)).to contain_exactly('http://a.com', 'http://b.com')
      expect(results).to all(satisfy(&:errored?))
    end
  end

  describe 'BatchSubmitter idle-poll throttling' do
    # Regression: while a slow crawler kept the queue empty with captures in
    # flight, the idle loop POSTed to the SPN2 status endpoint on every
    # 0.2s iteration — 3-5 requests/second versus the 3s POLL_INTERVAL used
    # everywhere else. The idle poll must respect POLL_INTERVAL.
    it 'does not poll the status endpoint on every idle iteration' do
      queue = SizedQueue.new(10)
      gate = Queue.new
      crawler = Thread.new { gate.pop }
      queue.push('http://example.com/first')

      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status)
        .and_return({ 'available' => 12, 'processing' => 0 })
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .and_return({ 'url' => 'http://example.com/first', 'job_id' => 'job-1' })

      idle_iterations = 0
      poll_calls = 0
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses) do |ids|
        poll_calls += 1
        # Job stays pending while the crawler is 'discovering'; resolves after.
        status = if idle_iterations >= 50
                   { 'status' => 'success', 'timestamp' => '20260326120000', 'original_url' => 'http://example.com/first' }
                 else
                   { 'status' => 'pending' }
                 end
        ids.to_h { |jid| [jid, status.merge('job_id' => jid)] }
      end

      submitter = WaybackArchiver::BatchSubmitter.new(queue, concurrency: 1, source_thread: crawler)
      allow(submitter).to receive(:sleep) do |duration|
        if duration == 0.2
          idle_iterations += 1
          gate.push(:done) if idle_iterations == 50
        end
      end

      results = submitter.call

      expect(results.length).to eq(1)
      expect(idle_iterations).to be >= 50
      # Old behavior: one poll per idle iteration (~50+). Throttled: the 3s
      # POLL_INTERVAL spans all ~50 sub-millisecond test iterations.
      expect(poll_calls).to be < 10,
        "expected idle polling to be throttled, got #{poll_calls} polls across #{idle_iterations} idle iterations"
    end
  end

  describe 'BatchSubmitter streaming-crawl exhaustion race' do
    # Regression: queue_exhausted? read @queue.empty? BEFORE
    # @source_thread.alive?. A crawler that pushed its final URL and exited
    # between the two reads made the queue look exhausted while the URL was
    # still in it — silently dropping it (never submitted, never reported).
    # Reading alive? first closes the window: a thread observed dead cannot
    # push afterwards.
    it 'does not drop a URL pushed just before the crawler exits' do
      require 'delegate'

      queue = SizedQueue.new(10)
      gate = Queue.new
      crawler = Thread.new { gate.pop }

      last_url = 'http://example.com/last-gasp'
      armed = true
      fire_last_gasp = lambda do
        next unless armed
        armed = false
        queue.push(last_url)
        gate.push(:done)
        crawler.join
      end

      # Wrap the queue so the racy interleaving fires deterministically right
      # after empty? is read (where the old code was vulnerable); the sleep
      # stub below covers the fixed code path, which no longer reads empty?
      # while the crawler is alive.
      racy_queue = SimpleDelegator.new(queue)
      racy_queue.define_singleton_method(:empty?) do
        result = __getobj__.empty?
        fire_last_gasp.call if result
        result
      end

      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status)
        .and_return({ 'available' => 12, 'processing' => 0 })
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .and_return({ 'url' => last_url, 'job_id' => 'job-last' })
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses) do |ids|
        ids.each_with_object({}) do |jid, h|
          h[jid] = { 'status' => 'success', 'job_id' => jid, 'timestamp' => '20260326120000', 'original_url' => last_url }
        end
      end

      submitter = WaybackArchiver::BatchSubmitter.new(racy_queue, concurrency: 1, source_thread: crawler)
      allow(submitter).to receive(:sleep) { fire_last_gasp.call }

      results = submitter.call

      expect(results.map(&:uri)).to include(last_url)
    end
  end

  # The rest of the suite forces concurrency=1 (see spec_helper) to keep WebMock
  # and rspec-mocks deterministic. This block deliberately runs the dispatch
  # pipeline under multiple real threads to catch orchestration-layer races.
  describe 'orchestration under real concurrency' do
    before do
      allow_any_instance_of(WaybackArchiver::BatchSubmitter).to receive(:sleep)
      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status)
        .and_return({ 'available' => 12, 'processing' => 0 })
      allow(WaybackArchiver::WaybackMachine).to receive(:submit) do |url|
        { 'url' => url, 'job_id' => "job-#{url[/\d+/]}" }
      end
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses) do |ids|
        ids.each_with_object({}) do |jid, h|
          h[jid] = { 'status' => 'success', 'job_id' => jid, 'timestamp' => '20260326120000', 'original_url' => 'http://example.com' }
        end
      end
    end

    it 'archives every URL exactly once with concurrency > 1' do
      urls = (1..24).map { |i| "http://example.com/#{i}" }

      results = described_class.post(urls, concurrency: 4)

      expect(results.map(&:uri)).to match_array(urls)
      expect(results).to all(satisfy(&:success?))
    end
  end

  describe '::post_url' do
    it 'delegates to WaybackMachine' do
      url = 'https://example.com'
      expected_result = WaybackArchiver::ArchiveResult.new(url, job_id: 'test-123', timestamp: '20260326120000')

      allow(WaybackArchiver::WaybackMachine).to receive(:call).and_return(expected_result)

      result = described_class.post_url(url)

      expect(result).to eq(expected_result)
      expect(WaybackArchiver::WaybackMachine).to have_received(:call).with(url)
    end

    it 'passes kwargs to WaybackMachine' do
      url = 'https://example.com'
      expected_result = WaybackArchiver::ArchiveResult.new(url)

      allow(WaybackArchiver::WaybackMachine).to receive(:call).and_return(expected_result)

      described_class.post_url(url, capture_all: true)

      expect(WaybackArchiver::WaybackMachine).to have_received(:call).with(url, capture_all: true)
    end

    it 'returns ArchiveResult with error when WaybackMachine fails' do
      url = 'https://example.com'
      error_result = WaybackArchiver::ArchiveResult.new(url, error: StandardError.new('boom'))

      allow(WaybackArchiver::WaybackMachine).to receive(:call).and_return(error_result)

      result = described_class.post_url(url)

      expect(result.uri).to eq(url)
      expect(result.errored?).to eq(true)
    end
  end
end
