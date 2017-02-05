module WaybackArchiver
  # Post URL(s) to Wayback Machine
  class Archive
    # Wayback Machine base URL.
    WAYBACK_BASE_URL    = 'https://web.archive.org/save/'.freeze
    # Default concurrency for archiving URLs
    DEFAULT_CONCURRENCY = 10
    # Send URLs to Wayback Machine.
    # @return [Array] with sent URLs.
    # @param [Array] urls URLs to send.
    # @param [Hash] options
    # @example Archive example.com, with default options
    #    Archive.post(['http://example.com'])
    # @example Archive example.com, using only 1 thread
    #    Archive.post(['http://example.com'], concurrency: 1)
    def self.post(urls, options = {})
      options     = { concurrency: DEFAULT_CONCURRENCY }.merge!(options)
      concurrency = options[:concurrency]

      puts "=== WAYBACK ARCHIVER ==="
      puts "Request are sent with up to #{concurrency} parallel threads"
      puts "Total urls to be sent: #{urls.length}"

      ProcessQueue.process(urls, threads_count: concurrency) { |url| post_url(url) }

      puts "#{urls.length} URLs sent to Internet archive"
      urls
    end

    # Send URL to Wayback Machine.
    # @return [String] the sent URL.
    # @param [String] url to send.
    # @example Archive example.com, with default options
    #    Archive.post_url('http://example.com')
    def self.post_url(url)
      request_url  = "#{WAYBACK_BASE_URL}#{url}"
      response     = Request.response(request_url)
      puts "[#{response.code}, #{response.message}] #{url}"
      url
    rescue Exception => e
      puts "Error message:     #{e.message}"
      puts "Failed to archive: #{url}"
    end
  end
end
