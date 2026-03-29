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
    def self.post(urls, concurrency: WaybackArchiver.concurrency, limit: WaybackArchiver.max_limit, **options, &block)
      WaybackArchiver.logger.info "Total URLs to be sent: #{urls.length}"
      WaybackArchiver.logger.info "Request are sent with up to #{concurrency} parallel threads"

      urls_queue = if limit == -1
                     urls
                   else
                     urls[0...limit]
                   end

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
    def self.crawl(source, hosts: [], concurrency: WaybackArchiver.concurrency, limit: WaybackArchiver.max_limit, **options)
      WaybackArchiver.logger.info "Request are sent with up to #{concurrency} parallel threads"

      results = Concurrent::Array.new
      pool = ThreadPool.build(concurrency)

      found_urls = URLCollector.crawl(source, hosts: hosts, limit: limit) do |url|
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
            submissions[response['job_id']] = url
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

    # Build an ArchiveResult from a batch poll status hash.
    def self.build_result_from_status(url, job_id, status, **options)
      if status['status'] == 'error'
        ArchiveResult.new(
          url,
          job_id: job_id,
          status_ext: status['status_ext'],
          response_error: status['message']
        )
      else
        screenshot_path = maybe_download_screenshot(
          status['screenshot'], status['original_url'] || url, options
        )

        ArchiveResult.new(
          url,
          job_id: job_id,
          timestamp: status['timestamp'],
          duration_sec: status['duration_sec'],
          resources: status['resources'] || [],
          outlinks: status['outlinks'] || {},
          screenshot_url: status['screenshot'],
          screenshot_path: screenshot_path,
          original_url: status['original_url'],
          code: '200'
        )
      end
    end
    private_class_method :build_result_from_status

    def self.maybe_download_screenshot(screenshot_url, original_url, options)
      return nil unless screenshot_url && options[:screenshot_dir]

      Screenshot.download(screenshot_url, original_url, directory: options[:screenshot_dir])
    rescue => e
      WaybackArchiver.logger.error("Failed to download screenshot: #{e.message}")
      nil
    end
    private_class_method :maybe_download_screenshot
  end
end
