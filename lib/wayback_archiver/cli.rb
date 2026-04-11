require 'wayback_archiver'
require 'wayback_archiver/session_file'
require 'wayback_archiver/timedelta'
require 'wayback_archiver/cli/progress_renderer'
require 'wayback_archiver/cli/option_parser'
require 'wayback_archiver/cli/summary'

module WaybackArchiver
  class CLIListener < NullListener
    attr_reader :renderer

    def initialize(stdout, tty: stdout.respond_to?(:tty?) && stdout.tty?)
      @stdout = stdout
      @tty = tty
      @mutex = Mutex.new
      @completed_count = 0
      @renderer = CLI::ProgressRenderer.new(stdout) if @tty
    end

    def on_resolved(strategy:, url_count:, source:)
      count = url_count ? "#{url_count} URLs" : "discovering URLs..."
      @stdout.puts "Strategy #{strategy} chosen: #{count}"
    end

    def on_batch_start(total:)
      @stdout.puts
      return unless @renderer

      @renderer.set_total(total) if total
      @renderer.start
      @renderer.repaint
    end

    def on_url_discovered(url:, count:)
      return unless @renderer

      @renderer.record_discovered
      @renderer.repaint
    end

    def on_crawl_complete(url_count:)
      return unless @renderer

      @renderer.set_total(url_count)
      @renderer.repaint
    end

    def on_submitted(url:, job_id:)
      @renderer&.set_state(CLI::ProgressRenderer::STATE_SUBMITTING)
    end

    def on_completed(result:)
      if @renderer
        n = @renderer.record_completion(errored: result.errored?)
        @renderer.print_result(format_result_line(n, result))
      else
        @mutex.synchronize do
          @completed_count += 1
          @stdout.puts format_result_line(@completed_count, result)
        end
      end
    end

    def on_progress(captured:, failed:, pending:)
      @renderer&.update_progress(pending: pending)
    end

    def on_waiting_for_slots(processing:)
      @renderer&.set_state(CLI::ProgressRenderer::STATE_WAITING)
    end

    def finish
      @renderer&.finish
    end

    private

    def format_result_line(n, result)
      label = result.status_label.ljust(6)
      detail = result.status_detail
      line = "[#{n}]  #{label}  #{result.uri}"
      line << "  #{detail}" if detail
      line
    end
  end

  class CLI
    # IO wrapper that routes writes through the progress renderer's
    # clear/write/redraw cycle so log messages don't collide with
    # the sticky footer.
    class FooterAwareOutput
      def initialize(io)
        @io = io
        @renderer = nil
      end

      attr_writer :renderer

      def write(str)
        r = @renderer
        r ? r.print_above(str) : @io.write(str)
      end

      # no-op: don't close the underlying IO (typically STDOUT)
      def close; end
    end

    def self.run(argv = ARGV, stdout: $stdout, stderr: $stderr)
      new(argv, stdout: stdout, stderr: stderr).run
    end

    def initialize(argv, stdout: $stdout, stderr: $stderr)
      @stdout = stdout
      @stderr = stderr
      @options = OptionParser.new(argv, stdout: stdout).parse!
      @summary = Summary.new(stdout: stdout, stderr: stderr)
    end

    def run
      return run_status if @options.status_mode

      setup_logger
      @options.strategy ||= 'auto'

      return run_check if @options.check_mode

      setup_session
      @archive_results = []
      install_signal_handler

      results = run_archive
      @summary.write_report(results, @options.report_path)
      cleanup_session(results)
      @summary.print_summary(results, @archive_start_time) if @options.show_summary
    ensure
      @cli_listener&.finish unless @interrupted
      @log_output&.renderer = nil
      @session&.close
    end

    private

    def setup_logger
      log_target = @options.log
      if log_target == @stdout
        @log_output = FooterAwareOutput.new(log_target)
        log_target = @log_output
      end

      WaybackArchiver.config.logger = Logger.new(log_target).tap do |logger|
        logger.progname = 'WaybackArchiver'
        logger.level = @options.log_level
        logger.formatter = proc do |severity, _time, _progname, msg|
          if severity == 'INFO'
            "#{msg}\n"
          else
            "#{severity}: #{msg}\n"
          end
        end
      end
    end

    def setup_session
      @auto_generated_session = false

      unless @options.no_session
        if @options.resume_path
          @session = SessionFile.new(@options.resume_path)
          WaybackArchiver.logger.info("Resuming from session: #{@session.path}")
        elsif @options.session_path
          @session = SessionFile.new(@options.session_path)
          WaybackArchiver.logger.info("Session file: #{@session.path}")
        else
          @session = SessionFile.new(SessionFile.auto_path)
          @auto_generated_session = true
          WaybackArchiver.logger.info("Session file: #{@session.path}")
        end
      end

      @skip_urls = @session&.completed_urls
      if @options.resume_path && @skip_urls&.any?
        WaybackArchiver.logger.info("Session contains #{@skip_urls.size} previously succeeded URL(s)")
      end
    end

    def run_status
      begin
        system_status = WaybackMachine.system_status
        @stdout.puts "System: #{system_status['status']}"
      rescue => e
        @stdout.puts "System: unreachable (#{e.message})"
      end

      begin
        user_status = WaybackMachine.check_user_status
        available = user_status['available']
        processing = user_status['processing']
        daily = user_status['daily_captures']
        daily_limit = user_status['daily_captures_limit']
        line = "Available: #{available}, Processing: #{processing}"
        line << ", Daily captures: #{daily}/#{daily_limit}" if daily && daily_limit
        @stdout.puts line
      rescue AuthenticationError
        @stdout.puts "User: credentials required (set WAYBACK_ACCESS_KEY and WAYBACK_SECRET_KEY)"
      rescue => e
        @stdout.puts "User: unreachable (#{e.message})"
      end

      exit(0)
    end

    def run_check
      all_urls = @options.urls.flat_map do |url|
        WaybackArchiver.discover_urls(url, strategy: @options.strategy, hosts: @options.hosts, limit: @options.limit)
      end

      WaybackArchiver.logger.info("Checking #{all_urls.length} URL(s) against the Wayback Machine")
      check_results = WaybackArchiver.check(all_urls, concurrency: @options.concurrency)
      check_results.sort_by!(&:url)

      check_results.each do |r|
        if r.archived?
          @stdout.puts "  \u2713 #{r.url}  #{r.captured_at}  #{r.wayback_url}"
        else
          @stdout.puts "  \u2717 #{r.url}  (not archived)"
        end
      end

      @summary.write_report(check_results, @options.report_path)

      if @options.show_summary
        archived_count = check_results.count(&:archived?)
        not_archived_count = check_results.length - archived_count
        @stdout.puts "\n#{archived_count} archived, #{not_archived_count} not archived (#{check_results.length} total)"
      end

      exit(0)
    end

    def run_archive
      all_results = []

      if @options.skip_archived
        skipped, extra_skip_urls = skip_archived_urls
        all_results.concat(skipped)
        @skip_urls ||= Set.new
        @skip_urls.merge(extra_skip_urls) if extra_skip_urls
      end

      WaybackArchiver.logger.info(@summary.startup_banner(@options))
      @cli_listener = CLIListener.new(@stdout)
      @log_output&.renderer = @cli_listener.renderer
      WaybackArchiver.config.listener = @cli_listener
      @archive_start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      archive_block = proc do |result|
        @session&.write_result(result)
        @archive_results << result unless result.submitted?
      end

      archive_opts = {
        hosts: @options.hosts,
        strategy: @options.strategy,
        concurrency: @options.concurrency,
        limit: @options.limit,
        skip_urls: @skip_urls,
        **@options.spn2_options
      }

      results = if %w[urls url].include?(@options.strategy)
                  WaybackArchiver.archive(@options.urls, **archive_opts, &archive_block)
                else
                  @options.urls.flat_map do |url|
                    WaybackArchiver.archive(url, **archive_opts, &archive_block)
                  end
                end
      all_results.concat(results)

      all_results
    end

    def skip_archived_urls
      urls_to_check = @options.urls.flat_map do |url|
        WaybackArchiver.discover_urls(url, strategy: @options.strategy, hosts: @options.hosts, limit: @options.limit)
      end

      urls_to_check = urls_to_check.reject { |u| @skip_urls&.include?(u) } if @skip_urls

      WaybackArchiver.logger.info("Checking #{urls_to_check.length} URL(s) against the Wayback Machine")
      check_results = WaybackArchiver.check(urls_to_check, concurrency: @options.concurrency)
      archived_checks = check_results.select(&:archived?)

      skipped_results = []
      extra_skip_urls = []

      archived_checks.each do |cr|
        result = ArchiveResult.new(cr.url, status_ext: 'skipped:already-archived', timestamp: cr.timestamp)
        @session&.write_result(result)
        skipped_results << result
        extra_skip_urls << cr.url
        WaybackArchiver.logger.debug("Skipping #{cr.url} (archived #{cr.timestamp})")
      end

      WaybackArchiver.logger.info("Skipped #{archived_checks.length} already-archived URL(s)") if archived_checks.any?

      [skipped_results, extra_skip_urls]
    end

    def cleanup_session(results)
      return unless @session

      if results.any?(&:errored?)
        @summary.print_resume_message(resume_command)
      elsif @auto_generated_session
        @session.delete!
        @session = nil
      end
    end

    def resume_command
      @resume_command ||= @summary.build_resume_command(@options, @session)
    end

    def install_signal_handler
      return unless @session

      cmd = resume_command
      stderr = @stderr
      stdout = @stdout
      summary = @summary
      cli_ref = self

      Signal.trap('INT') do
        # Clear the sticky progress footer before writing the summary,
        # otherwise the ensure block's finish call would erase our output
        # with ANSI cursor-up sequences.
        stdout.write(ProgressRenderer::CLEAR_FOOTER) if stdout.respond_to?(:tty?) && stdout.tty?
        cli_ref.instance_variable_set(:@interrupted, true)
        results = cli_ref.instance_variable_get(:@archive_results)
        start_time = cli_ref.instance_variable_get(:@archive_start_time)
        summary.print_summary(results, start_time) if results.length > 0 && start_time
        stderr.puts "Interrupted. Resume with:"
        stderr.puts "  #{cmd}"
        exit(1)
      end
    end
  end
end
