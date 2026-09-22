require 'spec_helper'
require 'wayback_archiver/cdx'

RSpec.describe WaybackArchiver::CDX do
  let(:cdx_url) { 'https://web.archive.org/cdx/search/cdx' }

  def fixture(name)
    File.read(File.expand_path("../data/cdx/#{name}", __dir__))
  end

  before do
    described_class.instance_variable_set(
      :@rate_limiter,
      WaybackArchiver::RateLimiter.new(max_requests: 999, enabled: false)
    )
    # Transient failures are retried with backoff — never sleep for real.
    allow(WaybackArchiver::Retry).to receive(:sleep)
  end

  def cdx_json_response(timestamp: '20260326120000', url: 'http://example.com')
    [
      %w[urlkey timestamp original mimetype statuscode digest length],
      ["com,example)/", timestamp, url, "text/html", "200", "ABC123", "1234"]
    ].to_json
  end

  describe '.reset_rate_limiter!' do
    it 'clears the rate limiter so a fresh one is created' do
      old_limiter = described_class.rate_limiter
      described_class.reset_rate_limiter!
      new_limiter = described_class.rate_limiter

      expect(new_limiter).not_to equal(old_limiter)
    end
  end

  describe '.check' do
    it 'returns archived CheckResult when CDX has a match' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .to_return(status: 200, body: cdx_json_response)

      result = described_class.check('http://example.com')

      expect(result).to be_a(WaybackArchiver::CheckResult)
      expect(result.archived?).to eq(true)
      expect(result.timestamp).to eq('20260326120000')
      expect(result.url).to eq('http://example.com')
    end

    it 'preserves the exact original URL from a recorded CDX response' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .to_return(status: 200, body: fixture('success.json'))

      result = described_class.check('https://cnn.com')

      expect(result.original_url).to eq('http://www.cnn.com/')
      expect(result.timestamp).to eq('20100215131836')
      expect(result.wayback_url)
        .to eq('https://web.archive.org/web/20100215131836/http://www.cnn.com/')
    end

    it 'returns not-archived CheckResult when CDX returns empty' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .to_return(status: 200, body: '[]')

      result = described_class.check('http://nonexistent.com')

      expect(result.archived?).to eq(false)
      expect(result.timestamp).to be_nil
    end

    it 'returns an errored CheckResult on an invalid empty response' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .to_return(status: 200, body: '')

      result = described_class.check('http://nonexistent.com')

      expect(result.archived?).to eq(false)
      expect(result.errored?).to eq(true)
      expect(result.error_category).to eq(:malformed_response)
    end

    it 'returns an errored CheckResult on an HTTP failure' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .to_return(status: 503, body: '<html>Service Unavailable</html>')

      result = described_class.check('http://example.com')

      expect(result.archived?).to eq(false)
      expect(result.errored?).to eq(true)
      expect(result.error_category).to eq(:request_failed)
      expect(result.error).to be_a(WaybackArchiver::Request::ResponseError)
    end

    it 'returns an errored CheckResult for an unexpected JSON object' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .to_return(status: 200, body: fixture('malformed.json'))

      result = described_class.check('http://example.com')

      expect(result.errored?).to eq(true)
      expect(result).to be_malformed_response
      expect(result.error).to be_a(described_class::UnexpectedResponseError)
    end

    it 'classifies a recorded administrative block without retrying it' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .to_return(status: 403, body: fixture('blocked_site.txt'))

      result = described_class.check('https://nationalpost.com/health')

      expect(result.error_category).to eq(:blocked_site)
      expect(result).to be_blocked
      expect(result.error).to be_a(described_class::BlockedSiteError)
      expect(WebMock).to have_requested(:get, /#{Regexp.escape(cdx_url)}/).once
    end

    it 'classifies a robots-policy block without retrying it' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .to_return(status: 403, body: fixture('blocked_by_robots.txt'))

      result = described_class.check('http://example.com/private')

      expect(result.error_category).to eq(:blocked_by_robots)
      expect(result).to be_blocked
      expect(result.error).to be_a(described_class::BlockedByRobotsError)
      expect(WebMock).to have_requested(:get, /#{Regexp.escape(cdx_url)}/).once
    end

    it 'returns not-archived CheckResult on CDX error' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .to_raise(Timeout::Error)

      result = described_class.check('http://example.com')

      expect(result.archived?).to eq(false)
      expect(result.error_category).to eq(:request_failed)
      expect(result.error).to be_a(WaybackArchiver::Request::ServerError)
    end

    it 'includes from parameter when specified' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}.*from=20260301/)
        .to_return(status: 200, body: cdx_json_response)

      result = described_class.check('http://example.com', from: '20260301000000')

      expect(result.archived?).to eq(true)
    end

    it 'does not include from parameter when nil' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .with { |req| !req.uri.query.include?('from=') }
        .to_return(status: 200, body: cdx_json_response)

      described_class.check('http://example.com')
    end

    it 'encodes every query value without allowing parameter injection' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .with do |req|
          pairs = URI.decode_www_form(req.uri.query)
          params = pairs.to_h
          params['url'] == 'http://example.com/path?q=1&from=attacker' &&
            params['from'] == '20260301000000&filter=attacker' &&
            pairs.count { |key, _| key == 'filter' } == 1 &&
            params['filter'] == 'statuscode:200'
        end
        .to_return(status: 200, body: '[]')

      result = described_class.check(
        'http://example.com/path?q=1&from=attacker',
        from: '20260301000000&filter=attacker'
      )
      expect(result).to be_a(WaybackArchiver::CheckResult)
    end

    it 'requests the most recent capture using limit=-1' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .with { |req| req.uri.query.include?('limit=-1') }
        .to_return(status: 200, body: cdx_json_response)

      described_class.check('http://example.com')
    end

    it 'acquires rate limiter before making request' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .to_return(status: 200, body: cdx_json_response)

      expect(described_class.rate_limiter).to receive(:acquire).once

      described_class.check('http://example.com')
    end
  end

  describe '.check_urls' do
    it 'checks multiple URLs and returns results' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .to_return(status: 200, body: cdx_json_response)

      results = described_class.check_urls(
        ['http://a.com', 'http://b.com'],
        concurrency: 1
      )

      expect(results.length).to eq(2)
      expect(results).to all(be_a(WaybackArchiver::CheckResult))
    end

    it 'yields each result as it completes' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .to_return(status: 200, body: cdx_json_response)

      yielded = []
      described_class.check_urls(['http://a.com', 'http://b.com'], concurrency: 1) do |result|
        yielded << result
      end

      expect(yielded.length).to eq(2)
    end

    it 'passes from parameter to each check' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}.*from=20260301/)
        .to_return(status: 200, body: cdx_json_response)

      results = described_class.check_urls(
        ['http://example.com'],
        concurrency: 1,
        from: '20260301000000'
      )

      expect(results.first.archived?).to eq(true)
    end
  end

  describe 'concurrency safety' do
    # Regression: a bare ||= built one limiter per racing worker, briefly
    # multiplying the requests/sec cap.
    it 'builds the rate limiter exactly once under concurrency' do
      described_class.reset_rate_limiter!
      built = Concurrent::AtomicFixnum.new(0)
      allow(WaybackArchiver::RateLimiter).to receive(:new) do |**|
        sleep 0.02 # widen the window so an unsynchronised ||= interleaves
        built.increment
        instance_double(WaybackArchiver::RateLimiter, acquire: nil)
      end

      12.times.map { Thread.new { described_class.rate_limiter } }.each(&:join)

      expect(built.value).to eq(1)
    ensure
      described_class.reset_rate_limiter!
    end

    # Regression: an exception escaping a pool worker is swallowed by
    # concurrent-ruby, so the URL silently vanished from the results — and a
    # failed lookup must read as "unknown", never as "not archived".
    it 'records a result even when a check raises unexpectedly' do
      allow(described_class).to receive(:check) do |url, **|
        raise 'boom' if url.end_with?('b')

        WaybackArchiver::CheckResult.new(url, archived: true, timestamp: '20260101000000')
      end

      results = described_class.check_urls(%w[http://a.com/a http://a.com/b], concurrency: 2)

      expect(results.length).to eq(2)
      expect(results.find { |r| r.url.end_with?('b') }).to be_errored
    end
  end

  describe 'retrying transient CDX failures' do
    # archive.org's CDX endpoint 503s intermittently — a live smoke test saw
    # 3 of 5 lookups fail, two of which succeeded on the very next attempt.
    # One shot per URL meant --check exited 1 most of the time and
    # --skip-archived re-archived URLs that were already in the archive.
    let(:rows) { '[["urlkey","timestamp"],["com,example)/","20260101000000"]]' }

    it 'retries a 503 and succeeds' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .to_return({ status: 503, body: 'busy' }, { status: 200, body: rows })

      result = described_class.check('http://example.com')

      expect(result.archived?).to eq(true)
      expect(result.errored?).to eq(false)
      expect(result.timestamp).to eq('20260101000000')
    end

    it 'retries a connection error and succeeds' do
      call = 0
      stub_request(:get, /#{Regexp.escape(cdx_url)}/).to_return do
        call += 1
        raise Timeout::Error if call == 1

        { status: 200, body: rows }
      end

      expect(described_class.check('http://example.com').archived?).to eq(true)
    end

    it 'gives up after the retry limit and preserves the original error' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/).to_return(status: 503, body: 'busy')

      result = described_class.check('http://example.com')

      expect(result.errored?).to eq(true)
      expect(result.error).to be_a(WaybackArchiver::Request::ResponseError)
      expect(result.error.code).to eq(503)
      expect(WebMock).to have_requested(:get, /#{Regexp.escape(cdx_url)}/)
        .times(described_class::MAX_RETRIES + 1)
    end

    it 'does not retry a client error that will not fix itself' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/).to_return(status: 400, body: 'bad')

      result = described_class.check('http://example.com')

      expect(result.errored?).to eq(true)
      expect(WebMock).to have_requested(:get, /#{Regexp.escape(cdx_url)}/).once
    end

    it 'does not retry a malformed but successful response' do
      stub_request(:get, /#{Regexp.escape(cdx_url)}/)
        .to_return(status: 200, body: '{"message":"nope"}')

      expect(described_class.check('http://example.com').errored?).to eq(true)
      expect(WebMock).to have_requested(:get, /#{Regexp.escape(cdx_url)}/).once
    end
  end

  describe '.rate_limiter' do
    # Internet Archive halved the CDX hard limit to 30/min: the reference
    # Python client dropped its default to 24/min in v0.5.1 (2026-06-19)
    # "in order to match the actual hard limits now set on Wayback Machine
    # servers". The older 60/min figure quoted in wayback#137 is superseded.
    # Exceeding it earns 429s, then an hour-long IP firewall block that
    # doubles on repeat. This was 15/s — thirty times the current ceiling.
    it 'stays inside the current 30 requests/minute hard limit' do
      described_class.reset_rate_limiter!
      limiter = described_class.rate_limiter

      expect(limiter.window).to eq(60.0)
      expect(limiter.max_requests).to be <= 30
    ensure
      described_class.reset_rate_limiter!
    end

    it 'leaves the headroom the reference client uses' do
      described_class.reset_rate_limiter!

      # 80% of the hard limit — the margin IA asked the Python client to adopt.
      expect(described_class.rate_limiter.max_requests).to eq(24)
    ensure
      described_class.reset_rate_limiter!
    end

    it 'caps the whole process regardless of --concurrency' do
      # One shared limiter, so N worker threads cannot multiply the rate.
      described_class.reset_rate_limiter!
      limiters = 4.times.map { Thread.new { described_class.rate_limiter } }.map(&:value)

      expect(limiters.uniq.length).to eq(1)
    ensure
      described_class.reset_rate_limiter!
    end
  end
end
