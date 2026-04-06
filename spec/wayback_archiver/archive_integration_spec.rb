require 'spec_helper'

# Integration tests for Archive.post that stub at the HTTP level (WebMock)
# rather than mocking WaybackMachine methods. Exercises the full
# submit → poll → result chain through real Ruby code.
RSpec.describe WaybackArchiver::Archive, 'integration' do
  before do
    WaybackArchiver.config.access_key = 'test-ak'
    WaybackArchiver.config.secret_key = 'test-sk'

    allow(WaybackArchiver::Archive).to receive(:sleep)

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

      # 1 initial + MAX_RETRIES (3) = 4 attempts
      expect(WebMock).to have_requested(:post, 'https://web.archive.org/save')
        .with(body: hash_including('url' => url))
        .times(4)
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
