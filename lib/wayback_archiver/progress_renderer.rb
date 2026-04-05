require 'wayback_archiver/rate_limiter'

module WaybackArchiver
  # TTY progress renderer with a sticky 2-line footer.
  #
  # Line 1: adaptive progress bar with stats
  # Line 2: current state (Submitting.../Polling.../Waiting for available slots...)
  #
  # Thread-safe: all public methods synchronize on an internal mutex.
  class ProgressRenderer
    ALPHA = 2.0 / (10 + 1) # EMA smoothing factor, N=10
    MIN_COMPLETIONS_FOR_ETA = 5
    EMA_WARMUP_THRESHOLD = 20
    SPN2_SECONDS_PER_URL = 60.0 / RateLimiter::RATE
    MIN_BAR_WIDTH = 10
    MAX_BAR_WIDTH = 30
    FILL_CHAR = "\u2588" # █
    EMPTY_CHAR = "\u2591" # ░
    BURST_THRESHOLD = 1.0 # seconds — completions closer than this are a burst

    STATE_SUBMITTING = 'Submitting...'
    STATE_POLLING = 'Polling...'
    STATE_WAITING = 'Waiting for available slots...'

    def initialize(stdout, terminal_width: nil)
      @stdout = stdout
      @terminal_width_override = terminal_width
      @mutex = Mutex.new
      @total = 0
      @completed = 0
      @failed = 0
      @pending = 0
      @state = STATE_SUBMITTING
      @start_time = nil
      @last_ema_time = nil
      @burst_count = 0
      @ema_seconds_per_url = nil
      @footer_drawn = false
      @cached_terminal_width = nil
      @terminal_width_checked_at = nil
    end

    def set_total(total)
      @mutex.synchronize { @total = total }
    end

    def start
      @mutex.synchronize do
        @start_time = monotonic_now
      end
    end

    # Record a completed URL and return the new completion count.
    # @return [Integer] the sequential completion number
    def record_completion(errored:)
      @mutex.synchronize do
        @completed += 1
        @failed += 1 if errored
        update_ema
        @completed
      end
    end

    # Print a result line above the footer, then repaint footer.
    def print_result(line)
      @mutex.synchronize do
        clear_footer
        @stdout.puts line
        render_footer
      end
    end

    # Update pending count and set state to "Polling...", then repaint.
    def update_progress(pending:)
      @mutex.synchronize do
        @pending = pending
        @state = STATE_POLLING
        repaint_footer
      end
    end

    # Change the status line. Only repaints if state actually changed.
    def set_state(state)
      @mutex.synchronize do
        return if @state == state

        @state = state
        repaint_footer
      end
    end

    # Clear the footer (call before final summary output).
    def finish
      @mutex.synchronize { clear_footer }
    end

    # Force a repaint of the footer (public for testing).
    def repaint
      @mutex.synchronize { repaint_footer }
    end

    private

    # Collapse burst completions (from a single poll resolving multiple jobs)
    # into one EMA sample: N URLs in T seconds → T/N seconds per URL.
    def update_ema
      now = monotonic_now
      @burst_count += 1
      @last_ema_time ||= @start_time
      interval = now - @last_ema_time

      if interval >= BURST_THRESHOLD
        seconds_per_url = interval / @burst_count
        if @ema_seconds_per_url.nil?
          @ema_seconds_per_url = seconds_per_url
        else
          @ema_seconds_per_url = ALPHA * seconds_per_url + (1 - ALPHA) * @ema_seconds_per_url
        end
        @last_ema_time = now
        @burst_count = 0
      end
    end

    def clear_footer
      return unless @footer_drawn

      # \e[A = move cursor up one line, \e[2K = clear entire line, \r = carriage return
      @stdout.write("\e[A\e[2K\e[A\e[2K\e[A\e[2K\r")
      @footer_drawn = false
    end

    def render_footer
      line1 = build_progress_line
      line2 = @state
      @stdout.write("\n#{line1}\n#{line2}\n")
      @footer_drawn = true
    end

    def repaint_footer
      clear_footer
      render_footer
    end

    def build_progress_line
      stats = build_stats_string
      width = terminal_width
      # Line format: "[BAR]  STATS" — overhead is "[" (1) + "]  " (3) = 4
      bar_width = [width - 4 - stats.length, MAX_BAR_WIDTH].min

      if bar_width >= MIN_BAR_WIDTH
        "[#{build_bar(bar_width)}]  #{stats}"
      else
        stats
      end
    end

    def build_stats_string
      pct = @total > 0 ? (@completed * 100 / @total) : 0
      parts = ["#{@completed}/#{@total} (#{pct}%)"]
      parts << "#{@pending} pending"
      parts << "#{@failed} failed"

      spu = effective_seconds_per_url
      if @completed >= MIN_COMPLETIONS_FOR_ETA && spu && spu > 0
        rate_per_min = 60.0 / spu
        remaining = @total - @completed
        eta_seconds = remaining * spu
        parts << "~#{format_duration(eta_seconds)} left (~#{rate_per_min.round} URLs/min)"
      end

      parts.join(" \u00b7 ") # \u00b7 = · (middle dot)
    end

    def effective_seconds_per_url
      if @completed < EMA_WARMUP_THRESHOLD || @ema_seconds_per_url.nil?
        SPN2_SECONDS_PER_URL
      else
        @ema_seconds_per_url
      end
    end

    def build_bar(width)
      filled = @total > 0 ? (width * @completed / @total) : 0
      filled = [filled, width].min
      FILL_CHAR * filled + EMPTY_CHAR * (width - filled)
    end

    def format_duration(seconds)
      if seconds < 60
        "#{seconds.round}s"
      elsif seconds < 3600
        "#{(seconds / 60).round} min"
      else
        hours = (seconds / 3600).floor
        mins = ((seconds % 3600) / 60).round
        "#{hours}h #{mins}m"
      end
    end

    TERMINAL_WIDTH_TTL = 5.0 # seconds between ioctl checks

    def terminal_width
      return @terminal_width_override if @terminal_width_override

      now = monotonic_now
      if @cached_terminal_width && @terminal_width_checked_at && (now - @terminal_width_checked_at) < TERMINAL_WIDTH_TTL
        return @cached_terminal_width
      end

      @terminal_width_checked_at = now
      @cached_terminal_width = detect_terminal_width
    rescue StandardError
      @cached_terminal_width = 80
    end

    def detect_terminal_width
      if @stdout.respond_to?(:winsize)
        @stdout.winsize[1]
      else
        require 'io/console'
        IO.console&.winsize&.last || 80
      end
    rescue StandardError
      80
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
