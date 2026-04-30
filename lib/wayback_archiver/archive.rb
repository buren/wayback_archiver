require 'concurrent'

require 'wayback_archiver/batch_submitter'
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
    def self.post(urls, concurrency: WaybackArchiver.config.concurrency, limit: WaybackArchiver.config.max_limit, skip_urls: nil, skip_patterns: nil, include_ext: nil, exclude_ext: nil, **options, &block)
      WaybackArchiver.logger.debug "Total URLs to be sent: #{urls.length}"
      WaybackArchiver.logger.debug "Request are sent with up to #{concurrency} parallel threads"

      urls_queue = if limit == -1
                     urls
                   else
                     urls[0...limit]
                   end

      if skip_urls && !skip_urls.empty?
        before = urls_queue.length
        urls_queue = urls_queue.reject { |url| skip_urls.include?(url) }
        skipped = before - urls_queue.length
        WaybackArchiver.logger.info "Skipped #{skipped} previously succeeded URL(s)" if skipped > 0
      end

      if skip_patterns && !skip_patterns.empty?
        before = urls_queue.length
        urls_queue = urls_queue.reject { |url| skip_patterns.any? { |pat| pat.match?(url) } }
        skipped = before - urls_queue.length
        WaybackArchiver.logger.info "Skipped #{skipped} URL(s) matching skip patterns" if skipped > 0
      end

      urls_queue = URLFilter.new(include_ext: include_ext, exclude_ext: exclude_ext).apply(urls_queue)

      BatchSubmitter.new(urls_queue, concurrency: concurrency, **options, &block).call
    end

    CRAWL_QUEUE_SIZE = 10_000 # SizedQueue capacity — backpressure when crawler outpaces SPN2

    # Send URLs to Wayback Machine by crawling the site.
    # Streams URLs to SPN2 as they are discovered — the crawler runs in a
    # background thread pushing into a SizedQueue that batch_post consumes.
    # @return [Array<ArchiveResult>] with URLs sent to the Wayback Machine.
    # @param [String] source for URL to crawl.
    # @param concurrency [Integer] the default is 1
    # @param [Array<String, Regexp>] hosts to crawl
    # @yield [archive_result] If a block is given, each result will be yielded
    # @yieldparam [ArchiveResult] archive_result
    def self.crawl(source, hosts: [], concurrency: WaybackArchiver.config.concurrency, limit: WaybackArchiver.config.max_limit, skip_urls: nil, skip_patterns: nil, include_ext: nil, exclude_ext: nil, skip_duplicates: true, **options, &block)
      queue = SizedQueue.new(CRAWL_QUEUE_SIZE)
      url_filter = URLFilter.new(include_ext: include_ext, exclude_ext: exclude_ext)
      discovered = Concurrent::AtomicFixnum.new(0)

      crawler_thread = Thread.new do
        Thread.current.report_on_exception = false # we re-raise via thread.value
        URLCollector.crawl(source, hosts: hosts, limit: limit, exts: include_ext, ignore_exts: exclude_ext, skip_duplicates: skip_duplicates) do |url|
          next if skip_urls&.include?(url)
          next if skip_patterns&.any? { |pat| pat.match?(url) }
          next unless url_filter.match?(url)
          count = discovered.increment
          queue.push(url) # blocks when queue is full (backpressure)
          WaybackArchiver.listener.on_url_discovered(url: url, count: count)
        end
      rescue ClosedQueueError
        # BatchSubmitter closed the queue to signal early termination (e.g. IP blocked)
      ensure
        WaybackArchiver.listener.on_crawl_complete(url_count: discovered.value)
      end

      BatchSubmitter.new(queue, concurrency: concurrency, source_thread: crawler_thread, **options, &block).call
    end

    # Send URL to Wayback Machine.
    # @return [ArchiveResult] the sent URL.
    # @param [String] url to send.
    def self.post_url(url, **options)
      WaybackMachine.call(url, **options)
    end
  end
end
