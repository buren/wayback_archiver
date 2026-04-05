require 'wayback_archiver/error_codes'

module WaybackArchiver
  # Result data for posting URL to archive
  class ArchiveResult
    attr_reader :uri, :code, :request_url, :response_error, :error,
                :job_id, :timestamp, :duration_sec, :resources,
                :outlinks, :screenshot_url, :screenshot_path,
                :status_ext, :original_url

    def initialize(uri, code: nil, request_url: nil, response_error: nil, error: nil,
                   job_id: nil, timestamp: nil, duration_sec: nil, resources: nil,
                   outlinks: nil, screenshot_url: nil, screenshot_path: nil,
                   status_ext: nil, original_url: nil)
      @uri = uri
      @code = code
      @request_url = request_url
      @response_error = response_error
      @error = error
      @job_id = job_id
      @timestamp = timestamp
      @duration_sec = duration_sec
      @resources = resources || []
      @outlinks = outlinks || {}
      @screenshot_url = screenshot_url
      @screenshot_path = screenshot_path
      @status_ext = status_ext
      @original_url = original_url
    end

    # @return [String] the URL that was archived
    def archived_url
      uri
    end

    # @return [Boolean] true if success (not submitted or errored)
    def success?
      !errored? && !submitted?
    end

    # @return [Boolean] true if errored
    def errored?
      !!error || (status_ext.is_a?(String) && status_ext.start_with?('error:'))
    end

    # @return [Boolean] true if skipped (e.g. already archived, CDX pre-check)
    def skipped?
      status_ext.is_a?(String) && status_ext.start_with?('skipped:')
    end

    # @return [Boolean] true if this is a cached capture (e.g. from if_not_archived_within)
    def cached?
      status_ext == 'cached'
    end

    # @return [Boolean] true if submitted to SPN2 but not yet confirmed
    def submitted?
      status_ext == 'submitted'
    end

    # @return [Symbol, nil] :transient, :daily_limit, :permanent, or nil
    def error_category
      ErrorCodes.category(status_ext)
    end

    # @return [String, nil] human-readable error description
    def error_message
      ErrorCodes.message(status_ext)
    end

    # Short label for display output (e.g. "ok", "FAIL", "cached", "skip").
    def status_label
      if errored?
        'FAIL'
      elsif cached?
        'cached'
      elsif skipped?
        'skip'
      elsif submitted?
        'submit'
      else
        'ok'
      end
    end

    # Human-readable detail string for display output.
    # For errors: the human-readable error message.
    # For successes: the capture duration.
    def status_detail
      if errored?
        error_message || status_ext || error&.message
      elsif cached?
        formatted_timestamp
      elsif duration_sec
        "#{'%.1f' % duration_sec}s"
      end
    end

    # Build an ArchiveResult from a poll status hash.
    # @param url [String] the original URL that was archived.
    # @param job_id [String] the SPN2 job ID.
    # @param status [Hash] the status hash from the SPN2 API.
    # @param options [Hash] capture options (used for screenshot download).
    # @return [ArchiveResult]
    def self.from_status(url, job_id, status, status_ext: nil, **options)
      if status['status'] == 'error'
        new(
          url,
          job_id: job_id,
          status_ext: status['status_ext'],
          response_error: status['message']
        )
      else
        screenshot_path = Screenshot.maybe_download(
          status['screenshot'], status['original_url'] || url, options
        )

        new(
          url,
          job_id: job_id,
          timestamp: status['timestamp'],
          duration_sec: status['duration_sec'],
          resources: status['resources'] || [],
          outlinks: status['outlinks'] || {},
          screenshot_url: status['screenshot'],
          screenshot_path: screenshot_path,
          original_url: status['original_url'],
          status_ext: status_ext,
          code: '200'
        )
      end
    end

    # @return [String, nil] human-readable timestamp (e.g. "2026-04-03 11:44:28 UTC")
    def formatted_timestamp
      ts = timestamp
      if ts&.match?(/\A\d{14}\z/)
        Time.new(ts[0..3].to_i, ts[4..5].to_i, ts[6..7].to_i, ts[8..9].to_i, ts[10..11].to_i, ts[12..13].to_i, 'UTC')
            .strftime('%Y-%m-%d %H:%M:%S UTC')
      else
        ts
      end
    end

    # @return [String, nil] URL to view the archived snapshot on the Wayback Machine
    def wayback_url
      return nil unless timestamp

      archived = original_url || uri
      "https://web.archive.org/web/#{timestamp}/#{archived}"
    end
  end
end
