require 'concurrent'

require 'wayback_archiver/batch_submitter'
require 'wayback_archiver/wayback_machine'

module WaybackArchiver
  # Post URL(s) to Wayback Machine
  class Archive
    # Keys accepted via **options across the archive entry points: the SPN2
    # capture params plus local side-channel options consumed downstream
    # (screenshot_dir at result construction, skip_duplicates by the CLI's
    # option plumbing). Anything else is a typo — build_post_body would
    # silently drop it, so reject it loudly here instead.
    ALLOWED_OPTIONS = (
      WaybackMachine::BOOLEAN_OPTIONS +
      WaybackMachine::VALUE_OPTIONS +
      %i[screenshot_dir skip_duplicates]
    ).freeze

    # Send URLs to Wayback Machine.
    # @return [Array<ArchiveResult>] one per submitted URL, including failures.
    # @param urls [Array<String>] URLs to send.
    # @param concurrency [Integer] parallel submission workers (default 4).
    # @param limit [Integer] cap on URLs to submit (-1 for unlimited).
    # @param skip_urls [Set<String>, nil] URLs to omit (e.g. from a session file).
    # @param skip_patterns [Array<Regexp>, nil] URLs matching any pattern are skipped.
    # @param include_ext [Array<String>, nil] only submit URLs ending in these
    #   extensions. A URL without an extension (https://example.com/about)
    #   matches nothing, so it is not submitted.
    # @param exclude_ext [Array<String>, nil] omit URLs ending in these extensions.
    # @param options [Hash] forwarded to SPN2 (capture_all:, capture_screenshot:, ...).
    # @yield [archive_result] called when a URL is accepted by SPN2 (interim
    #   result, +submitted?+ true) and again with the final result — guard with
    #   +result.submitted?+ to process only final results. May be invoked from
    #   multiple threads.
    # @yieldparam [ArchiveResult] archive_result
    # @example Archive a handful of URLs
    #   Archive.post(['https://example.com', 'https://example.com/about'])
    # @example Stream final results as they arrive
    #   Archive.post(urls) do |r|
    #     next if r.submitted? # interim notification — final result comes later
    #     puts r.success? ? r.wayback_url : "FAIL #{r.uri}: #{r.error}"
    #   end
    # @example Resume — skip URLs we've already archived
    #   Archive.post(urls, skip_urls: Set['https://example.com/old'])
    # @example Request full-page screenshots
    #   Archive.post(urls, capture_screenshot: true, screenshot_dir: 'shots/')
    def self.post(urls, concurrency: WaybackArchiver.config.concurrency, limit: WaybackArchiver.config.max_limit, skip_urls: nil, skip_patterns: nil, include_ext: nil, exclude_ext: nil, **options, &block)
      validate_options!(options)
      WaybackArchiver.logger.debug "Total URLs to be sent: #{urls.length}"
      WaybackArchiver.logger.debug "Request are sent with up to #{concurrency} parallel threads"

      # Sitemap indexes with overlapping children (and hand-assembled URL
      # lists) routinely repeat URLs. At 6 captures/min each duplicate is a
      # wasted slot, so collapse them before anything else counts them.
      urls_queue = urls.uniq
      if (dupes = urls.length - urls_queue.length) > 0
        WaybackArchiver.logger.info "Skipped #{dupes} duplicate URL(s)"
      end

      if skip_urls && !skip_urls.empty?
        before = urls_queue.length
        urls_queue = urls_queue.reject { |url| skip_urls.include?(url) }
        skipped = before - urls_queue.length
        WaybackArchiver.logger.info "Skipped #{skipped} URL(s) already handled by the session" if skipped > 0
      end

      if skip_patterns && !skip_patterns.empty?
        before = urls_queue.length
        urls_queue = urls_queue.reject { |url| skip_patterns.any? { |pat| pat.match?(url) } }
        skipped = before - urls_queue.length
        WaybackArchiver.logger.info "Skipped #{skipped} URL(s) matching skip patterns" if skipped > 0
      end

      urls_queue = URLFilter.new(include_ext: include_ext, exclude_ext: exclude_ext).apply(urls_queue)

      # Limit applies AFTER the filters: it is documented as a cap on URLs to
      # submit, so skipped/filtered URLs must not consume the budget (a
      # resumed run with --limit would otherwise silently under-archive).
      urls_queue = urls_queue[0...limit] unless limit == -1

      BatchSubmitter.new(urls_queue, concurrency: concurrency, **options, &block).call
    end

    CRAWL_QUEUE_SIZE = 10_000 # SizedQueue capacity — backpressure when crawler outpaces SPN2

    # Send URLs to Wayback Machine by crawling the site.
    # Streams URLs to SPN2 as they are discovered — the crawler runs in a
    # background thread pushing into a SizedQueue that batch_post consumes.
    # @return [Array<ArchiveResult>] one per archived URL, including failures.
    # @param source [String] seed URL to crawl from.
    # @param hosts [Array<String, Regexp>] additional hosts to follow (defaults to source's host).
    # @param concurrency [Integer] parallel submission workers (default 4).
    # @param limit [Integer] cap on URLs to discover/submit (-1 for unlimited).
    # @param skip_urls [Set<String>, nil] discovered URLs in this set are skipped.
    # @param skip_patterns [Array<Regexp>, nil] URLs matching any pattern are skipped.
    # @param include_ext [Array<String>, nil] only submit URLs ending in these
    #   extensions. A URL without an extension (https://example.com/about)
    #   matches nothing, so it is not submitted. Crawl traversal is unaffected:
    #   the pages linking to the matches still have to be visited.
    # @param exclude_ext [Array<String>, nil] omit URLs ending in these extensions.
    # @param skip_duplicates [Boolean] when true, pages with the same path and identical body are deduped.
    # @param options [Hash] forwarded to SPN2 (capture_all:, capture_screenshot:, ...).
    # @yield [archive_result] called when a URL is accepted by SPN2 (interim
    #   result, +submitted?+ true) and again with the final result — guard with
    #   +result.submitted?+ to process only final results. May be invoked from
    #   multiple threads.
    # @yieldparam [ArchiveResult] archive_result
    # @example Crawl a site
    #   Archive.crawl('https://example.com')
    # @example Crawl multiple hosts
    #   Archive.crawl('https://example.com', hosts: ['example.com', /docs\.example\.com/])
    # @example Stop after the first 100 URLs
    #   Archive.crawl('https://example.com', limit: 100)
    # @example Skip URL patterns and process results as they arrive
    #   Archive.crawl('https://example.com', skip_patterns: [/\/tag\//, /\?utm_/]) do |r|
    #     puts r.uri if r.success?
    #   end
    def self.crawl(source, hosts: [], concurrency: WaybackArchiver.config.concurrency, limit: WaybackArchiver.config.max_limit, skip_urls: nil, skip_patterns: nil, include_ext: nil, exclude_ext: nil, skip_duplicates: true, **options, &block)
      validate_options!(options)
      queue = SizedQueue.new(CRAWL_QUEUE_SIZE)
      url_filter = URLFilter.new(include_ext: include_ext, exclude_ext: exclude_ext)
      discovered = Concurrent::AtomicFixnum.new(0)

      crawler_thread = Thread.new do
        Thread.current.report_on_exception = false # we re-raise via thread.value
        # capture_all stays in options (it's an SPN2 body param) but the
        # crawler also needs it, to let 4xx/5xx pages through to submission.
        # include_ext/exclude_ext are applied to the yielded URLs below, never
        # handed to the crawler: they would gate traversal and starve the
        # crawl of the HTML pages that link to the matching documents.
        #
        # limit is enforced here, not by the crawler, so that (as in .post)
        # it caps URLs actually submitted — URLs dropped by the filters below
        # must not consume the budget.
        # Catch here rather than relying on URLCollector's own catch: this
        # block is what throws, so it owns the unwind and works no matter who
        # drives it.
        catch(URLCollector::HALT) do
          # limit: -1 explicitly. URLCollector.crawl defaults to
          # config.max_limit, so omitting it handed discovery a finite budget
          # again for anyone who set a global limit — truncating before the
          # filters below, which is the ordering this block exists to avoid.
          URLCollector.crawl(source, hosts: hosts, limit: -1, skip_duplicates: skip_duplicates, capture_all: !!options[:capture_all]) do |url|
            next if skip_urls&.include?(url)
            next if skip_patterns&.any? { |pat| pat.match?(url) }
            next unless url_filter.match?(url)
            count = discovered.increment
            queue.push(url) # blocks when queue is full (backpressure)
            WaybackArchiver.listener.on_url_discovered(url: url, count: count)
            throw URLCollector::HALT if limit != -1 && count >= limit
          end
        end
      rescue ClosedQueueError
        # BatchSubmitter closed the queue to signal early termination (e.g. IP blocked)
      ensure
        WaybackArchiver.listener.on_crawl_complete(url_count: discovered.value)
      end

      BatchSubmitter.new(queue, concurrency: concurrency, source_thread: crawler_thread, **options, &block).call
    end

    # Send a single URL to the Wayback Machine, submitting and polling until
    # the capture completes (or fails). For many URLs, prefer {.post}.
    # @return [ArchiveResult]
    # @param url [String] URL to archive.
    # @param options [Hash] forwarded to SPN2 (capture_all:, capture_screenshot:, ...).
    # @example
    #   result = Archive.post_url('https://example.com')
    #   result.success? # => true
    #   result.wayback_url # => "https://web.archive.org/web/.../https://example.com"
    # @example With capture options
    #   Archive.post_url('https://example.com', capture_screenshot: true)
    def self.post_url(url, **options)
      validate_options!(options)
      WaybackMachine.call(url, **options)
    end

    def self.validate_options!(options)
      unknown = options.keys - ALLOWED_OPTIONS
      return if unknown.empty?

      raise ArgumentError,
            "Unknown option#{'s' if unknown.size > 1}: #{unknown.map(&:inspect).join(', ')}. " \
            "Supported options: #{ALLOWED_OPTIONS.map(&:inspect).join(', ')}"
    end
    private_class_method :validate_options!
  end
end
