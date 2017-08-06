module WaybackArchiver
  # Result data for posting URL to archive
  ArchiveResult = Struct.new(:uri, :response, :error)
  class ArchiveResult
    # @return [String] the URL that was archived
    def archived_url
      uri
    end

    # @return [String] the requested URL
    def request_url
      return unless response?
      response.uri
    end

    # @return [String] The HTTP status code if any
    def code
      return unless response?
      response.code
    end

    # @return [Boolean] true if errored
    def errored?
      !!error
    end

    # @return [Boolean] true if response is present
    def response?
      !!response
    end
  end
end
