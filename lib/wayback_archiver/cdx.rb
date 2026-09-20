require 'cgi'
require 'json'

require 'wayback_archiver/check_result'
require 'wayback_archiver/rate_limiter'
require 'wayback_archiver/request'
require 'wayback_archiver/retry'
require 'wayback_archiver/thread_pool'

module WaybackArchiver
  # Client for the Wayback Machine CDX API.
  # Used to check if URLs are already archived.
  # @api private
  class CDX
    URL = 'https://web.archive.org/cdx/search/cdx'.freeze

    # Guards lazy rate-limiter construction: the first calls come from
    # concurrent pool workers, and a bare ||= could build two limiters,
    # briefly doubling the requests/sec cap.
    RATE_LIMITER_MUTEX = Mutex.new

    # Internet Archive's current ceiling for CDX. The reference Python client
    # (edgi-govdata-archiving/wayback) dropped its default to 24/min in v0.5.1
    # (2026-06-19) "in order to match the actual hard limits now set on Wayback
    # Machine servers"; its source derives that from 0.8 * 30/60. The 60/min
    # figure IA staff gave in wayback#137 dates from 2023 and is superseded.
    #
    # Going over earns 429s, and per that same thread: "If 429s are ignored for
    # more than a minute we block the IP at the firewall (no connection) for
    # 1 hour" — doubling on repeat offences.
    RATE_LIMIT_PER_MINUTE = 30
    # Run at 80% of it, the margin IA asked the reference Python client to
    # adopt. This limiter is process-wide, so it also caps the total rate
    # across --concurrency workers: IA specifically asks callers not to fire
    # concurrent CDX requests from one IP.
    RATE_LIMIT = (RATE_LIMIT_PER_MINUTE * 0.8).to_i
    RATE_WINDOW = 60.0

    # @return [RateLimiter] CDX rate limiter (24 req/min)
    def self.rate_limiter
      RATE_LIMITER_MUTEX.synchronize do
        @rate_limiter ||= RateLimiter.new(max_requests: RATE_LIMIT, window: RATE_WINDOW)
      end
    end

    # Reset the rate limiter (useful in tests).
    def self.reset_rate_limiter!
      RATE_LIMITER_MUTEX.synchronize { @rate_limiter = nil }
    end

    MAX_RETRIES = 3 # per-URL retry cap for transient CDX failures
    BASE_DELAY  = 1 # seconds, doubled each attempt
    MAX_DELAY   = 8 # seconds

    # HTTP statuses worth another attempt. archive.org's CDX endpoint sheds
    # load with 503/504 often enough that a single shot made --check report
    # "unknown" for most URLs and --skip-archived re-archive them.
    RETRYABLE_HTTP_CODES = [408, 425, 429, 500, 502, 503, 504].freeze

    # A CDX lookup is a small JSON read that normally answers in well under a
    # second. Fail fast and let the retry do the waiting, rather than letting
    # one hung request sit on the global 60s read timeout.
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 15

    # Check a single URL against the CDX API.
    # Transient failures are retried with backoff; anything else is reported
    # as an errored result, which reads as "unknown", never "not archived".
    # @param url [String] the URL to check
    # @param from [String, nil] CDX timestamp (YYYYMMDDHHMMSS) to limit recency
    # @return [CheckResult]
    def self.check(url, from: nil)
      response = Retry.with_backoff(
        max_retries: MAX_RETRIES, base_delay: BASE_DELAY, max_delay: MAX_DELAY,
        retry_on: [Request::Error], retry_if: method(:retryable_error?)
      ) do
        rate_limiter.acquire
        Request.get(
          "#{URL}?#{query(url, from)}",
          raise_on_http_error: true,
          open_timeout: OPEN_TIMEOUT,
          read_timeout: READ_TIMEOUT
        )
      end

      parse_response(url, response.body)
    rescue Request::Error => e
      WaybackArchiver.logger.warn("CDX check failed for #{url}: #{e.message}")
      CheckResult.new(url, archived: false, error: e)
    end

    def self.query(url, from)
      params = "url=#{CGI.escape(url)}&output=json&limit=-1&filter=statuscode:200"
      params << "&from=#{from}" if from
      params
    end
    private_class_method :query

    # A response that came back with a status tells us whether retrying is
    # worth it; a connection-level failure (timeout, reset, DNS) has no status
    # and is always worth one more go.
    def self.retryable_error?(error)
      return RETRYABLE_HTTP_CODES.include?(error.code) if error.is_a?(Request::ResponseError) && error.code

      true
    end
    private_class_method :retryable_error?

    # Check multiple URLs concurrently.
    # @param urls [Array<String>] URLs to check
    # @param concurrency [Integer] number of concurrent threads
    # @param from [String, nil] CDX timestamp to limit recency
    # @yield [CheckResult] each result as it completes
    # @return [Array<CheckResult>]
    def self.check_urls(urls, concurrency:, from: nil, &block)
      results = Concurrent::Array.new
      pool = ThreadPool.build(concurrency)

      urls.each do |url|
        pool.post do
          result = begin
            check(url, from: from)
          rescue StandardError => e
            # Anything escaping a pool worker is swallowed by concurrent-ruby
            # and the URL would silently vanish from the results — a failed
            # lookup must surface as "unknown", never as "not archived".
            WaybackArchiver.logger.error("CDX check raised for #{url}: #{e.class}, #{e.message}")
            CheckResult.new(url, archived: false, error: e)
          end
          results << result
          block&.call(result)
        end
      end

      pool.shutdown
      pool.wait_for_termination
      results.to_a
    end

    def self.parse_response(url, body)
      data = JSON.parse(body)
      # CDX JSON output: first row is header names, subsequent rows are values.
      # A JSON object is an API/proxy error, not evidence that the URL is absent.
      unless data.is_a?(Array)
        raise Request::ServerError, "Unexpected CDX response type: #{data.class}"
      end

      return CheckResult.new(url, archived: false) if data.length <= 1

      unless data[0].is_a?(Array) && data[1].is_a?(Array)
        raise Request::ServerError, "Unexpected CDX row format: #{data.inspect}"
      end

      headers = data[0]
      row = data[1]
      record = headers.zip(row).to_h
      CheckResult.new(url, archived: true, timestamp: record['timestamp'])
    rescue JSON::ParserError => e
      raise Request::ServerError, "Invalid JSON in CDX response: #{e.message}"
    end
    private_class_method :parse_response
  end
end
