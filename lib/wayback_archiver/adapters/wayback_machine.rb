require 'wayback_archiver/archive_result'
require 'wayback_archiver/request'

module WaybackArchiver
  class WaybackMachine
    # Wayback Machine base URL.
    BASE_URL    = 'https://web.archive.org/save/'.freeze

    # Send URL to Wayback Machine.
    # @return [ArchiveResult] the sent URL.
    # @param [String] url to send.
    # @example Archive example.com, with default options
    #    WaybackMachine.call('http://example.com')
    def self.call(url)
      request_url  = "#{BASE_URL}#{url}"
      response = Request.get(request_url, follow_redirects: false)
      WaybackArchiver.logger.info "Posted [#{response.code}, #{response.message}] #{url}"
      ArchiveResult.new(
        url,
        code: response.code,
        request_url: response.uri,
        response_error: response.error
      )
    rescue Request::Error => e
      WaybackArchiver.logger.error "Failed to archive #{url}: #{e.class}, #{e.message}"
      ArchiveResult.new(url, error: e)
    end
  end
end
