require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'wayback_archiver/cli'

RSpec.describe WaybackArchiver::CLI do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  def stdout_output
    stdout.string
  end

  def stderr_output
    stderr.string
  end

  def build_cli(*args)
    described_class.new(args, stdout: stdout, stderr: stderr)
  end

  # The archive path now fails fast without credentials; archive-path examples
  # stub WaybackArchiver.archive, so give them credentials to get past preflight.
  before do
    WaybackArchiver.config.access_key = 'test-access'
    WaybackArchiver.config.secret_key = 'test-secret'
  end

  describe '.run' do
    it 'creates an instance and calls run' do
      expect_any_instance_of(described_class).to receive(:run).and_call_original
      allow(WaybackArchiver).to receive(:archive).and_return([])
      expect do
        described_class.run(['--urls', '--no-session', '--no-summary', 'http://example.com'], stdout: stdout, stderr: stderr)
      end.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    end

    it 'exits 1 when one or more URLs failed' do
      failed = [WaybackArchiver::ArchiveResult.new('http://example.com', error: StandardError.new('fail'))]
      allow(WaybackArchiver).to receive(:archive).and_return(failed)
      expect do
        described_class.run(['--urls', '--no-session', '--no-summary', 'http://example.com'], stdout: stdout, stderr: stderr)
      end.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it 'reports rejected credentials cleanly with exit 3' do
      allow(WaybackArchiver).to receive(:archive)
        .and_raise(WaybackArchiver::AuthenticationError, 'credentials rejected')

      expect do
        described_class.run(['--urls', '--no-session', '--no-summary', 'http://example.com'],
                            stdout: stdout, stderr: stderr)
      end.to raise_error(SystemExit) { |e| expect(e.status).to eq(3) }

      expect(stderr_output).to include('wayback_archiver: credentials rejected')
    end
  end

  describe 'credentials preflight' do
    it 'exits before archiving when credentials are missing' do
      WaybackArchiver.config.access_key = nil
      WaybackArchiver.config.secret_key = nil
      allow(WaybackArchiver).to receive(:archive)

      cli = build_cli('--urls', '--no-session', '--no-summary', 'http://example.com')
      expect { cli.run }.to raise_error(SystemExit) { |e| expect(e.status).to eq(3) }

      expect(stderr_output).to include('credentials required')
      expect(WaybackArchiver).not_to have_received(:archive)
    end
  end

  describe 'status mode' do
    it 'prints system and user status' do
      allow(WaybackArchiver::WaybackMachine).to receive(:system_status)
        .and_return({ 'status' => 'ok' })
      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status)
        .and_return({ 'available' => 10, 'processing' => 2, 'daily_captures' => 50, 'daily_captures_limit' => 300 })

      cli = build_cli('--status')
      expect { cli.run }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      expect(stdout_output).to include('System: ok')
      expect(stdout_output).to include('Available: 10')
      expect(stdout_output).to include('Processing: 2')
      expect(stdout_output).to include('Daily captures: 50/300')
    end

    it 'handles missing credentials' do
      allow(WaybackArchiver::WaybackMachine).to receive(:system_status)
        .and_return({ 'status' => 'ok' })
      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status)
        .and_raise(WaybackArchiver::AuthenticationError)

      cli = build_cli('--status')
      expect { cli.run }.to raise_error(SystemExit)

      expect(stdout_output).to include('credentials required')
    end

    it 'handles system status error gracefully' do
      allow(WaybackArchiver::WaybackMachine).to receive(:system_status)
        .and_raise(StandardError.new('connection refused'))
      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status)
        .and_return({ 'available' => 10, 'processing' => 2 })

      cli = build_cli('--status')
      expect { cli.run }.to raise_error(SystemExit)

      expect(stdout_output).to include('unreachable')
      expect(stdout_output).to include('connection refused')
    end

    it 'handles user status error gracefully' do
      allow(WaybackArchiver::WaybackMachine).to receive(:system_status)
        .and_return({ 'status' => 'ok' })
      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status)
        .and_raise(StandardError.new('network error'))

      cli = build_cli('--status')
      expect { cli.run }.to raise_error(SystemExit)

      expect(stdout_output).to include('System: ok')
      expect(stdout_output).to include('unreachable')
    end

    it 'omits daily captures when not present' do
      allow(WaybackArchiver::WaybackMachine).to receive(:system_status)
        .and_return({ 'status' => 'ok' })
      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status)
        .and_return({ 'available' => 5, 'processing' => 1 })

      cli = build_cli('--status')
      expect { cli.run }.to raise_error(SystemExit)

      expect(stdout_output).to include('Available: 5')
      expect(stdout_output).not_to include('Daily captures:')
    end
  end

  describe 'list-urls mode' do
    it 'prints discovered URLs one per line' do
      allow(WaybackArchiver).to receive(:discover_urls)
        .and_return(%w[http://a.com http://b.com http://c.com])

      cli = build_cli('--list-urls', '--no-summary', '--sitemap', 'http://example.com')
      expect { cli.run }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      lines = stdout_output.strip.split("\n")
      expect(lines).to eq(%w[http://a.com http://b.com http://c.com])
    end

    it 'prints summary when enabled' do
      allow(WaybackArchiver).to receive(:discover_urls).and_return(%w[http://a.com http://b.com])

      cli = build_cli('--list-urls', '--sitemap', 'http://example.com')
      expect { cli.run }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      expect(stdout_output).to include('2 URL(s) discovered')
    end

    it 'applies --skip-patterns filter' do
      allow(WaybackArchiver).to receive(:discover_urls)
        .and_return(%w[http://example.com http://example.com/page?hs_amp=true])

      cli = build_cli('--list-urls', '--no-summary', '--skip-patterns=hs_amp=true', '--sitemap', 'http://example.com')
      expect { cli.run }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      lines = stdout_output.strip.split("\n")
      expect(lines).to eq(%w[http://example.com])
    end

    it 'applies --include-ext filter' do
      allow(WaybackArchiver).to receive(:discover_urls)
        .and_return(%w[http://example.com/doc.pdf http://example.com/image.png])

      cli = build_cli('--list-urls', '--no-summary', '--include-ext=pdf', '--sitemap', 'http://example.com')
      expect { cli.run }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      lines = stdout_output.strip.split("\n")
      expect(lines).to eq(%w[http://example.com/doc.pdf])
    end

    it 'applies --exclude-ext filter' do
      allow(WaybackArchiver).to receive(:discover_urls)
        .and_return(%w[http://example.com/doc.pdf http://example.com/image.png])

      cli = build_cli('--list-urls', '--no-summary', '--exclude-ext=png', '--sitemap', 'http://example.com')
      expect { cli.run }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      lines = stdout_output.strip.split("\n")
      expect(lines).to eq(%w[http://example.com/doc.pdf])
    end

    # Regression: routing every discovery through limit: -1 to make --limit a
    # command-wide cap also stopped the crawler from halting early, so
    # `--list-urls --crawl --limit 10` walked an entire site to print 10 URLs.
    # When nothing downstream can reduce the count, the budget is safe to push
    # into discovery.
    it 'stops discovery at the limit for a single unfiltered source' do
      allow(WaybackArchiver).to receive(:discover_urls).and_return(%w[a b c])

      cli = build_cli('--list-urls', '--no-summary', '--crawl', '--limit=3', 'http://one.example')
      expect { cli.run }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      expect(WaybackArchiver).to have_received(:discover_urls).with(
        anything, strategy: 'crawl', hosts: [], limit: 3
      )
    end

    it 'still discovers everything when a filter could reduce the count' do
      allow(WaybackArchiver).to receive(:discover_urls).and_return(%w[a b c])

      cli = build_cli('--list-urls', '--no-summary', '--crawl', '--limit=3',
                      '--exclude-ext=png', 'http://one.example')
      expect { cli.run }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      expect(WaybackArchiver).to have_received(:discover_urls).with(
        anything, strategy: 'crawl', hosts: [], limit: -1
      )
    end

    it 'deduplicates sources and applies --limit globally after filtering' do
      allow(WaybackArchiver).to receive(:discover_urls) do |source, **|
        if source.include?('one')
          %w[http://example.com/a http://example.com/image.png http://example.com/shared]
        else
          %w[http://example.com/shared http://example.com/b]
        end
      end

      cli = build_cli('--list-urls', '--no-summary', '--sitemap', '--exclude-ext=png',
                      '--limit=2', 'http://one.example', 'http://two.example')
      expect { cli.run }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      expect(stdout_output.lines.map(&:chomp))
        .to eq(%w[http://example.com/a http://example.com/shared])
      expect(WaybackArchiver).to have_received(:discover_urls).twice.with(
        anything, strategy: 'sitemap', hosts: [], limit: -1
      )
    end

    it 'suppresses log output by default' do
      allow(WaybackArchiver).to receive(:discover_urls).and_return(%w[http://a.com])

      cli = build_cli('--list-urls', '--no-summary', '--sitemap', 'http://example.com')
      expect { cli.run }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      expect(stdout_output).to eq("http://a.com\n")
    end

    it 'defaults to auto strategy' do
      allow(WaybackArchiver).to receive(:discover_urls).and_return(%w[http://a.com])

      cli = build_cli('--list-urls', '--no-summary', 'http://example.com')
      expect { cli.run }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      expect(WaybackArchiver).to have_received(:discover_urls).with(
        'http://example.com',
        strategy: 'auto',
        hosts: [],
        limit: -1
      )
    end
  end

  describe 'discovery failure' do
    # Discovery network errors now propagate from the sitemap/rss strategy
    # entry points (they used to be swallowed into []); the CLI must turn
    # them into a clean one-line error, not a raw backtrace.
    it 'reports a clean error and exits 4 when discovery raises' do
      allow(WaybackArchiver).to receive(:archive)
        .and_raise(WaybackArchiver::Request::ServerError.new('Errno::ECONNREFUSED, Connection refused'))

      expect do
        described_class.run(['--sitemap', '--no-session', '--no-summary', 'http://example.com'],
                            stdout: stdout, stderr: stderr)
      end.to raise_error(SystemExit) { |e| expect(e.status).to eq(4) }

      expect(stderr_output).to include('wayback_archiver: Errno::ECONNREFUSED, Connection refused')
    end
  end

  describe 'skip-archived mode' do
    # Regression: --skip-archived=TIMEDELTA parsed the window but never used
    # it — the CDX check ran without from:, so anything EVER archived was
    # skipped instead of anything archived within the window.
    it 'passes the parsed time window through to the CDX check' do
      require 'time'
      allow(WaybackArchiver).to receive(:discover_urls).and_return(%w[http://example.com/page])
      allow(WaybackArchiver).to receive(:check).and_return([])
      allow(WaybackArchiver).to receive(:archive).and_return([])

      cli = build_cli('--skip-archived=7d', '--no-session', '--no-summary', '--sitemap', 'http://example.com')
      expect { cli.run }.not_to raise_error

      expect(WaybackArchiver).to have_received(:check) do |urls, concurrency:, from:|
        expect(urls).to eq(%w[http://example.com/page])
        expect(from).to match(/\A\d{14}\z/)
        # CDX timestamps are UTC, not local time.
        cutoff = Time.strptime("#{from} UTC", '%Y%m%d%H%M%S %Z')
        expect(cutoff).to be_within(60).of(Time.now - (7 * 86_400))
      end
    end

    # Regression: after the CDX pass, run_archive re-resolved the original
    # strategy — with crawl/auto the entire site was crawled a second time.
    # Discovery must happen once; the remaining URLs are archived directly.
    it 'discovers once and archives the remaining URLs directly' do
      allow(WaybackArchiver).to receive(:discover_urls)
        .and_return(%w[http://example.com/a http://example.com/b])
      allow(WaybackArchiver).to receive(:check).and_return([
        WaybackArchiver::CheckResult.new('http://example.com/a', archived: true, timestamp: '20260101000000'),
        WaybackArchiver::CheckResult.new('http://example.com/b', archived: false)
      ])
      allow(WaybackArchiver).to receive(:archive).and_return([])

      cli = build_cli('--skip-archived', '--no-session', '--no-summary', '--crawl', 'http://example.com')
      expect { cli.run }.not_to raise_error

      expect(WaybackArchiver).to have_received(:discover_urls).once
      expect(WaybackArchiver).to have_received(:archive)
        .with(%w[http://example.com/b], hash_including(strategy: 'urls'))
    end

    it 'applies --limit after removing already-archived URLs' do
      urls = %w[http://example.com/old http://example.com/new]
      allow(WaybackArchiver).to receive(:discover_urls).and_return(urls)
      allow(WaybackArchiver).to receive(:check).and_return([
        WaybackArchiver::CheckResult.new(urls[0], archived: true, timestamp: '20260101000000'),
        WaybackArchiver::CheckResult.new(urls[1], archived: false)
      ])
      allow(WaybackArchiver).to receive(:archive).and_return([])

      cli = build_cli('--skip-archived', '--limit=1', '--no-session', '--no-summary',
                      '--sitemap', 'http://example.com')
      cli.run

      expect(WaybackArchiver).to have_received(:discover_urls).with(
        'http://example.com', strategy: 'sitemap', hosts: [], limit: -1
      )
      expect(WaybackArchiver).to have_received(:archive)
        .with(%w[http://example.com/new], hash_including(strategy: 'urls', limit: 1))
    end

    it 'checks without a window when --skip-archived has no value' do
      allow(WaybackArchiver).to receive(:discover_urls).and_return(%w[http://example.com/page])
      allow(WaybackArchiver).to receive(:check).and_return([])
      allow(WaybackArchiver).to receive(:archive).and_return([])

      cli = build_cli('--skip-archived', '--no-session', '--no-summary', '--sitemap', 'http://example.com')
      expect { cli.run }.not_to raise_error

      expect(WaybackArchiver).to have_received(:check) do |_urls, concurrency:, from:|
        expect(from).to be_nil
      end
    end
  end

  describe '#setup_logger' do
    it 'creates a logger at the configured level' do
      cli = build_cli('--verbose', '--urls', '--no-session', '--no-summary', 'http://example.com')
      allow(WaybackArchiver).to receive(:archive).and_return([])
      cli.run

      logger = WaybackArchiver.config.logger
      expect(logger).to be_a(Logger)
      expect(logger.level).to eq(Logger::DEBUG)
    end
  end

  describe '#setup_session' do
    it 'creates auto-generated session when no flags given' do
      cli = build_cli('--urls', '--no-summary', 'http://example.com')
      results = [WaybackArchiver::ArchiveResult.new('http://example.com', timestamp: '20240101000000')]
      allow(WaybackArchiver).to receive(:archive).and_return(results)

      cli.run

      expect(cli.instance_variable_get(:@auto_generated_session)).to eq(true)
      expect(cli.instance_variable_get(:@session)).to be_nil
    end

    it 'creates session at custom path with --session' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'custom.jsonl')
        cli = build_cli('--urls', '--no-summary', "--session=#{path}", 'http://example.com')
        allow(WaybackArchiver).to receive(:archive).and_return([])
        cli.run

        session = cli.instance_variable_get(:@session)
        expect(session.path).to eq(path)
        expect(cli.instance_variable_get(:@auto_generated_session)).to eq(false)
        session.delete!
      end
    end

    it 'resumes from existing session file' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'session.jsonl')
        File.write(path, '{"url":"http://done.com","success":true,"submitted":false}' + "\n")
        cli = build_cli('--urls', '--no-summary', "--resume=#{path}", 'http://example.com')
        allow(WaybackArchiver).to receive(:archive).and_return([])
        cli.run

        skip_urls = cli.instance_variable_get(:@skip_urls)
        expect(skip_urls).to include('http://done.com')
      end
    end

    it 'sets no session with --no-session' do
      cli = build_cli('--urls', '--no-summary', '--no-session', 'http://example.com')
      allow(WaybackArchiver).to receive(:archive).and_return([])
      cli.run

      expect(cli.instance_variable_get(:@session)).to be_nil
    end
  end

  describe '#cleanup_session' do
    it 'deletes auto-generated session when all results succeed' do
      cli = build_cli('--urls', '--no-summary', 'http://example.com')

      results = [WaybackArchiver::ArchiveResult.new('http://example.com', timestamp: '20240101000000')]
      allow(WaybackArchiver).to receive(:archive).and_return(results)
      cli.run

      expect(cli.instance_variable_get(:@auto_generated_session)).to eq(true)
      expect(cli.instance_variable_get(:@session)).to be_nil
    end

    it 'keeps session and prints resume command when results have errors' do
      Dir.mktmpdir do |dir|
        session_path = File.join(dir, 'session.jsonl')
        cli = build_cli('--urls', '--no-summary', "--session=#{session_path}", 'http://example.com')

        results = [WaybackArchiver::ArchiveResult.new('http://example.com', error: StandardError.new('fail'))]
        allow(WaybackArchiver).to receive(:archive).and_return(results)
        cli.run

        expect(File.exist?(session_path)).to eq(true)
        expect(stderr_output).to include('Resume with:')
      end
    end
  end

  describe '#write_report' do
    it 'writes a report progressively when --report is set' do
      Dir.mktmpdir do |dir|
        report_path = File.join(dir, 'report.json')
        cli = build_cli('--urls', '--no-session', '--no-summary', "--report=#{report_path}", 'http://example.com')

        result = WaybackArchiver::ArchiveResult.new('http://example.com', timestamp: '20240101000000')
        allow(WaybackArchiver).to receive(:archive).and_yield(result).and_return([result])
        cli.run

        expect(File.exist?(report_path)).to eq(true)
        data = JSON.parse(File.read(report_path))
        expect(data.length).to eq(1)
        expect(data.first['url']).to eq('http://example.com')
      end
    end

    it 'preserves existing report entries when resuming' do
      Dir.mktmpdir do |dir|
        report_path = File.join(dir, 'report.json')
        session_path = File.join(dir, 'session.jsonl')
        old_result = WaybackArchiver::ArchiveResult.new('http://old.example', timestamp: '20240101000000')
        WaybackArchiver::Report.write([old_result], report_path)
        File.write(session_path, JSON.generate(url: old_result.uri, success: true, submitted: false) + "\n")

        cli = build_cli('--urls', '--no-summary', "--resume=#{session_path}",
                        "--report=#{report_path}", 'http://old.example', 'http://new.example')
        new_result = WaybackArchiver::ArchiveResult.new('http://new.example', timestamp: '20240102000000')
        allow(WaybackArchiver).to receive(:archive).and_yield(new_result).and_return([new_result])

        cli.run

        expect(JSON.parse(File.read(report_path)).map { |entry| entry['url'] })
          .to eq(%w[http://old.example http://new.example])
      end
    end

    it 'does nothing when --report is not set' do
      cli = build_cli('--urls', '--no-session', '--no-summary', 'http://example.com')
      results = [WaybackArchiver::ArchiveResult.new('http://example.com', timestamp: '20240101000000')]
      allow(WaybackArchiver).to receive(:archive).and_return(results)

      expect { cli.run }.not_to raise_error
    end
  end

  describe '#run_archive' do
    it 'passes options through to WaybackArchiver.archive' do
      cli = build_cli('--urls', '--no-session', '--no-summary', '--capture-all', '--force-get', 'http://example.com')
      allow(WaybackArchiver).to receive(:archive).and_return([])

      cli.run

      expect(WaybackArchiver).to have_received(:archive).with(
        ['http://example.com'],
        hash_including(
          strategy: 'urls',
          capture_all: true,
          force_get: true
        )
      )
    end

    it 'passes all urls in one call for urls strategy' do
      cli = build_cli('--urls', '--no-session', '--no-summary', 'http://a.com', 'http://b.com', 'http://c.com')
      allow(WaybackArchiver).to receive(:archive).and_return([])

      cli.run

      expect(WaybackArchiver).to have_received(:archive).once.with(
        ['http://a.com', 'http://b.com', 'http://c.com'],
        hash_including(strategy: 'urls')
      )
    end

    it 'applies the limit across multiple discovery sources' do
      cli = build_cli('--sitemap', '--no-session', '--no-summary', '--limit=3',
                      'http://one.example/sitemap.xml', 'http://two.example/sitemap.xml')
      calls = []
      allow(WaybackArchiver).to receive(:archive) do |source, **options|
        calls << [source, options[:limit], options[:skip_urls].dup]
        if source.include?('one')
          %w[http://shared.example http://one.example/page].map do |url|
            WaybackArchiver::ArchiveResult.new(url, timestamp: '20240101000000')
          end
        else
          [WaybackArchiver::ArchiveResult.new('http://two.example/page', timestamp: '20240101000000')]
        end
      end

      cli.run

      expect(calls.map { |call| call[1] }).to eq([3, 1])
      expect(calls.last[2]).to include('http://shared.example', 'http://one.example/page')
    end

    it 'yields results to session writer' do
      Dir.mktmpdir do |dir|
        session_path = File.join(dir, 'session.jsonl')
        cli = build_cli('--urls', '--no-summary', "--session=#{session_path}", 'http://example.com')

        result = WaybackArchiver::ArchiveResult.new('http://example.com', timestamp: '20240101000000')
        allow(WaybackArchiver).to receive(:archive).and_yield(result).and_return([result])
        cli.run

        lines = File.readlines(session_path)
        expect(lines.length).to eq(1)
        data = JSON.parse(lines.first)
        expect(data['url']).to eq('http://example.com')
      end
    end

    # Regression: in TTY mode, the sticky progress footer was cleared in the
    # ensure block AFTER print_summary had already written below it. The
    # CURSOR_UP/CLEAR_LINE escapes that clear_footer emits would then erase the
    # bottom of the summary instead of the footer.
    it 'clears the progress footer before printing the summary (TTY mode)' do
      allow(stdout).to receive(:tty?).and_return(true)

      result = WaybackArchiver::ArchiveResult.new('http://example.com', timestamp: '20240101000000')
      allow(WaybackArchiver).to receive(:archive) do |*, **|
        listener = WaybackArchiver.listener
        listener.on_batch_start(total: 1)
        listener.on_progress(captured: 0, failed: 0, pending: 1)
        listener.on_completed(result: result)
        [result]
      end

      cli = build_cli('--urls', '--no-session', 'http://example.com')
      cli.run

      out = stdout_output
      summary_idx = out.index('--- Summary ---')
      expect(summary_idx).not_to be_nil, 'summary header should appear in output'
      # After the summary header, no CURSOR_UP escapes should follow — they
      # would mean we are about to clobber the summary we just printed.
      expect(out[summary_idx..]).not_to match(/\e\[A/),
        "found CURSOR_UP escape after summary — clear_footer is erasing summary lines.\nTail:\n#{out[summary_idx..].inspect}"
    end
  end

  describe WaybackArchiver::CLI::FooterAwareOutput do
    let(:io) { StringIO.new }
    let(:output) { described_class.new(io) }

    it 'writes directly to IO when no renderer is set' do
      output.write("hello\n")
      expect(io.string).to eq("hello\n")
    end

    it 'routes through renderer when one is set' do
      renderer = instance_double(WaybackArchiver::CLI::ProgressRenderer)
      expect(renderer).to receive(:print_above).with("WARN: error\n")

      output.renderer = renderer
      output.write("WARN: error\n")
    end

    it 'reverts to direct IO when renderer is cleared' do
      renderer = instance_double(WaybackArchiver::CLI::ProgressRenderer)
      output.renderer = renderer
      output.renderer = nil
      output.write("direct\n")

      expect(io.string).to eq("direct\n")
    end
  end

  describe '#install_signal_handler' do
    it 'does nothing without a session' do
      cli = build_cli('--no-session', '--no-summary', '--urls', 'http://example.com')
      allow(WaybackArchiver).to receive(:archive).and_return([])

      expect(Signal).not_to receive(:trap)
      cli.run
    end

    # Regression: the trap wrote CLEAR_FOOTER (3x cursor-up + clear-line)
    # whenever stdout was a TTY, even when the sticky footer had never been
    # drawn — Ctrl-C during the discovery phase erased 3 lines of real
    # terminal output above the cursor.
    it 'does not emit cursor-up escapes when the footer was never drawn' do
      require 'tmpdir'
      Dir.mktmpdir do |dir|
        handler = nil
        allow(Signal).to receive(:trap) { |_sig, &blk| handler = blk }
        allow(stdout).to receive(:tty?).and_return(true)
        # Archive without ever firing on_batch_start — footer never drawn
        # (simulates Ctrl-C during discovery).
        allow(WaybackArchiver).to receive(:archive).and_return([])

        cli = build_cli('--urls', '--no-summary', "--session=#{File.join(dir, 's.jsonl')}", 'http://example.com')
        cli.run
        expect(handler).not_to be_nil

        stdout.string = +'' # only capture trap output
        expect { handler.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(130) }

        expect(stdout_output).not_to include("\e[A"),
          "trap emitted CURSOR_UP escapes with no footer drawn:\n#{stdout_output.inspect}"
        expect(stderr_output).to include('Resume with:')
      end
    end
  end

  describe WaybackArchiver::CLIListener do
    describe 'non-TTY mode' do
      let(:listener) { described_class.new(stdout) }

      describe '#on_resolved' do
        it 'prints strategy and URL count' do
          listener.on_resolved(strategy: :sitemap, url_count: 42, source: 'http://example.com')
          expect(stdout_output).to include('sitemap')
          expect(stdout_output).to include('42 URLs')
        end

        it 'prints discovering when url_count is nil' do
          listener.on_resolved(strategy: :crawl, url_count: nil, source: 'http://example.com')
          expect(stdout_output).to include('discovering URLs...')
        end
      end

      describe '#on_completed' do
        it 'prints result with counter' do
          result = WaybackArchiver::ArchiveResult.new('http://example.com', timestamp: '20240101000000')
          listener.on_completed(result: result)

          expect(stdout_output).to include('[1]')
          expect(stdout_output).to include('http://example.com')
        end

        it 'increments counter across calls' do
          result1 = WaybackArchiver::ArchiveResult.new('http://a.com', timestamp: '20240101000000')
          result2 = WaybackArchiver::ArchiveResult.new('http://b.com', timestamp: '20240101000000')
          listener.on_completed(result: result1)
          listener.on_completed(result: result2)

          expect(stdout_output).to include('[1]')
          expect(stdout_output).to include('[2]')
        end

        # Regression: the counter padding was computed as ' ' * (4 - n.to_s.length),
        # which raises ArgumentError (negative argument) once n reaches 10000 —
        # crashing runs archiving >= 10k URLs at the moment of the 10000th result.
        it 'handles 5+ digit counters without raising' do
          result = WaybackArchiver::ArchiveResult.new('http://example.com', timestamp: '20240101000000')
          listener.instance_variable_set(:@completed_count, 9_999)

          expect { listener.on_completed(result: result) }.not_to raise_error
          expect(stdout_output).to include('[10000]')
        end
      end

      describe '#on_progress' do
        it 'does not print anything' do
          listener.on_progress(captured: 5, failed: 0, pending: 3)
          expect(stdout_output).to eq('')
        end
      end

      describe '#on_waiting_for_slots' do
        it 'does not print anything' do
          listener.on_waiting_for_slots(processing: 7)
          expect(stdout_output).to eq('')
        end
      end
    end

    describe 'TTY mode' do
      let(:listener) { described_class.new(stdout, tty: true) }

      def clean_output
        stdout_output.gsub(/\e\[[0-9;]*[A-Za-z]/, '')
      end

      it 'renders progress footer after on_batch_start' do
        listener.on_batch_start(total: 100)

        expect(clean_output).to include('0/100')
        expect(clean_output).to include(WaybackArchiver::CLI::ProgressRenderer::STATE_SUBMITTING)
      end

      it 'prints completed URL above footer' do
        listener.on_batch_start(total: 10)
        result = WaybackArchiver::ArchiveResult.new('http://example.com', timestamp: '20240101000000')
        listener.on_completed(result: result)

        expect(clean_output).to include('[1]')
        expect(clean_output).to include('http://example.com')
        expect(clean_output).to include('1/10')
      end

      it 'updates pending count on progress' do
        listener.on_batch_start(total: 10)
        listener.on_progress(captured: 2, failed: 0, pending: 5)

        expect(clean_output).to include('5 pending')
        expect(clean_output).to include(WaybackArchiver::CLI::ProgressRenderer::STATE_CAPTURING)
      end

      it 'shows waiting state' do
        listener.on_batch_start(total: 10)
        listener.on_waiting_for_slots(processing: 7)

        expect(clean_output).to include(WaybackArchiver::CLI::ProgressRenderer::STATE_WAITING)
      end

      it 'clears footer on finish' do
        listener.on_batch_start(total: 10)
        listener.finish

        expect(stdout_output).to include("\e[A")
      end

      it 'starts in indeterminate mode when total is nil' do
        listener.on_batch_start(total: nil)

        expect(clean_output).not_to include('/')
        expect(clean_output).not_to include('%')
      end

      it 'updates discovered count on on_url_discovered' do
        listener.on_batch_start(total: nil)
        listener.on_url_discovered(url: 'http://example.com', count: 1)
        listener.on_url_discovered(url: 'http://example.com/page2', count: 2)

        expect(clean_output).to include('2 discovered')
      end

      it 'switches to determinate mode on on_crawl_complete' do
        listener.on_batch_start(total: nil)
        3.times { |i| listener.on_url_discovered(url: "http://example.com/#{i}", count: i + 1) }
        listener.on_crawl_complete(url_count: 3)

        expect(clean_output).to include('0/3')
      end
    end
  end

  describe 'crawl failure' do
    # Regression: a crawler exception discarded every result already archived,
    # so a late network blip exited with no summary and no resume hint even
    # though the session file held the work.
    it 'reports the completed results, keeps the session and exits 4' do
      session_path = File.join(Dir.mktmpdir, 'session.jsonl')
      done = WaybackArchiver::ArchiveResult.new('http://example.com/a', timestamp: '20260326120000')

      allow(WaybackArchiver).to receive(:archive) do |*, **, &blk|
        blk&.call(done)
        raise WaybackArchiver::CrawlError.new(
          WaybackArchiver::Request::ServerError.new('network hiccup'), [done]
        )
      end

      cli = build_cli('--crawl', "--session=#{session_path}", 'http://example.com')
      expect(cli.run).to eq(4)

      expect(stdout_output).to include('Total: 1')
      expect(stderr_output).to include('crawl failed: network hiccup')
      expect(stderr_output).to include('Resume with:')
      expect(File.exist?(session_path)).to eq(true)
    end
  end
end
