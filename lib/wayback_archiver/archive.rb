require 'concurrent'

require 'wayback_archiver/thread_pool'
require 'wayback_archiver/request'

module WaybackArchiver
  # Post URL(s) to Wayback Machine
  class Archive
    # Wayback Machine base URL.
    WAYBACK_BASE_URL    = 'https://web.archive.org/save/'.freeze

    # Send URLs to Wayback Machine.
    # @return [Array<String>] with sent URLs.
    # @param [Array<String>] urls to send to the Wayback Machine.
    # @param concurrency [Integer] the default is 5
    # @example Archive urls, asynchronously
    #    Archive.post(['http://example.com'])
    # @example Archive urls, using only 1 thread
    #    Archive.post(['http://example.com'], concurrency: 1)
    # @example Stop after archiving 100 links
    #    Archive.post(['http://example.com'], limit: 100)
    # @example Explicitly set no limit on how many links are posted
    #    Archive.post(['http://example.com'], limit: -1)
    def self.post(urls, concurrency: WaybackArchiver.concurrency, limit: WaybackArchiver.max_limit)
      WaybackArchiver.logger.info "Total URLs to be sent: #{urls.length}"
      WaybackArchiver.logger.info "Request are sent with up to #{concurrency} parallel threads"

      urls_queue = if limit == -1
                     urls
                   else
                     urls[0...limit]
                   end

      posted_urls = Concurrent::Array.new
      pool = ThreadPool.build(concurrency)

      urls_queue.each do |url|
        pool.post do
          posted_url = post_url(url)
          posted_urls << posted_url if posted_url
        end
      end

      pool.shutdown
      pool.wait_for_termination

      WaybackArchiver.logger.info "#{posted_urls.length} URL(s) posted to Wayback Machine"
      posted_urls
    end

    # Send URLs to Wayback Machine by crawling the site.
    # @return [Array<String>] with URLs sent to the Wayback Machine.
    # @param [String] source for URL to crawl.
    # @param concurrency [Integer] the default is 5
    # @example Crawl example.com and send all URLs of the same domain
    #    WaybackArchiver.crawl('example.com')
    # @example Crawl example.com and send all URLs of the same domain with low concurrency
    #    WaybackArchiver.crawl('example.com', concurrency: 1)
    # @example Stop after archiving 100 links
    #    WaybackArchiver.crawl('example.com', limit: 100)
    def self.crawl(source, concurrency: WaybackArchiver.concurrency, limit: WaybackArchiver.max_limit)
      WaybackArchiver.logger.info "Request are sent with up to #{concurrency} parallel threads"

      posted_urls = Concurrent::Array.new
      pool = ThreadPool.build(concurrency)

      found_urls = URLCollector.crawl(source, limit: limit) do |url|
        pool.post do
          posted_url = post_url(url)
          posted_urls << posted_url if posted_url
        end
      end
      WaybackArchiver.logger.info "Crawling of #{source} finished, found #{found_urls.length} URL(s)"
      pool.shutdown
      pool.wait_for_termination

      WaybackArchiver.logger.info "#{posted_urls.length} URL(s) posted to Wayback Machine"
      posted_urls
    end

    # Send URL to Wayback Machine.
    # @return [String] the sent URL.
    # @param [String] url to send.
    # @example Archive example.com, with default options
    #    Archive.post_url('http://example.com')
    def self.post_url(url)
      request_url  = "#{WAYBACK_BASE_URL}#{url}"
      response     = Request.get(request_url, follow_redirects: false)
      WaybackArchiver.logger.info "Posted [#{response.code}, #{response.message}] #{url}"
      url
    rescue Request::Error => e
      WaybackArchiver.logger.error "Failed to archive #{url}: #{e.class}, #{e.message}"
      nil
    end
  end
end
