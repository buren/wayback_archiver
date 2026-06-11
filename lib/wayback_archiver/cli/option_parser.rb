require 'optparse'
require 'wayback_archiver'

module WaybackArchiver
  class CLI
    Options = Struct.new(
      :strategy, :file_path, :log, :log_level, :concurrency, :limit,
      :hosts, :spn2_options, :show_summary, :report_path,
      :session_path, :no_session, :resume_path,
      :check_mode, :status_mode, :list_mode, :skip_archived, :skip_archived_within,
      :skip_duplicates, :skip_patterns,
      :urls,
      keyword_init: true
    )

    # @api private
    class OptionParser
      def initialize(argv, stdout:)
        @argv = argv.dup
        @stdout = stdout
      end

      # Parse command-line arguments into an Options struct.
      # Raises ArgumentError for invalid input.
      # May call exit (--help, --version, --status).
      def parse!
        @opts = default_options
        @optparse = build_option_parser
        @optparse.parse!(@argv)

        return @opts if @opts.status_mode

        validate!
        read_urls!

        @opts
      end

      private

      # Split a comma-separated pattern list and compile each part to a Regexp.
      # Commas inside {} or [] are kept, so quantifiers like {2,4} and
      # character classes survive — OptionParser's Array type splits blindly.
      def parse_patterns(value, label)
        split_outside_groups(value).map do |v|
          Regexp.new(v)
        rescue RegexpError => e
          raise ArgumentError, "Invalid #{label} '#{v}': #{e.message}"
        end
      end

      def split_outside_groups(value)
        parts = []
        buf = +''
        depth = 0
        value.each_char do |ch|
          case ch
          when '{', '[' then depth += 1
          when '}', ']' then depth -= 1 if depth.positive?
          when ','
            if depth.zero?
              parts << buf
              buf = +''
              next
            end
          end
          buf << ch
        end
        parts << buf
        parts.reject(&:empty?)
      end

      def default_options
        Options.new(
          strategy: nil,
          file_path: nil,
          log: @stdout,
          log_level: Logger::INFO,
          concurrency: WaybackArchiver.config.concurrency,
          limit: WaybackArchiver.config.max_limit,
          hosts: [],
          spn2_options: {},
          show_summary: true,
          report_path: nil,
          session_path: nil,
          no_session: false,
          resume_path: nil,
          check_mode: false,
          status_mode: false,
          list_mode: false,
          skip_archived: false,
          skip_archived_within: nil,
          urls: []
        )
      end

      def build_option_parser
        opts = @opts

        ::OptionParser.new do |parser|
          parser.banner = 'Usage: wayback_archiver [<url>] [options]'

          parser.separator ''
          parser.separator 'Strategy options:'

          parser.on('--auto', 'Auto (default)') { opts.strategy = 'auto' }
          parser.on('--crawl', 'Crawl') { opts.strategy = 'crawl' }
          parser.on('--sitemap', 'Sitemap') { opts.strategy = 'sitemap' }
          parser.on('--urls', '--url', 'URL(s)') { opts.strategy = 'urls' }
          parser.on('--rss', 'RSS/Atom feed') { opts.strategy = 'rss' }

          parser.on('--hosts=[example.com]', String, 'Only spider links on certain hosts (comma-separated, repeatable)') do |value|
            if value
              opts.hosts.concat(parse_patterns(value, 'host pattern'))
            end
          end

          parser.on('--concurrency=N', Integer, 'Concurrency (default: 4)') do |value|
            raise ArgumentError, "Concurrency must be > 0, got #{value}" unless value > 0

            opts.concurrency = value
          end

          parser.on('--limit=N', Integer, 'Max number of URLs to archive') do |value|
            raise ArgumentError, "Limit must be -1 (unlimited) or > 0, got #{value}" unless value == -1 || value > 0

            opts.limit = value
          end

          parser.separator ''
          parser.separator 'Authentication (get keys at https://archive.org/account/s3.php):'
          parser.separator '  Preferred: set WAYBACK_ACCESS_KEY and WAYBACK_SECRET_KEY env vars'
          parser.separator '  (IA_S3_ACCESS_KEY / IA_S3_SECRET_KEY are also accepted)'

          parser.on('--access-key=KEY', String, 'Internet Archive S3 access key') do |value|
            WaybackArchiver.config.access_key = value
          end

          parser.on('--secret-key=KEY', String, 'Internet Archive S3 secret key') do |value|
            WaybackArchiver.config.secret_key = value
          end

          parser.separator ''
          parser.separator 'SPN2 capture options:'

          parser.on('--capture-all', 'Capture error pages (HTTP 4xx/5xx)') { opts.spn2_options[:capture_all] = true }
          parser.on('--capture-outlinks', 'Auto-capture linked pages (up to 100, requires auth)') { opts.spn2_options[:capture_outlinks] = true }
          parser.on('--capture-screenshot', 'Generate PNG screenshot of the page') { opts.spn2_options[:capture_screenshot] = true }

          parser.on('--screenshot-dir=PATH', String, 'Save screenshots locally (requires auth + --capture-screenshot)') do |value|
            opts.spn2_options[:screenshot_dir] = value
          end

          parser.on('--force-get', 'Force HTTP GET instead of HEAD+browser') { opts.spn2_options[:force_get] = true }
          parser.on('--skip-first-archive', 'Skip initial duplicate check (faster)') { opts.spn2_options[:skip_first_archive] = true }
          parser.on('--delay-wb-availability', 'Delay public availability ~12h') { opts.spn2_options[:delay_wb_availability] = true }

          parser.on('--if-not-archived-within=TIMEDELTA', String,
                   'Skip if recent snapshot exists (server-side).',
                   'Format: "3d 5h 20m", "7d", or seconds e.g. "120"') do |value|
            opts.spn2_options[:if_not_archived_within] = value
          end

          parser.on('--js-behavior-timeout=N', Integer, 'Run JS for N seconds after page load (0 to skip, max 30)') do |value|
            raise ArgumentError, "js-behavior-timeout must be between 0 and 30, got #{value}" unless value.between?(0, 30)

            opts.spn2_options[:js_behavior_timeout] = value
          end

          parser.on('--use-user-agent=AGENT', String, 'Custom User-Agent for target page') do |value|
            opts.spn2_options[:use_user_agent] = value
          end

          parser.on('--outlinks-availability', 'Return last-capture timestamp for outlinks') { opts.spn2_options[:outlinks_availability] = true }

          parser.separator ''
          parser.separator 'Check options:'

          parser.on('--check', 'Check which URLs are already archived (does not archive)') { opts.check_mode = true }
          parser.on('--list-urls', 'Discover URLs and print them (does not archive)') { opts.list_mode = true }

          parser.on('--skip-archived[=TIMEDELTA]', String,
                    'Skip URLs already in the Wayback Machine (client-side CDX check).',
                    'Optional: time window, e.g. "7d", "3d 5h 20m"') do |value|
            opts.skip_archived = true
            opts.skip_archived_within = value
          end

          parser.separator ''
          parser.separator 'Filter options:'

          parser.on('--include-ext=pdf,doc', Array, 'Only archive URLs with these extensions') do |value|
            opts.spn2_options[:include_ext] = value
          end

          parser.on('--exclude-ext=zip,png', Array, 'Skip URLs with these extensions') do |value|
            opts.spn2_options[:exclude_ext] = value
          end

          parser.on('--skip-patterns=PATTERN', String, 'Skip URLs matching regex pattern(s) (comma-separated, repeatable)') do |value|
            opts.skip_patterns = (opts.skip_patterns || []) + parse_patterns(value, 'skip pattern')
          end

          parser.separator ''
          parser.separator 'Input options:'

          parser.on('-f', '--file=PATH', String, 'Read URLs from file (one per line, "-" for stdin)') do |value|
            opts.file_path = value
          end

          parser.separator ''
          parser.separator 'Session options:'

          parser.on('--session=PATH', String, 'Write session file to PATH (default: auto-generated in /tmp)') do |value|
            opts.session_path = value
          end

          parser.on('--no-session', 'Disable session file') { opts.no_session = true }

          parser.on('--resume=PATH', String, 'Resume from a previous session file') do |value|
            opts.resume_path = value
          end

          parser.separator ''
          parser.separator 'General options:'

          parser.on('--log=output.log', String, 'Path to desired log file (defaults to STDOUT)') do |path|
            opts.log = path
          end

          parser.on('--[no-]verbose', 'Verbose logs') do |value|
            opts.log_level = value ? Logger::DEBUG : Logger::WARN
          end

          parser.on('--quiet', 'Suppress all log output') { opts.log_level = Logger::FATAL }

          parser.on('--[no-]summary', 'Print summary after archiving (default: true)') do |value|
            opts.show_summary = value
          end

          parser.on('--[no-]skip-duplicates', 'Skip URLs with duplicate page content (default: true)') do |value|
            opts.skip_duplicates = value
          end

          parser.on('--report=PATH', String, 'Write report to file (.csv, .json, or .jsonl)') do |value|
            ext = File.extname(value).downcase
            unless %w[.csv .json .jsonl].include?(ext)
              raise ArgumentError, "Unsupported report format: '#{value}'. Use .csv, .json, or .jsonl"
            end

            opts.report_path = value
          end

          parser.on('--status', 'Show SPN2 system and user status, then exit') { opts.status_mode = true }

          stdout = @stdout
          parser.on_tail('-h', '--help', 'Show this message') do
            stdout.puts parser
            exit
          end

          parser.on_tail('--version', 'Show version') do
            stdout.puts "WaybackArchiver version #{WaybackArchiver::VERSION}"
            exit
          end
        end
      end

      def validate!
        if @opts.spn2_options[:screenshot_dir] && !@opts.spn2_options[:capture_screenshot]
          raise ArgumentError, "--screenshot-dir requires --capture-screenshot"
        end

        if @opts.check_mode && @opts.skip_archived
          raise ArgumentError, "--check and --skip-archived are mutually exclusive"
        end

        if @opts.list_mode && @opts.check_mode
          raise ArgumentError, "--list-urls and --check are mutually exclusive"
        end

        if @opts.list_mode && @opts.skip_archived
          raise ArgumentError, "--list-urls and --skip-archived are mutually exclusive"
        end

        @opts.no_session = true if @opts.check_mode
        @opts.no_session = true if @opts.list_mode

        if @opts.resume_path && @opts.session_path
          raise ArgumentError, "--resume and --session are mutually exclusive"
        end

        if @opts.resume_path && @opts.no_session
          raise ArgumentError, "--resume and --no-session are mutually exclusive"
        end

        if @opts.resume_path && !File.exist?(@opts.resume_path)
          raise ArgumentError, "Session file not found: #{@opts.resume_path}"
        end
      end

      def read_urls!
        @opts.urls = @argv.map(&:strip).reject(&:empty?)

        if @opts.file_path
          lines = if @opts.file_path == '-'
                    $stdin.readlines
                  else
                    begin
                      File.readlines(@opts.file_path)
                    rescue Errno::ENOENT
                      raise ArgumentError, "File not found: #{@opts.file_path}"
                    rescue Errno::EACCES
                      raise ArgumentError, "File not readable: #{@opts.file_path}"
                    end
                  end

          file_urls = lines
            .map(&:strip)
            .reject(&:empty?)
            .reject { |line| line.start_with?('#') }

          @opts.urls.concat(file_urls)
          @opts.urls.uniq!

          @opts.strategy ||= 'urls'
        end

        if @opts.urls.empty?
          @stdout.puts @optparse.help
          raise ArgumentError, "[<url>] or --file is required"
        end
      end
    end
  end
end
