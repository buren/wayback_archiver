require 'spec_helper'
require 'stringio'
require 'wayback_archiver/cli/summary'
require 'wayback_archiver/cli/option_parser'

RSpec.describe WaybackArchiver::CLI::Summary do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:summary) { described_class.new(stdout: stdout, stderr: stderr) }

  def stdout_output
    stdout.string
  end

  def stderr_output
    stderr.string
  end

  describe '#print_summary' do
    it 'tallies results correctly' do
      results = [
        WaybackArchiver::ArchiveResult.new('http://a.com', timestamp: '20240101000000'),
        WaybackArchiver::ArchiveResult.new('http://b.com', status_ext: 'error:blocked-url'),
        WaybackArchiver::ArchiveResult.new('http://c.com', status_ext: 'cached'),
        WaybackArchiver::ArchiveResult.new('http://d.com', status_ext: 'skipped:already-archived'),
      ]

      summary.print_summary(results, Time.now.to_f)

      expect(stdout_output).to include('Succeeded: 1')
      expect(stdout_output).to include('Failed: 1')
      expect(stdout_output).to include('Cached: 1')
      expect(stdout_output).to include('Skipped: 1')
      expect(stdout_output).to include('Total: 4')
    end

    it 'shows submitted count when present' do
      results = [
        WaybackArchiver::ArchiveResult.new('http://a.com', job_id: 'j1', status_ext: 'submitted'),
      ]

      summary.print_summary(results, Process.clock_gettime(Process::CLOCK_MONOTONIC))

      expect(stdout_output).to include('Submitted: 1')
    end

    it 'shows error breakdown by category' do
      results = [
        WaybackArchiver::ArchiveResult.new('http://a.com', status_ext: 'error:too-many-requests'),
        WaybackArchiver::ArchiveResult.new('http://b.com', status_ext: 'error:too-many-daily-captures'),
        WaybackArchiver::ArchiveResult.new('http://c.com', status_ext: 'error:blocked-url'),
      ]

      summary.print_summary(results, Process.clock_gettime(Process::CLOCK_MONOTONIC))

      expect(stdout_output).to include('transient')
      expect(stdout_output).to include('daily limit')
      expect(stdout_output).to include('permanent')
    end

    it 'formats duration as seconds for short runs' do
      results = [WaybackArchiver::ArchiveResult.new('http://a.com', timestamp: '20240101000000')]
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 42.0
      summary.print_summary(results, start)

      expect(stdout_output).to include('Duration: 42s')
    end

    it 'formats duration as minutes and seconds' do
      results = [WaybackArchiver::ArchiveResult.new('http://a.com', timestamp: '20240101000000')]
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 754.0
      summary.print_summary(results, start)

      expect(stdout_output).to include('Duration: 12m 34s')
    end

    it 'formats duration as hours, minutes, and seconds' do
      results = [WaybackArchiver::ArchiveResult.new('http://a.com', timestamp: '20240101000000')]
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 5025.0
      summary.print_summary(results, start)

      expect(stdout_output).to include('Duration: 1h 23m 45s')
    end

    it 'clamps sub-second durations to 1s' do
      results = [WaybackArchiver::ArchiveResult.new('http://a.com', timestamp: '20240101000000')]
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 0.1
      summary.print_summary(results, start)

      expect(stdout_output).to include('Duration: 1s')
    end

    it 'shows URLs/min rate' do
      results = [WaybackArchiver::ArchiveResult.new('http://a.com', timestamp: '20240101000000')]
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 120.0
      summary.print_summary(results, start)

      expect(stdout_output).to include('URLs/min')
    end

    it 'shows duplicates skipped count when present' do
      results = [WaybackArchiver::ArchiveResult.new('http://a.com', timestamp: '20240101000000')]
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      summary.print_summary(results, start, duplicates_skipped: 42)

      expect(stdout_output).to include('Duplicates skipped: 42')
    end

    it 'omits duplicates skipped when zero' do
      results = [WaybackArchiver::ArchiveResult.new('http://a.com', timestamp: '20240101000000')]
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      summary.print_summary(results, start, duplicates_skipped: 0)

      expect(stdout_output).not_to include('Duplicates skipped')
    end
  end

  describe '#build_resume_command' do
    def build_options(**overrides)
      WaybackArchiver::CLI::Options.new(
        strategy: 'auto',
        file_path: nil,
        concurrency: WaybackArchiver::DEFAULT_CONCURRENCY,
        limit: WaybackArchiver::DEFAULT_MAX_LIMIT,
        hosts: [],
        spn2_options: {},
        urls: ['http://example.com'],
        **overrides
      )
    end

    it 'includes strategy, URLs, and session path' do
      opts = build_options(strategy: 'crawl', concurrency: 8)
      session = instance_double(WaybackArchiver::SessionFile, path: '/tmp/session.jsonl')

      cmd = summary.build_resume_command(opts, session)

      expect(cmd).to include('wayback_archiver')
      expect(cmd).to include('http://example.com')
      expect(cmd).to include('--resume=/tmp/session.jsonl')
      expect(cmd).to include('--crawl')
      expect(cmd).to include('--concurrency=8')
    end

    it 'includes --file when file_path was used' do
      opts = build_options(strategy: 'crawl', file_path: '/tmp/urls.txt')
      session = instance_double(WaybackArchiver::SessionFile, path: '/tmp/session.jsonl')

      cmd = summary.build_resume_command(opts, session)

      expect(cmd).to include('--file=/tmp/urls.txt')
      expect(cmd).not_to include('http://example.com')
    end

    it 'includes boolean SPN2 options' do
      opts = build_options(strategy: 'urls', spn2_options: { capture_all: true })
      session = instance_double(WaybackArchiver::SessionFile, path: '/tmp/session.jsonl')

      cmd = summary.build_resume_command(opts, session)

      expect(cmd).to include('--capture-all')
    end

    it 'includes array SPN2 options' do
      opts = build_options(strategy: 'urls', spn2_options: { include_ext: %w[pdf doc] })
      session = instance_double(WaybackArchiver::SessionFile, path: '/tmp/session.jsonl')

      cmd = summary.build_resume_command(opts, session)

      expect(cmd).to include('--include-ext=pdf,doc')
    end

    it 'includes scalar SPN2 options' do
      opts = build_options(strategy: 'urls', spn2_options: { js_behavior_timeout: 10 })
      session = instance_double(WaybackArchiver::SessionFile, path: '/tmp/session.jsonl')

      cmd = summary.build_resume_command(opts, session)

      expect(cmd).to include('--js-behavior-timeout=10')
    end

    # Regression: SPN2 option values were the only unescaped values in the
    # resume command — pasting a command with --if-not-archived-within='3d 5h
    # 20m' fed '5h' and '20m' to the shell as positional URL arguments.
    it 'shell-escapes SPN2 option values' do
      opts = build_options(strategy: 'urls', spn2_options: {
                             if_not_archived_within: '3d 5h 20m',
                             use_user_agent: 'Mozilla/5.0 (X11; Linux)'
                           })
      session = instance_double(WaybackArchiver::SessionFile, path: '/tmp/session.jsonl')

      cmd = summary.build_resume_command(opts, session)

      tokens = Shellwords.split(cmd)
      expect(tokens).to include('--if-not-archived-within=3d 5h 20m')
      expect(tokens).to include('--use-user-agent=Mozilla/5.0 (X11; Linux)')
    end

    it 'round-trips the report path' do
      opts = build_options(strategy: 'urls', report_path: '/tmp/out.csv')
      session = instance_double(WaybackArchiver::SessionFile, path: '/tmp/session.jsonl')

      cmd = summary.build_resume_command(opts, session)

      expect(cmd).to include('--report=/tmp/out.csv')
    end

    it 'round-trips skip patterns by source, one flag per pattern' do
      # One flag per pattern: a comma-joined list would corrupt patterns that
      # themselves contain commas (e.g. {2,4} quantifiers) on re-parse.
      opts = build_options(strategy: 'urls', skip_patterns: [/hs_amp=true/, /page\d{2,4}/])
      session = instance_double(WaybackArchiver::SessionFile, path: '/tmp/session.jsonl')

      cmd = summary.build_resume_command(opts, session)

      expect(cmd).to include('--skip-patterns=hs_amp\=true')
      expect(cmd).to include('--skip-patterns=page\\\\d\{2,4\}')
    end

    it 'emits --no-skip-duplicates only when explicitly disabled' do
      session = instance_double(WaybackArchiver::SessionFile, path: '/tmp/session.jsonl')

      disabled = summary.build_resume_command(build_options(skip_duplicates: false), session)
      default = summary.build_resume_command(build_options, session)

      expect(disabled).to include('--no-skip-duplicates')
      expect(default).not_to include('skip-duplicates')
    end

    it 'round-trips --skip-archived with and without a window' do
      session = instance_double(WaybackArchiver::SessionFile, path: '/tmp/session.jsonl')

      windowed = summary.build_resume_command(
        build_options(skip_archived: true, skip_archived_within: '7d'), session
      )
      bare = summary.build_resume_command(build_options(skip_archived: true), session)

      expect(windowed).to include('--skip-archived=7d')
      expect(bare).to include('--skip-archived')
      expect(bare).not_to include('--skip-archived=')
    end

    it 'round-trips verbosity from the log level' do
      session = instance_double(WaybackArchiver::SessionFile, path: '/tmp/session.jsonl')

      verbose = summary.build_resume_command(build_options(log_level: Logger::DEBUG), session)
      quiet = summary.build_resume_command(build_options(log_level: Logger::FATAL), session)
      default = summary.build_resume_command(build_options(log_level: Logger::INFO), session)

      expect(verbose).to include('--verbose')
      expect(quiet).to include('--quiet')
      expect(default).not_to match(/--verbose|--quiet/)
    end

    it 'round-trips a log file path' do
      opts = build_options(log: '/tmp/run.log')
      session = instance_double(WaybackArchiver::SessionFile, path: '/tmp/session.jsonl')

      cmd = summary.build_resume_command(opts, session)

      expect(cmd).to include('--log=/tmp/run.log')
    end
  end

  describe '#print_resume_message' do
    it 'prints resume command to stderr' do
      summary.print_resume_message('wayback_archiver --resume=/tmp/session.jsonl')

      expect(stderr_output).to include('Some URLs failed')
      expect(stderr_output).to include('Resume with:')
      expect(stderr_output).to include('wayback_archiver --resume=/tmp/session.jsonl')
    end
  end

  describe '#startup_banner' do
    it 'includes version and strategy' do
      opts = WaybackArchiver::CLI::Options.new(
        strategy: 'crawl',
        concurrency: 4,
        limit: WaybackArchiver::DEFAULT_MAX_LIMIT,
        hosts: [],
        skip_archived: false
      )

      banner = summary.startup_banner(opts)

      expect(banner).to include("wayback_archiver v#{WaybackArchiver::VERSION}")
      expect(banner).to include('strategy: crawl')
    end
  end
end
