require 'wayback_archiver/request'

module WaybackArchiver
  # Download screenshots from the Wayback Machine
  # @api private
  class Screenshot
    # Download a screenshot to a local directory.
    # @return [String] the saved file path.
    # @param screenshot_url [String] URL of the screenshot on archive.org.
    # @param original_url [String] the original page URL (used for filename).
    # @param directory [String] local directory to save the screenshot.
    # @raise [AuthenticationError] if credentials are not configured.
    # @raise [ArgumentError] if the directory does not exist.
    # PNG magic number. SPN2 hands back a screenshot URL that can 404 (or
    # serve a login page), and writing that body to a .png produced a file
    # that looked saved, logged as saved, and was recorded in the report —
    # but was an HTML error page on disk.
    PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze

    def self.download(screenshot_url, original_url, directory:)
      unless WaybackArchiver.config.credentials?
        raise AuthenticationError, 'Credentials required for screenshot download'
      end

      unless File.directory?(directory)
        raise ArgumentError, "Directory does not exist: #{directory}"
      end

      response = Request.get(
        screenshot_url,
        follow_redirects: true,
        raise_on_http_error: true,
        headers: auth_headers
      )

      body = response.body.to_s
      unless body.b.start_with?(PNG_SIGNATURE)
        raise Request::ServerError,
              "Screenshot response is not a PNG (#{body.bytesize} bytes) for #{original_url}"
      end

      filename = sanitize_filename(original_url)
      path = File.join(directory, "#{filename}.png")

      File.binwrite(path, body)
      WaybackArchiver.logger.info("Screenshot saved to #{path}")

      path
    end

    # Download a screenshot if the URL and directory are present.
    # Returns nil silently on failure (logs the error).
    # @return [String, nil] saved file path or nil.
    def self.maybe_download(screenshot_url, original_url, options)
      return nil unless screenshot_url && options[:screenshot_dir]

      download(screenshot_url, original_url, directory: options[:screenshot_dir])
    rescue => e
      WaybackArchiver.logger.error("Failed to download screenshot: #{e.message}")
      nil
    end

    # The method already refuses to run without credentials; send them rather
    # than demanding they exist and then fetching anonymously.
    def self.auth_headers
      {
        'Authorization' => "LOW #{WaybackArchiver.config.access_key}:#{WaybackArchiver.config.secret_key}"
      }
    end
    private_class_method :auth_headers

    def self.sanitize_filename(url)
      url.to_s
        .sub(%r{^https?://}, '')
        .gsub(%r{[/:?&#=+%]}, '_')
        .gsub(/_+/, '_')
        .gsub(/^_|_$/, '')
        .slice(0, 200)
    end
    private_class_method :sanitize_filename
  end
end
