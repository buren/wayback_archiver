require 'wayback_archiver/request'

module WaybackArchiver
  # Download screenshots from the Wayback Machine
  class Screenshot
    # Download a screenshot to a local directory.
    # @return [String] the saved file path.
    # @param screenshot_url [String] URL of the screenshot on archive.org.
    # @param original_url [String] the original page URL (used for filename).
    # @param directory [String] local directory to save the screenshot.
    # @raise [AuthenticationError] if credentials are not configured.
    # @raise [ArgumentError] if the directory does not exist.
    def self.download(screenshot_url, original_url, directory:)
      unless WaybackArchiver.config.credentials?
        raise AuthenticationError, 'Credentials required for screenshot download'
      end

      unless File.directory?(directory)
        raise ArgumentError, "Directory does not exist: #{directory}"
      end

      response = Request.get(screenshot_url, follow_redirects: true)
      filename = sanitize_filename(original_url)
      path = File.join(directory, "#{filename}.png")

      File.binwrite(path, response.body)
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
