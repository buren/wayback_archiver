require 'json'

require 'wayback_archiver/archive_result'
require 'wayback_archiver/request'
require 'wayback_archiver/rate_limiter'
require 'wayback_archiver/error_codes'
require 'wayback_archiver/retry'
require 'wayback_archiver/screenshot'

module WaybackArchiver
  # WaybackMachine adapter using the SPN2 API
  class WaybackMachine
    # Raised when polling exceeds the timeout
    class PollTimeoutError < StandardError; end

    SAVE_URL     = 'https://web.archive.org/save'.freeze
    STATUS_URL   = 'https://web.archive.org/save/status'.freeze
    POLL_INTERVAL = 3   # seconds between status polls
    POLL_TIMEOUT  = 120 # max seconds to wait for capture

    # Boolean SPN2 options that get serialized as "1"
    BOOLEAN_OPTIONS = %i[
      capture_all capture_outlinks capture_screenshot
      delay_wb_availability force_get skip_first_archive
      outlinks_availability email_result
    ].freeze

    # String/integer SPN2 options passed as-is
    VALUE_OPTIONS = %i[
      if_not_archived_within js_behavior_timeout
      capture_cookie use_user_agent target_username target_password
    ].freeze

    # Returns the rate limiter, creating one if needed.
    # @return [RateLimiter]
    def self.rate_limiter
      @rate_limiter ||= RateLimiter.for_current_user
    end

    # Reset the rate limiter (e.g. after credentials change).
    def self.reset_rate_limiter!
      @rate_limiter = nil
    end

    # Send URL to Wayback Machine via SPN2.
    # @return [ArchiveResult]
    # @param [String] url to archive.
    # @param [Hash] options SPN2 capture options.
    def self.call(url, **options)
      Retry.with_backoff do
        submit_and_poll(url, **options)
      end
    rescue PollTimeoutError, Request::Error, JSON::ParserError => e
      WaybackArchiver.logger.error("Failed to archive #{url}: #{e.class}, #{e.message}")
      ArchiveResult.new(url, error: e)
    rescue RetryableError => e
      WaybackArchiver.logger.error("Failed to archive #{url} after retries: #{e.message}")
      ArchiveResult.new(url, error: e, status_ext: e.message)
    end

    # Submit a URL for capture without polling.
    # @return [Hash, ArchiveResult] parsed JSON response {url, job_id} on success,
    #   or ArchiveResult with error on failure.
    # @param [String] url to archive.
    # @param [Hash] options SPN2 capture options.
    def self.submit(url, **options)
      rate_limiter.acquire

      body = build_post_body(url, **options)
      headers = build_headers

      WaybackArchiver.logger.debug("Submitting #{url} to SPN2")
      response = Request.post(SAVE_URL, body: body, headers: headers)
      JSON.parse(response.body)
    rescue Request::Error, JSON::ParserError => e
      WaybackArchiver.logger.error("Failed to submit #{url}: #{e.class}, #{e.message}")
      ArchiveResult.new(url, error: e)
    end

    # Batch-poll the status of multiple capture jobs.
    # @return [Hash<String, Hash>] job_id => status hash.
    # @param [Array<String>] job_ids to check.
    def self.poll_statuses(job_ids)
      headers = build_headers
      response = Request.post(
        STATUS_URL,
        body: { 'job_ids' => job_ids.join(',') },
        headers: headers
      )
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise Request::ServerError, "Invalid JSON in status response: #{e.message}"
    end

    # Check the user's current session status.
    # @return [Hash] with 'available' and 'processing' keys.
    # @raise [AuthenticationError] if no credentials configured.
    def self.check_user_status
      raise AuthenticationError, 'Credentials required for user status' unless WaybackArchiver.credentials?

      cache_buster = (Time.now.to_f * 1000).to_i
      response = Request.get(
        "#{STATUS_URL}/user?_t=#{cache_buster}",
        follow_redirects: false,
        headers: build_headers
      )
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise Request::ServerError, "Invalid JSON in user status response: #{e.message}"
    end

    # Check system status.
    # @return [Hash] with 'status' key.
    def self.system_status
      response = Request.get("#{STATUS_URL}/system", follow_redirects: false)
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise Request::ServerError, "Invalid JSON in system status response: #{e.message}"
    end

    def self.submit_and_poll(url, **options)
      data = submit(url, **options)
      return data if data.is_a?(ArchiveResult) # submission failed

      job_id = data['job_id']
      unless job_id
        # SPN2 returns the capture directly when if_not_archived_within matches a recent snapshot
        if data['timestamp']
          WaybackArchiver.logger.info("Recent capture returned for #{url} [#{data['timestamp']}]")
          return ArchiveResult.from_status(url, nil, data, status_ext: 'cached', **options)
        end

        msg = data['message'] || "Unexpected submit response for #{url}"
        raise Request::ServerError, msg
      end

      WaybackArchiver.logger.info("Capture started for #{url}, job_id: #{job_id}")

      status = poll_until_complete(job_id)

      if status['status'] == 'error'
        status_ext = status['status_ext']

        if ErrorCodes.retryable?(status_ext)
          raise RetryableError, status_ext
        end

        WaybackArchiver.logger.error("Capture failed for #{url}: #{status_ext} - #{status['message']}")
      else
        ts = status['timestamp']
        formatted_ts = if ts&.match?(/\A\d{14}\z/)
          Time.new(ts[0..3].to_i, ts[4..5].to_i, ts[6..7].to_i, ts[8..9].to_i, ts[10..11].to_i, ts[12..13].to_i, 'UTC')
              .strftime('%Y-%m-%d %H:%M:%S UTC')
        else
          ts
        end
        WaybackArchiver.logger.info("Captured #{url} [#{formatted_ts}]")
      end

      ArchiveResult.from_status(url, job_id, status, **options)
    end
    private_class_method :submit_and_poll

    def self.poll_until_complete(job_id)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      headers = build_headers

      loop do
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        if elapsed > POLL_TIMEOUT
          raise PollTimeoutError, "Polling timed out after #{POLL_TIMEOUT}s for job #{job_id}"
        end

        sleep(POLL_INTERVAL)

        response = Request.get(
          "#{STATUS_URL}/#{job_id}",
          follow_redirects: false,
          headers: headers
        )
        status = JSON.parse(response.body)

        WaybackArchiver.logger.debug("Poll #{job_id}: #{status['status']}")

        return status unless status['status'] == 'pending'
      end
    end
    private_class_method :poll_until_complete


    def self.build_post_body(url, **options)
      body = { 'url' => url.to_s.strip }

      BOOLEAN_OPTIONS.each do |opt|
        body[opt.to_s] = '1' if options[opt]
      end

      VALUE_OPTIONS.each do |opt|
        body[opt.to_s] = options[opt].to_s if options[opt]
      end

      body
    end
    private_class_method :build_post_body

    def self.build_headers
      unless WaybackArchiver.credentials?
        raise AuthenticationError,
          'Wayback Machine credentials required. ' \
          'Get your API keys at https://archive.org/account/s3.php ' \
          'and set WAYBACK_ACCESS_KEY and WAYBACK_SECRET_KEY environment variables.'
      end

      {
        'Accept' => 'application/json',
        'Authorization' => "LOW #{WaybackArchiver.access_key}:#{WaybackArchiver.secret_key}"
      }
    end
    private_class_method :build_headers
  end
end
