require 'cgi'
require 'json'

require 'wayback_archiver/check_result'
require 'wayback_archiver/rate_limiter'
require 'wayback_archiver/request'
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

    # @return [RateLimiter] CDX rate limiter (15 req/s)
    def self.rate_limiter
      RATE_LIMITER_MUTEX.synchronize do
        @rate_limiter ||= RateLimiter.new(max_requests: 15, window: 1.0)
      end
    end

    # Reset the rate limiter (useful in tests).
    def self.reset_rate_limiter!
      RATE_LIMITER_MUTEX.synchronize { @rate_limiter = nil }
    end

    # Check a single URL against the CDX API.
    # @param url [String] the URL to check
    # @param from [String, nil] CDX timestamp (YYYYMMDDHHMMSS) to limit recency
    # @return [CheckResult]
    def self.check(url, from: nil)
      rate_limiter.acquire

      params = "url=#{CGI.escape(url)}&output=json&limit=-1&filter=statuscode:200"
      params << "&from=#{from}" if from

      response = Request.get("#{URL}?#{params}", raise_on_http_error: true)
      parse_response(url, response.body)
    rescue Request::Error => e
      WaybackArchiver.logger.warn("CDX check failed for #{url}: #{e.message}")
      CheckResult.new(url, archived: false, error: e)
    end

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
