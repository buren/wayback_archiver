module WaybackArchiver
  # Result data for posting URL to archive
  class ArchiveResult
    attr_reader :uri, :code, :request_url, :response_error, :error

    def initialize(uri, code: nil, request_url: nil, response_error: nil, error: nil)
      @uri = uri
      @code = code
      @request_url = request_url
      @response_error = response_error
      @error = error
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
      !!error
    end
  end
end
