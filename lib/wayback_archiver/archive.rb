require 'concurrent'

require 'wayback_archiver/thread_pool'
require 'wayback_archiver/adapters/wayback_machine'

module WaybackArchiver
  # Post URL(s) to Wayback Machine
  class Archive
    # Send URLs to Wayback Machine.
    # @return [Array<ArchiveResult>] with sent URLs.
    # @param [Array<String>] urls to send to the Wayback Machine.
    # @param concurrency [Integer] the default is 1
    # @yield [archive_result] If a block is given, each result will be yielded
    # @yieldparam [ArchiveResult] archive_result
    # @example Archive urls, asynchronously
    #    Archive.post(['http://example.com'])
    #    Archiver.post(['http://example.com']) do |result|
    #      puts [result.code || 'error', result.url] # print response status and URL
    #    end
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
          sleep(12)
          result = post_url(url)
          yield(result) if block_given?
          posted_urls << result unless result.errored?
        end
      end

      pool.shutdown
      pool.wait_for_termination

      WaybackArchiver.logger.info "#{posted_urls.length} URL(s) posted to Wayback Machine"
      posted_urls
    end

    # Send URLs to Wayback Machine by crawling the site.
    # @return [Array<ArchiveResult>] with URLs sent to the Wayback Machine.
    # @param [String] source for URL to crawl.
    # @param concurrency [Integer] the default is 1
    # @param [Array<String, Regexp>] hosts to crawl
    # @yield [archive_result] If a block is given, each result will be yielded
    # @yieldparam [ArchiveResult] archive_result
    # @example Crawl example.com and send all URLs of the same domain
    #    Archiver.crawl('example.com')
    #    Archiver.crawl('example.com') do |result|
    #      puts [result.code || 'error', result.url] # print response status and URL
    #    end
    # @example Crawl example.com and send all URLs of the same domain with low concurrency
    #    Archiver.crawl('example.com', concurrency: 1)
    # @example Stop after archiving 100 links
    #    Archiver.crawl('example.com', limit: 100)
    # @example Crawl multiple hosts
    #    URLCollector.crawl(
    #      'http://example.com',
    #      hosts: [
    #        'example.com',
    #        /host[\d]+\.example\.com/
    #      ]
    #    )
    def self.crawl(source, hosts: [], concurrency: WaybackArchiver.concurrency, limit: WaybackArchiver.max_limit)
      WaybackArchiver.logger.info "Request are sent with up to #{concurrency} parallel threads"

      posted_urls = Concurrent::Array.new
      pool = ThreadPool.build(concurrency)

      found_urls = URLCollector.crawl(source, hosts: hosts, limit: limit) do |url|
        pool.post do
          result = post_url(url)
          yield(result) if block_given?
          posted_urls << result unless result.errored?
        end
      end
      WaybackArchiver.logger.info "Crawling of #{source} finished, found #{found_urls.length} URL(s)"
      pool.shutdown
      pool.wait_for_termination

      WaybackArchiver.logger.info "#{posted_urls.length} URL(s) posted to Wayback Machine"
      posted_urls
    end

    # Send URL to Wayback Machine.
    # @return [ArchiveResult] the sent URL.
    # @param [String] url to send.
    # @example Archive example.com, with default options
    #    Archive.post_url('http://example.com')
    def self.post_url(url)
      WaybackArchiver.adapter.call(url)
    end
  end
end
