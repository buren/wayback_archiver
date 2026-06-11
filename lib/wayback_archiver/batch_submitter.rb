require 'concurrent'

require 'wayback_archiver/thread_pool'
require 'wayback_archiver/adapters/wayback_machine'
require 'wayback_archiver/archive_result'
require 'wayback_archiver/request'
require 'wayback_archiver/error_codes'

module WaybackArchiver
  # Batch mode: submit URLs in chunks with intermediate polling.
  #
  # Manages concurrent submission to SPN2, slot waiting, polling,
  # retry with backoff, error classification, and streaming crawl
  # backpressure. Constructed as a one-shot object: configure via
  # initialize, execute via call.
  #
  # @param queue [Array, SizedQueue] URL source. For non-crawl strategies this
  #   is a plain Array; for streaming crawl it's a SizedQueue fed by a background
  #   crawler thread.
  # @param concurrency [Integer] max parallel submission threads.
  # @param source_thread [Thread, nil] when present, the crawler thread feeding
  #   the queue. Used to determine when all URLs have been discovered (the queue
  #   being empty is not sufficient while the crawler is still running).
  # @param options [Hash] SPN2 capture options forwarded to WaybackMachine.
  # @param block [Proc] optional per-result callback.
  class BatchSubmitter
    FALLBACK_CHUNK_SIZE = 2   # conservative fallback when check_user_status fails mid-run
    MAX_RETRIES         = 5   # per-URL retry cap for transient errors (session limits, connection errors)
    MAX_SLOT_WAIT       = 180 # max seconds to wait for available slots
    SLOT_WAIT_INTERVAL  = 10  # seconds between status checks when waiting for slots

    def initialize(queue, concurrency:, source_thread: nil, **options, &block)
      @queue = queue
      @concurrency = concurrency
      @source_thread = source_thread
      @options = options
      @block = block
    end

    # Execute the batch submission pipeline.
    # @return [Array<ArchiveResult>]
    def call
      @results = Concurrent::Array.new
      @pending = Concurrent::Hash.new
      @counts = Concurrent::Hash.new(0) # :success, :error — incremental counters
      @retries = Hash.new(0)
      # Separate buffer for URLs to retry. Never push retries into the SizedQueue
      # — that would deadlock when both the main thread and crawler thread block
      # on a full queue with nobody consuming.
      @retry_buffer = []

      # Total is unknown during streaming crawl — the listener will update it
      # when on_crawl_complete fires.
      @total = @source_thread ? nil : @queue.length
      WaybackArchiver.listener.on_batch_start(total: @total)
      # For non-streaming mode, copy the array so callers keep their original.
      # SizedQueue is already a separate object shared with the crawler thread.
      @queue = @queue.dup if @queue.is_a?(Array)
      @submitted = 0

      begin
        run_submission_loop

        # Surface any exception raised by the crawler thread. value joins first,
        # so this also waits out a crawler still tearing down on the abort path.
        @source_thread&.value

        # Any URLs still pending after final poll were submitted but unconfirmed
        @pending.each do |job_id, url|
          result = ArchiveResult.new(url, job_id: job_id, status_ext: 'submitted')
          @results << result
        end

        WaybackArchiver.logger.info "#{@counts[:success]} of #{@results.length} URL(s) posted to Wayback Machine"
        @results
      ensure
        # Never leak the crawler thread. Closing the queue unblocks a crawler
        # backpressured on a full SizedQueue (its push raises ClosedQueueError,
        # which it rescues); join then guarantees it has exited.
        if @source_thread
          @queue.close if @queue.respond_to?(:close) && !@queue.closed?
          @source_thread.join
        end
      end
    end

    private

    def run_submission_loop
      loop do
        until queue_exhausted?
          chunk_size = available_slots
          if chunk_size == :abort
            # Close the queue to stop the crawler thread via ClosedQueueError
            @queue.close if @source_thread && @queue.respond_to?(:close)
            abort_remaining
            break
          end

          chunk = drain_queue(chunk_size)

          # In streaming mode the queue may be temporarily empty while the
          # crawler is still discovering URLs. Do useful work (poll pending
          # jobs) while waiting for more URLs to arrive.
          if chunk.empty?
            poll_pending unless @pending.empty?
            log_progress
            sleep(0.2)
            next
          end

          pool = ThreadPool.build(@concurrency)
          retry_urls = Concurrent::Array.new
          chunk.each do |url|
            @submitted += 1
            n = @submitted
            pool.post do
              WaybackArchiver.logger.debug("Submitting #{url} (#{n}/#{@total || '?'})")
              handle_submit_response(WaybackMachine.submit(url, **@options), url, retry_urls)
            rescue Request::Error => e
              WaybackArchiver.logger.debug("Connection error for #{url}: #{e.message}, will retry")
              retry_urls << url
            end
          end
          pool.shutdown
          pool.wait_for_termination

          # Re-queue URLs that hit transient errors (session limits, connection errors)
          handle_retries(retry_urls)

          # Intermediate poll to check progress and free sessions
          poll_pending unless @pending.empty?
          log_progress
        end

        # Final poll phase: loop until all pending resolve or timeout
        break if @pending.empty?
        poll_until_done
        break if queue_exhausted? # no transient errors re-queued
        WaybackArchiver.logger.info("Re-submitting #{@retry_buffer.size + @queue.size} URL(s) after transient poll errors")
      end
    end

    # Check if the queue has been fully consumed.
    # For streaming mode (source_thread present), the queue is only exhausted
    # when it's empty AND the crawler thread has finished.
    def queue_exhausted?
      return false unless @retry_buffer.empty?
      return @queue.empty? unless @source_thread
      @queue.empty? && !@source_thread.alive?
    end

    # Determine how many URLs to submit in the next chunk.
    # Loops until slots are available, with timeout fallback.
    # @return [Integer, :abort] number of slots available, or :abort to stop
    def available_slots
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      waiting_logged = false

      loop do
        status = begin
          WaybackMachine.check_user_status
        rescue Request::Error => e
          if @counts[:success] == 0 && @pending.empty? && e.is_a?(Request::ClientError)
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

        poll_pending unless @pending.empty?
        log_progress
        sleep(SLOT_WAIT_INTERVAL)
      end
    end

    # Non-blocking drain that works with both Array and SizedQueue.
    # Pulls from retry_buffer first, then fills up from the main queue.
    # Returns up to +max+ items without blocking if the queue is empty.
    def drain_queue(max)
      items = @retry_buffer.shift(max)
      remaining = max - items.size
      return items if remaining <= 0

      if @queue.is_a?(Array)
        items.concat(@queue.shift(remaining) || [])
      else
        remaining.times do
          items << @queue.pop(true) # non-blocking; raises ThreadError when empty
        rescue ThreadError
          break
        end
      end
      items
    end

    def handle_submit_response(response, url, retry_urls)
      if response.is_a?(ArchiveResult)
        record_result(response)
        return
      end

      outcome, value = WaybackMachine.classify_submit_response(response, url)
      case outcome
      when :pending
        @pending[value] = url
        submitted_result = ArchiveResult.new(url, job_id: value, status_ext: 'submitted')
        @block&.call(submitted_result)
        WaybackArchiver.listener.on_submitted(url: url, job_id: value)
      when :cached
        WaybackArchiver.logger.debug("Recent capture returned for #{url} [#{response['timestamp']}]")
        result = ArchiveResult.from_status(url, nil, response, status_ext: 'cached', **@options)
        record_result(result)
      when :retry
        WaybackArchiver.logger.debug("Transient submit error for #{url}: #{value}, will retry")
        retry_urls << url
      when :error
        msg, status_ext = value
        error = Request::ServerError.new(msg)
        WaybackArchiver.logger.error(error.message)
        result = ArchiveResult.new(url, error: error, status_ext: status_ext)
        record_result(result)
      end
    end

    def handle_retries(retry_urls)
      return if retry_urls.empty?

      requeued = []
      retry_urls.each do |url|
        @retries[url] += 1
        if @retries[url] > MAX_RETRIES
          WaybackArchiver.logger.error("Retry limit exceeded (#{MAX_RETRIES}) for #{url}")
          result = ArchiveResult.new(url, error: Request::ServerError.new('retry limit exceeded'))
          record_result(result)
        else
          requeued << url
        end
      end
      unless requeued.empty?
        WaybackArchiver.logger.debug("Re-queuing #{requeued.size} URL(s) due to transient error")
        @retry_buffer.concat(requeued)
      end
    end

    # Single poll pass: collect completed results from pending jobs.
    # Transient errors are re-queued for a fresh submit attempt instead
    # of being recorded as failures.
    def poll_pending
      statuses = begin
        WaybackMachine.poll_statuses(@pending.keys)
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

        url = @pending.delete(job_id)
        next unless url

        # Re-queue transient errors before building the full result (which may
        # trigger screenshot downloads and other side effects)
        status_ext = status['status_ext']
        if status['status'] == 'error' && ErrorCodes.retryable?(status_ext)
          @retries[url] += 1
          if @retries[url] <= MAX_RETRIES
            WaybackArchiver.logger.debug("Transient poll error for #{url}: #{status_ext}, re-queuing (#{@retries[url]}/#{MAX_RETRIES})")
            @retry_buffer.push(url)
            next
          end
          WaybackArchiver.logger.error("Retry limit exceeded (#{MAX_RETRIES}) for #{url}: #{status_ext}")
        end

        result = ArchiveResult.from_status(url, job_id, status, **@options)
        if result.success?
          WaybackArchiver.logger.debug("Captured #{url} [#{result.formatted_timestamp}]")
        elsif result.errored?
          WaybackArchiver.logger.debug("Capture failed for #{url}: #{result.status_ext}")
        end
        record_result(result)
      end
    end

    # Poll in a loop until all pending jobs complete or timeout.
    def poll_until_done
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      until @pending.empty?
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        if elapsed > WaybackMachine::POLL_TIMEOUT
          WaybackArchiver.logger.info("Poll timeout reached, #{@pending.size} URL(s) submitted but unconfirmed")
          break
        end

        sleep(WaybackMachine::POLL_INTERVAL)
        poll_pending
        log_progress
      end
    end

    def abort_remaining
      all_urls = @retry_buffer + drain_all_queued
      @retry_buffer.clear
      all_urls.each do |url|
        result = ArchiveResult.new(url, error: Request::ClientError.new('Connection refused by web.archive.org'))
        record_result(result)
      end
    end

    # Pull every remaining URL out of the queue without blocking, so abort can
    # record them as errors rather than silently dropping them. For a closed
    # SizedQueue, non-blocking pop drains remaining items then returns nil.
    def drain_all_queued
      return @queue if @queue.is_a?(Array)

      drained = []
      loop do
        item = @queue.pop(true)
        break if item.nil?
        drained << item
      rescue ThreadError
        break
      end
      drained
    end

    def log_progress
      WaybackArchiver.logger.debug("  Polling... #{@counts[:success]} captured, #{@counts[:error]} failed, #{@pending.size} pending")
      WaybackArchiver.listener.on_progress(captured: @counts[:success], failed: @counts[:error], pending: @pending.size)
    end

    # Single funnel for final per-URL results: counts, callbacks, collection.
    # Every code path that produces a final result must go through here so
    # the progress totals can't drift from the recorded results.
    def record_result(result)
      if result.errored?
        @counts[:error] += 1
      elsif result.success?
        @counts[:success] += 1
      end
      @block&.call(result)
      WaybackArchiver.listener.on_completed(result: result)
      @results << result
    end
  end
end
