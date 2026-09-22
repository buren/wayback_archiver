require 'wayback_archiver/error_codes'

module WaybackArchiver
  # Result data for posting URL to archive
  class ArchiveResult
    attr_reader :uri, :response_error, :error,
                :job_id, :timestamp, :duration_sec, :resources,
                :outlinks, :screenshot_url, :screenshot_path,
                :status_ext, :original_url

    def initialize(uri, response_error: nil, error: nil,
                   job_id: nil, timestamp: nil, duration_sec: nil, resources: nil,
                   outlinks: nil, screenshot_url: nil, screenshot_path: nil,
                   status_ext: nil, original_url: nil)
      @uri = uri
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

    # @return [Boolean] true if success (not submitted, incomplete or errored)
    def success?
      !errored? && !submitted? && !incomplete?
    end

    # @return [Boolean] true if errored
    def errored?
      !!error || !!response_error ||
        (status_ext.is_a?(String) && status_ext.start_with?('error:'))
    end

    # @return [Boolean] true if skipped (e.g. already archived, CDX pre-check)
    def skipped?
      status_ext.is_a?(String) && status_ext.start_with?('skipped:')
    end

    # @return [Boolean] true if this is a cached capture (e.g. from if_not_archived_within)
    def cached?
      status_ext == 'cached'
    end

    # @return [Boolean] true for an interim submission notification
    def submitted?
      status_ext == 'submitted'
    end

    # A final local result whose remote outcome is still unknown. Unlike an
    # interim submitted notification, this is included in reports and callbacks.
    # @return [Boolean]
    def incomplete?
      status_ext.is_a?(String) && status_ext.start_with?('incomplete:')
    end

    # @return [Boolean] true if confirmed against the Wayback Machine after
    #   SPN2 forgot the job
    def recovered?
      status_ext == 'recovered'
    end

    # Only errors have an error category. Passing a non-error status_ext such
    # as 'cached', 'skipped:...' or 'recovered' through the registry reported
    # them as transient failures and logged an unknown-code warning for each.
    # @return [Symbol, nil] :transient, :daily_limit, :permanent, or nil
    def error_category
      return nil unless errored?

      ErrorCodes.category(status_ext)
    end

    # @return [String, nil] human-readable error description
    def error_message
      ErrorCodes.message(status_ext)
    end

    # The most useful description of why this failed, wherever it ended up.
    # A polled failure stores its message in response_error while an exception
    # lands in error, and exports only read the latter — so a failure could be
    # serialized with every error field null.
    # @return [String, nil]
    def failure_reason
      return nil unless errored?

      error&.message || response_error || error_message || status_ext
    end

    # Short label for display output (e.g. "ok", "FAIL", "cached", "skip").
    def status_label
      if errored?
        'FAIL'
      elsif incomplete?
        'INCOMPLETE'
      elsif recovered?
        'recovrd'
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
        error_message || response_error || status_ext || error&.message
      elsif incomplete?
        case status_ext
        when 'incomplete:status-unavailable' then 'Job status unavailable (possibly expired); retained, not resubmitted'
        when 'incomplete:missing-job-id' then 'Saved job ID missing; retained, not resubmitted'
        else 'Capture not confirmed before polling stopped; resume to check again'
        end
      elsif recovered? || cached?
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
          status_ext: status['status_ext'] || ('error:unknown' unless status['message']),
          response_error: status['message']
        )
      else
        screenshot_path = Screenshot.maybe_download(
          status['screenshot'], status['original_url'] || url, options,
          timestamp: status['timestamp']
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
          status_ext: status_ext
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
