require 'wayback_archiver/request'

module WaybackArchiver
  # Download screenshots from the Wayback Machine
  # @api private
  class Screenshot
    WAYBACK_ORIGIN = 'https://web.archive.org'.freeze

    # Magic numbers for the formats archive.org actually serves. The SPN2 docs
    # say "full-page screenshot (PNG)", but the bytes come back as image/jpg —
    # accept either and name the file after what arrived.
    #
    # Checking at all matters because the endpoint can answer with an HTML
    # error page, which used to be written straight to a .png.
    SIGNATURES = {
      "\x89PNG\r\n\x1a\n".b => 'png',
      "\xFF\xD8\xFF".b      => 'jpg'
    }.freeze

    # Download a screenshot to a local directory.
    # @return [String] the saved file path, extension matching the real format.
    # @param screenshot_url [String] the SPN2 `screenshot` field.
    # @param original_url [String] the original page URL (used for filename).
    # @param directory [String] local directory to save the screenshot.
    # @param timestamp [String, nil] capture timestamp, used to build the
    #   Wayback replay URL. Without it, screenshot_url must already be a usable
    #   HTTPS URL on web.archive.org (port 443).
    # @raise [AuthenticationError] if credentials are not configured.
    # @raise [ArgumentError] if the directory does not exist.
    # @raise [Request::Error] if the download fails or isn't an image.
    # @raise [Request::InvalidRedirectError] if the initial URL or a redirect
    #   leaves the trusted HTTPS origin or contains URL credentials.
    def self.download(screenshot_url, original_url, directory:, timestamp: nil)
      unless WaybackArchiver.config.credentials?
        raise AuthenticationError, 'Credentials required for screenshot download'
      end

      unless File.directory?(directory)
        raise ArgumentError, "Directory does not exist: #{directory}"
      end

      response = Request.get(
        replay_url(screenshot_url, timestamp),
        follow_redirects: true,
        raise_on_http_error: true,
        allowed_origin: WAYBACK_ORIGIN,
        headers: auth_headers
      )

      body = response.body.to_s
      extension = SIGNATURES.find { |magic, _| body.b.start_with?(magic) }&.last
      unless extension
        raise Request::ServerError,
              "Screenshot response is not an image (#{body.bytesize} bytes) for #{original_url}"
      end

      filename = sanitize_filename(original_url)
      path = File.join(directory, "#{filename}.#{extension}")

      File.binwrite(path, body)
      WaybackArchiver.logger.info("Screenshot saved to #{path}")

      path
    end

    # Download a screenshot if the URL and directory are present.
    # Returns nil silently on failure (logs the error).
    # @return [String, nil] saved file path or nil.
    def self.maybe_download(screenshot_url, original_url, options, timestamp: nil)
      return nil unless screenshot_url && options[:screenshot_dir]

      download(screenshot_url, original_url,
               directory: options[:screenshot_dir], timestamp: timestamp)
    rescue => e
      WaybackArchiver.logger.error("Failed to download screenshot: #{e.message}")
      nil
    end

    # SPN2's `screenshot` field names the URL the image was archived under, not
    # a live endpoint — requesting it directly returns 404, as does the example
    # in the official SPN2 docs. The image is a separate Wayback capture, so it
    # has to be replayed at the capture's timestamp.
    def self.replay_url(screenshot_url, timestamp)
      return screenshot_url if timestamp.to_s.empty?

      "#{WAYBACK_ORIGIN}/web/#{timestamp}/#{screenshot_url}"
    end
    private_class_method :replay_url

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
