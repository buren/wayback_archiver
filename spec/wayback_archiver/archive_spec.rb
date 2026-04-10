require 'spec_helper'
require 'tmpdir'

RSpec.describe WaybackArchiver::Archive do
  describe '::post' do
    before do
      allow(described_class).to receive(:sleep)
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
        # Should have tried submit 4 times (1 + 3 retries)
        expect(WaybackArchiver::WaybackMachine).to have_received(:submit).exactly(4).times
      end
    end
  end

  describe '::crawl' do
    before do
      allow(described_class).to receive(:sleep)
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
