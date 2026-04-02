module WaybackArchiver
  # Result of checking a URL against the Wayback Machine CDX API.
  class CheckResult
    attr_reader :url, :timestamp, :error

    # @param url [String] the URL that was checked
    # @param archived [Boolean] whether the URL exists in the Wayback Machine
    # @param timestamp [String, nil] most recent capture timestamp (YYYYMMDDHHMMSS)
    # @param error [Exception, nil] error if the CDX check itself failed
    def initialize(url, archived:, timestamp: nil, error: nil)
      @url = url
      @archived = archived
      @timestamp = timestamp
      @error = error
    end

    # @return [Boolean] true if the URL is in the Wayback Machine
    def archived?
      @archived
    end

    # @return [String, nil] URL to view the snapshot, or nil if not archived
    def wayback_url
      return nil unless timestamp

      "https://web.archive.org/web/#{timestamp}/#{url}"
    end
  end
end
