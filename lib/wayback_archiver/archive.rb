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

      urls_queue = URLFilter.new(include_ext: include_ext, exclude_ext: exclude_ext).apply(urls_queue)

      batch_post(urls_queue, concurrency: concurrency, **options, &block)
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
    def self.crawl(source, hosts: [], concurrency: WaybackArchiver.config.concurrency, limit: WaybackArchiver.config.max_limit, skip_urls: nil, include_ext: nil, exclude_ext: nil, skip_duplicates: true, **options, &block)
      queue = SizedQueue.new(CRAWL_QUEUE_SIZE)
      url_filter = URLFilter.new(include_ext: include_ext, exclude_ext: exclude_ext)
      discovered = Concurrent::AtomicFixnum.new(0)

      crawler_thread = Thread.new do
        Thread.current.report_on_exception = false # we re-raise via thread.value
        URLCollector.crawl(source, hosts: hosts, limit: limit, exts: include_ext, ignore_exts: exclude_ext, skip_duplicates: skip_duplicates) do |url|
          next if skip_urls&.include?(url)
          next unless url_filter.match?(url)
          count = discovered.increment
          queue.push(url) # blocks when queue is full (backpressure)
          WaybackArchiver.listener.on_url_discovered(url: url, count: count)
        end
      rescue ClosedQueueError
        # batch_post closed the queue to signal early termination (e.g. IP blocked)
      ensure
        WaybackArchiver.listener.on_crawl_complete(url_count: discovered.value)
      end

      batch_post(queue, concurrency: concurrency, source_thread: crawler_thread, **options, &block)
    end

    # Send URL to Wayback Machine.
    # @return [ArchiveResult] the sent URL.
    # @param [String] url to send.
    def self.post_url(url, **options)
      WaybackMachine.call(url, **options)
    end

    FALLBACK_CHUNK_SIZE = 2 # conservative fallback when check_user_status fails mid-run
    MAX_RETRIES = 5 # per-URL retry cap for transient errors (session limits, connection errors)

    # Batch mode: submit URLs in chunks with intermediate polling.
    #
    # @param queue [Array, SizedQueue] URL source. For non-crawl strategies this
    #   is a plain Array; for streaming crawl it's a SizedQueue fed by a background
    #   crawler thread.
    # @param source_thread [Thread, nil] when present, the crawler thread feeding
    #   the queue. Used to determine when all URLs have been discovered (the queue
    #   being empty is not sufficient while the crawler is still running).
    def self.batch_post(queue, concurrency:, source_thread: nil, **options, &block)
      results = Concurrent::Array.new
      pending = Concurrent::Hash.new
      counts = Concurrent::Hash.new(0) # :success, :error — incremental counters
      # Total is unknown during streaming crawl — the listener will update it
      # when on_crawl_complete fires.
      total = source_thread ? nil : queue.length
      WaybackArchiver.listener.on_batch_start(total: total)
      # For non-streaming mode, copy the array so callers keep their original.
      # SizedQueue is already a separate object shared with the crawler thread.
      queue = queue.dup if queue.is_a?(Array)
      submitted = 0
      retries = Hash.new(0)
      # Separate buffer for URLs to retry. Never push retries into the SizedQueue
      # — that would deadlock when both the main thread and crawler thread block
      # on a full queue with nobody consuming.
      retry_buffer = []

      loop do
        until queue_exhausted?(queue, source_thread, retry_buffer)
          chunk_size = available_slots(pending, results, counts, retry_buffer: retry_buffer, retries: retries, **options, &block)
          if chunk_size == :abort
            # Close the queue to stop the crawler thread via ClosedQueueError
            queue.close if source_thread && queue.respond_to?(:close)
            abort_remaining(queue, retry_buffer, results, counts, &block)
            break
          end

          chunk = drain_queue(queue, chunk_size, retry_buffer)

          # In streaming mode the queue may be temporarily empty while the
          # crawler is still discovering URLs. Do useful work (poll pending
          # jobs) while waiting for more URLs to arrive.
          if chunk.empty?
            poll_pending(pending, results, counts, retry_buffer: retry_buffer, retries: retries, **options, &block) unless pending.empty?
            log_progress(counts, pending)
            sleep(0.2)
            next
          end

          pool = ThreadPool.build(concurrency)
          retry_urls = Concurrent::Array.new
          chunk.each do |url|
            submitted += 1
            n = submitted
            pool.post do
              WaybackArchiver.logger.debug("Submitting #{url} (#{n}/#{total || '?'})")
              handle_submit_response(WaybackMachine.submit(url, **options), url, pending, results, retry_urls, **options, &block)
            rescue Request::Error => e
              WaybackArchiver.logger.debug("Connection error for #{url}: #{e.message}, will retry")
              retry_urls << url
            end
          end
          pool.shutdown
          pool.wait_for_termination

          # Re-queue URLs that hit transient errors (session limits, connection errors)
          handle_retries(retry_urls, retries, retry_buffer, results, counts, &block)

          # Intermediate poll to check progress and free sessions
          poll_pending(pending, results, counts, retry_buffer: retry_buffer, retries: retries, **options, &block) unless pending.empty?
          log_progress(counts, pending)
        end

        # Final poll phase: loop until all pending resolve or timeout
        break if pending.empty?
        poll_until_done(pending, results, counts, retry_buffer: retry_buffer, retries: retries, **options, &block)
        break if queue_exhausted?(queue, source_thread, retry_buffer) # no transient errors re-queued
        WaybackArchiver.logger.info("Re-submitting #{retry_buffer.size + queue.size} URL(s) after transient poll errors")
      end

      # Re-raise any exception from the crawler thread
      source_thread&.value if source_thread && !source_thread.alive?

      # Any URLs still pending after final poll were submitted but unconfirmed
      pending.each do |job_id, url|
        result = ArchiveResult.new(url, job_id: job_id, status_ext: 'submitted')
        results << result
      end

      WaybackArchiver.logger.info "#{counts[:success]} of #{results.length} URL(s) posted to Wayback Machine"
      results
    end
    private_class_method :batch_post

    # Check if the queue has been fully consumed.
    # For streaming mode (source_thread present), the queue is only exhausted
    # when it's empty AND the crawler thread has finished.
    def self.queue_exhausted?(queue, source_thread, retry_buffer = [])
      return false unless retry_buffer.empty?
      return queue.empty? unless source_thread
      queue.empty? && !source_thread.alive?
    end
    private_class_method :queue_exhausted?

    # Non-blocking drain that works with both Array and SizedQueue.
    # Pulls from retry_buffer first, then fills up from the main queue.
    # Returns up to +max+ items without blocking if the queue is empty.
    def self.drain_queue(queue, max, retry_buffer = [])
      items = retry_buffer.shift(max)
      remaining = max - items.size
      return items if remaining <= 0

      if queue.is_a?(Array)
        items.concat(queue.shift(remaining) || [])
      else
        remaining.times do
          items << queue.pop(true) # non-blocking; raises ThreadError when empty
        rescue ThreadError
          break
        end
      end
      items
    end
    private_class_method :drain_queue

    def self.handle_retries(retry_urls, retries, retry_buffer, results, counts, &block)
      return if retry_urls.empty?

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
        WaybackArchiver.logger.debug("Re-queuing #{requeued.size} URL(s) due to transient error")
        retry_buffer.concat(requeued)
      end
    end
    private_class_method :handle_retries

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
    # When retry_buffer and retries are provided, transient errors are re-queued
    # for a fresh submit attempt instead of being recorded as failures.
    def self.poll_pending(pending, results, counts, retry_buffer: nil, retries: nil, **options, &block)
      statuses = begin
        WaybackMachine.poll_statuses(pending.keys)
      rescue Request::Error => e
        WaybackArchiver.logger.debug("Poll failed: #{e.message}, will retry")
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
        if status['status'] == 'error' && retry_buffer && retries && ErrorCodes.retryable?(status_ext)
          retries[url] += 1
          if retries[url] <= MAX_RETRIES
            WaybackArchiver.logger.debug("Transient poll error for #{url}: #{status_ext}, re-queuing (#{retries[url]}/#{MAX_RETRIES})")
            retry_buffer.push(url)
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
    def self.poll_until_done(pending, results, counts, retry_buffer: nil, retries: nil, **options, &block)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      until pending.empty?
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        if elapsed > WaybackMachine::POLL_TIMEOUT
          WaybackArchiver.logger.info("Poll timeout reached, #{pending.size} URL(s) submitted but unconfirmed")
          break
        end

        sleep(WaybackMachine::POLL_INTERVAL)
        poll_pending(pending, results, counts, retry_buffer: retry_buffer, retries: retries, **options, &block)
        log_progress(counts, pending) unless pending.empty?
      end
    end
    private_class_method :poll_until_done

    MAX_SLOT_WAIT = 180 # max seconds to wait for available slots
    SLOT_WAIT_INTERVAL = 10 # seconds between status checks when waiting for slots

    # Determine how many URLs to submit in the next chunk.
    # Loops until slots are available, with timeout fallback.
    # @return [Integer, :abort] number of slots available, or :abort to stop
    def self.available_slots(pending, results, counts, retry_buffer: nil, retries: nil, **options, &block)
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
          WaybackArchiver.logger.debug("Status check failed: #{e.message}, will retry")
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

        poll_pending(pending, results, counts, retry_buffer: retry_buffer, retries: retries, **options, &block) unless pending.empty?
        log_progress(counts, pending)
        sleep(SLOT_WAIT_INTERVAL)
      end
    end
    private_class_method :available_slots

    def self.abort_remaining(queue, retry_buffer, results, counts, &block)
      all_urls = retry_buffer + (queue.is_a?(Array) ? queue : [])
      retry_buffer.clear
      all_urls.each do |url|
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

  end
end
