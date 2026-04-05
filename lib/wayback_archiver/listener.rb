module WaybackArchiver
  # Base listener with no-op defaults for all lifecycle events.
  # Subclass and override only the events you care about.
  #
  # All methods may be called from multiple threads (batch mode uses
  # thread pools). Implementations must handle their own thread safety.
  class NullListener
    def on_resolved(strategy:, url_count:, source:); end
    def on_submitted(url:, job_id:); end
    def on_completed(result:); end
    def on_progress(captured:, failed:, pending:); end
    def on_waiting_for_slots(processing:); end
    def on_batch_start(total:); end
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
