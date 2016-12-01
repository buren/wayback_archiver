module WaybackArchiver
  # Post URL(s) to Wayback Machine
  class Archive
    # Wayback Machine base URL.
    WAYBACK_BASE_URL    = 'https://web.archive.org/save/'
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
      puts "Request are sent with up to #{concurrency} parallel threads"
      puts "Total urls to be sent: #{urls.length}"
      group_size = (urls.length / concurrency) + 1
      urls.each_slice(group_size).to_a.map! do |archive_urls|
        Thread.new { archive_urls.each { |url| post_url(url) } }
      end.each(&:join)
      puts "#{urls.length} URLs sent to Internet archive"
      urls
    end

    # Send URL to Wayback Machine.
    # @return [String] the sent URL.
    # @param [String] url to send.
    # @example Archive example.com, with default options
    #    Archive.post_url('http://example.com')
    def self.post_url(url)
      resolved_url = Request.resolve_url(url)
      request_url  = "#{WAYBACK_BASE_URL}#{resolved_url}"
      response     = Request.response(request_url)
      puts "[#{response.code}, #{response.message}] #{resolved_url}"
      resolved_url
    rescue Exception => e
      puts "Error message:     #{e.message}"
      puts "Failed to archive: #{resolved_url}"
    end
  end
end
