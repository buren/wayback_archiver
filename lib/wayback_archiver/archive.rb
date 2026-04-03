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
    def self.post(urls, concurrency: WaybackArchiver.concurrency, limit: WaybackArchiver.max_limit, skip_urls: nil, include_ext: nil, exclude_ext: nil, **options, &block)
      WaybackArchiver.logger.info "Total URLs to be sent: #{urls.length}"
      WaybackArchiver.logger.info "Request are sent with up to #{concurrency} parallel threads"

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

      urls_queue = filter_by_extension(urls_queue, include_ext: include_ext, exclude_ext: exclude_ext)

      adapter = WaybackArchiver.adapter
      if batch_capable?(adapter)
        batch_post(urls_queue, adapter, concurrency: concurrency, **options, &block)
      else
        sequential_post(urls_queue, concurrency: concurrency, **options, &block)
      end
    end

    # Send URLs to Wayback Machine by crawling the site.
    # @return [Array<ArchiveResult>] with URLs sent to the Wayback Machine.
    # @param [String] source for URL to crawl.
    # @param concurrency [Integer] the default is 1
    # @param [Array<String, Regexp>] hosts to crawl
    # @yield [archive_result] If a block is given, each result will be yielded
    # @yieldparam [ArchiveResult] archive_result
    def self.crawl(source, hosts: [], concurrency: WaybackArchiver.concurrency, limit: WaybackArchiver.max_limit, skip_urls: nil, include_ext: nil, exclude_ext: nil, **options)
      WaybackArchiver.logger.info "Request are sent with up to #{concurrency} parallel threads"

      results = Concurrent::Array.new
      pool = ThreadPool.build(concurrency)
      include_ext = normalize_extensions(include_ext)
      exclude_ext = normalize_extensions(exclude_ext)

      found_urls = URLCollector.crawl(source, hosts: hosts, limit: limit) do |url|
        next if skip_urls&.include?(url)
        next unless match_extension?(url, include_ext: include_ext, exclude_ext: exclude_ext)

        pool.post do
          result = post_url(url, **options)
          yield(result) if block_given?
          results << result
        end
      end
      WaybackArchiver.logger.info "Crawling of #{source} finished, found #{found_urls.length} URL(s)"
      pool.shutdown
      pool.wait_for_termination

      WaybackArchiver.logger.info "#{results.count(&:success?)} of #{results.length} URL(s) posted to Wayback Machine"
      results
    end

    # Send URL to Wayback Machine.
    # @return [ArchiveResult] the sent URL.
    # @param [String] url to send.
    def self.post_url(url, **options)
      adapter = WaybackArchiver.adapter
      if options.any? && adapter.method(:call).parameters.any? { |type, _| %i[key keyrest].include?(type) }
        adapter.call(url, **options)
      else
        adapter.call(url)
      end
    end

    # Check if the adapter supports batch submit+poll.
    def self.batch_capable?(adapter)
      adapter.respond_to?(:submit) && adapter.respond_to?(:poll_statuses)
    end
    private_class_method :batch_capable?

    # Fallback: per-URL submit+poll via post_url (used for custom adapters).
    def self.sequential_post(urls, concurrency:, **options, &block)
      results = Concurrent::Array.new
      pool = ThreadPool.build(concurrency)

      urls.each do |url|
        pool.post do
          result = post_url(url, **options)
          yield(result) if block_given?
          results << result
        end
      end

      pool.shutdown
      pool.wait_for_termination

      WaybackArchiver.logger.info "#{results.count(&:success?)} of #{results.length} URL(s) posted to Wayback Machine"
      results
    end
    private_class_method :sequential_post

    # Batch mode: submit all URLs in parallel, then batch-poll until all complete.
    def self.batch_post(urls, adapter, concurrency:, **options, &block)
      results = Concurrent::Array.new
      pool = ThreadPool.build(concurrency)

      # Phase 1: Submit all URLs, collect {job_id => url} mapping
      submissions = Concurrent::Hash.new
      urls.each do |url|
        pool.post do
          response = adapter.submit(url, **options)
          if response.is_a?(ArchiveResult)
            # Submit failed — immediate error result
            yield(response) if block
            results << response
          else
            job_id = response['job_id']
            if job_id.nil? && response['timestamp']
              # SPN2 returns the capture directly when if_not_archived_within matches a recent snapshot
              WaybackArchiver.logger.info("Recent capture returned for #{url} [#{response['timestamp']}]")
              result = build_result_from_status(url, nil, response, status_ext: 'cached', **options)
              yield(result) if block
              results << result
            elsif job_id.nil?
              msg = response['message'] || "Unexpected submit response for #{url}"
              error = Request::ServerError.new(msg)
              WaybackArchiver.logger.error(error.message)
              result = ArchiveResult.new(url, error: error)
              yield(result) if block
              results << result
            else
              submissions[job_id] = url
            end
          end
        end
      end
      pool.shutdown
      pool.wait_for_termination

      # Phase 2: Batch-poll pending job_ids
      pending = submissions.dup
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      until pending.empty?
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        if elapsed > WaybackMachine::POLL_TIMEOUT
          # Timeout remaining jobs
          pending.each do |job_id, url|
            error = WaybackMachine::PollTimeoutError.new("Polling timed out after #{WaybackMachine::POLL_TIMEOUT}s for job #{job_id}")
            result = ArchiveResult.new(url, job_id: job_id, error: error)
            yield(result) if block
            results << result
          end
          break
        end

        sleep(WaybackMachine::POLL_INTERVAL)

        statuses = adapter.poll_statuses(pending.keys)

        statuses.each do |job_id, status|
          next if status['status'] == 'pending'

          url = pending.delete(job_id)
          result = build_result_from_status(url, job_id, status, **options)
          yield(result) if block
          results << result
        end
      end

      WaybackArchiver.logger.info "#{results.count(&:success?)} of #{results.length} URL(s) posted to Wayback Machine"
      results
    end
    private_class_method :batch_post

    def self.build_result_from_status(url, job_id, status, **options)
      ArchiveResult.from_status(url, job_id, status, **options)
    end
    private_class_method :build_result_from_status

    def self.url_extension(url)
      path = url.split('?', 2).first.split('#', 2).first
      File.extname(path).delete_prefix('.').downcase
    end
    private_class_method :url_extension

    def self.normalize_extensions(exts)
      return nil if exts.nil?

      exts.map { |e| e.delete_prefix('.').downcase }.freeze
    end
    private_class_method :normalize_extensions

    def self.match_extension?(url, include_ext:, exclude_ext:)
      ext = url_extension(url)
      return false if include_ext && !include_ext.include?(ext)
      return false if exclude_ext&.include?(ext)

      true
    end
    private_class_method :match_extension?

    def self.filter_by_extension(urls, include_ext: nil, exclude_ext: nil)
      return urls if include_ext.nil? && exclude_ext.nil?

      include_ext = normalize_extensions(include_ext)
      exclude_ext = normalize_extensions(exclude_ext)

      before = urls.length
      filtered = urls.select { |url| match_extension?(url, include_ext: include_ext, exclude_ext: exclude_ext) }
      skipped = before - filtered.length
      WaybackArchiver.logger.info "Filtered #{skipped} URL(s) by extension" if skipped > 0
      filtered
    end
    private_class_method :filter_by_extension

  end
end
