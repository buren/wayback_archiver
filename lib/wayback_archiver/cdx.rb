require 'cgi'
require 'json'

require 'wayback_archiver/check_result'
require 'wayback_archiver/rate_limiter'
require 'wayback_archiver/request'
require 'wayback_archiver/thread_pool'

module WaybackArchiver
  # Client for the Wayback Machine CDX API.
  # Used to check if URLs are already archived.
  class CDX
    URL = 'https://web.archive.org/cdx/search/cdx'.freeze

    # @return [RateLimiter] CDX rate limiter (15 req/s)
    def self.rate_limiter
      @rate_limiter ||= RateLimiter.new(max_requests: 15, window: 1.0)
    end

    # Reset the rate limiter (useful in tests).
    def self.reset_rate_limiter!
      @rate_limiter = nil
    end

    # Check a single URL against the CDX API.
    # @param url [String] the URL to check
    # @param from [String, nil] CDX timestamp (YYYYMMDDHHMMSS) to limit recency
    # @return [CheckResult]
    def self.check(url, from: nil)
      rate_limiter.acquire

      params = "url=#{CGI.escape(url)}&output=json&limit=-1&filter=statuscode:200"
      params << "&from=#{from}" if from

      response = Request.get("#{URL}?#{params}")
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
          result = check(url, from: from)
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
      # CDX JSON output: first row is header names, subsequent rows are values
      if data.is_a?(Array) && data.length > 1
        headers = data[0]
        row = data[1]
        record = headers.zip(row).to_h
        CheckResult.new(url, archived: true, timestamp: record['timestamp'])
      else
        CheckResult.new(url, archived: false)
      end
    rescue JSON::ParserError
      # Empty or non-JSON response = not archived
      CheckResult.new(url, archived: false)
    end
    private_class_method :parse_response
  end
end
