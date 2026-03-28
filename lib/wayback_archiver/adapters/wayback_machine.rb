require 'json'

require 'wayback_archiver/archive_result'
require 'wayback_archiver/request'
require 'wayback_archiver/retry'

module WaybackArchiver
  # WaybackMachine adapter using the SPN2 API
  class WaybackMachine
    # Raised when polling exceeds the timeout
    class PollTimeoutError < StandardError; end

    SAVE_URL     = 'https://web.archive.org/save'.freeze
    STATUS_URL   = 'https://web.archive.org/save/status'.freeze
    POLL_INTERVAL = 3   # seconds between status polls
    POLL_TIMEOUT  = 120 # max seconds to wait for capture

    # SPN2 error codes that warrant a retry
    RETRYABLE_ERRORS = %w[
      error:too-many-requests
      error:user-session-limit
      error:service-unavailable
      error:cannot-fetch
      error:no-browsers-available
      error:celery
    ].freeze

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

    # Send URL to Wayback Machine via SPN2.
    # @return [ArchiveResult]
    # @param [String] url to archive.
    # @param [Hash] options SPN2 capture options.
    def self.call(url, **options)
      Retry.with_backoff do
        submit_and_poll(url, **options)
      end
    rescue PollTimeoutError, Request::Error => e
      WaybackArchiver.logger.error("Failed to archive #{url}: #{e.class}, #{e.message}")
      ArchiveResult.new(url, error: e)
    rescue RetryableError => e
      WaybackArchiver.logger.error("Failed to archive #{url} after retries: #{e.message}")
      ArchiveResult.new(url, error: e, status_ext: e.message)
    end

    # Check the user's current session status.
    # @return [Hash] with 'available' and 'processing' keys.
    # @raise [AuthenticationError] if no credentials configured.
    def self.check_user_status
      raise AuthenticationError, 'Credentials required for user status' unless WaybackArchiver.credentials?

      cache_buster = (Time.now.to_f * 1000).to_i
      response = Request.get(
        "#{STATUS_URL}/user?_t=#{cache_buster}",
        follow_redirects: false
      )
      JSON.parse(response.body)
    end

    # Check system status.
    # @return [Hash] with 'status' key.
    def self.system_status
      response = Request.get("#{STATUS_URL}/system", follow_redirects: false)
      JSON.parse(response.body)
    end

    def self.submit_and_poll(url, **options)
      body = build_post_body(url, **options)
      headers = build_headers

      WaybackArchiver.logger.debug("Submitting #{url} to SPN2")
      response = Request.post(SAVE_URL, body: body, headers: headers)
      data = JSON.parse(response.body)

      job_id = data['job_id']
      WaybackArchiver.logger.info("Capture started for #{url}, job_id: #{job_id}")

      status = poll_until_complete(job_id)

      if status['status'] == 'error'
        status_ext = status['status_ext']

        if RETRYABLE_ERRORS.include?(status_ext)
          raise RetryableError, status_ext
        end

        WaybackArchiver.logger.error("Capture failed for #{url}: #{status_ext} - #{status['message']}")
        return ArchiveResult.new(
          url,
          job_id: job_id,
          status_ext: status_ext,
          response_error: status['message']
        )
      end

      WaybackArchiver.logger.info("Captured #{url} [#{status['timestamp']}]")

      ArchiveResult.new(
        url,
        job_id: job_id,
        timestamp: status['timestamp'],
        duration_sec: status['duration_sec'],
        resources: status['resources'] || [],
        outlinks: status['outlinks'] || {},
        screenshot_url: status['screenshot'],
        original_url: status['original_url'],
        code: '200'
      )
    end
    private_class_method :submit_and_poll

    def self.poll_until_complete(job_id)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      loop do
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        if elapsed > POLL_TIMEOUT
          raise PollTimeoutError, "Polling timed out after #{POLL_TIMEOUT}s for job #{job_id}"
        end

        sleep(POLL_INTERVAL)

        response = Request.get(
          "#{STATUS_URL}/#{job_id}",
          follow_redirects: false
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
      headers = { 'Accept' => 'application/json' }

      if WaybackArchiver.credentials?
        headers['Authorization'] = "LOW #{WaybackArchiver.access_key}:#{WaybackArchiver.secret_key}"
      end

      headers
    end
    private_class_method :build_headers
  end
end
