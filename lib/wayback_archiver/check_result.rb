module WaybackArchiver
  # Result of checking a URL against the Wayback Machine CDX API.
  class CheckResult
    attr_reader :url, :original_url, :timestamp, :error, :error_category

    # @param url [String] the URL that was checked
    # @param archived [Boolean] whether the URL exists in the Wayback Machine
    # @param original_url [String, nil] exact URL stored in the matching CDX record
    # @param timestamp [String, nil] most recent capture timestamp (YYYYMMDDHHMMSS)
    # @param error [Exception, nil] error if the CDX check itself failed
    # @param error_category [Symbol, nil] machine-readable failure category
    def initialize(url, archived:, original_url: nil, timestamp: nil, error: nil, error_category: nil)
      @url = url
      @archived = archived
      @original_url = original_url
      @timestamp = timestamp
      @error = error
      @error_category = error_category
    end

    # @return [Boolean] true if the URL is in the Wayback Machine
    def archived?
      @archived
    end

    # @return [Boolean] true if the CDX lookup itself failed — archived? is
    #   then unknown, not false.
    def errored?
      !!@error
    end

    # @return [Boolean] true when Wayback denies access to this URL's records
    def blocked?
      %i[blocked_by_robots blocked_site].include?(error_category)
    end

    # @return [Boolean] true when CDX answered but its response was unusable
    def malformed_response?
      error_category == :malformed_response
    end

    # @return [String, nil] formatted date (YYYY-MM-DD) of the most recent capture
    def captured_at
      return nil unless timestamp && timestamp.length >= 8

      "#{timestamp[0..3]}-#{timestamp[4..5]}-#{timestamp[6..7]}"
    end

    # @return [String, nil] URL to view the snapshot, or nil if not archived
    def wayback_url
      return nil unless timestamp

      captured_url = original_url.to_s.empty? ? url : original_url
      "https://web.archive.org/web/#{timestamp}/#{captured_url}"
    end
  end
end
