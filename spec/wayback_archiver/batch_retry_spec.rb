require 'spec_helper'

# Retry timing for the batch pipeline, exercised through the real
# orchestration (Archive.post -> BatchSubmitter) with HTTP stubbed at the
# WebMock level. Time is simulated: every sleep inside BatchSubmitter advances
# a fake monotonic clock instead of the wall clock, so the specs can assert on
# elapsed seconds without waiting for them.
RSpec.describe WaybackArchiver::Archive, 'batch retry backoff' do
  # `sleep` advances the clock, `monotonic_now` reads it.
  let(:clock) { SimulatedClock.new }

  before do
    # spec_helper zeroes the backoff for every other spec; these specs are
    # about the backoff, so put the real delay back.
    stub_const('WaybackArchiver::BatchSubmitter::RETRY_BASE_DELAY', 2)

    WaybackArchiver.config.access_key = 'test-ak'
    WaybackArchiver.config.secret_key = 'test-sk'
    # Setting credentials rebuilds the capture rate limiter, undoing the one
    # spec_helper disabled — and these specs submit more than its 6/min.
    WaybackArchiver::WaybackMachine.instance_variable_set(
      :@rate_limiter,
      WaybackArchiver::RateLimiter.new(max_requests: 999, enabled: false)
    )

    allow_any_instance_of(WaybackArchiver::BatchSubmitter)
      .to receive(:monotonic_now) { clock.now }
    allow_any_instance_of(WaybackArchiver::BatchSubmitter)
      .to receive(:sleep) { |_instance, seconds| clock.advance(seconds) }

    stub_request(:get, %r{https://web\.archive\.org/save/status/user})
      .to_return(status: 200, body: { 'available' => 12, 'processing' => 0 }.to_json)
  end

  # Records the simulated time of every capture request, per URL.
  def record_submits
    times = Hash.new { |h, k| h[k] = [] }
    stub_request(:post, 'https://web.archive.org/save')
      .to_return do |request|
        url = URI.decode_www_form(request.body).to_h['url']
        times[url] << clock.now
        { status: 200, body: yield(url).to_json }
      end
    times
  end

  def transient_error(status_ext = 'error:service-unavailable')
    { 'status' => 'error', 'status_ext' => status_ext, 'message' => 'Service unavailable' }
  end

  def stub_batch_poll(statuses)
    stub_request(:post, 'https://web.archive.org/save/status')
      .to_return(status: 200, body: statuses.to_json)
  end

  # Delays are MAX_RETRIES attempts of 2 * 2**(n - 1), each with up to 10%
  # jitter: 2, 4, 8, 16, 32 -> 62s, at most 68.2s.
  let(:total_backoff) { 62.0 }
  let(:max_jitter) { 1.1 }

  describe 'transient submit errors' do
    it 'spaces the retries of one URL with exponential backoff' do
      url = 'http://example.com'
      times = record_submits { transient_error }

      results = described_class.post([url], concurrency: 1)

      attempts = times[url]
      expect(attempts.length).to eq(WaybackArchiver::BatchSubmitter::MAX_RETRIES + 1)

      gaps = attempts.each_cons(2).map { |a, b| b - a }
      [2, 4, 8, 16, 32].each_with_index do |expected, i|
        expect(gaps[i]).to be_between(expected, expected * max_jitter)
      end

      expect(clock.now).to be >= total_backoff
      expect(results.length).to eq(1)
    end

    it 'keeps the original failure category when the retries run out' do
      times = record_submits { transient_error('error:no-browsers-available') }

      results = described_class.post(['http://example.com'], concurrency: 1)

      expect(times['http://example.com'].length).to eq(WaybackArchiver::BatchSubmitter::MAX_RETRIES + 1)
      result = results.first
      expect(result.errored?).to eq(true)
      expect(result.status_ext).to eq('error:no-browsers-available')
      expect(result.error_category).to eq(:transient)
    end

    it 'waits out one backoff when the retry succeeds' do
      url = 'http://example.com'
      attempt = 0
      times = record_submits do |_url|
        attempt += 1
        attempt == 1 ? transient_error : { 'url' => url, 'job_id' => 'job-1' }
      end
      stub_batch_poll(
        'job-1' => {
          'status' => 'success', 'job_id' => 'job-1',
          'timestamp' => '20260326120000', 'original_url' => url
        }
      )

      results = described_class.post([url], concurrency: 1)

      expect(times[url].length).to eq(2)
      expect(times[url][1] - times[url][0]).to be_between(2, 2 * max_jitter)
      expect(results.first.success?).to eq(true)
    end

    it 'backs off each URL independently instead of serializing them' do
      urls = %w[http://a.com http://b.com]
      times = record_submits { transient_error }

      described_class.post(urls, concurrency: 1)

      urls.each do |url|
        expect(times[url].length).to eq(WaybackArchiver::BatchSubmitter::MAX_RETRIES + 1)
      end
      # Both URLs back off on their own schedule and are retried in the same
      # waves; one waiting must not push the other's attempts further out.
      expect(clock.now).to be < total_backoff * 2
    end
  end

  describe 'transient poll errors' do
    it 'waits before resubmitting a job that failed transiently' do
      url = 'http://example.com'
      attempt = 0
      times = record_submits do |_url|
        attempt += 1
        { 'url' => url, 'job_id' => "job-#{attempt}" }
      end

      stub_batch_poll(
        'job-1' => { 'status' => 'error', 'job_id' => 'job-1', 'status_ext' => 'error:gateway-timeout' }
      ).then.to_return(
        status: 200,
        body: {
          'job-2' => {
            'status' => 'success', 'job_id' => 'job-2',
            'timestamp' => '20260326120000', 'original_url' => url
          }
        }.to_json
      )

      results = described_class.post([url], concurrency: 1)

      expect(times[url].length).to eq(2)
      expect(times[url][1] - times[url][0]).to be_between(2, 2 * max_jitter)
      expect(results.first.success?).to eq(true)
    end
  end
end
