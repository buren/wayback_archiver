require 'optparse'
require 'shellwords'
require 'wayback_archiver'
require 'wayback_archiver/session_file'
require 'wayback_archiver/timedelta'

module WaybackArchiver
  class CLIListener < NullListener
    def initialize(stdout)
      @stdout = stdout
      @mutex = Mutex.new
      @completed_count = 0
    end

    def on_resolved(strategy:, url_count:, source:)
      count = url_count ? "#{url_count} URLs" : "discovering..."
      @stdout.puts "Strategy #{strategy} chosen: #{count}"
    end

    def on_completed(result:)
      @mutex.synchronize do
        @completed_count += 1
        label = result.status_label.ljust(6)
        detail = result.status_detail
        line = "  [#{@completed_count}]  #{label}  #{result.uri}"
        line << "  #{detail}" if detail
        @stdout.puts line
      end
    end
  end

  class CLI
    def self.run(argv = ARGV, stdout: $stdout, stderr: $stderr)
      new(argv, stdout: stdout, stderr: stderr).run
    end

    def initialize(argv, stdout: $stdout, stderr: $stderr)
      @stdout = stdout
      @stderr = stderr
      @argv = argv.dup
      @strategy = nil
      @file_path = nil
      @log = STDOUT
      @log_level = Logger::INFO
      @concurrency = WaybackArchiver.config.concurrency
      @limit = WaybackArchiver.config.max_limit
      @hosts = []
      @options = {}
      @show_summary = true
      @report_path = nil
      @session_path = nil
      @no_session = false
      @resume_path = nil
      @check_mode = false
      @status_mode = false
      @skip_archived = false
      @skip_archived_within = nil

      parse_options!
    end

    def run
      return run_status if @status_mode

      validate!
      read_urls
      setup_logger
      @strategy ||= 'auto'

      return run_check if @check_mode

      setup_session
      install_signal_handler

      results = run_archive
      write_report(results)
      cleanup_session(results)
      print_summary(results, @archive_start_time) if @show_summary
    ensure
      @session&.close
    end

    private

    def parse_options!
      @optparse = build_option_parser
      @optparse.parse!(@argv)
    end

    def build_option_parser
      OptionParser.new do |parser|
        parser.banner = 'Usage: wayback_archiver [<url>] [options]'

        parser.separator ''
        parser.separator 'Strategy options:'

        parser.on('--auto', 'Auto (default)') { @strategy = 'auto' }
        parser.on('--crawl', 'Crawl') { @strategy = 'crawl' }
        parser.on('--sitemap', 'Sitemap') { @strategy = 'sitemap' }
        parser.on('--urls', '--url', 'URL(s)') { @strategy = 'urls' }
        parser.on('--rss', 'RSS/Atom feed') { @strategy = 'rss' }

        parser.on('--hosts=[example.com]', Array, 'Only spider links on certain hosts') do |value|
          if value
            @hosts = value.map do |v|
              Regexp.new(v)
            rescue RegexpError => e
              raise ArgumentError, "Invalid host pattern '#{v}': #{e.message}"
            end
          end
        end

        parser.on('--concurrency=N', Integer, 'Concurrency (default: 4)') do |value|
          raise ArgumentError, "Concurrency must be > 0, got #{value}" unless value > 0

          @concurrency = value
        end

        parser.on('--limit=N', Integer, 'Max number of URLs to archive') do |value|
          raise ArgumentError, "Limit must be -1 (unlimited) or > 0, got #{value}" unless value == -1 || value > 0

          @limit = value
        end

        parser.separator ''
        parser.separator 'Authentication (get keys at https://archive.org/account/s3.php):'

        parser.on('--access-key=KEY', String, 'Internet Archive S3 access key') do |value|
          WaybackArchiver.config.access_key = value
        end

        parser.on('--secret-key=KEY', String, 'Internet Archive S3 secret key') do |value|
          WaybackArchiver.config.secret_key = value
        end

        parser.separator ''
        parser.separator 'SPN2 capture options:'

        parser.on('--capture-all', 'Capture error pages (HTTP 4xx/5xx)') { @options[:capture_all] = true }
        parser.on('--capture-outlinks', 'Auto-capture linked pages (up to 100, requires auth)') { @options[:capture_outlinks] = true }
        parser.on('--capture-screenshot', 'Generate PNG screenshot of the page') { @options[:capture_screenshot] = true }

        parser.on('--screenshot-dir=PATH', String, 'Save screenshots locally (requires auth + --capture-screenshot)') do |value|
          @options[:screenshot_dir] = value
        end

        parser.on('--force-get', 'Force HTTP GET instead of HEAD+browser') { @options[:force_get] = true }
        parser.on('--skip-first-archive', 'Skip initial duplicate check (faster)') { @options[:skip_first_archive] = true }
        parser.on('--delay-wb-availability', 'Delay public availability ~12h') { @options[:delay_wb_availability] = true }

        parser.on('--if-not-archived-within=TIMEDELTA', String,
                 'Skip if recent snapshot exists (server-side).',
                 'Format: "3d 5h 20m", "7d", or seconds e.g. "120"') do |value|
          @options[:if_not_archived_within] = value
        end

        parser.on('--js-behavior-timeout=N', Integer, 'Run JS for N seconds after page load (0 to skip, max 30)') do |value|
          raise ArgumentError, "js-behavior-timeout must be between 0 and 30, got #{value}" unless value.between?(0, 30)

          @options[:js_behavior_timeout] = value
        end

        parser.on('--use-user-agent=AGENT', String, 'Custom User-Agent for target page') do |value|
          @options[:use_user_agent] = value
        end

        parser.on('--outlinks-availability', 'Return last-capture timestamp for outlinks') { @options[:outlinks_availability] = true }

        parser.separator ''
        parser.separator 'Check options:'

        parser.on('--check', 'Check which URLs are already archived (does not archive)') { @check_mode = true }

        parser.on('--skip-archived[=TIMEDELTA]', String,
                  'Skip URLs already in the Wayback Machine (client-side CDX check).',
                  'Optional: time window, e.g. "7d", "3d 5h 20m"') do |value|
          @skip_archived = true
          @skip_archived_within = value
        end

        parser.separator ''
        parser.separator 'Filter options:'

        parser.on('--include-ext=pdf,doc', Array, 'Only archive URLs with these extensions') do |value|
          @options[:include_ext] = value
        end

        parser.on('--exclude-ext=zip,png', Array, 'Skip URLs with these extensions') do |value|
          @options[:exclude_ext] = value
        end

        parser.separator ''
        parser.separator 'Input options:'

        parser.on('-f', '--file=PATH', String, 'Read URLs from file (one per line, "-" for stdin)') do |value|
          @file_path = value
        end

        parser.separator ''
        parser.separator 'Session options:'

        parser.on('--session=PATH', String, 'Write session file to PATH (default: auto-generated in /tmp)') do |value|
          @session_path = value
        end

        parser.on('--no-session', 'Disable session file') { @no_session = true }

        parser.on('--resume=PATH', String, 'Resume from a previous session file') do |value|
          @resume_path = value
        end

        parser.separator ''
        parser.separator 'General options:'

        parser.on('--log=output.log', String, 'Path to desired log file (defaults to STDOUT)') do |path|
          @log = path
        end

        parser.on('--[no-]verbose', 'Verbose logs') do |value|
          @log_level = value ? Logger::DEBUG : Logger::WARN
        end

        parser.on('--quiet', 'Suppress all log output') { @log_level = Logger::FATAL }

        parser.on('--[no-]summary', 'Print summary after archiving (default: true)') do |value|
          @show_summary = value
        end

        parser.on('--report=PATH', String, 'Write report to file (CSV or JSON, detected from extension)') do |value|
          @report_path = value
        end

        parser.on('--status', 'Show SPN2 system and user status, then exit') { @status_mode = true }

        parser.on_tail('-h', '--help', 'Show this message') do
          @stdout.puts parser
          exit
        end

        parser.on_tail('--version', 'Show version') do
          @stdout.puts "WaybackArchiver version #{WaybackArchiver::VERSION}"
          exit
        end
      end
    end

    def validate!
      if @check_mode && @skip_archived
        raise ArgumentError, "--check and --skip-archived are mutually exclusive"
      end

      @no_session = true if @check_mode

      if @resume_path && @session_path
        raise ArgumentError, "--resume and --session are mutually exclusive"
      end

      if @resume_path && @no_session
        raise ArgumentError, "--resume and --no-session are mutually exclusive"
      end

      if @resume_path && !File.exist?(@resume_path)
        raise ArgumentError, "Session file not found: #{@resume_path}"
      end
    end

    def read_urls
      @urls = @argv.map(&:strip).reject(&:empty?)

      if @file_path
        lines = if @file_path == '-'
                  $stdin.readlines
                else
                  begin
                    File.readlines(@file_path)
                  rescue Errno::ENOENT
                    raise ArgumentError, "File not found: #{@file_path}"
                  rescue Errno::EACCES
                    raise ArgumentError, "File not readable: #{@file_path}"
                  end
                end

        file_urls = lines
          .map(&:strip)
          .reject(&:empty?)
          .reject { |line| line.start_with?('#') }

        @urls.concat(file_urls)
        @urls.uniq!

        @strategy ||= 'urls'
      end

      if @urls.empty?
        @stdout.puts @optparse.help
        raise ArgumentError, "[<url>] or --file is required"
      end
    end

    def setup_logger
      WaybackArchiver.config.logger = Logger.new(@log).tap do |logger|
        logger.progname = 'WaybackArchiver'
        logger.level = @log_level
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

      unless @no_session
        if @resume_path
          @session = SessionFile.new(@resume_path)
          WaybackArchiver.logger.info("Resuming from session: #{@session.path}")
        elsif @session_path
          @session = SessionFile.new(@session_path)
          WaybackArchiver.logger.info("Session file: #{@session.path}")
        else
          @session = SessionFile.new(SessionFile.auto_path)
          @auto_generated_session = true
          WaybackArchiver.logger.info("Session file: #{@session.path}")
        end
      end

      @skip_urls = @session&.completed_urls
      if @resume_path && @skip_urls&.any?
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
      all_urls = @urls.flat_map do |url|
        WaybackArchiver.discover_urls(url, strategy: @strategy, hosts: @hosts, limit: @limit)
      end

      WaybackArchiver.logger.info("Checking #{all_urls.length} URL(s) against the Wayback Machine")
      check_results = WaybackArchiver.check(all_urls, concurrency: @concurrency)
      check_results.sort_by!(&:url)

      check_results.each do |r|
        if r.archived?
          @stdout.puts "  \u2713 #{r.url}  #{r.captured_at}  #{r.wayback_url}"
        else
          @stdout.puts "  \u2717 #{r.url}  (not archived)"
        end
      end

      write_report(check_results)

      if @show_summary
        archived_count = check_results.count(&:archived?)
        not_archived_count = check_results.length - archived_count
        @stdout.puts "\n#{archived_count} archived, #{not_archived_count} not archived (#{check_results.length} total)"
      end

      exit(0)
    end

    def run_archive
      all_results = []

      if @skip_archived
        skipped, extra_skip_urls = skip_archived_urls
        all_results.concat(skipped)
        @skip_urls ||= Set.new
        @skip_urls.merge(extra_skip_urls) if extra_skip_urls
      end

      WaybackArchiver.logger.info("wayback_archiver v#{WaybackArchiver::VERSION} | strategy: #{@strategy} | concurrency: #{@concurrency}")
      WaybackArchiver.config.listener = CLIListener.new(@stdout)
      @archive_start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      all_results.concat(@urls.flat_map do |url|
        WaybackArchiver.archive(
          url,
          hosts: @hosts,
          strategy: @strategy,
          concurrency: @concurrency,
          limit: @limit,
          skip_urls: @skip_urls,
          **@options
        ) do |result|
          @session&.write_result(result)
        end
      end)

      all_results
    end

    def skip_archived_urls
      urls_to_check = @urls.flat_map do |url|
        WaybackArchiver.discover_urls(url, strategy: @strategy, hosts: @hosts, limit: @limit)
      end

      urls_to_check = urls_to_check.reject { |u| @skip_urls&.include?(u) } if @skip_urls

      WaybackArchiver.logger.info("Checking #{urls_to_check.length} URL(s) against the Wayback Machine")
      check_results = WaybackArchiver.check(urls_to_check, concurrency: @concurrency)
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

    def write_report(results)
      return unless @report_path

      require 'wayback_archiver/report'
      Report.write(results, @report_path)
      WaybackArchiver.logger.info("Report written to #{@report_path}")
    end

    def cleanup_session(results)
      return unless @session

      if results.any?(&:errored?)
        @stderr.puts "Some URLs failed. Resume with:"
        @stderr.puts "  #{resume_command}"
      elsif @auto_generated_session
        @session.delete!
        @session = nil
      end
    end

    def print_summary(results, archive_start_time)
      tally = { succeeded: 0, submitted: 0, cached: 0, skipped: 0, failed: 0, errors: {} }
      results.each do |r|
        if r.errored?
          tally[:failed] += 1
          cat = r.error_category
          tally[:errors][cat] = (tally[:errors][cat] || 0) + 1
        elsif r.submitted?
          tally[:submitted] += 1
        elsif r.cached?
          tally[:cached] += 1
        elsif r.skipped?
          tally[:skipped] += 1
        else
          tally[:succeeded] += 1
        end
      end
      total = results.length

      @stdout.puts "\n--- Summary ---"
      breakdown = ""
      if tally[:failed] > 0
        parts = []
        parts << "#{tally[:errors][:transient]} transient" if tally[:errors][:transient]
        parts << "#{tally[:errors][:daily_limit]} daily limit" if tally[:errors][:daily_limit]
        parts << "#{tally[:errors][:permanent]} permanent" if tally[:errors][:permanent]
        parts << "#{tally[:errors][nil]} uncategorized" if tally[:errors][nil]
        breakdown = " (#{parts.join(', ')})" if parts.any?
      end
      line = "Total: #{total}  Succeeded: #{tally[:succeeded]}  Failed: #{tally[:failed]}#{breakdown}"
      line << "  Submitted: #{tally[:submitted]}" if tally[:submitted] > 0
      line << "  Cached: #{tally[:cached]}" if tally[:cached] > 0
      line << "  Skipped: #{tally[:skipped]}" if tally[:skipped] > 0
      @stdout.puts line

      wall_time = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - archive_start_time).round(1)
      rate = wall_time > 0 ? (total * 60.0 / wall_time).round(0) : 0
      @stdout.puts "Duration: #{wall_time}s (#{rate} URLs/min)"
    end

    def resume_command
      @resume_command ||= build_resume_command
    end

    def build_resume_command
      parts = ['wayback_archiver']
      if @file_path
        parts << "--file=#{Shellwords.shellescape(@file_path)}"
      else
        @urls.each { |u| parts << Shellwords.shellescape(u) }
      end
      parts << "--resume=#{Shellwords.shellescape(@session.path)}"
      parts << "--#{@strategy}"
      parts << "--concurrency=#{@concurrency}" if @concurrency != DEFAULT_CONCURRENCY
      parts << "--limit=#{@limit}" if @limit != DEFAULT_MAX_LIMIT
      @hosts.each { |h| parts << "--hosts=#{Shellwords.shellescape(h.source)}" } if @hosts.any?
      @options.each do |key, value|
        flag = key.to_s.tr('_', '-')
        if value == true
          parts << "--#{flag}"
        elsif value.is_a?(Array)
          parts << "--#{flag}=#{value.join(',')}"
        elsif value
          parts << "--#{flag}=#{value}"
        end
      end
      parts.join(' ')
    end

    def install_signal_handler
      return unless @session

      cmd = resume_command
      stderr = @stderr

      Signal.trap('INT') do
        stderr.puts "\nInterrupted. Resume with:"
        stderr.puts "  #{cmd}"
        exit(1)
      end
    end
  end
end
