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
    def self.post(urls, concurrency: WaybackArchiver.config.concurrency, limit: WaybackArchiver.config.max_limit, skip_urls: nil, include_ext: nil, exclude_ext: nil, **options, &block)
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

      urls_queue = filter_by_extension(urls_queue, include_ext: include_ext, exclude_ext: exclude_ext)

      batch_post(urls_queue, concurrency: concurrency, **options, &block)
    end

    # Send URLs to Wayback Machine by crawling the site.
    # @return [Array<ArchiveResult>] with URLs sent to the Wayback Machine.
    # @param [String] source for URL to crawl.
    # @param concurrency [Integer] the default is 1
    # @param [Array<String, Regexp>] hosts to crawl
    # @yield [archive_result] If a block is given, each result will be yielded
    # @yieldparam [ArchiveResult] archive_result
    def self.crawl(source, hosts: [], concurrency: WaybackArchiver.config.concurrency, limit: WaybackArchiver.config.max_limit, skip_urls: nil, include_ext: nil, exclude_ext: nil, **options, &block)
      WaybackArchiver.logger.debug "Request are sent with up to #{concurrency} parallel threads"

      results = Concurrent::Array.new
      pool = ThreadPool.build(concurrency)
      include_ext = normalize_extensions(include_ext)
      exclude_ext = normalize_extensions(exclude_ext)

      found_urls = URLCollector.crawl(source, hosts: hosts, limit: limit) do |url|
        next if skip_urls&.include?(url)
        next unless match_extension?(url, include_ext: include_ext, exclude_ext: exclude_ext)

        pool.post do
          result = post_url(url, **options)
          record_result(result, results, &block)
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
      WaybackMachine.call(url, **options)
    end

    FALLBACK_CHUNK_SIZE = 2 # conservative fallback when check_user_status fails mid-run
    MAX_RETRIES = 3 # per-URL retry cap for transient errors (session limits, connection errors)

    # Batch mode: submit URLs in chunks with intermediate polling.
    def self.batch_post(urls, concurrency:, **options, &block)
      results = Concurrent::Array.new
      pending = Concurrent::Hash.new
      counts = Concurrent::Hash.new(0) # :success, :error — incremental counters
      total = urls.length
      WaybackArchiver.listener.on_batch_start(total: total)
      queue = urls.dup
      submitted = 0
      retries = Hash.new(0)

      loop do
        until queue.empty?
          chunk_size = available_slots(pending, results, counts, queue: queue, retries: retries, **options, &block)
          if chunk_size == :abort
            abort_remaining(queue, results, counts, &block)
            break
          end

          chunk = queue.shift([chunk_size, queue.size].min)
          next if chunk.empty?

          pool = ThreadPool.build(concurrency)
          retry_urls = Concurrent::Array.new
          chunk.each do |url|
            submitted += 1
            n = submitted
            pool.post do
              WaybackArchiver.logger.debug("Submitting #{url} (#{n}/#{total})")
              handle_submit_response(WaybackMachine.submit(url, **options), url, pending, results, retry_urls, **options, &block)
            rescue Request::Error => e
              WaybackArchiver.logger.warn("Connection error for #{url}: #{e.message}")
              retry_urls << url
            end
          end
          pool.shutdown
          pool.wait_for_termination

          # Re-queue URLs that hit transient errors (session limits, connection errors)
          unless retry_urls.empty?
            requeued = []
            retry_urls.each do |url|
              retries[url] += 1
              if retries[url] > MAX_RETRIES
                WaybackArchiver.logger.error("Retry limit exceeded (#{MAX_RETRIES}) for #{url}")
                result = ArchiveResult.new(url, error: Request::ServerError.new('retry limit exceeded'))
                counts[:error] += 1
                record_result(result, results, &block)
              else
                requeued << url
              end
            end
            unless requeued.empty?
              WaybackArchiver.logger.warn("Re-queuing #{requeued.size} URL(s) due to transient error")
              queue.unshift(*requeued)
            end
          end

          # Intermediate poll to check progress and free sessions
          poll_pending(pending, results, counts, queue: queue, retries: retries, **options, &block) unless pending.empty?
          log_progress(counts, pending)
        end

        # Final poll phase: loop until all pending resolve or timeout
        break if pending.empty?
        poll_until_done(pending, results, counts, queue: queue, retries: retries, **options, &block)
        break if queue.empty? # no transient errors re-queued
        WaybackArchiver.logger.info("Re-submitting #{queue.size} URL(s) after transient poll errors")
      end

      # Any URLs still pending after final poll were submitted but unconfirmed
      pending.each do |job_id, url|
        result = ArchiveResult.new(url, job_id: job_id, status_ext: 'submitted')
        results << result
      end

      WaybackArchiver.logger.info "#{counts[:success]} of #{results.length} URL(s) posted to Wayback Machine"
      results
    end
    private_class_method :batch_post

    def self.handle_submit_response(response, url, pending, results, retry_urls, **options, &block)
      if response.is_a?(ArchiveResult)
        record_result(response, results, &block)
        return
      end

      job_id = response['job_id']
      if job_id.nil? && response['timestamp']
        WaybackArchiver.logger.debug("Recent capture returned for #{url} [#{response['timestamp']}]")
        result = build_result_from_status(url, nil, response, status_ext: 'cached', **options)
        record_result(result, results, &block)
      elsif job_id.nil?
        msg = response['message'] || "Unexpected submit response for #{url}"
        if msg.include?('limit of active')
          retry_urls << url
        else
          error = Request::ServerError.new(msg)
          WaybackArchiver.logger.error(error.message)
          result = ArchiveResult.new(url, error: error)
          record_result(result, results, &block)
        end
      else
        pending[job_id] = url
        submitted_result = ArchiveResult.new(url, job_id: job_id, status_ext: 'submitted')
        yield(submitted_result) if block
        WaybackArchiver.listener.on_submitted(url: url, job_id: job_id)
      end
    end
    private_class_method :handle_submit_response

    # Single poll pass: collect completed results from pending jobs.
    # When queue and retries are provided, transient errors are re-queued
    # for a fresh submit attempt instead of being recorded as failures.
    def self.poll_pending(pending, results, counts, queue: nil, retries: nil, **options, &block)
      statuses = begin
        WaybackMachine.poll_statuses(pending.keys)
      rescue Request::Error => e
        WaybackArchiver.logger.warn("Poll failed: #{e.message}")
        return
      end

      # SPN2 occasionally returns a JSON array instead of the expected {job_id => status} hash
      if statuses.is_a?(Array)
        statuses = statuses.each_with_object({}) do |entry, h|
          jid = entry['job_id']
          h[jid] = entry if jid
        end
      end

      unless statuses.is_a?(Hash)
        WaybackArchiver.logger.warn("Unexpected poll response type: #{statuses.class}, #{statuses}")
        return
      end

      statuses.each do |job_id, status|
        next if status.nil? || status['status'] == 'pending'

        url = pending.delete(job_id)
        next unless url

        # Re-queue transient errors before building the full result (which may
        # trigger screenshot downloads and other side effects)
        status_ext = status['status_ext']
        if status['status'] == 'error' && queue && retries && ErrorCodes.retryable?(status_ext)
          retries[url] += 1
          if retries[url] <= MAX_RETRIES
            WaybackArchiver.logger.warn("Transient poll error for #{url}: #{status_ext}, re-queuing (#{retries[url]}/#{MAX_RETRIES})")
            queue.push(url)
            next
          end
          WaybackArchiver.logger.error("Retry limit exceeded (#{MAX_RETRIES}) for #{url}: #{status_ext}")
        end

        result = build_result_from_status(url, job_id, status, **options)
        if result.success?
          counts[:success] += 1
          WaybackArchiver.logger.debug("Captured #{url} [#{result.formatted_timestamp}]")
        elsif result.errored?
          counts[:error] += 1
          WaybackArchiver.logger.debug("Capture failed for #{url}: #{result.status_ext}")
        end
        record_result(result, results, &block)
      end
    end
    private_class_method :poll_pending

    # Poll in a loop until all pending jobs complete or timeout.
    def self.poll_until_done(pending, results, counts, queue: nil, retries: nil, **options, &block)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      until pending.empty?
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        if elapsed > WaybackMachine::POLL_TIMEOUT
          WaybackArchiver.logger.info("Poll timeout reached, #{pending.size} URL(s) submitted but unconfirmed")
          break
        end

        sleep(WaybackMachine::POLL_INTERVAL)
        poll_pending(pending, results, counts, queue: queue, retries: retries, **options, &block)
        log_progress(counts, pending) unless pending.empty?
      end
    end
    private_class_method :poll_until_done

    MAX_SLOT_WAIT = 180 # max seconds to wait for available slots
    SLOT_WAIT_INTERVAL = 10 # seconds between status checks when waiting for slots

    # Determine how many URLs to submit in the next chunk.
    # Loops until slots are available, with timeout fallback.
    # @return [Integer, :abort] number of slots available, or :abort to stop
    def self.available_slots(pending, results, counts, queue: nil, retries: nil, **options, &block)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      waiting_logged = false

      loop do
        status = begin
          WaybackMachine.check_user_status
        rescue Request::Error => e
          if counts[:success] == 0 && pending.empty? && e.is_a?(Request::ClientError)
            WaybackArchiver.logger.error("Connection refused by web.archive.org — your IP may be temporarily blocked. Try again later.")
            return :abort
          end
          WaybackArchiver.logger.warn("Status check failed: #{e.message}")
          nil
        end

        available = status&.dig('available').to_i
        return available if available > 0

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        if elapsed >= MAX_SLOT_WAIT
          WaybackArchiver.logger.warn("No slots available after #{MAX_SLOT_WAIT}s, using fallback chunk size")
          return FALLBACK_CHUNK_SIZE
        end

        unless waiting_logged
          WaybackArchiver.logger.debug("Waiting for available slots...")
          WaybackArchiver.listener.on_waiting_for_slots(processing: status&.dig('processing').to_i)
          waiting_logged = true
        end

        poll_pending(pending, results, counts, queue: queue, retries: retries, **options, &block) unless pending.empty?
        log_progress(counts, pending)
        sleep(SLOT_WAIT_INTERVAL)
      end
    end
    private_class_method :available_slots

    def self.abort_remaining(queue, results, counts, &block)
      queue.each do |url|
        result = ArchiveResult.new(url, error: Request::ClientError.new('Connection refused by web.archive.org'))
        counts[:error] += 1
        record_result(result, results, &block)
      end
    end
    private_class_method :abort_remaining

    def self.log_progress(counts, pending)
      WaybackArchiver.logger.debug("  Polling... #{counts[:success]} captured, #{counts[:error]} failed, #{pending.size} pending")
      WaybackArchiver.listener.on_progress(captured: counts[:success], failed: counts[:error], pending: pending.size)
    end
    private_class_method :log_progress

    def self.record_result(result, results, &block)
      yield(result) if block
      WaybackArchiver.listener.on_completed(result: result)
      results << result
    end
    private_class_method :record_result

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
