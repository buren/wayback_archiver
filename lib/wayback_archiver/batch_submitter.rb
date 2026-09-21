require 'concurrent'

require 'wayback_archiver/thread_pool'
require 'wayback_archiver/wayback_machine'
require 'wayback_archiver/archive_result'
require 'wayback_archiver/request'
require 'wayback_archiver/error_codes'
require 'wayback_archiver/cdx'
require 'time'

module WaybackArchiver
  # Raised when the crawler thread fails partway through a streaming crawl.
  #
  # Carries the results collected before the failure, so a late network blip
  # doesn't throw away work that was already archived — callers can still
  # report a summary and point the user at a resume command.
  class CrawlError < StandardError
    # @return [Array<ArchiveResult>] results completed before the failure
    attr_reader :results
    # @return [Exception] the error the crawler thread raised
    attr_reader :original_error

    def initialize(original_error, results)
      @original_error = original_error
      @results = results
      super(original_error.message)
    end
  end

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
  # @param pending_jobs [Hash] saved URL => job ID pairs to recover before submitting.
  # @param block [Proc] optional per-result callback.
  # @api private
  class BatchSubmitter
    FALLBACK_CHUNK_SIZE = 2   # conservative fallback when check_user_status fails mid-run
    MAX_RETRIES         = 5   # per-URL retry cap for transient errors (session limits, connection errors)
    MAX_SLOT_WAIT       = 180 # max seconds to wait for available slots
    SLOT_WAIT_INTERVAL  = 10  # seconds between status checks when waiting for slots
    IDLE_SLEEP          = 0.2 # seconds between checks while the crawler catches up
    # Below this age, absence from the Wayback Machine means the index hasn't
    # caught up yet — not that the capture never happened.
    CDX_INDEX_GRACE     = 3600

    def initialize(queue, concurrency:, source_thread: nil, pending_jobs: {}, **options, &block)
      @queue = queue
      @concurrency = concurrency
      @source_thread = source_thread
      @initial_pending = pending_jobs
      @options = options
      @block = block
    end

    # Execute the batch submission pipeline.
    # @return [Array<ArchiveResult>]
    def call
      @results = Concurrent::Array.new
      @pending = Concurrent::Hash.new
      @recovering_ids = []
      @poll_failures = 0
      # AtomicFixnum, not a Hash: record_result runs on pool workers and
      # `hash[k] += 1` is a non-atomic read-modify-write.
      @counts = { success: Concurrent::AtomicFixnum.new, error: Concurrent::AtomicFixnum.new }
      @retries = Hash.new(0)
      # Separate buffer for URLs to retry. Never push retries into the SizedQueue
      # — that would deadlock when both the main thread and crawler thread block
      # on a full queue with nobody consuming.
      @retry_buffer = []

      # Total is unknown during streaming crawl — the listener will update it
      # when on_crawl_complete fires.
      @total = @source_thread ? nil : @queue.length + @initial_pending.size
      WaybackArchiver.listener.on_batch_start(total: @total)
      # For non-streaming mode, copy the array so callers keep their original.
      # SizedQueue is already a separate object shared with the crawler thread.
      @queue = @queue.dup if @queue.is_a?(Array)
      @submitted = 0

      begin
        restore_pending
        run_submission_loop

        # Surface any exception raised by the crawler thread. value joins first,
        # so this also waits out a crawler still tearing down on the abort path.
        crawler_error = nil
        begin
          @source_thread&.value
        rescue StandardError => e
          crawler_error = e
        end

        # A final incomplete outcome is distinct from the interim submission
        # notification: it must reach callbacks, reports and recovery state.
        @pending.each do |job_id, url|
          record_incomplete(url, job_id, 'poll-timeout')
        end

        # Still raise — a failed crawl is not a successful run — but hand the
        # completed results over rather than discarding them with the stack.
        raise CrawlError.new(crawler_error, @results.to_a) if crawler_error

        WaybackArchiver.logger.info "#{@counts[:success].value} of #{@results.length} URL(s) posted to Wayback Machine"
        @results
      ensure
        # Never leak the crawler thread. Closing the queue unblocks a crawler
        # backpressured on a full SizedQueue (its push raises ClosedQueueError,
        # which it rescues); join then guarantees it has exited.
        if @source_thread
          @queue.close if @queue.respond_to?(:close) && !@queue.closed?
          begin
            @source_thread.join
          rescue StandardError
            # join re-raises the thread's exception. On the normal path we
            # already captured it above and are raising CrawlError; letting it
            # escape from here would clobber that with the bare error and lose
            # the partial results.
            nil
          end
        end
      end
    end

    private

    def restore_pending
      @pending_since = {}
      @initial_pending.each do |url, info|
        # Sessions written before pending timing was recorded store a bare
        # job id; treat those as undateable rather than unreadable.
        job_id, since = info.is_a?(Hash) ? [info[:job_id], info[:since]] : [info, nil]
        @pending_since[url] = since

        if job_id.is_a?(String) && !job_id.strip.empty?
          @pending[job_id] = url
        else
          record_incomplete(url, nil, 'missing-job-id')
        end
      end
      @recovering_ids = @pending.keys
      # Most jobs from a stopped process will already be done: check them in
      # one batch immediately, without spending any new capture allowance.
      poll_pending unless @pending.empty?
    end

    # SPN2 forgets a job's status about an hour after submission, but the
    # Wayback Machine itself is the durable record of whether the capture
    # landed — so ask it rather than leaving the URL in permanent limbo.
    #
    # Only an answer resolves the job. "Nothing indexed" resolves it as failed
    # (and therefore resubmittable) solely once enough time has passed for the
    # index to have caught up; sooner than that, or if the lookup itself
    # fails, the outcome is still unknown and the job stays pending.
    def resolve_unavailable(url, job_id)
      since = parse_recorded_at(@pending_since[url])
      # Without a submission time an older capture can't be told from this
      # job's; count it anyway, since "the URL is archived" is the outcome
      # that matters and the alternative is limbo for pre-timing sessions.
      check = CDX.check(url, from: since&.strftime('%Y%m%d%H%M%S'))

      if check.archived?
        WaybackArchiver.logger.info("Confirmed #{url} in the Wayback Machine [#{check.timestamp}]")
        record_result(ArchiveResult.new(url, job_id: job_id, timestamp: check.timestamp, status_ext: 'recovered'))
      elsif check.errored?
        record_incomplete(url, job_id, 'status-unavailable')
      elsif since && (Time.now.utc - since) > CDX_INDEX_GRACE
        WaybackArchiver.logger.warn("#{url}: job status expired and no capture was found; it will be retried")
        record_result(
          ArchiveResult.new(
            url, job_id: job_id,
            error: Request::ServerError.new('job status expired and no capture found in the Wayback Machine')
          )
        )
      else
        record_incomplete(url, job_id, 'status-unavailable')
      end
    end

    def parse_recorded_at(value)
      Time.iso8601(value.to_s).utc
    rescue ArgumentError, TypeError
      nil
    end

    def record_incomplete(url, job_id, reason)
      result = ArchiveResult.new(url, job_id: job_id, status_ext: "incomplete:#{reason}")
      WaybackArchiver.logger.warn("#{url}: #{result.status_detail}")
      record_result(result)
    end

    def run_submission_loop
      loop do
        until queue_exhausted?
          # In streaming mode the queue may be temporarily empty while the
          # crawler is still discovering URLs. Do useful work (poll pending
          # jobs) while waiting for more — but ask SPN2 for slot availability
          # only when there is something to submit. available_slots is an HTTP
          # call, and this branch loops every IDLE_SLEEP seconds: checking it
          # here would fire ~5 status requests/second for the whole crawl.
          if nothing_to_submit?
            idle_poll
            log_progress
            sleep(IDLE_SLEEP)
            next
          end

          chunk_size = available_slots
          if chunk_size == :abort
            # Close the queue to stop the crawler thread via ClosedQueueError
            @queue.close if @source_thread && @queue.respond_to?(:close)
            abort_remaining
            break
          end

          chunk = drain_queue(chunk_size)
          next if chunk.empty? # nothing_to_submit? already ruled this out; belt and braces

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
            rescue StandardError => e
              # Anything escaping a pool worker is swallowed by concurrent-ruby
              # — the URL would silently vanish from the results. Record it as
              # an error so the totals always add up.
              WaybackArchiver.logger.error("Unexpected error for #{url}: #{e.class}, #{e.message}")
              record_result(ArchiveResult.new(url, error: e))
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

    # Whether there is nothing to hand to SPN2 right now. Distinct from
    # {#queue_exhausted?}: in streaming mode the queue can be momentarily
    # empty while the crawler is still running, which is not exhaustion.
    def nothing_to_submit?
      @retry_buffer.empty? && @queue.empty?
    end

    # Check if the queue has been fully consumed.
    # For streaming mode (source_thread present), the queue is only exhausted
    # when it's empty AND the crawler thread has finished.
    def queue_exhausted?
      return false unless @retry_buffer.empty?
      return @queue.empty? unless @source_thread
      # Read alive? BEFORE empty?: a crawler that pushes its final URL and
      # exits between the two reads would otherwise look exhausted while the
      # URL is still queued. A thread observed dead cannot push afterwards,
      # so this order closes the window.
      !@source_thread.alive? && @queue.empty?
    end

    # Determine how many URLs to submit in the next chunk.
    # Loops until slots are available, with timeout fallback.
    # @return [Integer, :abort] number of slots available, or :abort to stop
    def available_slots
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      waiting_logged = false
      rejection_logged = false

      loop do
        status = begin
          WaybackMachine.check_user_status
        rescue AuthenticationError => e
          # Credentials that have already worked don't stop working mid-run:
          # archive.org rejects this endpoint under load. Only believe it when
          # nothing has succeeded yet — otherwise a healthy run would abort
          # with "credentials were rejected", dropping the remaining URLs.
          raise if @counts[:success].value.zero? && @pending.empty?

          unless rejection_logged
            WaybackArchiver.logger.warn(
              "Status check rejected mid-run (#{e.message}) - treating as transient"
            )
            rejection_logged = true
          end
          nil
        rescue Request::Error => e
          if @counts[:success].value.zero? && @pending.empty? && e.is_a?(Request::ClientError)
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

    # Poll from the idle (queue-empty) loop, rate-limited to POLL_INTERVAL.
    def idle_poll
      return if @pending.empty?

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @last_idle_poll && (now - @last_idle_poll) < WaybackMachine::POLL_INTERVAL

      @last_idle_poll = now
      poll_pending
    end

    # Single poll pass: collect completed results from pending jobs.
    # Transient errors are re-queued for a fresh submit attempt instead
    # of being recorded as failures.
    def poll_pending
      statuses = begin
        WaybackMachine.poll_statuses(@pending.keys)
      rescue Request::Error => e
        @poll_failures += 1
        WaybackArchiver.logger.debug("Poll failed: #{e.message}, will retry")
        return
      end
      @poll_failures = 0

      # SPN2 occasionally returns a JSON array instead of the expected {job_id => status} hash
      if statuses.is_a?(Array)
        statuses = statuses.each_with_object({}) do |entry, h|
          next unless entry.is_a?(Hash)

          jid = entry['job_id']
          h[jid] = entry if jid
        end
      end

      unless statuses.is_a?(Hash)
        WaybackArchiver.logger.warn("Unexpected poll response type: #{statuses.class}, #{statuses}")
        return
      end

      # Status records are ephemeral. A missing recovered job is unknown, not
      # a failed capture and not permission to submit a duplicate. Retain it
      # for manual reconciliation instead of polling it indefinitely.
      @recovering_ids.each do |job_id|
        next unless @pending.key?(job_id) && statuses[job_id].nil?

        resolve_unavailable(@pending.delete(job_id), job_id)
      end

      completed = []
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

        completed << [url, job_id, status]
      end

      finalize_completed(completed)
    end

    # Turn completed statuses into results.
    #
    # ArchiveResult.from_status downloads the screenshot when screenshot_dir
    # is set — an HTTP fetch per URL. Done serially that stalls the whole
    # poll loop for the length of the batch, so fan the batch out when
    # screenshots are in play. Without them this is pure CPU and stays serial.
    def finalize_completed(completed)
      return if completed.empty?

      if @options[:screenshot_dir] && completed.length > 1 && @concurrency > 1
        pool = ThreadPool.build([@concurrency, completed.length].min)
        completed.each { |url, job_id, status| pool.post { finalize_one(url, job_id, status) } }
        pool.shutdown
        pool.wait_for_termination
      else
        completed.each { |url, job_id, status| finalize_one(url, job_id, status) }
      end
    end

    def finalize_one(url, job_id, status)
      result = ArchiveResult.from_status(url, job_id, status, **@options)
      if result.success?
        WaybackArchiver.logger.debug("Captured #{url} [#{result.formatted_timestamp}]")
      elsif result.errored?
        WaybackArchiver.logger.debug("Capture failed for #{url}: #{result.status_ext}")
      end
      record_result(result)
    rescue StandardError => e
      # Same contract as the submit path: never let a URL vanish silently.
      WaybackArchiver.logger.error("Failed to build result for #{url}: #{e.class}, #{e.message}")
      record_result(ArchiveResult.new(url, error: e))
    end

    # Poll in a loop until all pending jobs complete or timeout.
    def poll_until_done
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      until @pending.empty?
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        remaining = WaybackMachine::POLL_TIMEOUT - elapsed
        if remaining <= 0
          WaybackArchiver.logger.info("Poll timeout reached, #{@pending.size} URL(s) submitted but unconfirmed")
          break
        end

        # Status reads have no documented unlimited allowance. Slow down after
        # errors (including 429s), and do not issue a request after the deadline.
        delay = [WaybackMachine::POLL_INTERVAL * (2 ** [@poll_failures, 4].min), 30].min
        sleep([delay, remaining].min)
        next if Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time >= WaybackMachine::POLL_TIMEOUT

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
      WaybackArchiver.logger.debug("  Polling... #{@counts[:success].value} captured, #{@counts[:error].value} failed, #{@pending.size} pending")
      WaybackArchiver.listener.on_progress(captured: @counts[:success].value, failed: @counts[:error].value, pending: @pending.size)
    end

    # Single funnel for final per-URL results: counts, callbacks, collection.
    # Every code path that produces a final result must go through here so
    # the progress totals can't drift from the recorded results.
    def record_result(result)
      if result.errored?
        @counts[:error].increment
      elsif result.success?
        @counts[:success].increment
      end
      @block&.call(result)
      WaybackArchiver.listener.on_completed(result: result)
      @results << result
    end
  end
end
