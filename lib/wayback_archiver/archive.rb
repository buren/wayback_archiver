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
    # @example Archive urls, asynchronously
    #    Archive.post(['http://example.com'])
    # @example Archive urls, using only 1 thread
    #    Archive.post(['http://example.com'], concurrency: 1)
    def self.post(urls, concurrency: DEFAULT_CONCURRENCY)
      puts "=== WAYBACK ARCHIVER ==="
      puts "Request are sent with up to #{concurrency} parallel threads"
      puts "Total urls to be sent: #{urls.length}"

      pool = Concurrent::FixedThreadPool.new(concurrency)
      urls.each do |url|
        pool.post { Archive.post_url(url) }
      end

      puts "#{urls.length} URLs sent to Internet archive"
      urls
    end

    # Send URLs to Wayback Machine by crawling the site.
    # @return [Array] with URLs sent to the Wayback Machine.
    # @param [String] source for URL to crawl.
    # @param [Integer] concurrency (default is 5).
    # @example Crawl example.com and send all URLs of the same domain
    #    WaybackArchiver.crawl('example.com')
    # @example Crawl example.com and send all URLs of the same domain with low concurrency
    #    WaybackArchiver.crawl('example.com', concurrency: 1)
    def self.crawl(source, concurrency: 5)
      pool = Concurrent::FixedThreadPool.new(concurrency) # X threads

      UrlCollector.crawl(source) do |url|
        pool.post { Archive.post_url(url) }
      end
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
