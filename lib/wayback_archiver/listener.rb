module WaybackArchiver
  # Base listener with no-op defaults for all archiving lifecycle events.
  # Subclass and override only the events you care about.
  #
  # All methods may be called from multiple threads (batch mode uses
  # thread pools). Implementations must handle their own thread safety.
  #
  # @example Subclass to log completed captures
  #   class MyListener < WaybackArchiver::NullListener
  #     def on_completed(result:)
  #       puts "#{result.archived_url} => #{result.status_label}"
  #     end
  #   end
  #
  # @see ListenerProxy for wrapping arbitrary objects or proc hashes as listeners
  class NullListener
    # Called once URL discovery has finished and the strategy is known.
    #
    # @param strategy [Symbol] the archiving strategy used
    #   (e.g. +:crawl+, +:sitemap+, +:rss+, +:urls+, +:auto+)
    # @param url_count [Integer] number of URLs discovered
    # @param source [String] the origin URL or path that was resolved
    # @return [void]
    def on_resolved(strategy:, url_count:, source:); end

    # Called when a new batch of URLs is about to be submitted.
    #
    # @param total [Integer, nil] total number of URLs in the batch,
    #   or +nil+ when the total is not yet known (streaming crawl mode)
    # @return [void]
    def on_batch_start(total:); end

    # Called each time a URL is discovered during a streaming crawl.
    # Only fired for the crawl strategy; other strategies discover all
    # URLs upfront before archiving begins.
    #
    # @param url [String] the discovered URL
    # @param count [Integer] total number of URLs discovered so far
    # @return [void]
    def on_url_discovered(url:, count:); end

    # Called when the crawler has finished discovering URLs.
    # After this event, the total URL count is known and progress
    # can switch from indeterminate to determinate mode.
    #
    # @param url_count [Integer] final number of URLs discovered
    # @return [void]
    def on_crawl_complete(url_count:); end

    # Called when a single URL has been submitted to the SPN2 API.
    #
    # @param url [String] the URL that was submitted
    # @param job_id [String] the SPN2 job ID assigned to this capture
    # @return [void]
    def on_submitted(url:, job_id:); end

    # Called when a capture job has finished (successfully or with an error).
    #
    # @param result [ArchiveResult] the result of the capture, including
    #   status, timestamps, and any error information
    # @return [void]
    def on_completed(result:); end

    # Called periodically to report overall progress of the current batch.
    #
    # @param captured [Integer] number of URLs successfully captured so far
    # @param failed [Integer] number of URLs that have failed so far
    # @param pending [Integer] number of URLs still being processed
    # @return [void]
    def on_progress(captured:, failed:, pending:); end

    # Called when a URL is skipped during crawl because its content
    # is a duplicate of a previously seen page at the same path.
    #
    # @param url [String] the URL that was skipped
    # @return [void]
    def on_duplicate_skipped(url:); end

    # Called when the SPN2 API has no available processing slots and
    # the archiver is waiting before retrying.
    #
    # @param processing [Integer] number of jobs currently being processed
    #   by the SPN2 API
    # @return [void]
    def on_waiting_for_slots(processing:); end
  end

  # Wraps any object or hash of procs as a safe listener.
  # Delegates to methods the object responds to, calls hash procs by key,
  # and silently skips anything unimplemented.
  class ListenerProxy
    def initialize(listener)
      @listener = listener
    end

    NullListener.instance_methods(false).each do |method|
      define_method(method) do |**kwargs|
        if @listener.respond_to?(method)
          @listener.send(method, **kwargs)
        elsif @listener.is_a?(Hash) && @listener[method]
          @listener[method].call(**kwargs)
        end
      end
    end

    def respond_to_missing?(method, include_private = false)
      @listener.respond_to?(method, include_private) || super
    end

    def method_missing(method, ...)
      if @listener.respond_to?(method)
        @listener.send(method, ...)
      else
        super
      end
    end
  end
end
