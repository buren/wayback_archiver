require 'spec_helper'

# Batch submission with the capture rate limiter actually enabled.
#
# Every other spec runs with it disabled (spec_helper), so nothing verified
# that the documented 6 captures/minute reaches the batch path at all, nor how
# pacing interacts with the poll deadline and the per-URL retry backoff — the
# two other things in this pipeline that watch the clock.
#
# Time is simulated: the limiter sleeps inside its mutex, and a real run of
# these specs would take minutes.
RSpec.describe WaybackArchiver::Archive, 'batch pacing' do
  let(:clock) { SimulatedClock.new }
  let(:rate) { WaybackArchiver::RateLimiter::RATE }
  let(:submits) { [] }
  let(:record_lock) { Mutex.new }
  # Every HTTP round trip costs a little time. Without it the sliding window
  # is fed a stream of identical timestamps, which no real clock produces and
  # which its pruning rule (drop timestamps strictly older than the cutoff)
  # does not model well.
  let(:request_duration) { 0.01 }

  def enable_rate_limiter!(max_requests: rate)
    # Assigning credentials calls reset_rate_limiter!, which discards the
    # disabled limiter spec_helper installed and lazily builds a real one — the
    # trap behind more than one mysteriously slow spec. Here that is what we
    # want, so it is done deliberately and the limiter is built explicitly.
    WaybackArchiver.config.access_key = 'test-ak'
    WaybackArchiver.config.secret_key = 'test-sk'
    allow(WaybackArchiver::RateLimiter).to receive(:for_current_user)
      .and_return(WaybackArchiver::RateLimiter.new(max_requests: max_requests))
    WaybackArchiver::WaybackMachine.reset_rate_limiter!
  end

  def urls(count)
    Array.new(count) { |i| "https://example.com/page-#{i}" }
  end

  def tick
    clock.advance(request_duration)
  end

  before do
    enable_rate_limiter!

    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { clock.now }
    [WaybackArchiver::RateLimiter, WaybackArchiver::BatchSubmitter].each do |klass|
      allow_any_instance_of(klass).to receive(:sleep) { |_instance, seconds| clock.advance(seconds) }
    end

    stub_request(:get, %r{https://web\.archive\.org/save/status/user}).to_return do
      tick
      { status: 200, body: { 'available' => 12, 'processing' => 0 }.to_json }
    end

    stub_request(:post, 'https://web.archive.org/save').to_return do |request|
      url = URI.decode_www_form(request.body.to_s).to_h['url']
      job_id = record_lock.synchronize do
        submits << [url, clock.now]
        "job-#{submits.length}"
      end
      tick
      { status: 200, body: submit_response(url, job_id).to_json }
    end

    stub_request(:post, 'https://web.archive.org/save/status').to_return do |request|
      ids = URI.decode_www_form(request.body.to_s).to_h['job_ids'].to_s.split(',')
      tick
      { status: 200, body: ids.to_h { |id| [id, poll_status(id)] }.to_json }
    end
  end

  # Overridden per example group to inject failures or pending jobs.
  def submit_response(url, job_id)
    { 'url' => url, 'job_id' => job_id }
  end

  def poll_status(job_id)
    success_status(job_id)
  end

  def success_status(job_id)
    {
      'status' => 'success', 'job_id' => job_id,
      'timestamp' => '20260326120000', 'original_url' => 'https://example.com'
    }
  end

  def submit_times
    submits.map(&:last)
  end

  describe 'the capture rate' do
    it 'paces submissions at the documented captures per minute' do
      results = described_class.post(urls(rate * 2), concurrency: 1)

      expect(results.count(&:success?)).to eq(rate * 2)
      # The window opens at the first capture, so exactly one window's worth
      # of captures may happen before a full minute has passed.
      expect(submit_times.count { |at| at < 60 }).to eq(rate)
      expect(clock.now).to be >= 60
    end

    it 'holds the cap across concurrent submitters' do
      # The limiter sleeps while holding its mutex precisely so that pacing is
      # shared: four threads must not get four separate allowances.
      described_class.post(urls(rate * 2), concurrency: 4)

      expect(submits.length).to eq(rate * 2)
      expect(submit_times.count { |at| at < 60 }).to eq(rate)
    end

    it 'costs nothing when the limiter is disabled' do
      # The counterfactual: without this, a pacing assertion could be satisfied
      # by any other sleep in the pipeline.
      allow(WaybackArchiver::RateLimiter).to receive(:for_current_user)
        .and_return(WaybackArchiver::RateLimiter.new(max_requests: 999, enabled: false))
      WaybackArchiver::WaybackMachine.reset_rate_limiter!

      described_class.post(urls(rate * 2), concurrency: 1)

      expect(submits.length).to eq(rate * 2)
      expect(clock.now).to be < 60
    end
  end

  describe 'the poll deadline' do
    let(:total) { rate * 4 }
    # Polls issued once every URL has been submitted.
    let(:final_polls) { [] }

    # Jobs stay pending through the submission loop *and* through the
    # intermediate poll that follows the last chunk, so they are still
    # outstanding when the final poll phase starts its deadline — several
    # minutes into a run that spent them waiting for capture slots. A deadline
    # measured from the start of the run would report every job as unconfirmed.
    before do
      stub_request(:post, 'https://web.archive.org/save/status').to_return do |request|
        ids = URI.decode_www_form(request.body.to_s).to_h['job_ids'].to_s.split(',')
        tick
        submitted_all = submits.length >= total
        record_lock.synchronize { final_polls << clock.now } if submitted_all
        resolved = submitted_all && final_polls.length > 1

        body = ids.to_h do |id|
          [id, resolved ? success_status(id) : { 'status' => 'pending', 'job_id' => id }]
        end
        { status: 200, body: body.to_json }
      end
    end

    it 'is not spent waiting for capture slots' do
      results = described_class.post(urls(total), concurrency: 1)

      expect(clock.now).to be > WaybackArchiver::WaybackMachine::POLL_TIMEOUT
      # More than one poll after the last submission means the run really did
      # hand over to the final poll phase rather than resolving on the way.
      expect(final_polls.length).to be >= 2
      expect(final_polls.first).to be > WaybackArchiver::WaybackMachine::POLL_TIMEOUT
      expect(results.count(&:success?)).to eq(total)
      expect(results.select(&:incomplete?)).to be_empty
    end
  end

  describe 'a transient failure while the limiter is pacing the run' do
    def submit_response(url, job_id)
      return { 'status' => 'error', 'status_ext' => 'error:service-unavailable' } if first_attempt?(url)

      { 'url' => url, 'job_id' => job_id }
    end

    def first_attempt?(url)
      record_lock.synchronize { submits.count { |submitted, _| submitted == url } == 1 }
    end

    before { stub_const('WaybackArchiver::BatchSubmitter::RETRY_BASE_DELAY', 2) }

    it 'recovers instead of exhausting its retries' do
      results = described_class.post(urls(rate * 2), concurrency: 1)

      expect(results.count(&:success?)).to eq(rate * 2)
      expect(results.select(&:errored?)).to be_empty
      # One retry each, not five: waiting for a capture slot is not a failure.
      expect(submits.length).to eq(rate * 4)
    end
  end
end
