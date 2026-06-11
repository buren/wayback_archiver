require 'spec_helper'

# Integration tests for Archive.post that stub at the HTTP level (WebMock)
# rather than mocking WaybackMachine methods. Exercises the full
# submit → poll → result chain through real Ruby code.
RSpec.describe WaybackArchiver::Archive, 'integration' do
  before do
    WaybackArchiver.config.access_key = 'test-ak'
    WaybackArchiver.config.secret_key = 'test-sk'

    allow_any_instance_of(WaybackArchiver::BatchSubmitter).to receive(:sleep)

    stub_request(:get, %r{https://web\.archive\.org/save/status/user})
      .to_return(status: 200, body: { 'available' => 12, 'processing' => 0 }.to_json)
  end

  def stub_submit(url, response_body)
    stub_request(:post, 'https://web.archive.org/save')
      .with(body: hash_including('url' => url))
      .to_return(status: 200, body: response_body.to_json)
  end

  def stub_batch_poll(statuses)
    stub_request(:post, 'https://web.archive.org/save/status')
      .to_return(status: 200, body: statuses.to_json)
  end

  def success_status(job_id, url, timestamp: '20260326120000')
    {
      'status' => 'success',
      'job_id' => job_id,
      'timestamp' => timestamp,
      'original_url' => url,
      'duration_sec' => 4.2,
      'resources' => [],
      'outlinks' => {}
    }
  end

  describe 'happy path: submit → poll → success' do
    it 'archives a single URL through the full submit and poll cycle' do
      url = 'http://example.com'
      job_id = 'spn2-abc123'

      stub_submit(url, { 'url' => url, 'job_id' => job_id })

      stub_batch_poll(
        job_id => { 'status' => 'pending', 'job_id' => job_id }
      ).then
       .to_return(status: 200, body: {
         job_id => success_status(job_id, url)
       }.to_json)

      results = described_class.post([url], concurrency: 1)

      expect(results.length).to eq(1)
      result = results.first
      expect(result.success?).to eq(true)
      expect(result.uri).to eq(url)
      expect(result.timestamp).to eq('20260326120000')
    end
  end

  describe 'multiple URLs: submit all → batch poll → all succeed' do
    it 'archives multiple URLs and collects all results' do
      urls = %w[http://a.com http://b.com http://c.com]
      jobs = {
        'http://a.com' => 'job-a',
        'http://b.com' => 'job-b',
        'http://c.com' => 'job-c'
      }

      # Each URL gets its own submit stub
      urls.each do |url|
        stub_submit(url, { 'url' => url, 'job_id' => jobs[url] })
      end

      # First poll: all pending. Second poll: all succeed.
      pending_statuses = jobs.transform_keys { |url| jobs[url] }
        .transform_values { |job_id| { 'status' => 'pending', 'job_id' => job_id } }

      success_statuses = jobs.map { |url, job_id|
        [job_id, success_status(job_id, url)]
      }.to_h

      stub_batch_poll(pending_statuses)
        .then
        .to_return(status: 200, body: success_statuses.to_json)

      yielded = []
      results = described_class.post(urls, concurrency: 1) { |r| yielded << r }

      expect(results.length).to eq(3)
      expect(results.map(&:uri)).to match_array(urls)
      expect(results).to all(satisfy(&:success?))

      # Block receives submitted notifications + completed results
      expect(yielded.length).to be >= 3
    end

    it 'fires listener events for each URL' do
      urls = %w[http://a.com http://b.com]
      jobs = { 'http://a.com' => 'job-a', 'http://b.com' => 'job-b' }

      urls.each { |url| stub_submit(url, { 'url' => url, 'job_id' => jobs[url] }) }

      success_statuses = jobs.map { |url, job_id|
        [job_id, success_status(job_id, url)]
      }.to_h

      stub_batch_poll(success_statuses)

      described_class.post(urls, concurrency: 1)

      listener = WaybackArchiver.config.listener
      expect(listener.batch_start_events.length).to eq(1)
      expect(listener.batch_start_events.first[:total]).to eq(2)
      expect(listener.submitted_events.length).to eq(2)
      expect(listener.completed_events.length).to eq(2)
    end
  end

  describe 'transient error → retry → success' do
    it 'requeues a URL on retryable submit error and succeeds on second attempt' do
      url = 'http://example.com/retry'
      job_id = 'job-retry-ok'

      # First submit: session limit error (triggers retry in batch mode)
      # Second submit: success with job_id
      stub_request(:post, 'https://web.archive.org/save')
        .with(body: hash_including('url' => url))
        .to_return(
          { status: 200, body: { 'message' => 'You have reached the limit of active sessions' }.to_json },
          { status: 200, body: { 'url' => url, 'job_id' => job_id }.to_json }
        )

      # After successful submit, poll returns success
      stub_batch_poll(job_id => success_status(job_id, url))

      results = described_class.post([url], concurrency: 1)

      expect(results.length).to eq(1)
      result = results.first
      expect(result.success?).to eq(true)
      expect(result.uri).to eq(url)

      # Submit was called twice (retry)
      expect(WebMock).to have_requested(:post, 'https://web.archive.org/save')
        .with(body: hash_including('url' => url))
        .times(2)
    end

    it 'fails after exceeding max retries' do
      url = 'http://example.com/fail'

      # All submits return session limit error
      stub_request(:post, 'https://web.archive.org/save')
        .with(body: hash_including('url' => url))
        .to_return(
          status: 200,
          body: { 'message' => 'You have reached the limit of active sessions' }.to_json
        )

      results = described_class.post([url], concurrency: 1)

      expect(results.length).to eq(1)
      expect(results.first.errored?).to eq(true)

      # 1 initial + MAX_RETRIES (5) = 6 attempts
      expect(WebMock).to have_requested(:post, 'https://web.archive.org/save')
        .with(body: hash_including('url' => url))
        .times(6)
    end
  end

  describe 'transient submit-time status_ext → retry → success' do
    # Regression: batch mode only retried submit responses whose message
    # contained 'limit of active'; a retryable status_ext (per ErrorCodes)
    # was recorded as a permanent failure — while the single-URL path
    # retried it. Both paths must honor ErrorCodes.retryable?.
    it 'retries a submit response with a retryable status_ext' do
      url = 'http://example.com/transient'
      job_id = 'job-transient-ok'

      stub_request(:post, 'https://web.archive.org/save')
        .with(body: hash_including('url' => url))
        .to_return(
          { status: 200, body: { 'status' => 'error', 'status_ext' => 'error:too-many-requests',
                                 'message' => 'The server cannot currently handle the request' }.to_json },
          { status: 200, body: { 'url' => url, 'job_id' => job_id }.to_json }
        )

      stub_batch_poll(job_id => success_status(job_id, url))

      results = described_class.post([url], concurrency: 1)

      expect(results.length).to eq(1)
      expect(results.first.success?).to eq(true)
      expect(WebMock).to have_requested(:post, 'https://web.archive.org/save')
        .with(body: hash_including('url' => url))
        .times(2)
    end

    # Regression: a 5xx/429 with a non-JSON body (HTML load-shedding page)
    # became JSON::ParserError → terminal failure, bypassing all retry.
    it 'retries a raw HTTP 503 with an HTML body on submit' do
      url = 'http://example.com/lb-hiccup'
      job_id = 'job-lb-ok'
      call_count = 0

      stub_request(:post, 'https://web.archive.org/save')
        .with(body: hash_including('url' => url))
        .to_return do
          call_count += 1
          if call_count == 1
            { status: 503, body: '<html>Service Unavailable</html>' }
          else
            { status: 200, body: { 'url' => url, 'job_id' => job_id }.to_json }
          end
        end

      stub_batch_poll(job_id => success_status(job_id, url))

      results = described_class.post([url], concurrency: 1)

      expect(results.length).to eq(1)
      expect(results.first.success?).to eq(true)
      expect(call_count).to eq(2)
    end

    it 'records the status_ext on permanent submit failures' do
      url = 'http://example.com/blocked'

      stub_request(:post, 'https://web.archive.org/save')
        .with(body: hash_including('url' => url))
        .to_return(status: 200, body: { 'status' => 'error', 'status_ext' => 'error:blocked-url',
                                        'message' => 'URL is on a block list' }.to_json)

      results = described_class.post([url], concurrency: 1)

      expect(results.length).to eq(1)
      expect(results.first.errored?).to eq(true)
      expect(results.first.status_ext).to eq('error:blocked-url')
      # Permanent error: no retry
      expect(WebMock).to have_requested(:post, 'https://web.archive.org/save')
        .with(body: hash_including('url' => url))
        .times(1)
    end
  end

  describe 'transient poll error → re-submit → success' do
    it 're-queues URL on transient poll error and succeeds on second attempt' do
      url = 'http://example.com/proxy-retry'
      job1 = 'job-fail'
      job2 = 'job-ok'

      # First submit → job1, second submit → job2
      stub_request(:post, 'https://web.archive.org/save')
        .with(body: hash_including('url' => url))
        .to_return(
          { status: 200, body: { 'url' => url, 'job_id' => job1 }.to_json },
          { status: 200, body: { 'url' => url, 'job_id' => job2 }.to_json }
        )

      # First poll: job1 returns transient error
      # Second poll: job2 succeeds
      stub_request(:post, 'https://web.archive.org/save/status')
        .to_return(
          { status: 200, body: { job1 => { 'status' => 'error', 'job_id' => job1, 'status_ext' => 'error:proxy-error' } }.to_json },
          { status: 200, body: { job2 => success_status(job2, url) }.to_json }
        )

      results = described_class.post([url], concurrency: 1)

      expect(results.length).to eq(1)
      expect(results.first.success?).to eq(true)
      expect(results.first.uri).to eq(url)

      # Submit called twice (original + re-queue after transient poll error)
      expect(WebMock).to have_requested(:post, 'https://web.archive.org/save')
        .with(body: hash_including('url' => url))
        .times(2)
    end

    it 'fails after exceeding max retries from transient poll errors' do
      url = 'http://example.com/always-proxy-error'

      # Every submit returns a new job_id
      call_count = 0
      stub_request(:post, 'https://web.archive.org/save')
        .with(body: hash_including('url' => url))
        .to_return do |_req|
          call_count += 1
          { status: 200, body: { 'url' => url, 'job_id' => "job-#{call_count}" }.to_json }
        end

      # Every poll returns transient error
      stub_request(:post, 'https://web.archive.org/save/status')
        .to_return do |req|
          body = URI.decode_www_form(req.body).to_h
          job_ids = body['job_ids'].split(',')
          statuses = job_ids.to_h { |jid| [jid, { 'status' => 'error', 'job_id' => jid, 'status_ext' => 'error:bad-gateway' }] }
          { status: 200, body: statuses.to_json }
        end

      results = described_class.post([url], concurrency: 1)

      expect(results.length).to eq(1)
      expect(results.first.errored?).to eq(true)

      # 1 initial + MAX_RETRIES (5) = 6 submit attempts
      expect(WebMock).to have_requested(:post, 'https://web.archive.org/save')
        .with(body: hash_including('url' => url))
        .times(6)
    end

    it 'does not re-queue permanent poll errors' do
      url = 'http://example.com/blocked'
      job_id = 'job-blocked'

      stub_submit(url, { 'url' => url, 'job_id' => job_id })

      stub_batch_poll(
        job_id => { 'status' => 'error', 'job_id' => job_id, 'status_ext' => 'error:blocked-url' }
      )

      results = described_class.post([url], concurrency: 1)

      expect(results.length).to eq(1)
      expect(results.first.errored?).to eq(true)
      expect(results.first.status_ext).to eq('error:blocked-url')

      # Only 1 submit — no re-queue for permanent errors
      expect(WebMock).to have_requested(:post, 'https://web.archive.org/save')
        .with(body: hash_including('url' => url))
        .times(1)
    end
  end

  describe 'retry logging' do
    it 'logs transient poll errors at debug level and only errors on final failure' do
      url = 'http://example.com/quiet-retry'

      call_count = 0
      stub_request(:post, 'https://web.archive.org/save')
        .with(body: hash_including('url' => url))
        .to_return do |_req|
          call_count += 1
          { status: 200, body: { 'url' => url, 'job_id' => "job-#{call_count}" }.to_json }
        end

      stub_request(:post, 'https://web.archive.org/save/status')
        .to_return do |req|
          body = URI.decode_www_form(req.body).to_h
          job_ids = body['job_ids'].split(',')
          statuses = job_ids.to_h { |jid| [jid, { 'status' => 'error', 'job_id' => jid, 'status_ext' => 'error:proxy-error' }] }
          { status: 200, body: statuses.to_json }
        end

      described_class.post([url], concurrency: 1)

      # Intermediate retries should NOT be warn level
      warn_transient_lines = WaybackArchiver.logger.warn_log.select { |l| l.include?('Transient poll error') }
      expect(warn_transient_lines).to be_empty

      # They should be at debug level
      debug_transient_lines = WaybackArchiver.logger.debug_log.select { |l| l.include?('Transient poll error') }
      expect(debug_transient_lines).not_to be_empty

      # Final failure stays at error level
      error_lines = WaybackArchiver.logger.error_log.select { |l| l.include?('Retry limit exceeded') }
      expect(error_lines.length).to eq(1)
    end
  end

  describe 'cached result (if_not_archived_within)' do
    it 'returns cached result without polling when server has recent snapshot' do
      url = 'http://example.com/cached'

      # Submit returns timestamp directly (no job_id) — server-side cache hit
      stub_submit(url, {
        'url' => url,
        'timestamp' => '20260325180000',
        'duration_sec' => 0,
        'resources' => [],
        'outlinks' => {},
        'original_url' => url
      })

      results = described_class.post([url], concurrency: 1, if_not_archived_within: '7d')

      expect(results.length).to eq(1)
      result = results.first
      expect(result.cached?).to eq(true)
      expect(result.uri).to eq(url)
      expect(result.timestamp).to eq('20260325180000')

      # No batch poll should have been made (no pending jobs)
      expect(WebMock).not_to have_requested(:post, 'https://web.archive.org/save/status')
    end
  end
end
