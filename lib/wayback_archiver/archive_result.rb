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

    # @return [Boolean] true if success
    def success?
      !errored?
    end

    # @return [Boolean] true if errored
    def errored?
      !!error || (status_ext.is_a?(String) && status_ext.start_with?('error:'))
    end

    # @return [String, nil] URL to view the archived snapshot on the Wayback Machine
    def wayback_url
      return nil unless timestamp

      archived = original_url || uri
      "https://web.archive.org/web/#{timestamp}/#{archived}"
    end
  end
end
